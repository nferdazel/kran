## Test integrasi invarian kursor outbox (T-025; O-037) — butuh `KRAN_DATABASE_URL`.
##
## **Invarian**: transaksi yang menulis peristiwa outbox wajib menulis entri audit lebih dulu, di
## transaksi yang sama. Alasannya mekanis: `seq` outbox dialokasikan saat INSERT, sedangkan urutan
## commit bisa berbeda; trigger rantai audit memegang `pg_advisory_xact_lock(hashtext(
## 'platform.audit_log'))` **sampai commit**, sehingga penulis yang menulis audit terserialkan dan
## urutan commit mengikuti urutan `seq`. Pump realtime membaca tabel dengan kursor `seq`
## (`eventsAfter`), jadi bila urutan itu bisa terbalik, peristiwa yang commit belakangan akan
## **terlewat** selamanya — bukan sekadar tertunda.
##
## Dua bagian, sengaja dipisah:
##  1. **Invarian berlaku** (dua koneksi, dua thread): penulis kedua benar-benar menunggu commit
##     penulis pertama, dan `seq` penulis kedua lebih besar. Ini yang runtuh bila lock audit hilang.
##  2. **Karakterisasi bahaya**: bila aturan "audit lebih dulu" dilanggar, kursor `seq` melewatkan
##     peristiwa. Ini yang membuat invarian wajib, bukan sekadar konvensi gaya.
##
## Test ini **tidak** menghapus schema; ia menambah baris outbox dengan `dedup_key` unik.

import std/[atomics, json, os, strutils, times, unittest]

import db_connector/db_postgres
import db_connector/postgres # `pqtransactionStatus`/`PQTRANS_IDLE` (dipakai pool juga)

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[auditcontext, clock, ids]
import platform/domain/[audit, event]
import platform/infrastructure/[audit_repo, outbox_repo]

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itoutboxcursor: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
let sysClock = systemClock()
discard applyAllMigrations(db, ".")

var counter = 0

proc uniqueKey(prefix: string): string =
  inc counter
  prefix & ":" & $epochTime() & ":" & $counter

proc seqOf(db: DbConn, eventId: string): int64 =
  parseBiggestInt(db.getValue(
    sql"SELECT seq FROM platform.outbox WHERE outbox_id = ?::uuid", eventId))

proc auditEventFirst(db: DbConn, action, resourceId, key: string): OutboxEvent =
  ## Bentuk penulisan yang benar: **audit lebih dulu**, lalu event, dalam satu transaksi.
  let ctx = newAuditContext(newId(sysClock), sysClock)
  discard appendAudit(db, newAuditEntry(ctx, action, "param_value", resourceId, sysClock,
    after = %*{"resource": resourceId}))
  result = newOutboxEvent(newId(sysClock), "param.changed", "param_value", resourceId,
    uniqueKey("kursor"), %*{"key": key})
  check appendEvent(db, result)

# ---------------------------------------------------------------------------------------------
# 1. Invarian berlaku antar dua koneksi
# ---------------------------------------------------------------------------------------------

const HoldMs = 800

var
  firstAuditWritten: Atomic[bool]
  firstSeq: Atomic[int64]
  secondSeq: Atomic[int64]
  secondWaitedMs: Atomic[int64]

proc firstWriter(pool: DbPool) {.thread.} =
  {.cast(gcsafe).}:
    let seq = pool.withTx(proc(d: DbConn): int64 {.closure.} =
      let ev = auditEventFirst(d, "param.submit", "kursor-first", "kursor.first")
      let s = seqOf(d, $ev.eventId)
      # Sampai titik ini audit sudah tertulis → kunci advisory dipegang sampai commit.
      firstAuditWritten.store(true)
      sleep(HoldMs)
      s)
    firstSeq.store(seq)

proc secondWriter(pool: DbPool) {.thread.} =
  {.cast(gcsafe).}:
    while not firstAuditWritten.load():
      sleep(5)
    let started = epochTime()
    let seq = pool.withTx(proc(d: DbConn): int64 {.closure.} =
      let ev = auditEventFirst(d, "param.approve", "kursor-second", "kursor.second")
      secondWaitedMs.store(int64((epochTime() - started) * 1000.0))
      seqOf(d, $ev.eventId))
    secondSeq.store(seq)

suite "platform: invarian kursor outbox (O-037)":
  test "penulis kedua menunggu commit penulis pertama; urutan commit == urutan seq":
    var first: Thread[DbPool]
    var second: Thread[DbPool]
    createThread(first, firstWriter, dbPool)
    createThread(second, secondWriter, dbPool)
    joinThread(first)
    joinThread(second)

    # Penulis pertama menahan transaksi `HoldMs` setelah audit; bila audit tidak menserialkan,
    # penulis kedua tidak akan menunggu (dan test ini gagal).
    check secondWaitedMs.load() >= int64(HoldMs) - 400
    check firstSeq.load() > 0
    check secondSeq.load() > firstSeq.load()

  test "karakterisasi bahaya: tanpa audit lebih dulu, kursor seq melewatkan peristiwa":
    # Pelanggar: event ditulis **tanpa** audit, transaksinya dibiarkan terbuka. Dibungkus
    # `try`/`finally` supaya kegagalan di tengah jalan tidak mengembalikan koneksi dengan transaksi
    # terbuka ke pool (baris outbox-nya akan terkunci untuk test berikutnya).
    let offender = dbPool.acquire()
    var lost: OutboxEvent
    var committed: OutboxEvent
    var lostSeq = 0'i64
    var committedSeq = 0'i64
    try:
      exec(offender, sql"BEGIN")
      lost = newOutboxEvent(newId(sysClock), "param.changed", "param_value", "kursor-gap",
        uniqueKey("kursor-gap"), %*{"key": "kursor.gap"})
      check appendEvent(offender, lost)
      lostSeq = seqOf(offender, $lost.eventId)

      # Penulis patuh: audit lalu event, commit lebih dulu.
      committed = dbPool.withTx(proc(d: DbConn): OutboxEvent {.closure.} =
        auditEventFirst(d, "param.submit", "kursor-after", "kursor.after"))
      committedSeq = seqOf(db, $committed.eventId)
      check committedSeq > lostSeq

      exec(offender, sql"COMMIT") # pelanggar commit belakangan
    finally:
      if pqtransactionStatus(offender) != PQTRANS_IDLE:
        exec(offender, sql"ROLLBACK")
      dbPool.release(offender)

    # Pembaca berkursor (bentuk yang dipakai pump): sudah sampai `committed` → yang seq-nya lebih
    # kecil tapi commit belakangan tidak akan pernah terbaca.
    for ev in fetchAfter(db, $committed.eventId, 10_000):
      check ev.eventId != lost.eventId

    # Barisnya tidak hilang dari tabel — pembaca dari awal tetap melihatnya.
    var terlihatDariAwal = false
    for ev in fetchAfter(db, zeroUuid, 10_000):
      if ev.eventId == lost.eventId:
        terlihatDariAwal = true
    check terlihatDariAwal
