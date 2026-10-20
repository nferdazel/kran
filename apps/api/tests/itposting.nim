## Test integrasi konsumen posting (T-074) — butuh `KRAN_DATABASE_URL`.
##
## Membuktikan: event akuntansi → tepat satu jurnal; pengiriman ulang tidak menambah jurnal;
## event tanpa rule gagal **terlihat** (last_error/DEAD); event non-akuntansi diabaikan;
## periode tertutup membuat event gagal, bukan jurnal setengah jadi.

import std/[json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids, money]
import ledger/domain/[journal, period]
import ledger/infrastructure/[journal_repo, ledger_repo, posting_repo]
import platform/domain/event
import platform/infrastructure/[inbox_repo, outbox_repo]
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[context, posting]

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itposting: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

# POSTING_HARNESS_RESET
resetTestSchemas(db, ".")
discard applyMigrations(db, ".")
execScript(db, readFile("packs/base/generated/param_definitions.sql"))
execScript(db, readFile("packs/base/generated/param_values.sql"))

let
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")
  branch = "11111111-1111-7111-8111-111111111111"
  periodId = newId(testClock)

discard insertPeriod(db,
  Period(periodId: periodId, startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)

var app = AppContext(version: "itposting-0.0.0", role: "worker", startedAt: epochTime(),
                     pool: dbPool, clock: testClock)

proc accountingEvent(eventType = "DepositPosted", amount = "150.0000",
                     businessDate = "2026-10-15", accounting = true): Id =
  let ev = newOutboxEvent(
    newId(testClock), eventType, "deposit", "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa",
    "itposting:" & $newId(testClock),
    %*{"amount": amount, "branchId": branch, "product": "SAV",
       "businessDate": businessDate},
    headers = %*{"accounting": accounting})
  check appendEvent(db, ev)
  ev.eventId

proc statusOf(id: Id): string =
  db.getValue(sql"SELECT status FROM platform.outbox WHERE outbox_id = ?", $id)

proc lastErrorOf(id: Id): string =
  db.getValue(sql"SELECT coalesce(last_error, '') FROM platform.outbox WHERE outbox_id = ?",
    $id)

proc journalCount(eventType: string): int =
  journals(db, "", eventType).len

suite "posting: alur normal":
  test "event akuntansi → satu jurnal seimbang, outbox DONE, inbox tercatat":
    let eventId = accountingEvent()
    check processBatch(app, "test-worker", 10, 3, 0) >= 1
    check statusOf(eventId) == "DONE"
    check journalCount("DepositPosted") == 1
    check inboxSeen(db, consumerName, eventId)

    let j = journals(db, "2026-10-15", "DepositPosted")[0]
    let full = journalById(db, j.journalId).get()
    check full.lines.len == 2
    check full.businessDate == "2026-10-15"
    check full.idempotencyKey == "outbox:" & $eventId
    check full.lines[0].glAccount == "101"
    check full.lines[0].debit == money(150_0000)
    check full.lines[1].glAccount == "201"
    check full.lines[1].credit == money(150_0000)
    check full.lines.totalDebit == full.lines.totalCredit

    # Konsumen memancarkan `journal.posted` dalam transaksi yang sama (spec §8.1).
    check db.getValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'journal.posted' AND aggregate_id = ?""", $j.journalId) == "1"

  test "pengiriman ulang event yang sama tidak menambah jurnal":
    let eventId = accountingEvent(amount = "75.0000")
    discard processBatch(app, "test-worker", 10, 3, 0)
    check journalCount("DepositPosted") == 2

    # Simulasi redelivery (crash setelah commit): status dikembalikan ke PENDING.
    db.exec(sql"UPDATE platform.outbox SET status = 'PENDING' WHERE outbox_id = ?", $eventId)
    discard processBatch(app, "test-worker", 10, 3, 0)
    check journalCount("DepositPosted") == 2
    check statusOf(eventId) == "DONE"

  test "event non-akuntansi diabaikan (DONE tanpa jurnal)":
    let before = journals(db).len
    let eventId = accountingEvent(eventType = "PartyOnboarded", accounting = false)
    discard processBatch(app, "test-worker", 10, 3, 0)
    check statusOf(eventId) == "DONE"
    check journals(db).len == before

suite "posting: kegagalan terlihat":
  test "event akuntansi tanpa posting rule → PENDING + last_error, lalu DEAD":
    let eventId = accountingEvent(eventType = "UnknownPosted")
    discard processBatch(app, "test-worker", 10, 1, 0)
    check statusOf(eventId) == "DEAD"
    check lastErrorOf(eventId).contains("tidak ada posting rule")
    check journals(db, "", "UnknownPosted").len == 0

  test "periode tertutup → event gagal, tidak ada jurnal setengah jadi":
    let closedPeriod = newId(testClock)
    discard insertPeriod(db,
      Period(periodId: closedPeriod, startsOn: "2026-09-01", endsOn: "2026-09-30"), actor)
    discard closePeriod(db, closedPeriod, actor)
    let before = journalCount("FeeCharged")
    let eventId = accountingEvent(eventType = "FeeCharged", businessDate = "2026-09-15")
    discard processBatch(app, "test-worker", 10, 1, 0)
    check statusOf(eventId) == "DEAD"
    check lastErrorOf(eventId).contains("periode")
    check journalCount("FeeCharged") == before

suite "posting: retry, lease, dan header salah":
  test "kegagalan pertama PENDING + last_error, percobaan berikut DEAD":
    let eventId = accountingEvent(eventType = "RetryPosted")
    discard processBatch(app, "test-worker", 10, 2, 0)
    check statusOf(eventId) == "PENDING"
    check lastErrorOf(eventId).contains("tidak ada posting rule")
    # Backoff memundurkan available_at; paksa siap lalu proses lagi.
    db.exec(sql"UPDATE platform.outbox SET available_at = now() WHERE outbox_id = ?", $eventId)
    discard processBatch(app, "test-worker", 10, 2, 0)
    check statusOf(eventId) == "DEAD"

  test "event IN_FLIGHT yang terdampar direbut kembali lewat lease":
    let eventId = accountingEvent(amount = "10.0000")
    let first = dbPool.withConn(proc(d: DbConn): seq[OutboxEvent] {.gcsafe.} =
      claimBatch(d, "worker-mati", 50, 0))
    var claimed = false
    for ev in first:
      if ev.eventId == eventId:
        claimed = true
    check claimed
    # Worker "mati": locked_at lama. Claim berikutnya dengan lease harus mengambilnya kembali.
    db.exec(sql"""
      UPDATE platform.outbox SET locked_at = now() - make_interval(secs => 900)
       WHERE outbox_id = ?""", $eventId)
    let reclaimed = dbPool.withConn(proc(d: DbConn): seq[OutboxEvent] {.gcsafe.} =
      claimBatch(d, "worker-baru", 50, 300))
    var found = false
    for ev in reclaimed:
      if ev.eventId == eventId:
        found = true
        check ev.lockedBy == "worker-baru"
    check found

  test "header accounting salah tipe = gagal terlihat, bukan diabaikan":
    let ev = newOutboxEvent(newId(testClock), "DepositPosted", "deposit",
      "bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb", "itposting:bad-header:" & $newId(testClock),
      %*{"amount": "5.0000", "branchId": branch, "businessDate": "2026-10-15"},
      headers = %*{"accounting": "true"})
    check appendEvent(db, ev)
    discard processBatch(app, "test-worker", 10, 1, 0)
    check statusOf(ev.eventId) == "DEAD"
    check lastErrorOf(ev.eventId).contains("accounting harus boolean")
