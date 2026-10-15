## Test peran CLI `cbs-api` (T-026, O-013) — butuh `CBS_DATABASE_URL`.
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
import platform/infrastructure/audit_repo

import ../src/main

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_roles: CBS_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

suite "cbs-api: peran CLI (O-013)":
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
