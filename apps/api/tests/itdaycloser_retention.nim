## Test integrasi task day-close retensi outbox/inbox (T-282, D-206) — butuh `KRAN_DATABASE_URL`.
##
## Tiga hal yang dibuktikan, dan ketiganya harus gagal kalau implementasinya rusak:
##   1. Task yang terdaftar benar-benar memangkas baris lewat masa retensi, dan mengulang task
##      yang sama pada hari yang sama tidak menghapus apa pun lagi (idempoten per tanggal buku).
##   2. **Fail-closed**: parameter retensi yang hilang membuat task `FAILED` dengan nol baris
##      terhapus. Ini test pertama T-282 — arah sebaliknya (menghapus lebih banyak) tidak bisa
##      dibatalkan, jadi tidak boleh ada nilai bawaan yang menyelamatkan konfigurasi rusak.
##   3. Task purge benar-benar **terdaftar** di registry day-close, dan predikat hapusnya tahan
##      terhadap `redrive` yang terjadi di antara CTE dan DELETE (race nyata, dua sesi).
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain).

import std/[json, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[dayclose, result]

import daycloser/api
import daycloser/domain/registry # archcheck:ok perakitan registry untuk membuktikan registrasi task retensi (T-282)

import ../src/daycloser_tasks

const
  repoRoot = "."
  businessDate = "2026-11-16"
  outboxTaskId = "platform.outbox_purge"
  inboxTaskId = "platform.inbox_purge"
  outboxKey = "platform.outbox.retention_days"
  inboxKey = "platform.inbox.retention_days"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_retention: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyAllMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

## Task diambil dari konstruktor publiknya, bukan dari registry: registry butuh `Registry` yang
## sengaja tidak diekspor modul `daycloser` (composition root yang memilikinya), dan aturan
## archcheck melarang test `apps/` menyentuh internal modul lain.
let outboxTask = outboxPurgeTask(dbPool)
let inboxTask = inboxPurgeTask(dbPool)

proc ctx(): TaskContext =
  TaskContext(runId: "test-retention", scopeType: "INSTITUTION", scopeId: "",
    businessDate: businessDate, levels: {clEOD}, mode: rmReal, chunkSize: 100)

proc insertDoneEvent(completedAgoDays: int) =
  discard db.execAffectedRows(sql"""
    INSERT INTO platform.outbox
      (outbox_id, event_type, aggregate_type, aggregate_id, payload, dedup_key, status,
       completed_at)
    VALUES (gen_random_uuid(), 'RetentionFixture', 'Fixture', gen_random_uuid()::text,
            '{}'::jsonb, gen_random_uuid()::text, 'DONE',
            now() - make_interval(days => ?::int))""", completedAgoDays)

proc insertDoneEventId(completedAgoDays: int): string =
  ## Sama seperti `insertDoneEvent`, tapi mengembalikan id supaya test race bisa menunjuk barisnya.
  db.getValue(sql"""
    INSERT INTO platform.outbox
      (outbox_id, event_type, aggregate_type, aggregate_id, payload, dedup_key, status,
       completed_at)
    VALUES (gen_random_uuid(), 'RetentionFixture', 'Fixture', gen_random_uuid()::text,
            '{}'::jsonb, gen_random_uuid()::text, 'DONE',
            now() - make_interval(days => ?::int))
    RETURNING outbox_id::text""", completedAgoDays)

proc statusOf(outboxId: string): string =
  db.getValue(sql"SELECT status FROM platform.outbox WHERE outbox_id = ?::uuid", outboxId)

type
  PurgeArgs = object
    pool: DbPool
    ctx: TaskContext

var
  ## Hasil purge dari thread. Dibaca setelah `joinThread`, yang menjadi batas sinkronisasi.
  raceOk = false
  raceDeleted = -1
  raceThread: Thread[PurgeArgs]

proc purgeInThread(args: PurgeArgs) {.thread.} =
  ## Menjalankan task purge yang sesungguhnya (lewat konstruktor publiknya), bukan repo langsung:
  ## yang diuji adalah jalur yang berjalan saat EOD.
  ##
  ## `cast(gcsafe)`: `DayCloseTask.run` adalah closure, jadi pemanggilannya lewat pointer fungsi
  ## dan compiler tidak bisa membuktikan keamanan thread. Asumsinya sama dengan yang sudah
  ## didokumentasikan di `apps/api/src/db_bridge.nim` — `DbPool.withConn` dilindungi `Lock` dan
  ## dirancang dipakai antar-thread. Kalau asumsi itu keliru, ini test yang akan menunjukkannya.
  {.cast(gcsafe).}:
    let run = outboxPurgeTask(args.pool).run(args.ctx, Chunk(chunkNo: 0))
    if run.isOk:
      raceOk = true
      raceDeleted = run.value.metrics["deleted"].getInt

proc purgeBackendsWaiting(): int64 =
  ## Berapa backend yang sedang menunggu lock sambil menjalankan statement purge outbox.
  ## Dipakai untuk memastikan interleaving benar-benar terbentuk sebelum sesi A commit; tanpa
  ## pemeriksaan ini test bisa "hijau" hanya karena B kebetulan berjalan setelah commit.
  let probe = dbPool.acquire()
  try:
    result = parseBiggestInt(probe.getValue(sql"""
      SELECT count(*) FROM pg_stat_activity
       WHERE wait_event_type = 'Lock'
         AND query LIKE '%FROM platform.outbox%'
         AND pid <> pg_backend_pid()"""))
  finally:
    dbPool.release(probe)

proc waitForPurgeLock(timeoutSeconds = 10.0): bool =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if purgeBackendsWaiting() > 0:
      return true
    sleep(20)
  false

proc insertInbox(receivedAgoDays: int) =
  discard db.execAffectedRows(sql"""
    INSERT INTO platform.inbox (consumer, event_id, received_at)
    VALUES ('retention-task-test', gen_random_uuid(),
            now() - make_interval(days => ?::int))""", receivedAgoDays)

proc countRows(table: string): int64 =
  parseBiggestInt(db.getValue(sql("SELECT count(*) FROM platform." & table)))

suite "task retensi outbox/inbox":
  test "kedua task terdaftar sebagai proses EOD yang tidak kritis":
    check outboxTask.id == outboxTaskId
    check inboxTask.id == inboxTaskId
    for t in [outboxTask, inboxTask]:
      check t.module == "platform"
      check t.levels == {clEOD}
      check t.kind == tkProcess
      check not t.critical
      check t.idempotency == imPerBusinessDate
    check outboxTask.requiredParams == @[outboxKey]
    check inboxTask.requiredParams == @[inboxKey]

  test "task purge terdaftar di registry day-close, bukan hanya di konstruktor":
    # Test di atas memakai konstruktor langsung, jadi menghapus dua baris `reg.register` di
    # `registerDayCloseTasks` tidak membuat suite ini merah — purge hanya jadi no-op diam-diam
    # saat EOD. Di sini registry yang sebenarnya dibangun, dan task yang dijalankan adalah objek
    # yang keluar dari registry, bukan konstruktornya.
    let reg = newRegistry()
    registerDayCloseTasks(reg, dbPool)
    let tasks = resolve(reg, {clEOD, clEOM})

    var hasOutbox = false
    var hasInbox = false
    var purgeFromRegistry: DayCloseTask
    for t in tasks:
      if t.id == outboxTaskId:
        hasOutbox = true
        purgeFromRegistry = t
      if t.id == inboxTaskId:
        hasInbox = true
    check hasOutbox
    check hasInbox

    execScript(db, "DELETE FROM platform.outbox")
    insertDoneEvent(45)
    let run = purgeFromRegistry.run(ctx(), Chunk(chunkNo: 0))
    check run.isOk
    check run.value.metrics["deleted"].getInt == 1
    check countRows("outbox") == 0

  test "purge memangkas riwayat kedaluwarsa dan idempoten pada tanggal buku yang sama":
    execScript(db, "DELETE FROM platform.outbox; DELETE FROM platform.inbox")
    for _ in 1 .. 3:
      insertDoneEvent(45)
    insertDoneEvent(2)
    insertInbox(45)
    insertInbox(2)

    let first = outboxTask.run(ctx(), Chunk(chunkNo: 0))
    check first.isOk
    check first.value.metrics["deleted"].getInt == 3
    check first.value.metrics["retentionDays"].getInt == 30
    check countRows("outbox") == 1

    let inbox = inboxTask.run(ctx(), Chunk(chunkNo: 0))
    check inbox.isOk
    check inbox.value.metrics["deleted"].getInt == 1
    check countRows("inbox") == 1

    let again = outboxTask.run(ctx(), Chunk(chunkNo: 0))
    check again.isOk
    check again.value.metrics["deleted"].getInt == 0

  test "fail-closed: parameter hilang = task gagal, nol baris terhapus":
    execScript(db, "DELETE FROM platform.outbox")
    insertDoneEvent(45)
    discard db.execAffectedRows(sql"DELETE FROM platform.param_value WHERE key = ?", outboxKey)
    discard db.execAffectedRows(sql"DELETE FROM platform.param_value WHERE key = ?", inboxKey)

    let outbox = outboxTask.run(ctx(), Chunk(chunkNo: 0))
    check outbox.isErr
    check outbox.error.code == "DAY-402"
    check countRows("outbox") == 1

    let inbox = inboxTask.run(ctx(), Chunk(chunkNo: 0))
    check inbox.isErr
    check inbox.error.code == "DAY-404"

  test "redrive di antara CTE dan DELETE: baris PENDING tidak ikut terhapus (race)":
    # Pulihkan parameter yang dihapus test sebelumnya
    execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))
    # Race nyata, bukan simulasi: sesi A menjalankan `redrive` (DONE -> PENDING) dan menahan
    # transaksinya, sesi B menjalankan purge. CTE B sudah melihat baris itu `DONE`, jadi tanpa
    # predikat status di DELETE, B menghapus baris yang baru saja dikembalikan ke antrean —
    # peristiwanya hilang dan tidak pernah terkirim ulang, tanpa galat di mana pun.
    #
    # Urutannya sengaja dipaksa: purge B harus benar-benar menunggu lock baris sebelum A commit,
    # kalau tidak test ini hanya menguji "PENDING tidak terhapus" yang sudah benar sejak awal.
    execScript(db, "DELETE FROM platform.outbox")
    let outboxId = insertDoneEventId(45)
    check statusOf(outboxId) == "DONE"

    let redriver = dbPool.acquire()
    try:
      redriver.exec(sql"BEGIN")
      discard redriver.execAffectedRows(sql"""
        UPDATE platform.outbox SET status = 'PENDING' WHERE outbox_id = ?::uuid""", outboxId)

      raceOk = false
      raceDeleted = -1
      createThread(raceThread, purgeInThread, PurgeArgs(pool: dbPool, ctx: ctx()))
      check waitForPurgeLock()

      redriver.exec(sql"COMMIT")
      joinThread(raceThread)

      check raceOk
      check raceDeleted == 0
      check statusOf(outboxId) == "PENDING"
      check countRows("outbox") == 1
    finally:
      dbPool.release(redriver)

