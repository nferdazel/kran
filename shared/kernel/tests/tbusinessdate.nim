import std/unittest
import std/times
import kernel

suite "businessdate":
  test "parse dan format ISO round-trip":
    let d = parseBusinessDate("2026-10-13").value
    check d.year == 2026
    check d.month == 10
    check d.day == 13
    check d.toIso == "2026-10-13"
    check $d == "2026-10-13"
    check businessDate(2026, 1, 5).value.toIso == "2026-01-05"
    check parseBusinessDate(" 2026-10-13 ").value == d

  test "menolak tanggal tidak sah":
    for s in ["2026-02-30", "2023-02-29", "2026-13-01", "2026-00-10", "2026-10-32",
              "2026-1-1", "20261013", "2026/10/13", "", "abcd-ef-gh", "2026-10-13T00:00"]:
      check parseBusinessDate(s).isErr
    check businessDate(2024, 2, 29).isOk # 2024 kabisat
    check businessDate(0, 1, 1).isErr
    check businessDate(10000, 1, 1).isErr

  test "tahun kabisat":
    # Kualifikasi modul wajib di sini: `std/times` juga mengekspor `isLeapYear`.
    check businessdate.isLeapYear(2024)
    check businessdate.isLeapYear(2000)
    check not businessdate.isLeapYear(2100)
    check not businessdate.isLeapYear(2023)
    check daysInMonth(2024, 2) == 29
    check daysInMonth(2023, 2) == 28
    check daysInMonth(2026, 4) == 30

  test "addDays melintasi batas bulan/tahun/kabisat":
    check parseBusinessDate("2024-02-28").value.addDays(1).toIso == "2024-02-29"
    check parseBusinessDate("2024-02-28").value.addDays(2).toIso == "2024-03-01"
    check parseBusinessDate("2023-02-28").value.addDays(1).toIso == "2023-03-01"
    check parseBusinessDate("2023-12-31").value.addDays(1).toIso == "2024-01-01"
    check parseBusinessDate("2024-01-01").value.addDays(-1).toIso == "2023-12-31"
    let d = parseBusinessDate("2026-10-13").value
    check d.addDays(365).addDays(-365) == d

  test "daysBetween":
    let a = parseBusinessDate("2024-01-01").value
    let b = parseBusinessDate("2024-12-31").value
    check daysBetween(a, b) == 365
    check daysBetween(a, parseBusinessDate("2025-01-01").value) == 366 # 2024 kabisat
    check daysBetween(b, a) == -365
    check daysBetween(a, a) == 0

  test "dayOfWeek (ISO: 1=Senin) cocok dengan std/times":
    # Cross-check independen: tanggal acuan dihitung dengan pustaka standar.
    for s in ["1970-01-01", "2000-02-29", "2023-01-01", "2024-02-29", "2026-10-13",
              "2099-12-31", "2026-01-04", "2026-01-05"]:
      let d = parseBusinessDate(s).value
      let dt = dateTime(d.year, Month(d.month), d.day, 0, 0, 0, 0, utc())
      let isoDow = weekday(dt).ord + 1 # WeekDay: dMon..dSun = 0..6
      check d.dayOfWeek == isoDow

  test "akhir bulan/tahun":
    check parseBusinessDate("2024-02-29").value.isLastDayOfMonth
    check not parseBusinessDate("2024-02-28").value.isLastDayOfMonth
    check parseBusinessDate("2023-02-28").value.isLastDayOfMonth
    check parseBusinessDate("2026-12-31").value.isLastDayOfYear
    check not parseBusinessDate("2026-12-30").value.isLastDayOfYear

  test "urutan":
    check parseBusinessDate("2026-01-31").value < parseBusinessDate("2026-02-01").value
    check parseBusinessDate("2026-02-01").value <= parseBusinessDate("2026-02-01").value
    check cmp(parseBusinessDate("2026-02-01").value,
              parseBusinessDate("2026-01-31").value) == 1
