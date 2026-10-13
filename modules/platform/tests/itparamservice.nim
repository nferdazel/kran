## Test integrasi layanan parameter (T-016). Butuh `CBS_DATABASE_URL`.
##
## Cakupan kriteria T-016: akses bertipe lewat lapisan application (tanpa driver DB di sana),
## cache in-proc melayani nilai tanpa menyentuh DB dan **invalid setelah NOTIFY**, guard drift
## kode vs DB. Test ini **menghapus schema `platform`** di DB yang ditunjuk `CBS_DATABASE_URL`.

import std/[json, options, os, strutils, unittest]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[auditcontext, clock, ids, paramkey, result]
import kernel/generated/paramkeys
import platform/application/[param_cache, param_drift, param_service]
import platform/domain/[param, scope]
import platform/infrastructure/[param_repo, param_source_db]

const
  repoRoot = "."
  bizDate = "2026-10-13"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itparamservice: CBS_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
let listener = dbPool.acquire() # koneksi kedua: penerima NOTIFY
let sysClock = systemClock()

execScript(db, "DROP SCHEMA IF EXISTS platform CASCADE")
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

let service = newParamService(dbParamSource(db))
let instScope = institutionScope()
let keyIdle = P_platform_security_session_idle_minutes
let keyFiscal = P_platform_calendar_fiscal_year_start_month

proc idleNow(): int =
  service.get(keyIdle, bizDate, instScope).value()

suite "layanan parameter di atas DB":
  test "guard drift: definisi kode (paramgen) == definisi terpasang di DB":
    let problems = driftAgainstDatabase(db, paramDefinitions)
    check problems.len == 0
    check dbDefinitions(db).len == paramDefinitions.len
    check dbDefinitions(db).len > 0

  test "nilai bertipe diambil dari pack lewat cache":
    check service.get(keyFiscal, bizDate, instScope).value() == 1
    check service.get(keyFiscal, bizDate, instScope).value() == 1
    check service.cache.hits >= 1
    check idleNow() == 30
    # scope cabang tanpa nilai khusus tetap jatuh ke GLOBAL
    check service.get(keyIdle, bizDate, branchScope("11111111-1111-1111-1111-111111111111")).value() ==
      30

  test "cache melayani nilai lama sampai di-invalidasi (bukan sekadar ambil ulang)":
    let awal = idleNow()
    # Ubah langsung di DB — jalur ini TIDAK mengirim NOTIFY, jadi cache harus tetap nilai lama.
    db.exec(sql"""
      UPDATE platform.param_value SET value = ?::jsonb
       WHERE key = ? AND status = 'ACTIVE'""", $(awal + 1), keyString(keyIdle))
    check idleNow() == awal
    check service.invalidate(keyString(keyIdle)) >= 1
    check idleNow() == awal + 1
    # kembalikan nilai pack
    db.exec(sql"""
      UPDATE platform.param_value SET value = ?::jsonb
       WHERE key = ? AND status = 'ACTIVE'""", $awal, keyString(keyIdle))
    discard service.invalidate(keyString(keyIdle))
    check idleNow() == awal

  test "NOTIFY dari alur maker-checker meng-invalidasi cache":
    listenChanges(listener)
    let sebelum = idleNow()
    let maker = newAuditContext(parseId($newId(sysClock)).value(), sysClock)
    let checker = newAuditContext(parseId($newId(sysClock)).value(), sysClock)
    let perubahan = submitChange(listener, maker, sysClock, keyString(keyIdle), "GLOBAL", "",
      %*(sebelum + 5), "2026-09-01", "", "uji invalidasi cache")
    discard approveChange(listener, checker, sysClock, perubahan.paramValueId)

    # cache masih memegang nilai lama (belum ada invalidasi)
    check idleNow() == sebelum
    let berubah = watchParamChanges(listener, service, 3000)
    check keyString(keyIdle) in berubah
    check idleNow() == sebelum + 5

  test "nilai efektif-dated: tanggal sebelum perubahan memakai nilai lama":
    discard service.invalidateAll()
    let lama = service.get(keyIdle, "2026-08-31", instScope)
    check lama.isOk
    check lama.value() == 30 # pack base berlaku sejak 1970
    check service.get(keyIdle, bizDate, instScope).value() == 35

  test "key ada di kode tetapi tidak punya nilai aktif pada tanggal itu → not found":
    # `invalidateAll` supaya pembacaan benar-benar ke sumber, bukan cache
    discard service.invalidateAll()
    let hasil = service.get(keyIdle, "1969-12-31", instScope)
    check hasil.isErr
    check hasil.error().kind == pekNotFound
