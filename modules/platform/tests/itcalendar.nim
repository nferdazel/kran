## Test integrasi kalender & business date (butuh `CBS_DATABASE_URL`).
##
## Cakupan kriteria T-007: bentuk kalender (akhir pekan, awal tahun fiskal) datang dari
## parameter; hari libur dari tabel `platform.holiday` (+ perluasan tahunan); level penutupan
## EOD/EOM/EOQ/EOY dipilih kalender; transisi state business date ilegal ditolak; rollover ke
## hari kerja berikutnya. Sekaligus mutation test param (spec §10.4): ubah nilai akhir pekan.
##
## Test ini **menghapus schema `platform`** di DB yang ditunjuk `CBS_DATABASE_URL` (DB dev).

import std/[unittest, os, json, options, sets, strutils]
import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[auditcontext, businessdate, clock, ids, paramkey, result]
import platform/domain/calendar
import platform/infrastructure/[param_repo, calendar_repo]

const
  repoRoot = "."
  weekendKey = "platform.calendar.weekend_days"
  asOf = "2026-10-30"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itcalendar: CBS_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
let sysClock = systemClock()

execScript(db, "DROP SCHEMA IF EXISTS platform CASCADE")
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

let instScope = ScopeRef(scopeType: pstInstitution, scopeId: "")
let branchScope = ScopeRef(scopeType: pstBranch, scopeId: "br-bandung")
let actor = newId(sysClock)
let maker = newId(sysClock)
let checker = newId(sysClock)

proc bd(y, m, d: int): BusinessDate =
  businessDate(y, m, d).value()

proc state(): string =
  businessDateOf(db, instScope).get().state.`$`

suite "kalender dari DB (param + tabel hari libur)":
  test "bentuk kalender awal: akhir pekan & awal tahun fiskal dari pack":
    let shape = calendarShape(db, instScope, asOf)
    check shape.weekendDays == @[6, 7]
    check shape.fiscalYearStartMonth == 1
    check shape.holidays.card == 0

  test "hari kerja vs non-kerja + level penutupan":
    let jumat = workingDayInfo(db, instScope, "2026-10-30")
    check jumat.isWorkingDay
    check not jumat.isWeekend
    check jumat.closeLevels == {clEOD, clEOM} # hari kerja terakhir Oktober 2026

    let sabtu = workingDayInfo(db, instScope, "2026-10-31")
    check sabtu.isWeekend
    check not sabtu.isWorkingDay
    check sabtu.closeLevels == {} # tidak ada penutupan di hari non-kerja

    let akhirTahun = workingDayInfo(db, instScope, "2026-12-31")
    check akhirTahun.closeLevels == {clEOD, clEOM, clEOQ, clEOY}
    check workingDayInfo(db, instScope, "2026-11-30").closeLevels == {clEOD, clEOM}
    check workingDayInfo(db, instScope, "2026-12-30").closeLevels == {clEOD}

  test "hari libur dari tabel menutup hari kerja (idempotent)":
    check addHoliday(db, instScope, "2026-11-02", "holiday.nasional.cuti_bersama")
    check not addHoliday(db, instScope, "2026-11-02", "holiday.nasional.cuti_bersama")
    let libur = workingDayInfo(db, instScope, "2026-11-02")
    check libur.isHoliday
    check not libur.isWorkingDay
    check libur.closeLevels == {}
    # tanggal lain di bulan yang sama tetap hari kerja
    check workingDayInfo(db, instScope, "2026-11-03").isWorkingDay

  test "hari libur berulang tahunan diperluas per tahun, 29 Feb aman":
    check addHoliday(db, instScope, "2026-08-17", "holiday.nasional.kemerdekaan", true)
    check addHoliday(db, instScope, "2028-02-29", "holiday.lokal.uji_kabisat", true)
    let dates = holidayDates(db, instScope, 2026, 2029)
    check "2026-08-17" in dates
    check "2027-08-17" in dates
    check "2029-08-17" in dates
    check "2028-02-29" in dates
    check "2029-02-29" notin dates # tahun non-kabisat: tanggalnya tidak ada
    # libur cabang tidak bocor ke institusi (dan sebaliknya ikut terbaca dari cabang)
    check addHoliday(db, branchScope, "2026-12-24", "holiday.lokal.cuti_bersama_cabang")
    check "2026-12-24" notin holidayDates(db, instScope, 2026, 2026)
    check "2026-12-24" in holidayDates(db, branchScope, 2026, 2026)
    check "2026-08-17" in holidayDates(db, branchScope, 2026, 2026)

  test "hari kerja berikutnya menghormati akhir pekan + libur":
    let shape = calendarShape(db, instScope, asOf)
    check nextWorkingDay(bd(2026, 10, 30), shape) == bd(2026, 11, 3) # 31/1 akhir pekan, 2 Nov libur
    check addHoliday(db, instScope, "2026-11-16", "holiday.lokal.uji_senin")
    let shape2 = calendarShape(db, instScope, asOf)
    check previousWorkingDay(bd(2026, 11, 17), shape2) == bd(2026, 11, 13)

