## Test integrasi penjadwal day-close `ctl daycloser-auto` (T-139b) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan: saklar parameter benar-benar menghentikan penjadwal, jam lokal dibandingkan
## dengan jadwal (bukan dengan UTC mentah), tanggal buku yang belum jatuh tempo/`CLOSING` tidak
## ditutup, dan run yang sudah ada untuk tanggal buku itu tidak diulang.
##
## Penutupan yang benar-benar berjalan di sini memakai task nyata (sama seperti suite daycloser
## lain), jadi test ini juga membuktikan jalur `daycloser-auto` → orkestrasi → segel.

import std/[json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids]
import platform/domain/scope
import "platform-lib/db/config"
import "platform-lib/db/pool"

import daycloser/domain/[run, schedule, types]
import daycloser/infrastructure/run_repo

import ../src/[daycloser_auto, daycloser_ctl]

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_auto: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let repoRoot = "."
let dbPool = newDbPool(dbConfigFromEnv(envT))

block:
  let db = dbPool.acquire()
  resetTestSchemas(db, repoRoot)
  discard applyAllMigrations(db, repoRoot)
  execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
  execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))
  dbPool.release(db)

let db = dbPool.acquire()

proc setParam(key, jsonLiteral: string) =
  execScript(db, "UPDATE platform.param_value SET value = '" & jsonLiteral & "'::jsonb " &
    "WHERE param_value_id = md5('" & key & "|base')::uuid")

proc runCount(): int =
  db.getValue(sql"SELECT count(*)::text FROM daycloser.run").parseInt

proc clearRuns() =
  execScript(db, "DELETE FROM daycloser.chunk")
  execScript(db, "DELETE FROM daycloser.task")
  execScript(db, "DELETE FROM daycloser.run")

# Jam tetap supaya jadwal bisa diuji dari dua sisi tanpa menunggu waktu nyata.
# 2026-10-28 12:00 UTC.
let fakeNow = dateTime(2026, mOct, 28, 12, 0, 0, zone = utc())
let testClock = fakeClock(fakeNow)

# `daycloser-auto` membaca parameter pada tanggal UTC hari ini; baris business date memakai
# tanggal yang sama supaya tidak ada pergeseran yang membingungkan.
let Today = "2026-10-28"

proc seedBusinessDate(dateIso, state: string) =
  execScript(db, "DELETE FROM platform.business_date")
  execScript(db, """
    INSERT INTO platform.business_date (scope_type, scope_id, current_business_date, state)
    VALUES ('INSTITUTION', NULL, DATE '""" & dateIso & """', '""" & state & """')
  """)

suite "penjadwal: saklar parameter":
  test "nonaktif → tidak ada run, kode keluar 0":
    clearRuns()
    seedBusinessDate(Today, "OPEN")
    setParam("daycloser.auto.enabled", "false")
    check autoRun(dbPool, testClock) == 0
    check runCount() == 0

  test "aktif tetapi jadwal belum tiba → tidak ada run":
    clearRuns()
    setParam("daycloser.auto.enabled", "true")
    # 12:00 UTC; jadwal 23:30 UTC → belum.
    setParam("daycloser.auto.run_at", "\"23:30\"")
    setParam("daycloser.auto.utc_offset_minutes", "0")
    check autoRun(dbPool, testClock) == 0
    check runCount() == 0

  test "offset zona membuat jadwal lokal sudah lewat":
    clearRuns()
    # 12:00 UTC + 420 menit (WIB) = 19:00 lokal; jadwal 18:00 lokal → jatuh tempo.
    setParam("daycloser.auto.run_at", "\"18:00\"")
    setParam("daycloser.auto.utc_offset_minutes", "420")
    check dueConfig(AutoConfig(enabled: true, runAt: ClockTime(hour: 18, minute: 0),
      utcOffsetMinutes: 420), fakeNow)
    check autoRun(dbPool, testClock) == 0
    check runCount() == 1

proc seedFinishedRun(dateIso: string) =
  ## Run yang sudah ada untuk tanggal buku berjalan. Snapshot parameter harus konsisten dengan
  ## hash-nya karena `runForDate` membacanya lewat `snapshot()`.
  let cfg = Config(chunkSize: 100, maxAttempts: 3, retryBackoffSeconds: 0)
  let runId = $newId(testClock)
  let snapshotJson = $cfg.configJson
  let snapshotHash = configHash(cfg)
  execScript(db, "INSERT INTO daycloser.run (run_id, scope_type, scope_id, business_date, " &
    "levels, mode, state, control, param_snapshot, param_snapshot_hash, started_at, finished_at) " &
    "VALUES ('" & runId & "', 'INSTITUTION', NULL, DATE '" & dateIso & "', " &
    "'{EOD}', 'REAL', 'COMPLETED', 'NONE', '" & snapshotJson & "'::jsonb, '" & snapshotHash &
    "', now(), now())")

suite "penjadwal: keadaan tanggal buku":
  test "run yang sudah ada untuk tanggal buku berjalan tidak diulang":
    clearRuns()
    seedBusinessDate(Today, "OPEN")
    seedFinishedRun(Today)
    check autoRun(dbPool, testClock) == 0
    check runCount() == 1

  test "tanggal buku belum ada → ditolak (kode keluar 3), bukan menutup buku yang salah":
    clearRuns()
    execScript(db, "DELETE FROM platform.business_date")
    check autoRun(dbPool, testClock) == 3
    check runCount() == 0

  test "tanggal buku CLOSING tidak dijalankan oleh penjadwal":
    clearRuns()
    seedBusinessDate(Today, "CLOSING")
    check autoRun(dbPool, testClock) == 0
    check runCount() == 0

  test "tanggal bukan hari kerja tetap dicoba dan ditolak orkestrasi, bukan diperiksa di sini":
    # Penjadwal tidak punya kalender sendiri: keputusan "hari kerja" milik penutupan (satu tempat).
    clearRuns()
    seedBusinessDate("2026-10-31", "OPEN") # Sabtu
    let code = autoRun(dbPool, testClock)
    check code == 3
    check runCount() == 0

# Kembalikan parameter dan tanggal buku supaya suite/e2e berikutnya mulai netral.
setParam("daycloser.auto.enabled", "false")
execScript(db, "DELETE FROM platform.business_date")
