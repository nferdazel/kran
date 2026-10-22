## Test peran CLI `kran-api` (T-026, O-013) — butuh `KRAN_DATABASE_URL`.
##
## Yang diuji adalah **kontrak** yang dipakai `ops/scripts/migrate.sh` dan gate deploy:
## `--role=migrate` idempoten, dan `--role=ctl <perintah>` dengan kode keluar yang bisa diandalkan.
## Peran dipanggil langsung (bukan lewat biner) supaya test tidak bergantung pada hasil
## `./task build`; biner-nya sendiri hanya menjalankan `main()` yang memanggil jalur yang sama.
##
## Catatan: test ini **tidak** menuntut rantai audit utuh, karena `itplatform` sengaja merusak rantai
## untuk membuktikan deteksi. Yang diuji di sini: kode keluar `ctl verify-audit` **konsisten** dengan
## hasil `verifyChain` pada DB yang sedang dipakai.

import std/[options, os, strutils, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import platform/domain/scope
import platform/infrastructure/[audit_repo, auth_repo, auth_service, password_hasher,
  worker_repo]

import ../src/main

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_roles: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

# --- prasyarat parameter (T-059) -----------------------------------------------------------------
# `ctl bootstrap-admin` membaca kebijakan keamanan dari parameter DB (`settingsOf`). Bila suite
# lain (mis. `itplatform`) baru membuat ulang schema `platform` tanpa menyemai nilai, perintah
# keluar 1 ("parameter … tidak punya nilai aktif") alih-alih kontrak 3 (ditolak karena admin sudah
# ada) — test gagal tanpa sebab yang terbaca. Harness menyiapkan prasyaratnya sendiri: migrasi +
# seed pack `generated/` yang idempoten (`ON CONFLICT`), jadi aman dijalankan walau nilainya sudah
# ada. Bila tetap tidak bisa, sebut sebabnya dan berhenti — jangan lanjut ke assertion yang
# membingungkan.
block:
  try:
    discard applyAllMigrations(db, ".")
    for rel in seedFiles("."):
      execScript(db, readFile(rel))
    # Buktikan prasyaratnya benar-benar terpenuhi lewat pembaca yang sama dengan produksi.
    discard settingsOf(db, institutionScope(), utcIso(systemClock().now())[0 .. 9])
  except CatchableError as e:
    echo "itapi_roles: prasyarat T-059 (parameter keamanan) tidak siap: " & e.msg
    quit(1)

suite "kran-api: peran CLI (O-013)":
  test "ctl tanpa perintah / help → 0; perintah tak dikenal → 2":
    check runCtl("", ".") == 0
    check runCtl("help", ".") == 0
    check runCtl("bukan-perintah", ".") == 2

  test "kontrak kode keluar verify-audit: utuh 0, tidak utuh 1":
    check auditExitCode(@[AuditChainRow(seq: 1, rowHashOk: true, linkOk: true,
      expectedHash: "a", actualHash: "a")]) == 0
    check auditExitCode(@[
      AuditChainRow(seq: 1, rowHashOk: true, linkOk: true, expectedHash: "a", actualHash: "a"),
      AuditChainRow(seq: 2, rowHashOk: false, linkOk: true, expectedHash: "b",
        actualHash: "a")]) == 1
    check auditExitCode(@[AuditChainRow(seq: 2, rowHashOk: true, linkOk: false,
      expectedHash: "b", actualHash: "b")]) == 1

  test "verify-audit pada DB nyata: kode keluar konsisten dengan verifyChain":
    let baris = verifyChain(db)
    check runCtl("verify-audit", ".") == auditExitCode(baris)

  test "outbox-status → 0":
    check runCtl("outbox-status", ".") == 0

  test "ctl daycloser-status: dikenali, tapi belum ada di Fase 0 → 3":
    check runCtl("daycloser-status", ".") == 3

  test "ctl audit-anchor: kepala rantai ke berkas append (O-009)":
    let path = getTempDir() / ("kran-anchor-" & $newId(systemClock()) & ".txt")
    defer: removeFile(path)
    let line = runAuditAnchor(db, systemClock(), path)
    let head = auditHead(db)
    check line.contains("seq=" & $head.seq)
    check line.contains("hash=" & head.hash)
    check readFile(path).strip() == line
    # Anchor kedua menambah baris (append), bukan menimpa.
    discard runAuditAnchor(db, systemClock(), path)
    check readFile(path).strip().splitLines().len == 2

  test "ctl bootstrap-admin: tanpa --username → 2 (salah pakai), bantuan menyebutnya":
    # `bootstrap-admin` salah satu dari dua perintah `ctl` yang menulis (D-100), jadi kontraknya diuji eksplisit.
    # Alur sukses + kata sandi yang dicetak sekali diuji di `itauth` (butuh skema bersih); di sini
    # yang penting: salah pakai tidak diam-diam membuat admin, dan perintahnya terlihat di bantuan.
    check runCtl(bootstrapAdminCmd, ".", "") == 2
    check CtlUsage.contains(bootstrapAdminCmd)

  test "ctl bootstrap-admin: menolak bila sudah ada pemegang role admin (kode 3)":
    let uid = $newId(systemClock())
    let siap = insertUser(db, NewUser(userId: uid, username: "itapi-admin-lama",
      fullName: "Uji Admin Lama", passwordHash: "x"))
    if siap:
      discard grantRole(db, uid, bootstrapAdminRole, "", "")
    defer:
      discard db.execAffectedRows(sql"DELETE FROM platform.user_role WHERE user_id = ?::uuid", uid)
      discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    # Kode 3 = "dikenali, tapi tidak bisa dijalankan sekarang" (kontrak T-026) — bukan 2 (salah
    # pakai) dan bukan 0 (seolah-olah berhasil).
    check runCtl(bootstrapAdminCmd, ".", "itapi-admin-baru") == 3

  test "withRoleDb(useTx = true): kegagalan di tengah membatalkan seluruh tulisan":
    # Bootstrap menulis tiga hal (pengguna, role, audit). Kalau salah satunya gagal dan transaksinya
    # tidak membatalkan yang lain, yang tersisa adalah pengguna setengah jadi tanpa role — dan itu
    # membuat namanya terpakai selamanya tanpa bisa dipakai bekerja.
    let uid = $newId(systemClock())
    let code = withRoleDb(proc(db: DbConn): int {.closure.} =
      discard insertUser(db, NewUser(userId: uid, username: "itapi-rollback",
        fullName: "Uji Rollback", passwordHash: "x"))
      # Sengaja gagal setelah tulisan pertama: pembagian dengan nol → `DbError`.
      discard db.getValue(sql"select (1/0)::int")
      0, useTx = true)
    check code == 1
    check db.getValue(sql"select count(*) from platform.app_user where user_id = ?::uuid",
      uid) == "0"

  test "tanpa useTx, koneksi perintah tidak membuka transaksi (perilaku lama tetap)":
    # Penjagaan untuk perubahan di atas: perintah read-only tidak perlu (dan tidak boleh dipaksa)
    # berjalan dalam transaksi — kalau kelak `useTx` dibalik jadi default, test ini gagal.
    let uid = $newId(systemClock())
    check withRoleDb(proc(db: DbConn): int {.closure.} =
      discard insertUser(db, NewUser(userId: uid, username: "itapi-no-tx",
        fullName: "Uji Tanpa Tx", passwordHash: "x"))
      0) == 0
    check db.getValue(sql"select count(*) from platform.app_user where user_id = ?::uuid",
      uid) == "1"
    discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)

  test "migrate idempoten: jalan pertama & kedua → 0, jalan kedua tidak menerapkan apa pun":
    check runMigrate(".") == 0
    check runMigrate(".") == 0
    check runMigrate(".", "--up") == 0
    check applyAllMigrations(db, ".").applied.len == 0

  test "ctl reset-password: hash baru, wajib ganti, sesi dicabut, audit, lockout pulih (O-071)":
    let uid = $newId(systemClock())
    let uname = "itapi-reset-" & uid[0 .. 7]
    check insertUser(db, NewUser(userId: uid, username: uname,
      fullName: "Uji Reset", passwordHash: $hashPassword("sandi-lama-123", 1000)))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    # Skenario nyata pemicu reset: akun terkunci + ada sesi aktif di beberapa perangkat.
    check setUserStatus(db, uid, "LOCKED")
    let nowIso = utcIso(systemClock().now())
    for i in 1 .. 2:
      check createSession(db, $newId(systemClock()), uid, "token-reset-" & uid & "-" & $i,
        nowIso, nowIso, "", "", "")
    let setelan = settingsOf(db, institutionScope(), nowIso[0 .. 9])

    let r = resetUserPassword(db, uname, systemClock())
    check r.code == 0
    check r.password.len >= 12
    let sesudah = userById(db, uid).get()
    check sesudah.status == "ACTIVE" # LOCKED tidak boleh terkunci permanen
    check sesudah.mustChangePassword
    check sesudah.failedAttempts == 0
    check sesudah.lockedUntil.len == 0
    check verifyPassword(r.password, sesudah.passwordHash)
    check not verifyPassword("sandi-lama-123", sesudah.passwordHash)
    check sesudah.passwordHash.split('$')[1] == $setelan.pbkdf2Iterations
    check db.getValue(sql"""select count(*) from platform.session
                             where user_id = ?::uuid and revoked_at is null""", uid) == "0"
    check db.getValue(sql"""select count(*) from platform.user_password_history
                             where user_id = ?::uuid""", uid) == "1"
    check verifyPassword("sandi-lama-123", db.getValue(
      sql"""select password_hash from platform.user_password_history
             where user_id = ?::uuid""", uid))
    check db.getValue(sql"""select after_value->>'must_change_password'
                              from platform.audit_log
                             where action = 'user.password_reset' and resource_id = ?""",
      uid) == "true"
    # Status yang sengaja dinonaktifkan tidak ikut diaktifkan oleh reset.
    let uidNonaktif = $newId(systemClock())
    let unameNonaktif = "itapi-reset-off-" & uidNonaktif[0 .. 7]
    check insertUser(db, NewUser(userId: uidNonaktif, username: unameNonaktif,
      fullName: "Uji Reset Nonaktif", passwordHash: $hashPassword("sandi-lama-123", 1000)))
    check setUserStatus(db, uidNonaktif, "INACTIVE")
    check resetUserPassword(db, unameNonaktif, systemClock()).code == 0
    check userById(db, uidNonaktif).get().status == "INACTIVE"
    discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uidNonaktif)

    # Kontrak CLI (tanpa menyentuh akun nyata): argumen kurang = 2, pengguna tidak ada = 3.
    check runCtl(resetPasswordCmd, ".", "") == 2
    check runCtl(resetPasswordCmd, ".", "tidak-ada") == 3

  test "denyut worker: tulis, usia, throttle, isolasi nama, hitung DEAD (O-081)":
    let wname = "it-denyut-" & $newId(systemClock())
    let wnameLain = "it-denyut-lain-" & $newId(systemClock())
    defer:
      discard db.execAffectedRows(sql"""
        DELETE FROM platform.worker_heartbeat WHERE worker_name IN (?, ?)""", wname, wnameLain)
    check workerHeartbeatAgeSeconds(db, wname) == -1
    check touchWorkerHeartbeat(db, wname)
    check workerHeartbeatAgeSeconds(db, wname) >= 0
    # Baris worker lain yang basi tidak boleh memengaruhi usia worker ini (WHERE tidak boleh hilang).
    check touchWorkerHeartbeat(db, wnameLain)
    discard db.execAffectedRows(sql"""
      UPDATE platform.worker_heartbeat SET last_seen_at = now() - interval '1 hour'
       WHERE worker_name = ?""", wnameLain)
    check workerHeartbeatAgeSeconds(db, wname) < 60
    check workerHeartbeatAgeSeconds(db, wnameLain) >= 3500
    # Putaran berikutnya dalam <15 detik tidak menulis ulang (throttle).
    check not touchWorkerHeartbeat(db, wname)
    # Denyut yang sudah basi ditulis ulang.
    discard db.execAffectedRows(sql"""
      UPDATE platform.worker_heartbeat SET last_seen_at = now() - interval '1 minute'
       WHERE worker_name = ?""", wname)
    check touchWorkerHeartbeat(db, wname)
    check workerHeartbeatAgeSeconds(db, wname) <= 5
    # Jam mundur/NTP: denyut di masa depan tidak boleh terbaca sebagai "belum pernah melapor".
    discard db.execAffectedRows(sql"""
      UPDATE platform.worker_heartbeat SET last_seen_at = now() + interval '1 hour'
       WHERE worker_name = ?""", wname)
    check workerHeartbeatAgeSeconds(db, wname) == 0
    check deadEventCount(db) >= 0

  test "migrate --seed: menulis ulang nilai hilang, tanpa seed dev (O-090)":
    # Selektor: hanya pack generated; seed dev/test (`packs/*/seed/`) tidak boleh ikut.
    # Dipaku pada fungsi yang dipakai `--seed` (bukan `seedFiles` langsung), supaya mutasi
    # `dev = true` di jalur produksi membuat test ini gagal.
    for f in seedBaseFiles("."):
      check "/seed/" notin f
    var adaDev = false
    for f in seedFiles(".", dev = true):
      if "/seed/" in f:
        adaDev = true
    check adaDev

    # Bukti menulis: hapus satu nilai seed deterministik, lalu `--seed` harus mengembalikannya.
    # (Tanpa langkah ini, test bisa hijau walau subperintah `--seed` tidak melakukan apa pun.)
    let seedId = db.getValue(sql"select md5('ledger.posting.batch_size|base')")
    discard db.execAffectedRows(
      sql"DELETE FROM platform.param_value WHERE param_value_id = ?::uuid", seedId)
    # Kembalikan baris apa pun hasil assertion berikut (mis. EXCLUDE karena DB dev punya ACTIVE
    # non-seed untuk key ini), supaya kegagalan tidak meninggalkan DB tanpa nilai posting.
    defer: discard runMigrate(".", "--seed")
    check db.getValue(
      sql"select count(*) from platform.param_value where param_value_id = ?::uuid", seedId) == "0"
    check runMigrate(".", "--seed") == 0
    check db.getValue(
      sql"select value::text from platform.param_value where param_value_id = ?::uuid", seedId) == "50"
    check db.getValue(
      sql"select status from platform.param_value where param_value_id = ?::uuid", seedId) == "ACTIVE"
    check db.getValue(
      sql"select count(*) from platform.param_value where key = 'ledger.posting.batch_size' and status = 'ACTIVE'") == "1"
    # Idempoten: jalan kedua tidak menggandakan baris ACTIVE.
    check runMigrate(".", "--seed") == 0
    check db.getValue(
      sql"select count(*) from platform.param_value where key = 'ledger.posting.batch_size' and status = 'ACTIVE'") == "1"

  test "migrate --check (read-only): 0 saat tidak ada yang tertunda atau berubah isinya":
    check runMigrate(".", "--check") == 0

  test "`--up` menolak migrasi bertanda destruktif yang belum diterapkan (O-048)":
    let status = @[
      MigrationStatus(migration: Migration(id: "0001_ok", seq: 1, destructive: false),
        applied: false),
      MigrationStatus(migration: Migration(id: "0002_drop", seq: 2, destructive: true),
        applied: true), # sudah diterapkan: bukan urusan `--up`
      MigrationStatus(migration: Migration(id: "0003_drop", seq: 3, destructive: true),
        applied: false)]
    check destructivePending(status) == @["0003_drop"]
    check destructivePending(@[]).len == 0
    # Di repo ini belum ada migrasi berpenanda destruktif, jadi `--up` tetap jalan.
    check runMigrate(".", "--up") == 0

  test "migrate --contract/--down: kode keluar 0 / 2 / 3 sesuai kontrak (T-035)":
    # Root sintetis: seluruh modul disalin seperti root repo, lalu ditambah satu berkas contract.
    # Migrasi nyata sudah diterapkan test sebelumnya di suite ini, jadi yang baru hanya berkas ini.
    let root = ".build/itapi-roles/dua-tahap"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    copyDir("modules", root / "modules")

    let nama = "0900_probe_cli"
    let id = "platform/" & nama
    let berkas = root / "modules" / "platform" / "migrations" / (nama & ".sql")
    let pasangan = root / "modules" / "platform" / "migrations" / (nama & ".down.sql")
    writeFile(berkas, "-- dbtools:contract uji kode keluar CLI (sintetis)\n" &
      "CREATE TABLE platform.probe_cli (id int);\n")
    writeFile(pasangan, "DROP TABLE platform.probe_cli;\n")
    # Bersihkan sisa nama ini bila ada (uji lain/mutasi bisa meninggalkannya): tanpa ini uji hanya
    # benar sekali, dan itu membuat hasil ulangnya menyesatkan.
    execScript(db, "DROP TABLE IF EXISTS platform.probe_cli;")
    discard db.execAffectedRows(
      sql"DELETE FROM platform.schema_migration WHERE migration_id = ?", id)

    # Gate `--check` tidak boleh merah hanya karena ada berkas contract menunggu keputusan operator.
    check runMigrate(root, "--check") == 0
    # Jalur expand melewatinya: tidak diterapkan, jadi tabelnya belum ada.
    check runMigrate(root, "--up") == 0
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NULL)::text") == "true"

    check runMigrate(root, "--contract") == 0
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NOT NULL)::text") == "true"
    check runMigrate(root, "--contract") == 0 # idempoten
    check runMigrate(root, "--up") == 0 # expand tetap tidak menyentuh berkas contract

    # Keadaan membahayakan → 3 (dikenali tetapi ditolak), salah pakai → 2. Tidak ada yang ditebak.
    check runMigrate(root, "--down") == 3
    check runMigrate(root, "--down", "0") == 3
    check runMigrate(root, "--down", "abc") == 2
    check runMigrate(root, "--down", "99") == 3

    # Pasangan rollback hilang: ditolak **sebelum** ada tulisan apa pun.
    removeFile(pasangan)
    check runMigrate(root, "--down", "1") == 3
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NOT NULL)::text") == "true"

    # Dipulihkan: pasangan dikembalikan, rollback jalan, dan DB kembali seperti sebelum uji.
    writeFile(pasangan, "DROP TABLE platform.probe_cli;\n")
    check runMigrate(root, "--down", "1") == 0
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NULL)::text") == "true"
    check db.getValue(
      sql"SELECT count(*) FROM platform.schema_migration WHERE migration_id = ?", id) == "0"
