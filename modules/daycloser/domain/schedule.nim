## Domain murni modul `daycloser` (T-139b): jadwal penutupan otomatis.
##
## Repo belum punya basis data zona waktu (spec §22: "disimpan UTC; tampil sesuai cabang"),
## sedangkan operator berpikir dalam jam lokal. Karena itu jadwal dinyatakan sebagai **jam lokal**
## plus **selisih UTC dalam menit** dari parameter (`daycloser.auto.utc_offset_minutes`), bukan
## nama zona. Konsekuensinya jujur: institusi dengan DST harus menyesuaikan parameternya sendiri —
## tidak ada di Indonesia, dan menebak zona dari nama akan butuh tabel tz.
##
## Tidak ada I/O, tidak ada DB, tidak ada jam sistem: semua masukan eksplisit supaya bisa diuji.

import std/[math, strutils]

type
  ClockTime* = object
    ## Jam lokal `HH:MM` (24 jam).
    hour*: int
    minute*: int

const
  minutesPerDay* = 24 * 60 # nomagic:ok invarian kalender, bukan ambang bisnis
  minutesPerHour = 60      # nomagic:ok invarian kalender
  clockTextLength = 5      # nomagic:ok panjang bentuk "HH:MM"
  colonAt = 2              # nomagic:ok posisi ':' pada bentuk "HH:MM"
  lastHour = 23            # nomagic:ok kalender 24 jam
  lastMinute = 59          # nomagic:ok kalender 60 menit

proc parseClockTime*(s: string): ClockTime =
  ## Bentuk yang diterima hanya `HH:MM` (dua digit, 00–23 / 00–59). Nilai lain **ditolak**:
  ## parameter yang salah ketik tidak boleh diam-diam berarti tengah malam.
  let raw = s.strip()
  if raw.len != clockTextLength or raw[colonAt] != ':':
    raise newException(ValueError, "jam harus berbentuk HH:MM, bukan '" & s & "'")
  let hh = raw[0 .. colonAt - 1]
  let mm = raw[colonAt + 1 .. ^1]
  if not (hh[0] in {'0' .. '9'} and hh[1] in {'0' .. '9'} and
          mm[0] in {'0' .. '9'} and mm[1] in {'0' .. '9'}):
    raise newException(ValueError, "jam harus berbentuk HH:MM, bukan '" & s & "'")
  let hour = parseInt(hh)
  let minute = parseInt(mm)
  if hour > lastHour or minute > lastMinute:
    raise newException(ValueError, "jam di luar rentang 00:00–23:59: '" & s & "'")
  ClockTime(hour: hour, minute: minute)

proc toMinutes*(t: ClockTime): int =
  ## Menit sejak tengah malam lokal.
  t.hour * minutesPerHour + t.minute

proc localMinutesOfDay*(utcMinutes: int; offsetMinutes: int): int =
  ## Menit sejak tengah malam **lokal**, dari menit UTC dan selisih zona. Nilai dibungkus ke
  ## 0..1439 (offset negatif bisa memundurkan ke hari sebelumnya — itu benar untuk perbandingan
  ## "apakah jam lokal sudah lewat", bukan untuk menghitung tanggal).
  result = (utcMinutes + offsetMinutes) mod minutesPerDay
  if result < 0:
    result += minutesPerDay

proc dueNow*(nowMinutes, runAtMinutes: int): bool =
  ## Jadwal dianggap jatuh tempo setelah jamnya terlewati **pada hari itu**. Tanpa toleransi:
  ## pemanggil (timer) yang mengulang setiap beberapa menit, dan penjaga "sudah ada run untuk
  ## tanggal buku ini" yang mencegah penutupan ganda.
  nowMinutes >= runAtMinutes
