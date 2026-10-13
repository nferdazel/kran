## Money — uang fixed-point skala 10⁴ dalam int64 (spec §9.1(2), ADR-011).
##
## **Tidak ada `float` di berkas ini.** Pembulatan yang dipakai seragam: **half-to-even**
## (banker's rounding), karena pembulatan "selalu ke atas" membuat bias pada akrual besar.
##
## Overflow int64 **tidak pernah dibiarkan diam-diam**: operasi yang melampaui rentang
## menaikkan `MoneyOverflowError` (spec §12.2: exception untuk kondisi di luar kontrak).

import std/strutils
import ./result, ./rate, ./checkedint

export checkedint

type
  ## Alias yang lebih spesifik untuk pemakaian uang. Tipe yang sama dengan
  ## `ArithmeticOverflowError` supaya aturan overflow hanya ada satu.
  MoneyOverflowError* = ArithmeticOverflowError
  Money* = object
    units: int64 ## unit terkecil = 10⁻⁴; private agar tidak dibuat sembarangan

const
  moneyScale* = 4
  moneyScaleFactor* = 10_000'i64
  rateDenominator* = 1_000_000'i64 ## 1e6 = penyebut untuk perkalian dengan Rate

proc zero*(): Money {.inline.} =
  Money(units: 0)

proc money*(minorUnits: int64): Money {.inline.} =
  ## Membungkus unit terkecil (10⁻⁴). `money(15000000)` = 1500,0000.
  Money(units: minorUnits)

proc minorUnits*(m: Money): int64 {.inline.} =
  m.units

proc `+`*(a, b: Money): Money {.inline.} =
  Money(units: checkedAdd(a.units, b.units))

proc `-`*(a, b: Money): Money {.inline.} =
  Money(units: checkedSub(a.units, b.units))

proc `-`*(a: Money): Money {.inline.} =
  Money(units: checkedNeg(a.units))

proc `==`*(a, b: Money): bool {.inline.} =
  a.units == b.units

proc cmp*(a, b: Money): int {.inline.} =
  system.cmp(a.units, b.units)

proc `<`*(a, b: Money): bool {.inline.} =
  a.units < b.units

proc `<=`*(a, b: Money): bool {.inline.} =
  a.units <= b.units

proc isZero*(m: Money): bool {.inline.} =
  m.units == 0

proc isNegative*(m: Money): bool {.inline.} =
  m.units < 0

proc isPositive*(m: Money): bool {.inline.} =
  m.units > 0

proc abs*(m: Money): Money =
  Money(units: (if m.units < 0: checkedNeg(m.units) else: m.units))

proc sum*(xs: openArray[Money]): Money =
  var acc = zero()
  for x in xs:
    acc = acc + x
  acc

proc `*`*(m: Money, factor: int64): Money {.inline.} =
  Money(units: checkedMul(m.units, factor))

proc `div`*(m: Money, divisor: int64): Money =
  ## Pembagian dengan pembulatan half-to-even. Pembagi 0 dilarang (nilai bisnis).
  if divisor == 0:
    raise newException(ValueError, "pembagian Money dengan nol")
  let neg = divisor < 0
  let d = (if neg: -divisor else: divisor)
  let q = divRoundHalfEven(m.units, d)
  Money(units: (if neg: -q else: q))

proc moneyErr(msg: string, code = "CBS-1101"): AppError {.inline.} =
  appError(code, "error.money.invalid", aekValidation, msg)

proc moneyFromString*(s: string): AppResult[Money] =
  ## Bentuk yang diterima: `[+-]?angka[.desimal]` dengan **maksimum 4 desimal**
  ## (skala penyimpanan spec §9.1(2)). Lebih dari 4 desimal ditolak, bukan dibulatkan.
  var t = s.strip()
  if t.len == 0:
    return err[Money, AppError](moneyErr("string kosong"))

  var neg = false
  var i = 0
  if t[0] == '-' or t[0] == '+':
    neg = t[0] == '-'
    inc i

  let intStart = i
  var whole: int64 = 0
  while i < t.len and t[i] in {'0' .. '9'}:
    try:
      whole = checkedMul(whole, 10)
      whole = checkedAdd(whole, int64(ord(t[i]) - ord('0')))
    except MoneyOverflowError:
      return err[Money, AppError](moneyErr("angka terlalu besar: " & s, "CBS-1102"))
    inc i
  let intDigits = i - intStart

  var frac = ""
  var sawDot = false
  if i < t.len and t[i] == '.':
    sawDot = true
    inc i
    while i < t.len and t[i] in {'0' .. '9'}:
      frac.add(t[i])
      inc i
  if i != t.len:
    return err[Money, AppError](moneyErr("karakter tidak dikenal: " & s))
  if intDigits == 0:
    return err[Money, AppError](moneyErr("bagian bulat wajib ada: " & s))
  if sawDot and frac.len == 0:
    return err[Money, AppError](moneyErr("titik tanpa angka desimal: " & s))
  if frac.len > moneyScale:
    return err[Money, AppError](moneyErr(
      "maksimum " & $moneyScale & " desimal: " & s, "CBS-1103"
    ))

  while frac.len < moneyScale:
    frac.add('0')
  var fracUnits: int64 = 0
  for c in frac:
    fracUnits = fracUnits * 10 + int64(ord(c) - ord('0'))

  try:
    var u = checkedAdd(checkedMul(whole, moneyScaleFactor), fracUnits)
    if neg:
      u = -u
    result = ok[Money, AppError](money(u))
  except MoneyOverflowError:
    result = err[Money, AppError](moneyErr("angka terlalu besar: " & s, "CBS-1102"))

proc toDecimalString*(m: Money): string =
  ## Bentuk kanonik untuk API/kontrak: **selalu 4 desimal**, mis. "1500000.0000".
  let neg = m.units < 0
  let a = (if neg: checkedNeg(m.units) else: m.units)
  var frac = $(a mod moneyScaleFactor)
  while frac.len < moneyScale:
    frac = "0" & frac
  (if neg: "-" else: "") & $(a div moneyScaleFactor) & "." & frac

proc toDisplayString*(m: Money): string =
  ## Bentuk untuk tampilan umum: 2 desimal, half-to-even (spec §16.2: IDR tanpa desimal
  ## di tampilan umum tetap ditampilkan tanpa pemotongan nilai — pemformatan locale
  ## dilakukan frontend; ini hanya representasi ringkas).
  let cents = divRoundHalfEven(m.units, 100)
  let neg = cents < 0
  let a = (if neg: checkedNeg(cents) else: cents)
  var frac = $(a mod 100)
  while frac.len < 2:
    frac = "0" & frac
  (if neg: "-" else: "") & $(a div 100) & "." & frac

proc applyRate*(m: Money, r: Rate): Money =
  ## Money × Rate dengan pembulatan half-to-even. Perkalian didekomposisi agar tidak
  ## overflow: (q·10⁶ + rem) × micro / 10⁶ = q·micro + (rem·micro)/10⁶.
  let micro = r.microUnits
  if m.units == 0 or micro == 0:
    return zero()
  let q = m.units div rateDenominator
  let rem = m.units mod rateDenominator
  var u = checkedMul(q, micro)
  u = checkedAdd(u, divRoundHalfEven(checkedMul(rem, micro), rateDenominator))
  Money(units: u)
