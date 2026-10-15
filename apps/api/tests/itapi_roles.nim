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
import platform/infrastructure/[audit_repo, auth_repo]

import ../src/main

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_roles: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

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
