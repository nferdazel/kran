## Kalender kerja & business date (spec §9.3, §11.2) — murni, tanpa I/O.
##
## Semua **nilai** kalender datang dari DB: hari libur dari tabel `platform.holiday`, bentuk
## kalender (akhir pekan, awal tahun fiskal) dari parameter (spec §10.5). Yang tinggal di sini
## hanya invarian matematis & aturan transisi state.
##
## `CloseLevel` hidup di kernel (`kernel/dayclose`) karena dipakai dua modul: kalender yang
## menentukannya dan `daycloser` yang melaksanakannya. Modul ini hanya menyediakan
## `closeLevelsFor` + aturan transisi business date.

import std/[json, sets]
import kernel/[businessdate, dayclose, result]

export dayclose

type
  BusinessDateState* = enum
    bdsOpen = "OPEN"
    bdsClosing = "CLOSING"
    bdsClosed = "CLOSED"

  CalendarShape* = object
    ## Bentuk kalender efektif (dari param + tabel hari libur).
    weekendDays*: seq[int]     ## nomor hari ISO (1 = Senin … 7 = Minggu)
    fiscalYearStartMonth*: int ## 1..12
    holidays*: HashSet[string] ## tanggal ISO (YYYY-MM-DD) yang bukan hari kerja

const
  monthsInYear* = 12
  monthsPerQuarter* = 3  # nomagic:ok invarian matematis: 3 bulan per kuartal (spec §10.1)
  ## Nomor hari ISO: 1 = Senin … 7 = Minggu (standar ISO-8601, bukan nilai bisnis).
  isoWeekdaysInWeek* = 7 # nomagic:ok invarian kalender ISO-8601

proc parseWeekendDays*(node: JsonNode): seq[int] =
  ## Validasi nilai param `platform.calendar.weekend_days` (array nomor hari ISO).
  ## Raise `ValueError` bila bentuknya salah — tidak ada fallback diam-diam (spec §10.6).
  if node.isNil or node.kind != JArray:
    raise newException(ValueError, "weekend_days harus array nomor hari ISO (1..7)")
  if node.len == 0:
    raise newException(ValueError, "weekend_days tidak boleh kosong")
  for item in node:
    if item.kind != JInt:
      raise newException(ValueError, "weekend_days harus berisi angka, dapat: " & $item)
    let v = int(item.getInt())
    if v < 1 or v > isoWeekdaysInWeek:
      raise newException(ValueError,
        "nomor hari ISO di luar 1.." & $isoWeekdaysInWeek & ": " & $v)
    if v in result:
      raise newException(ValueError, "nomor hari ganda di weekend_days: " & $v)
    result.add v

proc isWeekend*(d: BusinessDate, weekendDays: openArray[int]): bool =
  d.dayOfWeek in weekendDays

proc holidaySet*(isoDates: openArray[string]): HashSet[string] =
  for s in isoDates:
    result.incl s

proc isHoliday*(d: BusinessDate, holidays: HashSet[string]): bool =
  d.toIso in holidays

proc isWorkingDay*(d: BusinessDate, shape: CalendarShape): bool =
  not isWeekend(d, shape.weekendDays) and not isHoliday(d, shape.holidays)

proc nextWorkingDay*(start: BusinessDate, shape: CalendarShape): BusinessDate =
  ## Hari kerja berikutnya setelah `start` (tidak termasuk `start`).
  result = start.addDays(1)
  while not isWorkingDay(result, shape):
    result = result.addDays(1)

proc previousWorkingDay*(start: BusinessDate, shape: CalendarShape): BusinessDate =
  result = start.addDays(-1)
  while not isWorkingDay(result, shape):
    result = result.addDays(-1)

proc lastWorkingDayOfMonth*(year, month: int, shape: CalendarShape): BusinessDate =
  ## Hari kerja terakhir pada bulan tersebut (mundur bila akhir bulan jatuh di libur/akhir pekan).
  result = businessDate(year, month, daysInMonth(year, month)).value()
  while not isWorkingDay(result, shape):
    result = result.addDays(-1)

proc isQuarterEndMonth*(month: int): bool =
  month mod monthsPerQuarter == 0

proc fiscalYearEndMonth*(fiscalYearStartMonth: int): int =
  ## Bulan terakhir tahun fiskal = bulan sebelum tahun fiskal berikutnya dimulai.
  if fiscalYearStartMonth < 1 or fiscalYearStartMonth > monthsInYear:
    raise newException(ValueError,
      "fiscal_year_start_month di luar 1..12: " & $fiscalYearStartMonth)
  if fiscalYearStartMonth == 1:
    monthsInYear
  else:
    fiscalYearStartMonth - 1

proc closeLevelsFor*(d: BusinessDate, shape: CalendarShape): set[CloseLevel] =
  ## Level penutupan untuk satu tanggal (spec §11.2).
  ##   - Hari bukan hari kerja → himpunan kosong (tidak ada penutupan yang dijalankan).
  ##   - `EOD` selalu; `EOM` bila hari kerja terakhir bulan; `EOQ` bila sekaligus akhir kuartal;
  ##     `EOY` bila sekaligus akhir tahun fiskal.
  if not isWorkingDay(d, shape):
    return {}
  result = {clEOD}
  if d != lastWorkingDayOfMonth(d.year, d.month, shape):
    return
  result.incl clEOM
  if isQuarterEndMonth(d.month):
    result.incl clEOQ
  if d.month == fiscalYearEndMonth(shape.fiscalYearStartMonth):
    result.incl clEOY

proc canTransition*(current, next: BusinessDateState): bool =
  ## Hanya satu jalur sah: `OPEN → CLOSING → CLOSED`.
  ##   - Rollover mengubah `current_date` pada baris yang sudah `CLOSED` (state kembali `OPEN`
  ##     untuk tanggal berikutnya) — bukan "membuka kembali" tanggal lama.
  ##   - Reopen/reverse EOD default **dilarang** (spec §11.7): butuh kebijakan param +
  ##     approval berjenjang, belum ada di Fase 0.
  (current == bdsOpen and next == bdsClosing) or (current == bdsClosing and next == bdsClosed)

proc canAbortClose*(current: BusinessDateState): bool =
  ## Membatalkan **percobaan** penutupan yang belum tersegel: `CLOSING → OPEN`.
  ##
  ## Ini bukan reopen EOD: belum ada seal, belum ada laporan, dan hari itu tidak pernah
  ## dinyatakan tutup — hanya dibekukan lalu gagal/dibatalkan. `CLOSED` tetap tidak bisa
  ## dibuka kembali (spec §11.7); tanpa jalur abort ini, satu run yang dibatalkan akan
  ## membekukan institusi selamanya.
  current == bdsClosing

proc parseState*(s: string): BusinessDateState =
  for st in BusinessDateState:
    if $st == s:
      return st
  raise newException(ValueError, "state business date tidak dikenal: " & s)
