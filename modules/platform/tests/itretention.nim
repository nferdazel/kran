## Test integrasi retensi outbox/inbox (T-282, D-206, spec §5.6) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan di sini, dan tidak bisa dibuktikan unit test:
##   1. `markDone`/`markFailed` benar-benar mengisi `completed_at`; kegagalan yang masih akan
##      dicoba ulang (`PENDING`) tidak mengisi apa pun.
##   2. `redrive` **tidak** mengosongkan `completed_at`, dan baris hasil re-drive tidak ikut
##      terhapus karena statusnya bukan lagi `DONE`/`DEAD`.
##   3. Purge hanya menyentuh baris `DONE`/`DEAD` yang lewat masa retensi; `PENDING`/`IN_FLIGHT`
##      dan baris muda tetap ada.
##   4. Ambang yang tidak terbaca atau tidak masuk akal **gagal** (raise), bukan menghapus lebih
##      banyak — kegagalan yang salah arah di sini tidak bisa dibatalkan.
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain).

import std/[os, strutils, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/ids

import platform/infrastructure/[outbox_repo, retention_repo]

const
  repoRoot = "."
  asOf = "2026-11-16"
  outboxKey = "platform.outbox.retention_days"
  inboxKey = "platform.inbox.retention_days"
  ## Nilai retensi yang tersemai dari pack base (D-206): 30 hari.
  seededDays = 30

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itretention: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyAllMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

proc insertEvent(status: string; completedAgoDays: int): Id =
  ## `completedAgoDays < 0` = `completed_at` NULL (baris yang belum pernah selesai).
  result = Id(db.getValue(sql"SELECT gen_random_uuid()::text"))
  discard db.execAffectedRows(sql"""
    INSERT INTO platform.outbox
      (outbox_id, event_type, aggregate_type, aggregate_id, payload, dedup_key, status,
       completed_at)
    VALUES (?::uuid, 'RetentionFixture', 'Fixture', ?, '{}'::jsonb, ?, ?,
            CASE WHEN ? < 0 THEN NULL ELSE now() - make_interval(days => ?::int) END)""",
    $result, $result, "dedup-" & $result, status, completedAgoDays, completedAgoDays)

proc completedAtOf(id: Id): string =
  db.getValue(sql"""SELECT coalesce(completed_at::text, '') FROM platform.outbox
                     WHERE outbox_id = ?""", $id)

proc insertInbox(receivedAgoDays: int) =
  discard db.execAffectedRows(sql"""
    INSERT INTO platform.inbox (consumer, event_id, received_at)
    VALUES ('retention-test', gen_random_uuid(), now() - make_interval(days => ?::int))""",
    receivedAgoDays)

proc existsOf(id: Id): bool =
  db.getValue(sql"SELECT count(*) FROM platform.outbox WHERE outbox_id = ?", $id) == "1"

proc countRows(table: string): int64 =
  parseBiggestInt(db.getValue(sql("SELECT count(*) FROM platform." & table)))

suite "retensi: completed_at dan predikat purge":
  test "ambang retensi terbaca dari pack base":
    check retentionDays(db, outboxKey, asOf) == seededDays
    check retentionDays(db, inboxKey, asOf) == seededDays

  test "markDone mengisi completed_at":
    let id = insertEvent("IN_FLIGHT", -1)
    check completedAtOf(id) == ""
    markDone(db, id)
    check completedAtOf(id) != ""

  test "markFailed mengisi completed_at hanya saat baris berhenti di DEAD":
    let retrying = insertEvent("IN_FLIGHT", -1)
    markFailed(db, retrying, "sementara", backoffSeconds = 60, maxAttempts = 3)
    check statusOf(db, retrying) == "PENDING"
    check completedAtOf(retrying) == ""

    let dead = insertEvent("IN_FLIGHT", -1)
    markFailed(db, dead, "habis", backoffSeconds = 60, maxAttempts = 0)
    check statusOf(db, dead) == "DEAD"
    check completedAtOf(dead) != ""

  test "redrive mempertahankan completed_at dan mengeluarkan baris dari predikat purge":
    let id = insertEvent("IN_FLIGHT", -1)
    markFailed(db, id, "habis", backoffSeconds = 60, maxAttempts = 0)
    let deadAt = completedAtOf(id)
    check redrive(db, id)
    check statusOf(db, id) == "PENDING"
    check completedAtOf(id) == deadAt
    # Walau jamnya tua, baris yang kembali antre bukan riwayat.
    discard db.execAffectedRows(sql"""
      UPDATE platform.outbox SET completed_at = now() - make_interval(days => 90)
       WHERE outbox_id = ?""", $id)
    check purgeOutbox(db, seededDays, batch = 100) == 0
    check statusOf(db, id) == "PENDING"

  test "purgeOutbox hanya menghapus DONE/DEAD yang lewat masa retensi":
    execScript(db, "DELETE FROM platform.outbox")
    let oldDone = insertEvent("DONE", 35)
    let oldDead = insertEvent("DEAD", 40)
    let youngDone = insertEvent("DONE", 5)
    let oldPending = insertEvent("PENDING", 90)
    let oldInFlight = insertEvent("IN_FLIGHT", 90)

    check purgeOutbox(db, seededDays, batch = 100) == 2
    check countRows("outbox") == 3
    check not existsOf(oldDone)
    check not existsOf(oldDead)
    check statusOf(db, youngDone) == "DONE"
    check statusOf(db, oldPending) == "PENDING"
    check statusOf(db, oldInFlight) == "IN_FLIGHT"

  test "purgeOutbox menghapus per batch, bukan sekaligus":
    execScript(db, "DELETE FROM platform.outbox")
    for _ in 1 .. 5:
      discard insertEvent("DONE", 45)
    check purgeOutbox(db, seededDays, batch = 2) == 2
    check countRows("outbox") == 3
    check purgeOutbox(db, seededDays, batch = 100) == 3
    check countRows("outbox") == 0

  test "purgeInbox menghapus baris yang lewat masa retensi saja":
    execScript(db, "DELETE FROM platform.inbox")
    insertInbox(35)
    insertInbox(40)
    insertInbox(1)
    check purgeInbox(db, seededDays, batch = 100) == 2
    check countRows("inbox") == 1

  test "ambang yang hilang atau tidak masuk akal menolak berjalan":
    expect ValueError:
      discard retentionDays(db, "platform.retention.key.tidak_ada", asOf)

    discard db.execAffectedRows(sql"""
      UPDATE platform.param_value SET value = '0'::jsonb
       WHERE key = ? AND status = 'ACTIVE'""", outboxKey)
    expect ValueError:
      discard retentionDays(db, outboxKey, asOf)
