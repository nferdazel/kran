## `BusinessDate` — tanggal buku (spec §9.1(6): `business_date` dipisah dari `value_date` dan
## `recorded_at`). **Tanpa import `std/times`** — aritmetika kalender dihitung sendiri agar
## domain bebas dari jam/ zona waktu implisit.
##
## Rentang tahun yang didukung: 1..9999 (format ISO `YYYY-MM-DD`).

import ./result

export result

type
  ## Tanggal buku tanpa waktu (YYYY-MM-DD).
  BusinessDate* = object
    year*, month*, day*: int

proc isLeapYear*(y: int): bool =
  ## True bila tahun kabisat (kaidah Gregorian).
  (y mod 4 == 0 and y mod 100 != 0) or (y mod 400 == 0)

proc daysInMonth(y, m: int): int =
  const tbl = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if m == 2 and isLeapYear(y):
    29
  else:
    tbl[m - 1]

proc businessDate*(y, m, d: int): AppResult[BusinessDate] =
  ## Bangun tanggal buku; memvalidasi bulan & hari nyata (termasuk kabisat).
  if y < 1 or y > 9999:
    return err[BusinessDate, AppError](
      appError("KRN-1201", "kernel.date.invalid", aekValidation, "tahun di luar 1..9999"))
  if m < 1 or m > 12:
    return err[BusinessDate, AppError](
      appError("KRN-1201", "kernel.date.invalid", aekValidation, "bulan tidak sah"))
  if d < 1 or d > daysInMonth(y, m):
    return err[BusinessDate, AppError](
      appError("KRN-1201", "kernel.date.invalid", aekValidation, "hari tidak sah"))
  ok[BusinessDate, AppError](BusinessDate(year: y, month: m, day: d))

proc isDigit(c: char): bool {.inline.} = c in {'0' .. '9'}

proc twoDigits(s: string, i: int): int {.inline.} =
  (ord(s[i]) - ord('0')) * 10 + (ord(s[i + 1]) - ord('0'))

proc parseBusinessDate*(s: string): AppResult[BusinessDate] =
  ## Parse tepat `"YYYY-MM-DD"`; bentuk lain ditolak.
  if s.len != 10 or s[4] != '-' or s[7] != '-':
    return err[BusinessDate, AppError](
      appError("KRN-1201", "kernel.date.invalid", aekValidation, s))
  for i in 0 ..< 10:
    if i == 4 or i == 7:
      continue
    if not isDigit(s[i]):
      return err[BusinessDate, AppError](
        appError("KRN-1201", "kernel.date.invalid", aekValidation, s))
  let y = (ord(s[0]) - ord('0')) * 1000 + (ord(s[1]) - ord('0')) * 100 +
          (ord(s[2]) - ord('0')) * 10 + (ord(s[3]) - ord('0'))
  businessDate(y, twoDigits(s, 5), twoDigits(s, 8))

proc pad(n, width: int): string =
  result = $n
  while result.len < width:
    result = "0" & result

proc toIso*(d: BusinessDate): string =
  ## Representasi ISO `"YYYY-MM-DD"` (tahun 4 digit).
  pad(d.year, 4) & "-" & pad(d.month, 2) & "-" & pad(d.day, 2)

proc `$`*(d: BusinessDate): string = toIso(d)

proc `==`*(a, b: BusinessDate): bool {.inline.} =
  a.year == b.year and a.month == b.month and a.day == b.day

proc cmp*(a, b: BusinessDate): int =
  if a.year != b.year: cmp(a.year, b.year)
  elif a.month != b.month: cmp(a.month, b.month)
  else: cmp(a.day, b.day)

proc `<`*(a, b: BusinessDate): bool {.inline.} = cmp(a, b) < 0
proc `<=`*(a, b: BusinessDate): bool {.inline.} = cmp(a, b) <= 0

proc daysFromCivil(y, m, d: int): int =
  ## Hari sejak 1970-01-01 (algoritma Howard Hinnant).
  var yy = y
  if m <= 2:
    dec yy
  let era = (if yy >= 0: yy else: yy - 399) div 400
  let yoe = yy - era * 400
  let doy = (153 * (if m > 2: m - 3 else: m + 9) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc civilFromDays(z: int): BusinessDate =
  let zz = z + 719468
  let era = (if zz >= 0: zz else: zz - 146096) div 146097
  let doe = zz - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  BusinessDate(year: (if m <= 2: y + 1 else: y), month: m, day: d)

proc addDays*(d: BusinessDate, n: int): BusinessDate =
  ## Geser `n` hari (boleh negatif) melintasi batas bulan/tahun.
  civilFromDays(daysFromCivil(d.year, d.month, d.day) + n)

proc daysBetween*(a, b: BusinessDate): int =
  ## Jumlah hari dari `a` ke `b` (`b - a`).
  daysFromCivil(b.year, b.month, b.day) - daysFromCivil(a.year, a.month, a.day)

proc dayOfWeek*(d: BusinessDate): int =
  ## ISO-8601: 1 = Senin .. 7 = Minggu.
  let z = daysFromCivil(d.year, d.month, d.day)
  ((z + 3) mod 7 + 7) mod 7 + 1

proc isLastDayOfMonth*(d: BusinessDate): bool =
  ## True bila `d` adalah hari terakhir bulan.
  d.day == daysInMonth(d.year, d.month)

proc isLastDayOfYear*(d: BusinessDate): bool =
  ## True bila `d` adalah 31 Desember.
  d.month == 12 and d.day == 31
