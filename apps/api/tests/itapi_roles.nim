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

import std/[os, strutils, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import platform/domain/scope
import platform/infrastructure/[audit_repo, auth_repo, auth_service]

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
    discard applyMigrations(db, ".")
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

  test "ctl bootstrap-admin: tanpa --username → 2 (salah pakai), bantuan menyebutnya":
    # `bootstrap-admin` satu-satunya perintah `ctl` yang menulis, jadi kontraknya diuji eksplisit.
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
    check applyMigrations(db, ".").applied.len == 0

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
