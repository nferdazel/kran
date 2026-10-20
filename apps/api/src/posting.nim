## Konsumen outbox → jurnal `ledger` (T-074).
##
## Composition root: modul `ledger` tetap murni (domain saja); pengambilan/kunci outbox, inbox,
## dan pengulangan ada di sini. Alur per event:
##
##   claimBatch (IN_FLIGHT) → transaksi: claimInbox → resolve posting rule → tulis jurnal → markDone
##   gagal → rollback transaksi event itu, lalu markFailed (backoff/DEAD) di koneksi terpisah.
##
## Idempotensi berlapis: `platform.inbox (consumer, event_id)` mencegah event yang sama diproses dua
## kali, dan `journal.idempotency_key = "outbox:<eventId>"` mencegah jurnal ganda bila inbox
## terhapus/terlewat. Event non-akuntansi (tanpa header `accounting: true`) = DONE tanpa jurnal;
## event akuntansi **tanpa rule** = gagal terlihat (`last_error`, lalu DEAD), bukan jurnal kosong.

import std/[json, os, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"

import kernel/[clock, ids, money, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/[event, scope]
import platform/infrastructure/[auth_service, inbox_repo, outbox_repo, param_repo]
import ledger/domain/[journal, period, posting]
import ledger/infrastructure/[journal_repo, posting_repo]

import ./context

const
  consumerName* = "ledger-postings"
  ## Aktor sistem untuk kolom `created_by` jurnal. Bukan akun manusia: tidak bisa login, dan
  ## jejak sebenarnya ada di `source_event`/`source_ref` + outbox.
  systemActor* = Id("00000000-0000-0000-0000-0000000000a1")

type
  PostingOutcome* = enum
    poPosted = "posted"
    poIgnored = "ignored"
    poDuplicate = "duplicate"

proc isAccounting(ev: OutboxEvent): bool =
  ## Penanda akuntansi harus **boolean**. Header yang ada tetapi salah tipe = kesalahan produsen
  ## (gagal terlihat), bukan diam-diam diabaikan (fail-closed).
  if ev.headers.isNil or ev.headers.kind != JObject or not ev.headers.hasKey("accounting"):
    return false
  if ev.headers["accounting"].kind != JBool:
    raise newException(ValueError, "header accounting harus boolean")
  ev.headers["accounting"].getBool()

proc requireString(node: JsonNode, field: string): string =
  if node.kind != JObject or not node.hasKey(field) or node[field].kind != JString or
      node[field].getStr().strip().len == 0:
    raise newException(ValueError, "payload." & field & " wajib berupa teks")
  node[field].getStr()

proc businessDateOf(db: DbConn, clock: Clock, payload: JsonNode): string =
  ## Tanggal bisnis event: dari payload bila ada (event bisa terlambat), selain itu tanggal bisnis
  ## institusi saat ini. Periode OPEN tetap diperiksa trigger DB.
  if payload.kind == JObject and payload.hasKey("businessDate"):
    return parseIsoDate(requireString(payload, "businessDate"), "payload.businessDate")
  businessDateFor(db, institutionScope(), businessDateIso(clock))

proc processEvent*(db: DbConn, clock: Clock, ev: OutboxEvent): PostingOutcome =
  ## Satu event, di dalam transaksi pemanggil. `ValueError` = event gagal (dipetakan markFailed).
  if not isAccounting(ev):
    return poIgnored
  if not claimInbox(db, consumerName, ev.eventId):
    return poDuplicate

  let amount = moneyOf(requireString(ev.payload, "amount"))
  let branchId = parseId(requireString(ev.payload, "branchId"))
  if branchId.isErr:
    raise newException(ValueError, "payload.branchId bukan uuid")
  let businessDate = businessDateOf(db, clock, ev.payload)

  let rule = selectRule(activeRules(db, ev.eventType, businessDate), ev.eventType, ev.payload)
  let lines = buildLines(rule, amount, branchId.value())
  let sourceRef = parseId(ev.aggregateId)
  if sourceRef.isErr:
    raise newException(ValueError, "aggregate_id event bukan uuid")

  let journal = Journal(
    journalId: newId(clock),
    businessDate: businessDate,
    valueDate: businessDate,
    sourceEvent: ev.eventType,
    sourceRef: sourceRef.value(),
    idempotencyKey: "outbox:" & $ev.eventId,
    reversalOf: "")
  discard insertJournal(db, journal, systemActor)
  for line in lines:
    insertJournalLine(db, journal.journalId, line)
  # Event turunan untuk konsumen lain/realtime. Tanpa header `accounting` supaya tidak loop ke
  # konsumen ini sendiri (spec §8.1: ledger mem-publish `journal.posted`).
  discard appendEvent(db, newOutboxEvent(newId(clock), "journal.posted", "journal",
    $journal.journalId, "journal.posted:" & $journal.journalId,
    %*{"journalId": $journal.journalId, "businessDate": businessDate,
       "sourceEvent": ev.eventType, "reversalOf": nil,
       "totalDebit": lines.totalDebit.toDecimalString}))
  poPosted

proc paramInt(db: DbConn, key: ParamKey[int64], asOf: string): int {.gcsafe.} =
  # `activeValueJson` tidak ditandai gcsafe (indirect call lewat resolver scope), sama seperti
  # pemanggilan parameter lain dari konteks HTTP; asumsi tanpa state bersama ditegaskan di sini.
  {.cast(gcsafe).}:
    let node = activeValueJson(db, keyString(key), asOf, lookupFor(institutionScope()))
    if node.kind != JInt:
      raise newException(ValueError, "parameter " & keyString(key) & " bukan integer")
    int(node.getBiggestInt())

proc processBatch*(app: AppContext, workerId: string, batchSize, maxAttempts,
                   backoffSeconds: int, leaseSeconds = 0): int =
  ## Mengklaim dan memproses sampai `batchSize` event. Mengembalikan jumlah event yang diklaim.
  ## `leaseSeconds > 0` merebut kembali event yang terdampar `IN_FLIGHT` (worker sebelumnya mati).
  let events = app.pool.withConn(proc(db: DbConn): seq[OutboxEvent] {.gcsafe.} =
    claimBatch(db, workerId, batchSize, leaseSeconds))
  for i in 0 ..< events.len:
    let ev = events[i]
    if ev.attempts > maxAttempts:
      # Klaim berulang tanpa pernah selesai (mis. fault non-Catchable/OOM). Paksa DEAD supaya
      # tidak menahan event sesudahnya selamanya (review T-074 putaran 2).
      discard app.pool.withConn(proc(db: DbConn): int {.gcsafe.} =
        markFailed(db, ev.eventId, "percobaan klaim melebihi batas; event tidak selesai",
                   backoffSeconds, maxAttempts)
        1)
      stderr.writeLine "kran-worker: event " & $ev.eventId & " melewati batas percobaan"
      continue
    try:
      let outcome = app.pool.withTx(proc(db: DbConn): PostingOutcome {.gcsafe.} =
        let outcome = processEvent(db, app.clock, ev)
        markDone(db, ev.eventId)
        outcome)
      if outcome == poPosted:
        stderr.writeLine "kran-worker: jurnal diposting untuk event " & $ev.eventId
    except CatchableError as e:
      let message = e.msg
      if "journal_idempotency_uq" in message:
        # Inbox terhapus/terlewat tetapi jurnalnya sudah ada: bukan kegagalan, tandai selesai.
        discard app.pool.withConn(proc(db: DbConn): int {.gcsafe.} =
          markDone(db, ev.eventId)
          1)
        stderr.writeLine "kran-worker: event " & $ev.eventId & " sudah pernah diposting"
      else:
        # Koneksi transaksi sudah di-ROLLBACK; kegagalan dicatat di koneksi terpisah.
        discard app.pool.withConn(proc(db: DbConn): int {.gcsafe.} =
          markFailed(db, ev.eventId, message, backoffSeconds, maxAttempts)
          1)
        stderr.writeLine "kran-worker: event " & $ev.eventId & " gagal: " & message
  events.len

proc runWorker*(): int =
  ## Loop worker `ledger`. Batas dari parameter DB (fail-fast bila belum tersemai): lebih baik
  ## menolak start daripada memakai angka yang bukan konfigurasi institusi.
  if not databaseUrlSet(envTableFromProcess()):
    stderr.writeLine "kran-worker: KRAN_DATABASE_URL kosong — worker tidak bisa berjalan"
    return 2
  let clock = systemClock()
  let pool = newDbPool(dbConfigFromProcessEnv())
  var app = AppContext(version: "worker", role: "worker", startedAt: epochTime(),
    pool: pool, clock: clock)
  var batchSize, maxAttempts, backoffSeconds, pollMs, leaseSeconds: int
  try:
    let asOf = businessDateIso(clock)
    discard pool.withConn(proc(db: DbConn): int {.gcsafe.} =
      batchSize = paramInt(db, P_ledger_posting_batch_size, asOf)
      maxAttempts = paramInt(db, P_ledger_posting_max_attempts, asOf)
      backoffSeconds = paramInt(db, P_ledger_posting_retry_backoff_seconds, asOf)
      pollMs = paramInt(db, P_ledger_posting_poll_interval_ms, asOf)
      leaseSeconds = paramInt(db, P_ledger_posting_lease_seconds, asOf)
      1)
  except DbError as e:
    # DB belum siap/jaringan: transien. Keluar 1 supaya systemd mengulang.
    stderr.writeLine "kran-worker: database tidak terbaca: " & e.msg
    return 1
  except ValueError as e:
    # Parameter belum tersemai / salah tipe: permanen sampai diperbaiki. Keluar 2 (tidak di-restart).
    stderr.writeLine "kran-worker: parameter posting tidak terbaca: " & e.msg
    return 2

  # Identitas per proses hanya untuk jejak (`locked_by`). Jaminan anti-rebut datang dari **lease**,
  # bukan dari identitas ini: di container pid selalu 1, jadi replika tidak bisa dibedakan.
  let workerId = "kran-worker:" & $getCurrentProcessId()
  stderr.writeLine "kran-worker: mulai (" & workerId & ", batch=" & $batchSize &
    ", maxAttempts=" & $maxAttempts & ", backoff=" & $backoffSeconds & "s, lease=" &
    $leaseSeconds & "s, poll=" & $pollMs & "ms)"
  while true:
    let claimed = processBatch(app, workerId, batchSize, maxAttempts, backoffSeconds,
      leaseSeconds)
    if claimed == 0:
      sleep(pollMs)
