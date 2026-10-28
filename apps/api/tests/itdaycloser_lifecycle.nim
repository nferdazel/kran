## Test integrasi siklus business date lewat perintah `ctl` day-close (T-135) — butuh
## `KRAN_DATABASE_URL`.
##
## Yang dibuktikan di sini adalah hal yang tidak bisa dibuktikan unit test: perintah `ctl` yang
## sebenarnya memindahkan `platform.business_date` (`OPEN → CLOSING → CLOSED → rollover`), menulis
## event `BusinessDateOpened` di transaksi yang sama, menolak run kedua pada tanggal yang sama, dan
## membuka kembali tanggal yang dibekukan saat run dibatalkan.
##
## Test ini me-reset seluruh schema di DB dev (pola suite integrasi lain) dan menghapus baris
## `business_date` di akhir supaya suite berikutnya/e2e mulai dari keadaan tanpa penutupan.

import std/[options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[clock, dayclose]

import daycloser/domain/[run, types]
import daycloser/infrastructure/run_repo
import platform/domain/[calendar, scope]
import platform/infrastructure/calendar_repo

import ../src/daycloser_ctl
import ../src/daycloser_service

const
  repoRoot = "."
  ## Senin–Jumat kerja, Sabtu/Minggu libur (pack `base`), tanpa hari libur tersemai.
  Monday = "2026-10-26"
  Tuesday = "2026-10-27"
  Wednesday = "2026-10-28"
  Thursday = "2026-10-29"
  Friday = "2026-10-30"
  Saturday = "2026-10-31"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_lifecycle: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

proc bd(): Option[BusinessDateRow] =
  businessDateOf(db, institutionScope())

proc isoStamp(): string =
  format(getTime().utc, "yyyy-MM-dd'T'HH:mm:ss'Z'")

proc runState(runId: string): string =
  db.getValue(sql"SELECT state FROM daycloser.run WHERE run_id = ?::uuid", runId)

proc auditCount(action: string): int =
  parseInt(db.getValue(sql"SELECT count(*) FROM platform.audit_log WHERE action = ?", action))

proc openedEventPayload(nextDate: string): string =
  db.getValue(sql"""
    SELECT coalesce(payload->>'businessDate', '')
      FROM platform.outbox
     WHERE event_type = 'BusinessDateOpened'
       AND payload->>'businessDate' = ?""", nextDate)

proc seedRun(runId, businessDate: string; state: RunState) =
  ## Run yang "mati" pada tanggal yang sudah dibekukan: keadaan yang tersisa setelah proses
  ## `daycloser-run` dibunuh di tengah, atau setelah run gagal dan belum ditangani.
  discard dbPool.withTx(proc(d: DbConn): int =
    d.insertRun(runId, RunRequest(scopeType: "INSTITUTION", scopeId: "",
      businessDate: businessDate, levels: {clEOD}, mode: rmReal,
      config: Config(chunkSize: 10, maxAttempts: 1, retryBackoffSeconds: 0)), @[], isoStamp())
    d.setRunState(runId, state, isoStamp(), "")
    1)

proc seedPausedRun(runId, businessDate: string) =
  seedRun(runId, businessDate, rsPaused)
  execScript(db, "UPDATE platform.business_date SET state = 'CLOSING'")

suite "dayclose: siklus business date lewat ctl":
  test "bootstrap menutup hari pertama, menyegel, dan rollover ke hari kerja berikutnya":
    check bd().isNone
    check runDayCloserCtl(dayCloserRunCmd, Monday, "", bootstrap = true) == 0

    let row = bd().get
    check row.currentDate == Tuesday
    check row.state == bdsOpen
    check openedEventPayload(Tuesday) == Tuesday
    check auditCount("daycloser.date.freeze") == 1
    check auditCount("daycloser.date.rollover") == 1
    check auditCount("daycloser.run.finish") == 1

    let runId = db.getValue(sql"""
      SELECT run_id::text FROM daycloser.run WHERE business_date = ?::date""", Monday)
    check runState(runId) == "COMPLETED"
    check db.getValue(sql"""
      SELECT coalesce(length(summary_hash), 0)::text FROM daycloser.run
       WHERE run_id = ?::uuid""", runId) == "64"

  test "tanggal lain dan bootstrap kedua ditolak tanpa mengubah tanggal buku":
    check runDayCloserCtl(dayCloserRunCmd, Wednesday, "") == 3
    check runDayCloserCtl(dayCloserRunCmd, Tuesday, "", bootstrap = true) == 3
    check runDayCloserCtl(dayCloserRunCmd, Saturday, "") == 3
    check bd().get.currentDate == Tuesday
    check bd().get.state == bdsOpen

  test "tanggal buku berjalan ditutup lalu maju satu hari kerja":
    check runDayCloserCtl(dayCloserRunCmd, Tuesday, "") == 0
    check bd().get.currentDate == Wednesday
    check bd().get.state == bdsOpen
    check openedEventPayload(Wednesday) == Wednesday

  test "CLOSING menahan run baru & gate deploy; cancel membuka kembali tanggal":
    let runId = "01900000-0000-7000-8000-0000000000aa"
    seedPausedRun(runId, Wednesday)

    check runDayCloserCtl(dayCloserStatusCmd, "", "") == 1
    check runDayCloserCtl(dayCloserRunCmd, Wednesday, "") == 3
    check bd().get.state == bdsClosing

    check runDayCloserCtl(dayCloserCancelCmd, "", runId) == 0
    check runState(runId) == "CANCELED"
    check bd().get.state == bdsOpen
    check bd().get.currentDate == Wednesday
    check auditCount("daycloser.run.cancel") == 1
    check runDayCloserCtl(dayCloserStatusCmd, "", "") == 0

  test "tanggal yang sudah punya run tidak bisa ditutup dua kali":
    check runDayCloserCtl(dayCloserRunCmd, Monday, "") == 3
    check bd().get.currentDate == Wednesday

  test "tanggal yang run-nya dibatalkan bisa ditutup lagi (bukan jalan buntu)":
    # Tanpa ini, satu pembatalan membekukan tanggal itu selamanya: satu-satunya cara memajukan
    # buku adalah menyegel run untuk tanggal tersebut, sementara run baru selalu ditolak.
    check runDayCloserCtl(dayCloserRunCmd, Wednesday, "") == 0
    check bd().get.currentDate == Thursday
    check bd().get.state == bdsOpen
    check db.getValue(sql"""
      SELECT count(*)::text FROM daycloser.run WHERE business_date = ?::date""",
      Wednesday) == "2"

  test "pemulihan: run CANCELED yang meninggalkan tanggal CLOSING bisa dibuka":
    let runId = "01900000-0000-7000-8000-0000000000bb"
    seedRun(runId, Thursday, rsCanceled)
    execScript(db, "UPDATE platform.business_date SET state = 'CLOSING'")
    check runDayCloserCtl(dayCloserStatusCmd, "", "") == 1

    check runDayCloserCtl(dayCloserCancelCmd, "", runId) == 0
    check bd().get.state == bdsOpen
    check bd().get.currentDate == Thursday
    check runDayCloserCtl(dayCloserStatusCmd, "", "") == 0

    # Setelah pulih, tanggal itu bisa ditutup seperti biasa.
    check runDayCloserCtl(dayCloserRunCmd, Thursday, "") == 0
    check bd().get.currentDate == Friday

suite "dayclose: dry-run SIMULATION":
  test "dry-run mencetak rencana yang sama dengan run nyata tanpa menulis apa pun":
    let runsBefore = parseInt(db.getValue(sql"SELECT count(*) FROM daycloser.run"))
    let journalsBefore = parseInt(db.getValue(sql"SELECT count(*) FROM ledger.journal"))
    let res = startSimulationAction(dbPool, systemClock(), Friday)
    check res.status == asOk
    check res.code == "simulated"
    # Rencana memuat task deposit yang akan menulis, dan menyatakan bahwa dry-run tidak menulis.
    check "deposit.interest_accrual" in res.message
    check "deposit.maturity_aro" in res.message
    check "\"mode\": \"SIMULATION\"" in res.message
    check "\"writes\": false" in res.message
    # Tidak ada baris run, jurnal, atau perubahan tanggal buku.
    check parseInt(db.getValue(sql"SELECT count(*) FROM daycloser.run")) == runsBefore
    check parseInt(db.getValue(sql"SELECT count(*) FROM ledger.journal")) == journalsBefore
    check bd().get.currentDate == Friday
    check bd().get.state == bdsOpen

  test "ctl dry-run keluar 0 dan tidak memajukan tanggal buku":
    check runDayCloserCtl(dayCloserRunCmd, Friday, "", simulate = true) == 0
    check bd().get.currentDate == Friday
    check bd().get.state == bdsOpen
    check db.getValue(sql"""
      SELECT count(*)::text FROM daycloser.run WHERE business_date = ?::date""", Friday) == "0"

  test "dry-run menolak tanggal yang bukan tanggal buku atau bukan hari kerja":
    # Sama seperti run nyata: pratinjau tidak menjanjikan run yang toh akan ditolak.
    # `Thursday` sudah punya run `COMPLETED`, jadi penolakan di situ adalah `run_exists`; kasus
    # "bukan tanggal buku" butuh hari kerja tanpa run (Senin 2 Nov 2026).
    check runDayCloserCtl(dayCloserRunCmd, Thursday, "", simulate = true) == 3
    let mismatch = startSimulationAction(dbPool, systemClock(), "2026-11-02")
    check mismatch.status == asConflict
    check mismatch.code == "business_date_mismatch"
    check runDayCloserCtl(dayCloserRunCmd, Saturday, "", simulate = true) == 3
    check bd().get.currentDate == Friday

  test "dry-run menolak tanggal buku CLOSING dengan kode yang sama seperti run nyata":
    execScript(db, "UPDATE platform.business_date SET state = 'CLOSING'")
    let res = startSimulationAction(dbPool, systemClock(), Friday)
    check res.status == asConflict
    check res.code == "business_date_closing"
    check runDayCloserCtl(dayCloserRunCmd, Friday, "", simulate = true) == 3
    execScript(db, "UPDATE platform.business_date SET state = 'OPEN'")
    check bd().get.state == bdsOpen

# E2E berjalan setelah suite ini pada DB yang sama: jangan tinggalkan tanggal buku dalam keadaan
# yang menahan perubahan HTTP.
block:
  execScript(db, "DELETE FROM platform.business_date")
