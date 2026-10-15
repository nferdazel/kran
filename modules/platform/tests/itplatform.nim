## Test integrasi modul `platform` (butuh `KRAN_DATABASE_URL`, lihat docs/runbooks/dev-db.md).
##
## Cakupan: migrasi idempotent + atomik + anti-drift, outbox (de-dup, klaim SKIP LOCKED,
## backoff, dead-letter, re-drive), inbox (de-dup per konsumen), audit_log (hash chain,
## append-only, deteksi perusakan).
##
## Test ini **menghapus schema `platform`** di database yang ditunjuk `KRAN_DATABASE_URL`.
## Itu memang tujuan `kran_dev` (DB dev khusus), jangan arahkan ke DB lain.

import std/[unittest, os, json, strutils]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, auditcontext]
import platform/domain/[audit, event]
import platform/infrastructure/[audit_repo, inbox_repo, outbox_repo]

const
  repoRoot = "."
  workDir = ".build/itplatform"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itplatform: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)
if not dirExists(repoRoot / "modules" / "platform" / "migrations"):
  echo "itplatform: jalankan dari akar repo (modules/platform/migrations tidak ditemukan)"
  quit(2)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
let sysClock = systemClock()

# State awal bersih: schema dibuang, migrasi diterapkan ulang oleh test pertama.
execScript(db, "DROP SCHEMA IF EXISTS platform CASCADE")

proc expectDbError(sqlText: SqlQuery, needle = "") =
  var raised = false
  try:
    exec(db, sqlText)
  except DbError as e:
    raised = true
    if needle.len > 0:
      check e.msg.contains(needle)
  check raised

proc tempRoot(name: string): string =
  let root = workDir / name
  if dirExists(root):
    removeDir(root)
  createDir(root)
  copyDir(repoRoot / "modules", root / "modules")
  root

suite "platform: migrasi":
  test "menerapkan semua, lalu idempotent (up 2x aman)":
    let jumlahMigrasi = migrationsOf(repoRoot).len
    check jumlahMigrasi > 0
    let first = applyMigrations(db, repoRoot)
    check first.applied.len == jumlahMigrasi
    check first.skipped.len == 0
    let second = applyMigrations(db, repoRoot)
    check second.applied.len == 0
    check second.skipped.len == jumlahMigrasi
    check db.getValue(
      sql"SELECT (to_regclass('platform.schema_migration') IS NOT NULL)::text") == "true"
    check db.getValue(
      sql"SELECT (to_regclass('platform.outbox') IS NOT NULL)::text") == "true"
    check db.getValue(
      sql"SELECT (to_regclass('platform.inbox') IS NOT NULL)::text") == "true"
    check db.getValue(
      sql"SELECT (to_regclass('platform.audit_log') IS NOT NULL)::text") == "true"
    check db.getValue(sql"SELECT count(*) FROM platform.schema_migration") ==
      $jumlahMigrasi

  test "berkas migrasi yang sudah diterapkan tidak boleh berubah (checksum)":
    let root = tempRoot("drift")
    let target = root / "modules" / "platform" / "migrations" / "0001_platform_schema.sql"
    writeFile(target, readFile(target) & "\n-- perubahan kecil setelah diterapkan\n")
    var raised = false
    try:
      discard applyMigrations(db, root)
    except MigrateError as e:
      raised = true
      check e.msg.contains("isinya berubah")
    check raised

  test "migrasi yang gagal tidak diterapkan dan tidak tercatat (atomik)":
    let root = tempRoot("broken")
    writeFile(root / "modules" / "platform" / "migrations" / "0004_broken_probe.sql",
      "CREATE TABLE platform.probe_broken (id uuid);\nSELECT 1 / 0;\n")
    var raised = false
    try:
      discard applyMigrations(db, root)
    except DbError as e:
      raised = true
      check e.msg.contains("0004_broken_probe")
    check raised
    check db.getValue(
      sql"SELECT (to_regclass('platform.probe_broken') IS NULL)::text") == "true"
    # semua migrasi asli sudah tercatat pada test pertama; probe yang gagal tidak tercatat
    check db.getValue(sql"SELECT count(*) FROM platform.schema_migration") ==
      $migrationsOf(repoRoot).len

