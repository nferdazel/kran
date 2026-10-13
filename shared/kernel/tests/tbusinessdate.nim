import std/unittest

import kernel/businessdate

proc d(s: string): BusinessDate =
  parseBusinessDate(s).value

suite "businessdate":
  test "validasi tanggal nyata":
    check businessDate(2024, 2, 29).isOk      # kabisat
    check businessDate(2023, 2, 29).isErr     # bukan kabisat
    check businessDate(2026, 2, 30).isErr
    check businessDate(2026, 13, 1).isErr
    check businessDate(2026, 0, 1).isErr
    check businessDate(2026, 4, 31).isErr
    check businessDate(0, 1, 1).isErr

  test "isLeapYear":
    check isLeapYear(2024)
    check not isLeapYear(2023)
    check not isLeapYear(1900)
    check isLeapYear(2000)

  test "parse tepat YYYY-MM-DD":
    check parseBusinessDate("2026-10-13").isOk
    check parseBusinessDate("2026-10-13").value.toIso == "2026-10-13"
    check parseBusinessDate("2026-2-1").isErr
    check parseBusinessDate("2026-02-30").isErr
    check parseBusinessDate("2026/10/13").isErr
    check parseBusinessDate("2026-10-13 ").isErr

  test "dayOfWeek ISO-8601":
    check d("1970-01-01").dayOfWeek == 4    # Kamis
    check d("2000-01-01").dayOfWeek == 6    # Sabtu
    check d("2026-10-13").dayOfWeek == 2    # Selasa
    check d("2024-02-29").dayOfWeek == 4    # Kamis (kabisat)

  test "addDays lintas bulan/tahun":
    check d("2024-02-28").addDays(1).toIso == "2024-02-29"
    check d("2024-02-28").addDays(2).toIso == "2024-03-01"
    check d("2023-02-28").addDays(1).toIso == "2023-03-01"
    check d("2024-03-01").addDays(-1).toIso == "2024-02-29"
    check d("2024-12-31").addDays(1).toIso == "2025-01-01"

  test "daysBetween lintas kabisat":
    check daysBetween(d("2024-01-01"), d("2025-01-01")) == 366
    check daysBetween(d("2023-01-01"), d("2024-01-01")) == 365
    check daysBetween(d("2024-02-28"), d("2024-03-01")) == 2
    check daysBetween(d("2023-02-28"), d("2023-03-01")) == 1
    check daysBetween(d("2024-03-01"), d("2024-02-28")) == -2

  test "isLastDayOfMonth / isLastDayOfYear":
    check d("2024-02-29").isLastDayOfMonth
    check not d("2024-02-28").isLastDayOfMonth
    check d("2026-04-30").isLastDayOfMonth
    check d("2024-12-31").isLastDayOfYear
    check not d("2024-12-30").isLastDayOfYear

  test "urutan":
    check d("2024-01-01") < d("2024-01-02")
    check d("2024-01-02") <= d("2024-01-02")
    check d("2023-12-31") < d("2024-01-01")
