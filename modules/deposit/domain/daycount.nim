## Domain murni modul `deposit` (T-138a): basis hitung hari bunga (day-count).
##
## Batas berkas ini sengaja sempit: **hanya hari**. Nominal bunga (uang) dihitung di tempat lain,
## karena rumusnya menyentuh `Money`, `interest_rate`, dan `rounding_scale` dari parameter produk
## dan wajib lewat review manusia (D-152, AGENTS.md §8). Tidak ada uang, tidak ada pembulatan,
## tidak ada I/O di sini.
##
## Basis dipilih lewat parameter `product.savings.day_count_basis` (enum yang sama, spec §10.5).
## Berkas ini **tidak** punya basis default: nilai default institusi `dcAct365` adalah keputusan
## pemilik (D-152) yang dibaca composition root dari parameter, bukan bawaan kode.

import std/strutils

import kernel/[businessdate, result]

const
  ## Konvensi pasar untuk pembagi tahun, **bukan** kebijakan institusi: ACT/365 memakai panjang
  ## tahun sipil, sedangkan ACT/360 dan 30/360 memakai tahun fiskal 360 hari yang lazim di pasar
  ## uang. Angka ini mengubah arti nama basis, jadi jangan "disesuaikan" per produk.
  actYearDays = 365 # nomagic:ok konvensi pasar ACT/365, bukan nilai bisnis (D-152)
  fiscalYearDays = 360 # nomagic:ok konvensi pasar ACT/360 & 30/360, bukan nilai bisnis (D-152)
  ## Konvensi 30/360 memperlakukan setiap bulan sebagai 30 hari.
  daysPerMonth30 = 30 # nomagic:ok konvensi 30/360: satu bulan = 30 hari
  ## Batas kalender Gregorian; dipakai untuk mendeteksi tanggal 31.
  maxDaysInMonth = 31 # nomagic:ok invarian kalender Gregorian

type
  ## Basis day-count yang boleh dipakai akrual bunga. Nilai string sama persis dengan
  ## `product.savings.day_count_basis`; menambah anggota = mengubah definisi parameter, bukan
  ## menerima nilai bebas.
  DayCountBasis* = enum
    dcAct365 = "ACT_365"
    dcAct360 = "ACT_360"
    dcThirty360 = "THIRTY_360"

proc parseDayCountBasis*(s: string): DayCountBasis =
  ## Menerjemahkan nilai parameter menjadi basis. Case-insensitive; nilai tak dikenal menaikkan
  ## `ValueError` — sengaja tanpa fallback diam-diam, supaya salah ketik di seed/param tidak
  ## diam-diam berubah menjadi basis lain (yang berarti bunga salah hitung).
  let t = s.strip()
  for b in DayCountBasis:
    if cmpIgnoreCase($b, t) == 0:
      return b
  raise newException(ValueError, "unknown day-count basis: " & s)

proc basisDays*(b: DayCountBasis): int =
  ## Pembagi tahun untuk basis ini (hari dalam setahun menurut konvensi). ACT/365 dan ACT/360
  ## hanya berbeda di sini, bukan di hitungan hari.
  case b
  of dcAct365: actYearDays
  of dcAct360, dcThirty360: fiscalYearDays

proc parseOrRaise(s: string): BusinessDate =
  let r = parseBusinessDate(s)
  if isErr(r):
    raise newException(ValueError, "invalid ISO date '" & s & "': " & r.error.details)
  value(r)

proc accrualDays*(b: DayCountBasis, startsOn, endsOn: string): int =
  ## Jumlah hari akrual dari `startsOn` sampai `endsOn` (tanggal ISO `YYYY-MM-DD`), menurut `b`.
  ## Keduanya inklusif-awal/eksklusif-akhir seperti `daysBetween`: rentang satu hari = 1.
  ## `startsOn` harus <= `endsOn`; urutan terbalik menaikkan `ValueError` (akrual negatif bukan
  ## kejadian sah, dan menebak tanda akan menyembunyikan bug pemanggil).
  ##
  ## ACT/365 dan ACT/360 memakai selisih hari kalender yang sama; basis hanya memengaruhi
  ## `basisDays` (pembagi) saat bunga dihitung.
  ##
  ## dcThirty360 memakai konvensi 30/360 US (NASD):
  ##   1. D1 = 31 → D1 = 30;
  ##   2. D2 = 31 dan D1 ∈ {30, 31} (setelah langkah 1) → D2 = 30;
  ##   3. bila **kedua** tanggal adalah hari terakhir Februari → D2 = 30.
  ## Rumus: 360*(y2−y1) + 30*(m2−m1) + (d2−d1).
  ##
  ## NEEDS-COMPLIANCE-REVIEW: 30/360 US dipilih karena paling umum untuk simpanan; alternatif
  ## 30E/360 (tanpa langkah 2) memberi hasil berbeda pada sebagian tanggal, jadi konvensi ini
  ## perlu dikonfirmasi compliance sebelum data anggota nyata. Konsekuensi yang harus diketahui
  ## pemakai: rentang pendek di akhir bulan bisa menghasilkan **0 hari** (mis. 30 Jan → 31 Jan),
  ## karena kedua tanggal dipetakan ke hari ke-30. Itu artefak konvensi, bukan bug — dan alasan
  ## `ACT_365` menjadi default institusi (D-152).
  let a = parseOrRaise(startsOn)
  let z = parseOrRaise(endsOn)
  if z < a:
    raise newException(ValueError, "startsOn must not be after endsOn: " & startsOn & " > " & endsOn)

  case b
  of dcAct365, dcAct360:
    daysBetween(a, z)
  of dcThirty360:
    var d1 = a.day
    var d2 = z.day
    if d1 == maxDaysInMonth:
      d1 = daysPerMonth30
    if d2 == maxDaysInMonth and d1 == daysPerMonth30:
      d2 = daysPerMonth30
    if a.month == 2 and z.month == 2 and isLastDayOfMonth(a) and isLastDayOfMonth(z):
      d2 = daysPerMonth30
    fiscalYearDays * (z.year - a.year) +
      daysPerMonth30 * (z.month - a.month) + (d2 - d1)
