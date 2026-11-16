## Test integrasi task day-close retensi outbox/inbox (T-282, D-206) — butuh `KRAN_DATABASE_URL`.
##
## Dua hal yang dibuktikan, dan keduanya harus gagal kalau implementasinya rusak:
##   1. Task yang terdaftar benar-benar memangkas baris lewat masa retensi, dan mengulang task
##      yang sama pada hari yang sama tidak menghapus apa pun lagi (idempoten per tanggal buku).
##   2. **Fail-closed**: parameter retensi yang hilang membuat task `FAILED` dengan nol baris
##      terhapus. Ini test pertama T-282 — arah sebaliknya (menghapus lebih banyak) tidak bisa
##      dibatalkan, jadi tidak boleh ada nilai bawaan yang menyelamatkan konfigurasi rusak.
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain).

import std/[json, os, strutils, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[dayclose, result]

import daycloser/api

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