suite "business date: state & rollover":
  test "bootstrap tanggal buku (idempotent)":
    check ensureBusinessDate(db, instScope, "2026-10-30", actor)
    check not ensureBusinessDate(db, instScope, "2026-10-30", actor)
    let row = businessDateOf(db, instScope)
    check row.isSome
    check row.get().currentDate == "2026-10-30"
    check row.get().state == bdsOpen

  test "transisi ilegal ditolak sebelum menyentuh DB":
    for (dari, ke) in [(bdsOpen, bdsClosed), (bdsClosing, bdsOpen), (bdsClosed, bdsOpen),
                       (bdsOpen, bdsOpen)]:
      var raised = false
      try:
        discard transitionBusinessDate(db, instScope, dari, ke, actor)
      except ValueError as e:
        raised = true
        check e.msg.contains("ilegal")
      check raised
    check businessDateOf(db, instScope).get().state == bdsOpen # tidak berubah

  test "jalur sah OPEN → CLOSING → CLOSED, penjagaan CAS":
    check transitionBusinessDate(db, instScope, bdsOpen, bdsClosing, actor)
    check state() == "CLOSING"
    # state DB sudah CLOSING: permintaan OPEN → CLOSING sah secara aturan, tapi tidak kena baris
    check not transitionBusinessDate(db, instScope, bdsOpen, bdsClosing, actor)
    check not rollOverBusinessDate(db, instScope, "2026-11-02", actor) # belum CLOSED
    check transitionBusinessDate(db, instScope, bdsClosing, bdsClosed, actor)
    check state() == "CLOSED"

  test "rollover ke hari kerja berikutnya membuka tanggal baru":
    check rollOverBusinessDate(db, instScope, "2026-11-03", actor)
    let row = businessDateOf(db, instScope).get()
    check row.currentDate == "2026-11-03"
    check row.state == bdsOpen
    check not rollOverBusinessDate(db, instScope, "2026-11-04", actor) # sudah OPEN
    check businessDateOf(db, instScope).get().currentDate == "2026-11-03"

suite "kalender dari parameter (mutation test §10.4)":
  test "ubah akhir pekan lewat framework parameter (maker-checker)":
    let ctxMaker = newAuditContext(maker, sysClock)
    let ctxChecker = newAuditContext(checker, sysClock)
    # Nilai pack base mulai 1970; nilai baru mulai 2026-10-01 menggantikannya (supersede).
    let change = submitChange(db, ctxMaker, sysClock, weekendKey, "GLOBAL", "", %*[5, 6],
      "2026-10-01", "", "kalender uji: Jumat–Sabtu")
    discard approveChange(db, ctxChecker, sysClock, change.paramValueId)

    let shape = calendarShape(db, instScope, "2026-10-13")
    check shape.weekendDays == @[5, 6]
    check isWeekend(bd(2026, 10, 16), shape.weekendDays) # Jumat kini non-kerja
    check not isWeekend(bd(2026, 10, 18), shape.weekendDays) # Minggu kini kerja
    check workingDayInfo(db, instScope, "2026-10-16").isWeekend
    # hari kerja terakhir Oktober 2026 kini Kamis 2026-10-29 (30 Okt Jumat = non-kerja)
    check workingDayInfo(db, instScope, "2026-10-29").closeLevels == {clEOD, clEOM}

  test "nilai di luar schema ditolak (tidak ada fallback diam-diam)":
    var raised = false
    try:
      discard submitValue(db, $newId(sysClock), weekendKey, "GLOBAL", "", %*"6,7",
        "2026-11-01", "", maker, "bentuk salah")
    except ValueError as e:
      raised = true
      check e.msg.contains("array")
    check raised