suite "platform: outbox":
  test "de-dup: publisher yang di-retry tidak menggandakan peristiwa":
    exec(db, sql"DELETE FROM platform.outbox")
    let ev = newOutboxEvent(newId(sysClock), "param.changed", "param_value",
      "lending.collectibility.dpd.kl", "param.update:lending.collectibility.dpd.kl:1",
      %*{"key": "lending.collectibility.dpd.kl", "value": "91"})
    check appendEvent(db, ev)
    check not appendEvent(db, ev)
    check countByStatus(db, Pending) == 1

  test "klaim batch: IN_FLIGHT tidak diklaim ulang, attempts naik, selesai = DONE":
    let batch = claimBatch(db, "worker-1", 10)
    check batch.len == 1
    check batch[0].status == InFlight
    check batch[0].attempts == 1
    check batch[0].payload["value"].getStr == "91"
    check batch[0].dedupKey.len > 0
    check claimBatch(db, "worker-2", 10).len == 0
    markDone(db, batch[0].eventId)
    check statusOf(db, batch[0].eventId) == "DONE"
    check countByStatus(db, Done) == 1

  test "kegagalan: backoff menunda klaim, dead-letter setelah batas, re-drive":
    let ev = newOutboxEvent(newId(sysClock), "account.balance_changed", "account",
      "acc-1", "account.balance:acc-1:1", %*{"balance": "1000.0000"})
    check appendEvent(db, ev)

    let first = claimBatch(db, "worker-1", 10)
    check first.len == 1
    check first[0].eventId == ev.eventId

    markFailed(db, ev.eventId, "konsumen mati", backoffSeconds = 3_600, maxAttempts = 5)
    check statusOf(db, ev.eventId) == "PENDING"
    check claimBatch(db, "worker-1", 10).len == 0 # available_at belum lewat

    # Percepat jadwal untuk menguji jalur dead-letter tanpa menunggu.
    discard db.execAffectedRows(
      sql"UPDATE platform.outbox SET available_at = now() WHERE outbox_id = ?", $ev.eventId)
    let second = claimBatch(db, "worker-1", 10)
    check second.len == 1
    check second[0].attempts == 2
    markFailed(db, ev.eventId, "konsumen mati lagi", backoffSeconds = 1, maxAttempts = 2)
    check statusOf(db, ev.eventId) == "DEAD"
    check claimBatch(db, "worker-1", 10).len == 0 # DEAD tidak diklaim otomatis

    check redrive(db, ev.eventId)
    check statusOf(db, ev.eventId) == "PENDING"
    let third = claimBatch(db, "worker-1", 10)
    check third.len == 1
    check third[0].attempts == 1 # attempts direset saat re-drive
    markDone(db, ev.eventId)

  test "batch dibatasi limit":
    exec(db, sql"DELETE FROM platform.outbox")
    for i in 1 .. 3:
      check appendEvent(db, newOutboxEvent(newId(sysClock), "param.changed", "param_value",
        "key-" & $i, "param.update:key-" & $i & ":1", %*{"i": i}))
    let batch = claimBatch(db, "worker-1", 2)
    check batch.len == 2
    check countByStatus(db, InFlight) == 2
    check countByStatus(db, Pending) == 1

suite "platform: inbox":
  test "de-dup per konsumen":
    let eventId = newId(sysClock)
    check claimInbox(db, "ledger-posting", eventId)
    check not claimInbox(db, "ledger-posting", eventId)
    check claimInbox(db, "compliance", eventId) # konsumen berbeda tetap memproses
    check inboxSeen(db, "ledger-posting", eventId)
    check countInbox(db, "ledger-posting") == 1

