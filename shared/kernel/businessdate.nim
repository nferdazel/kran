## BusinessDate — tanggal buku (spec §9.1(6)), murni aritmetika kalender **tanpa** `std/times`.
##
## Tiga jenis tanggal dipisahkan tegas di seluruh sistem: `business_date` (tanggal buku),
## `value_date`, dan `recorded_at` (timestamptz teknis). Tipe ini hanya mewakili yang pertama.
##
## Konversi ke/dari `DateTime` dilakukan lapisan infrastruktur (bukan di domain).

import std/strutils
import ./result

type
  BusinessDate* = object
    year*: int
    month*: int ## 1–12
    day*: int   ## 1–31, divalidasi per bulan

proc isLeapYear*(y: int): bool =
  (y mod 4 == 0 and y mod 100 != 0) or (y mod 400 == 0)

proc daysInMonth*(y, m: int): int =
  case m
  of 1, 3, 5, 7, 8, 10, 12: 31
  of 4, 6, 9, 11: 30
  of 2: (if isLeapYear(y): 29 else: 28)
  else: 0

proc dateErr(msg: string): AppError {.inline.} =
  appError("CBS-1201", "error.businessDate.invalid", aekValidation, msg)

proc businessDate*(y, m, d: int): AppResult[BusinessDate] =
  if y < 1 or y > 9999:
    return err[BusinessDate, AppError](dateErr("tahun di luar 1..9999: " & $y))
  if m < 1 or m > 12:
    return err[BusinessDate, AppError](dateErr("bulan di luar 1..12: " & $m))
  if d < 1 or d > daysInMonth(y, m):
    return err[BusinessDate, AppError](dateErr(
      "hari di luar rentang bulan: " & $y & "-" & $m & "-" & $d
    ))
  ok[BusinessDate, AppError](BusinessDate(year: y, month: m, day: d))

proc toIso*(d: BusinessDate): string =
  ## "YYYY-MM-DD" (spec §13: tanggal bisnis selalu ISO).
  var y = $d.year
  while y.len < 4:
    y = "0" & y
  var m = $d.month
  if m.len < 2: m = "0" & m
  var dd = $d.day
  if dd.len < 2: dd = "0" & dd
  y & "-" & m & "-" & dd

proc `$`*(d: BusinessDate): string =
  toIso(d)

proc parseBusinessDate*(s: string): AppResult[BusinessDate] =
  ## Wajib persis "YYYY-MM-DD".
  let t = s.strip()
  if t.len != 10 or t[4] != '-' or t[7] != '-':
    return err[BusinessDate, AppError](dateErr("format harus YYYY-MM-DD: " & s))
  var nums: array[3, int]
  var idx = 0
  var acc = 0
  for i in 0 ..< t.len:
    if i == 4 or i == 7:
      nums[idx] = acc
      inc idx
      acc = 0
      continue
    let c = t[i]
    if c notin {'0' .. '9'}:
      return err[BusinessDate, AppError](dateErr("bukan angka: " & s))
    acc = acc * 10 + (ord(c) - ord('0'))
  nums[idx] = acc
  businessDate(nums[0], nums[1], nums[2])

proc cmp*(a, b: BusinessDate): int =
  result = system.cmp(a.year, b.year)
  if result == 0: result = system.cmp(a.month, b.month)
  if result == 0: result = system.cmp(a.day, b.day)

proc `==`*(a, b: BusinessDate): bool {.inline.} =
  a.year == b.year and a.month == b.month and a.day == b.day

proc `<`*(a, b: BusinessDate): bool {.inline.} =
  cmp(a, b) < 0

proc `<=`*(a, b: BusinessDate): bool {.inline.} =
  cmp(a, b) <= 0

proc daysFromCivil*(y, m, d: int): int64 =
  ## Hari sejak 1970-01-01 (algoritma Hinnant, invarian matematis — boleh di kode).
  var yy = int64(y)
  if m <= 2:
    dec yy
  let era = (if yy >= 0: yy else: yy - 399) div 400
  let yoe = yy - era * 400
  let mp = int64((m + 9) mod 12)
  let doy = (153 * mp + 2) div 5 + int64(d) - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc civilFromDays*(z: int64): BusinessDate =
  var zz = z + 719468
  let era = (if zz >= 0: zz else: zz - 146096) div 146097
  let doe = zz - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = (mp + 2) mod 12 + 1
  let yy = if m <= 2: y + 1 else: y
  BusinessDate(year: int(yy), month: int(m), day: int(d))

proc addDays*(d: BusinessDate, n: int): BusinessDate =
  civilFromDays(daysFromCivil(d.year, d.month, d.day) + int64(n))

proc daysBetween*(a, b: BusinessDate): int =
  ## b - a, dalam hari (boleh negatif).
  int(daysFromCivil(b.year, b.month, b.day) - daysFromCivil(a.year, a.month, a.day))

proc floorMod(a, b: int): int {.inline.} =
  ((a mod b) + b) mod b

proc dayOfWeek*(d: BusinessDate): int =
  ## ISO-8601: 1 = Senin … 7 = Minggu.
  let z = daysFromCivil(d.year, d.month, d.day)
  floorMod(int(floorMod(z, 7)) + 3, 7) + 1

proc isLastDayOfMonth*(d: BusinessDate): bool =
  d.day == daysInMonth(d.year, d.month)

proc isLastDayOfYear*(d: BusinessDate): bool =
  d.month == 12 and d.day == 31
