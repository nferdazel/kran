import std/[unittest, json]

import kernel/[businessdate, result]
import platform/domain/calendar

proc bd(y, m, d: int): BusinessDate =
  businessDate(y, m, d).value()

proc shape(weekend: seq[int], fiscalStart: int, holidays: seq[string] = @[]): CalendarShape =
  CalendarShape(weekendDays: weekend, fiscalYearStartMonth: fiscalStart,
    holidays: holidaySet(holidays))

# 2026-10-13 = Selasa (lihat kernel tests untuk verifikasi dayOfWeek).
let senin = bd(2026, 10, 12)
let jumat = bd(2026, 10, 16)
let sabtu = bd(2026, 10, 17)
let minggu = bd(2026, 10, 18)

suite "kalender: hari kerja":
  test "akhir pekan Sabtu/Minggu":
    let s = shape(@[6, 7], 1)
    check isWeekend(sabtu, s.weekendDays)
    check isWeekend(minggu, s.weekendDays)
    check not isWeekend(jumat, s.weekendDays)
    check isWorkingDay(jumat, s)
    check not isWorkingDay(sabtu, s)

  test "bentuk kalender bisa berbeda (Jumat/Sabtu libur, mis. segmen tertentu)":
    let s = shape(@[5, 6], 1)
    check not isWorkingDay(jumat, s)
    check isWorkingDay(minggu, s)
    check isWorkingDay(senin, s)

  test "hari libur dari tabel menutup hari kerja":
    let s = shape(@[6, 7], 1, @["2026-10-14"]) # Rabu libur
    check not isWorkingDay(bd(2026, 10, 14), s)
    check isWorkingDay(bd(2026, 10, 13), s)
    check isHoliday(bd(2026, 10, 14), s.holidays)

  test "hari kerja berikutnya & sebelumnya melewati akhir pekan + libur":
    let s = shape(@[6, 7], 1, @["2026-10-19"]) # Senin libur
    check nextWorkingDay(jumat, s) == bd(2026, 10, 20) # Sab, Min libur; Sen libur
    check previousWorkingDay(bd(2026, 10, 20), s) == bd(2026, 10, 16)

  test "hari kerja terakhir bulan mundur dari libur akhir pekan":
    let s = shape(@[6, 7], 1)
    # 2026-05-31 = Minggu → hari kerja terakhir Mei = Jumat 2026-05-29
    check lastWorkingDayOfMonth(2026, 5, s) == bd(2026, 5, 29)
    check lastWorkingDayOfMonth(2026, 10, s) == bd(2026, 10, 30) # 31 Okt = Sabtu
    # dengan Jumat sebagai akhir pekan, September berakhir Kamis 2026-09-30
    check lastWorkingDayOfMonth(2026, 9, shape(@[5, 6], 1)) == bd(2026, 9, 30)

  test "parse weekend_days dari param (nilai bisnis dari DB)":
    check parseWeekendDays(parseJson("[6,7]")) == @[6, 7]
    check parseWeekendDays(parseJson("[5,6]")) == @[5, 6]
    for bad in ["[]", "[0]", "[8]", "[6,6]", "[6,\"7\"]", "\"6,7\"", "{}"]:
      var raised = false
      try:
        discard parseWeekendDays(parseJson(bad))
      except ValueError:
        raised = true
      check raised

suite "kalender: level penutupan (kaskade §11.2)":
  test "hari kerja biasa hanya EOD":
    check closeLevelsFor(bd(2026, 10, 13), shape(@[6, 7], 1)) == {clEOD}

  test "hari bukan hari kerja tidak ada penutupan":
    check closeLevelsFor(sabtu, shape(@[6, 7], 1)) == {}
    check closeLevelsFor(bd(2026, 10, 14), shape(@[6, 7], 1, @["2026-10-14"])) == {}

  test "akhir bulan -> EOD + EOM":
    let s = shape(@[6, 7], 1)
    check closeLevelsFor(bd(2026, 10, 30), s) == {clEOD, clEOM}
    check closeLevelsFor(bd(2026, 11, 30), s) == {clEOD, clEOM} # November bukan akhir kuartal
    check closeLevelsFor(bd(2026, 12, 31), s) == {clEOD, clEOM, clEOQ, clEOY}

  test "akhir kuartal -> EOD + EOM + EOQ":
    let s = shape(@[6, 7], 1)
    check closeLevelsFor(bd(2026, 9, 30), s) == {clEOD, clEOM, clEOQ}
    check closeLevelsFor(bd(2026, 6, 30), s) == {clEOD, clEOM, clEOQ}

  test "akhir tahun fiskal (mulai Januari) -> EOD + EOM + EOQ + EOY":
    let s = shape(@[6, 7], 1)
    # 2026-12-31 = Kamis → hari kerja terakhir Desember
    check closeLevelsFor(bd(2026, 12, 31), s) == {clEOD, clEOM, clEOQ, clEOY}

  test "tahun fiskal mulai April -> EOY di akhir Maret":
    let s = shape(@[6, 7], 4)
    check closeLevelsFor(bd(2027, 3, 31), s) == {clEOD, clEOM, clEOQ, clEOY}
    check closeLevelsFor(bd(2027, 2, 26), s) == {clEOD, clEOM} # akhir bulan, bukan kuartal
    check closeLevelsFor(bd(2026, 12, 31), s) == {clEOD, clEOM, clEOQ}

  test "tahun fiskal mulai Februari -> EOY di akhir Januari tanpa EOQ":
    let s = shape(@[6, 7], 2)
    # 2026-01-31 = Sabtu → hari kerja terakhir Januari = Jumat 2026-01-30
    check lastWorkingDayOfMonth(2026, 1, s) == bd(2026, 1, 30)
    check closeLevelsFor(bd(2026, 1, 30), s) == {clEOD, clEOM, clEOY}
    check closeLevelsFor(bd(2026, 1, 29), s) == {clEOD}

  test "bulan terakhir tahun fiskal bisa bukan bulan kalender 12":
    check fiscalYearEndMonth(1) == 12
    check fiscalYearEndMonth(4) == 3
    check fiscalYearEndMonth(2) == 1
    var raised = false
    try:
      discard fiscalYearEndMonth(0)
    except ValueError:
      raised = true
    check raised

  test "levelsCsv deterministik":
    check levelsCsv({clEOD, clEOM, clEOQ, clEOY}) == "EOD,EOM,EOQ,EOY"
    check levelsCsv({clEOD}) == "EOD"
    check levelsCsv({}) == ""

suite "business date: transisi state":
  test "jalur sah: OPEN -> CLOSING -> CLOSED":
    check canTransition(bdsOpen, bdsClosing)
    check canTransition(bdsClosing, bdsClosed)

  test "transisi tidak sah ditolak (termasuk lompat & reopen)":
    check not canTransition(bdsOpen, bdsClosed) # lompat tanpa freeze
    check not canTransition(bdsOpen, bdsOpen)
    check not canTransition(bdsClosing, bdsOpen) # reopen default dilarang (§11.7)
    check not canTransition(bdsClosed, bdsOpen)
    check not canTransition(bdsClosed, bdsClosing)
    check not canTransition(bdsClosing, bdsClosing)

  test "parseState & parseCloseLevel menolak nilai tak dikenal":
    check parseState("OPEN") == bdsOpen
    check parseState("CLOSING") == bdsClosing
    check parseState("CLOSED") == bdsClosed
    check parseCloseLevel("EOQ") == clEOQ
    for bad in ["open", "DONE", ""]:
      var raised = false
      try:
        discard parseState(bad)
      except ValueError:
        raised = true
      check raised