suite "platform: audit_log":
  var firstHash = ""
  var secondHash = ""

  test "append menulis rantai hash yang bisa diverifikasi":
    let ctx = newAuditContext(newId(sysClock), sysClock, branchIds = @[newId(sysClock)])
    firstHash = appendAudit(db, newAuditEntry(ctx, "param.update", "param_value",
      "lending.collectibility.dpd.kl", sysClock, role = "admin", businessDate = "2026-10-13",
      before = %*{"value": "91"}, after = %*{"value": "95"}))
    secondHash = appendAudit(db, newAuditEntry(ctx, "param.update", "param_value",
      "lending.ppap.rate.kl", sysClock, role = "admin", businessDate = "2026-10-13",
      before = %*{"value": "0.5"}, after = %*{"value": "0.6"}))
    let thirdHash = appendAudit(db, newAuditEntry(ctx, "user.unmask", "party_person",
      "party-1", sysClock, role = "supervisor", businessDate = "2026-10-13"))
    check firstHash.len == 64
    check secondHash.len == 64
    check firstHash != secondHash
    check thirdHash != secondHash

    let rows = verifyChain(db)
    check rows.len == 3
    check chainOk(rows)
    check db.getValue(sql"SELECT prev_hash FROM platform.audit_log WHERE seq = 1") ==
      repeat('0', 64)
    check db.getValue(sql"SELECT prev_hash FROM platform.audit_log WHERE seq = 2") == firstHash
    check db.getValue(sql"SELECT prev_hash FROM platform.audit_log WHERE seq = 3") == secondHash
    check db.getValue(sql"SELECT hash FROM platform.audit_log WHERE seq = 1") == firstHash

  test "append-only: UPDATE dan DELETE ditolak trigger":
    expectDbError(sql"UPDATE platform.audit_log SET reason = 'diubah' WHERE seq = 1",
      "append-only")
    expectDbError(sql"DELETE FROM platform.audit_log WHERE seq = 1", "append-only")
    check countAudit(db) == 3

  test "perusakan payload terdeteksi (hash tidak lagi cocok)":
    exec(db, sql"ALTER TABLE platform.audit_log DISABLE TRIGGER audit_log_no_change_trg")
    discard db.execAffectedRows(
      sql"UPDATE platform.audit_log SET after_value = jsonb_build_object('value', '999') WHERE seq = 2")
    exec(db, sql"ALTER TABLE platform.audit_log ENABLE TRIGGER audit_log_no_change_trg")

    let rows = verifyChain(db)
    check not rows[1].rowHashOk # isi baris 2 berubah
    check rows[1].linkOk # rantai dari baris 1 masih benar
    check not chainOk(rows)

  test "perusakan dengan hash dihitung ulang: rantai putus di baris berikutnya":
    exec(db, sql"ALTER TABLE platform.audit_log DISABLE TRIGGER audit_log_no_change_trg")
    discard db.execAffectedRows(sql"""UPDATE platform.audit_log a
      SET hash = encode(digest(a.prev_hash || '|' ||
            platform.audit_log_payload(a), 'sha256'), 'hex')
      WHERE a.seq = 2""")
    exec(db, sql"ALTER TABLE platform.audit_log ENABLE TRIGGER audit_log_no_change_trg")

    let rows = verifyChain(db)
    check rows[1].rowHashOk # baris 2 sekarang konsisten dengan dirinya sendiri
    check not rows[2].linkOk # tetapi baris 3 menunjuk hash baris 2 yang lama
    check not chainOk(rows)
    check not chainOk(verifyChain(db, 3))

  test "rantai tetap tumbuh dan perusakan lama tetap terdeteksi":
    let ctx = newAuditContext(newId(sysClock), sysClock)
    discard appendAudit(db, newAuditEntry(ctx, "user.login", "user", "u-1", sysClock))
    let rows = verifyChain(db)
    check rows.len == 4
    check not chainOk(rows) # temuan lama tidak hilang
    check not rows[2].linkOk # baris 3 masih menunjuk hash lama baris 2
    check rows[3].linkOk # baris terbaru merantai dengan benar
    check countAudit(db) == 4

  test "TRUNCATE ditolak trigger":
    expectDbError(sql"TRUNCATE platform.audit_log", "append-only")
    check countAudit(db) == 4
