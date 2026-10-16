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
  test "DB baru (tanpa tabel riwayat): reportStatus read-only, tidak membuat tabelnya sendiri":
    # Deploy pertama ke DB kosong (D-043/T-045): `--check`/`--up` memanggil reportStatus **sebelum**
    # menerapkan apa pun, jadi ia harus tahan saat `platform.schema_migration` belum ada. Kalau ia
    # yang membuat tabelnya, perintah read-only jadi menulis skema — dan itu tidak ketahuan.
    check db.getValue(
      sql"SELECT (to_regclass('platform.schema_migration') IS NULL)::text") == "true"
    let status = reportStatus(db, repoRoot)
    check status.len > 0
    var belum = 0
    for s in status:
      if not s.applied: inc belum
    check belum == status.len
    check db.getValue(
      sql"SELECT (to_regclass('platform.schema_migration') IS NULL)::text") == "true"

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

suite "platform: migrasi dua tahap (contract & rollback, T-035)":
  ## Migrasi nyata sudah diterapkan suite pertama; yang ditambahkan di sini adalah berkas sintetis
  ## pada root sementara. Yang diuji bukan hanya kode keluar, tetapi **efeknya di DB**: DDL benar
  ## dijalankan/dikembalikan, dan baris `schema_migration` mengikuti kenyataan.
  proc contractRoot(name: string, berkas: seq[(string, string)]): string =
    let root = tempRoot(name)
    let migDir = root / "modules" / "platform" / "migrations"
    for (nama, sql) in berkas:
      writeFile(migDir / nama, sql)
    root

  test "contract dilewati jalur expand, diterapkan `--contract`, dikembalikan `--down`":
    let root = contractRoot("dua-tahap", @[
      ("0900_probe_dua_tahap.sql",
       "-- dbtools:contract uji dua tahap (sintetis)\n" &
       "CREATE TABLE platform.probe_dua_tahap (id int);\n"),
      ("0900_probe_dua_tahap.down.sql", "DROP TABLE platform.probe_dua_tahap;\n")])
    let id = "platform/0900_probe_dua_tahap"

    let expand = applyMigrations(db, root)
    check expand.applied.len == 0
    check id in expand.contractPending
    check db.getValue(sql"SELECT (to_regclass('platform.probe_dua_tahap') IS NULL)::text") ==
      "true"

    let tahapDua = applyMigrations(db, root, contract = true)
    check tahapDua.applied == @[id]
    check db.getValue(
      sql"SELECT (to_regclass('platform.probe_dua_tahap') IS NOT NULL)::text") == "true"
    # sudah diterapkan: tidak ikut lagi di jalur mana pun (idempoten di kedua mode)
    check applyMigrations(db, root).applied.len == 0
    check applyMigrations(db, root, contract = true).applied.len == 0

    let sebelum = parseInt(db.getValue(sql"SELECT count(*) FROM platform.schema_migration"))
    check rollbackMigrations(db, root, 1) == @[id]
    check db.getValue(sql"SELECT (to_regclass('platform.probe_dua_tahap') IS NULL)::text") == "true"
    # barisnya dihapus: `status`/`--check` harus mencerminkan DB, bukan niat
    check parseInt(db.getValue(sql"SELECT count(*) FROM platform.schema_migration")) == sebelum - 1
    check db.getValue(
      sql"SELECT count(*) FROM platform.schema_migration WHERE migration_id = ?", id) == "0"

  test "`--contract` menolak jalan selama migrasi expand masih tertunda":
    let root = contractRoot("dua-tahap-pending", @[
      ("0901_probe_pending.sql", "CREATE TABLE platform.probe_pending (id int);\n"),
      ("0902_probe_pending_contract.sql",
       "-- dbtools:destructive uji penolakan (sintetis)\n" &
       "-- dbtools:contract uji penolakan (sintetis)\n" &
       "DROP TABLE platform.probe_pending;\n")])
    var raised = false
    try:
      discard applyMigrations(db, root, contract = true)
    except MigrateError as e:
      raised = true
      check e.msg.contains("expand masih tertunda")
    check raised
    # ditolak berarti tidak menulis apa pun — bukan "sebagian lalu gagal"
    check db.getValue(sql"SELECT (to_regclass('platform.probe_pending') IS NULL)::text") == "true"

  test "pembatalan yang gagal tidak menghapus barisnya (satu berkas = satu transaksi)":
    let root = contractRoot("dua-tahap-gagal", @[
      ("0903_probe_gagal.sql",
       "-- dbtools:contract uji atomik (sintetis)\n" &
       "CREATE TABLE platform.probe_gagal (id int);\n"),
      # pasangan ini sengaja gagal **setelah** satu DDL berhasil
      ("0903_probe_gagal.down.sql",
       "CREATE TABLE platform.probe_efek_samping (id int);\n" &
       "DROP TABLE platform.tidak_ada_tabel_ini;\n")])
    let id = "platform/0903_probe_gagal"
    check applyMigrations(db, root, contract = true).applied == @[id]

    var raised = false
    try:
      discard rollbackMigrations(db, root, 1)
    except DbError as e:
      raised = true
      check e.msg.contains("0903_probe_gagal.down.sql")
    check raised
    # DDL pertama di berkas pasangan ikut dibatalkan, dan barisnya TIDAK dihapus
    check db.getValue(
      sql"SELECT (to_regclass('platform.probe_efek_samping') IS NULL)::text") == "true"
    check db.getValue(
      sql"SELECT count(*) FROM platform.schema_migration WHERE migration_id = ?", id) == "1"

    # dipulihkan: pasangan diperbaiki, pembatalan berjalan, DB kembali ke keadaan semula
    writeFile(root / "modules" / "platform" / "migrations" / "0903_probe_gagal.down.sql",
      "DROP TABLE platform.probe_gagal;\n")
    check rollbackMigrations(db, root, 1) == @[id]
    check db.getValue(sql"SELECT (to_regclass('platform.probe_gagal') IS NULL)::text") == "true"

  test "DDL pembatalan se-transaksi dengan penghapusan barisnya":
    # Berkas multi-pernyataan sudah atomik sendiri di Postgres (satu `PQexec` = satu transaksi
    # implisit), jadi uji sebelumnya tidak bisa membedakan ada-tidaknya transaksi eksplisit. Di sini
    # **penghapusan barisnya** yang dibuat gagal: bila DDL pembatalan tidak berada dalam transaksi
    # yang sama, DDL itu akan tetap tinggal padahal barisnya batal dihapus.
    let root = contractRoot("dua-tahap-tx", @[
      ("0904_probe_tx.sql",
       "-- dbtools:contract uji transaksi (sintetis)\n" &
       "CREATE TABLE platform.probe_tx (id int);\n"),
      ("0904_probe_tx.down.sql", "DROP TABLE platform.probe_tx;\n")])
    let id = "platform/0904_probe_tx"
    check applyMigrations(db, root, contract = true).applied == @[id]

    execScript(db, """CREATE FUNCTION platform.probe_tolak_hapus() RETURNS trigger AS $$
                        BEGIN RAISE EXCEPTION 'tolak hapus (uji)'; END; $$ LANGUAGE plpgsql""")
    execScript(db, """CREATE TRIGGER probe_tolak_hapus BEFORE DELETE ON platform.schema_migration
                      FOR EACH ROW EXECUTE FUNCTION platform.probe_tolak_hapus()""")
    var raised = false
    try:
      discard rollbackMigrations(db, root, 1)
    except DbError as e:
      raised = true
      check e.msg.contains("tolak hapus")
    check raised
    # DDL pembatalan ikut dibatalkan bersama penghapusan barisnya
    check db.getValue(sql"SELECT (to_regclass('platform.probe_tx') IS NOT NULL)::text") == "true"
    check db.getValue(
      sql"SELECT count(*) FROM platform.schema_migration WHERE migration_id = ?", id) == "1"

    execScript(db, "DROP TRIGGER probe_tolak_hapus ON platform.schema_migration")
    execScript(db, "DROP FUNCTION platform.probe_tolak_hapus()")
    check rollbackMigrations(db, root, 1) == @[id]
    check db.getValue(sql"SELECT (to_regclass('platform.probe_tx') IS NULL)::text") == "true"
