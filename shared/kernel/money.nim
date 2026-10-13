## `Money` — fixed-point skala 10⁴ (int64 minor units), **tanpa float** (spec §9.1(2), ADR-011).
##
## Semua operasi integer. Pembulatan di seluruh kernel = **half-to-even** (banker's rounding).
## Overflow int64 menaikkan `MoneyOverflowError`; pembagian dengan nol menaikkan `ValueError`.
##
## Field minor unit privat; akses lewat `minorUnits()`.

import ./result
import ./rate

export result

type
  ## Overflow aritmetika `Money` (int64 tidak muat).
  MoneyOverflowError* = object of ValueError

  ## Uang diskalakan 10⁴ (10_000 minor unit per unit mayor). Field privat.
  Money* = object
    units: int64

const moneyScale* = 4
const moneyFactor = 10_000'i64

proc zero*(): Money {.inline.} =
  ## Uang nol.
  Money(units: 0)

proc money*(minorUnits: int64): Money {.inline.} =
  ## Bangun `Money` dari minor unit.
  Money(units: minorUnits)

proc minorUnits*(m: Money): int64 {.inline.} =
  ## Minor unit (10⁴ per unit mayor).
  m.units

# --- utilitas integer privat (tanpa float) ------------------------------------------------

proc absU(x: int64): uint64 {.inline.} =
  if x >= 0: uint64(x) else: uint64(-(x + 1)) + 1'u64

type U128 = object
  hi, lo: uint64

proc umul64(a, b: uint64): U128 =
  ## Produk 64×64 → 128 bit (uint64 wrap untuk bagian rendah).
  let a0 = a and 0xFFFFFFFF'u64
  let a1 = a shr 32
  let b0 = b and 0xFFFFFFFF'u64
  let b1 = b shr 32
  let p00 = a0 * b0
  let p01 = a0 * b1
  let p10 = a1 * b0
  let p11 = a1 * b1
  let mid = p01 + p10
  let midCarry = (if mid < p01: 1'u64 else: 0'u64)
  let midShift = mid shl 32
  let lo = p00 + midShift
  let loCarry = (if lo < p00: 1'u64 else: 0'u64)
  U128(hi: p11 + (mid shr 32) + (midCarry shl 32) + loCarry, lo: lo)

proc bitAt(n: U128, i: int): uint64 {.inline.} =
  if i >= 64: (n.hi shr (i - 64)) and 1'u64 else: (n.lo shr i) and 1'u64

proc udiv128by64(n: U128, d: uint64): (uint64, uint64) =
  ## Bagi 128 bit dengan 64 bit (d > 0). Quotient ≥ 2⁶⁴ menaikkan `MoneyOverflowError`.
  var q: uint64 = 0
  var rHi: uint64 = 0
  var rLo: uint64 = 0
  for i in countdown(127, 0):
    rHi = (rHi shl 1) or (rLo shr 63)
    rLo = rLo shl 1
    if bitAt(n, i) == 1'u64:
      rLo = rLo or 1'u64
    if rHi > 0 or rLo >= d:
      let oldLo = rLo
      rLo = rLo - d
      if oldLo < d:
        rHi = rHi - 1
      if i >= 64:
        raise newException(MoneyOverflowError, "money overflow")
      q = q or (1'u64 shl i)
  (q, rLo)

proc mulDivHalfEven(a, b, c: int64): int64 =
  ## round_half_even(a × b / c) untuk c ≠ 0. Overflow menaikkan `MoneyOverflowError`.
  if c == 0:
    raise newException(ValueError, "money: pembagian dengan nol")
  let neg = (a < 0) xor (b < 0) xor (c < 0)
  let uc = absU(c)
  let res = udiv128by64(umul64(absU(a), absU(b)), uc)
  var q = res[0]
  let rem = res[1]
  if rem > uc - rem:
    inc q
  elif rem == uc - rem and (q and 1'u64) == 1'u64:
    inc q
  let lim = if neg: (1'u64 shl 63) else: uint64(high(int64))
  if q > lim:
    raise newException(MoneyOverflowError, "money overflow")
  if neg:
    (if q == (1'u64 shl 63): low(int64) else: -int64(q))
  else:
    int64(q)

proc mulInt64Checked(a, b: int64): int64 =
  ## a × b dengan penjaga overflow (menaikkan `MoneyOverflowError`).
  if a == 0 or b == 0:
    return 0
  let ua = absU(a)
  let ub = absU(b)
  if ua > (1'u64 shl 63) div ub:
    raise newException(MoneyOverflowError, "money overflow")
  let prod = ua * ub
  let neg = (a < 0) xor (b < 0)
  if neg:
    (if prod == (1'u64 shl 63): low(int64) else: -int64(prod))
  else:
    if prod > uint64(high(int64)):
      raise newException(MoneyOverflowError, "money overflow")
    int64(prod)

proc formatFixed(units: int64, scale: int): string =
  ## Format minor unit dengan `scale` desimal (selalu diisi nol di belakang).
  let neg = units < 0
  let mag = absU(units)
  var factor: uint64 = 1
  for _ in 0 ..< scale:
    factor = factor * 10'u64
  result = ""
  if neg:
    result.add '-'
  result.add $(mag div factor)
  if scale > 0:
    result.add '.'
    var fs = $(mag mod factor)
    while fs.len < scale:
      fs = "0" & fs
    result.add fs

# --- konstruksi dari string ----------------------------------------------------------------

proc moneyFromString*(s: string): AppResult[Money] =
  ## Parse desimal uang: `"1500000.00"`, `"-12.5"`, `"0"` (maks 4 desimal).
  ## Bentuk tak valid dikembalikan sebagai error validasi.
  if s.len == 0:
    return err[Money, AppError](
      appError("KRN-1001", "kernel.money.invalid", aekValidation, "string kosong"))

  var i = 0
  var neg = false
  if s[i] == '-' or s[i] == '+':
    neg = s[i] == '-'
    inc i
  if i >= s.len or s[i] notin {'0' .. '9'}:
    return err[Money, AppError](
      appError("KRN-1001", "kernel.money.invalid", aekValidation, s))

  var intMag: uint64 = 0
  while i < s.len and s[i] in {'0' .. '9'}:
    let d = uint64(ord(s[i]) - ord('0'))
    if intMag > (high(uint64) - d) div 10'u64:
      return err[Money, AppError](
        appError("KRN-1002", "kernel.money.overflow", aekValidation, s))
    intMag = intMag * 10'u64 + d
    inc i

  var fracMag: uint64 = 0
  var fracDigits = 0
  if i < s.len and s[i] == '.':
    inc i
    if i >= s.len or s[i] notin {'0' .. '9'}:
      return err[Money, AppError](
        appError("KRN-1001", "kernel.money.invalid", aekValidation, s))
    while i < s.len and s[i] in {'0' .. '9'}:
      if fracDigits >= moneyScale:
        return err[Money, AppError](
          appError("KRN-1001", "kernel.money.invalid", aekValidation, "lebih dari 4 desimal"))
      fracMag = fracMag * 10'u64 + uint64(ord(s[i]) - ord('0'))
      inc fracDigits
      inc i
  if i != s.len:
    return err[Money, AppError](
      appError("KRN-1001", "kernel.money.invalid", aekValidation, s))

  var mag = intMag
  if mag > high(uint64) div uint64(moneyFactor):
    return err[Money, AppError](
      appError("KRN-1002", "kernel.money.overflow", aekValidation, s))
  mag = mag * uint64(moneyFactor)
  for _ in 0 ..< (moneyScale - fracDigits):
    fracMag = fracMag * 10'u64
  mag = mag + fracMag

  let lim = if neg: (1'u64 shl 63) else: uint64(high(int64))
  if mag > lim:
    return err[Money, AppError](
      appError("KRN-1002", "kernel.money.overflow", aekValidation, s))
  let units = if neg:
                (if mag == (1'u64 shl 63): low(int64) else: -int64(mag))
              else:
                int64(mag)
  ok[Money, AppError](money(units))

# --- format --------------------------------------------------------------------------------

proc toDecimalString*(m: Money): string =
  ## Selalu 4 desimal: `money(15000000000)` → `"1500000.0000"`.
  formatFixed(m.units, moneyScale)

proc toDisplayString*(m: Money): string =
  ## 2 desimal, pembulatan half-to-even (untuk tampilan).
  formatFixed(mulDivHalfEven(m.units, 1, 100), 2)

# --- relasi --------------------------------------------------------------------------------

proc `==`*(a, b: Money): bool {.inline.} = a.units == b.units
proc `<`*(a, b: Money): bool {.inline.} = a.units < b.units
proc `<=`*(a, b: Money): bool {.inline.} = a.units <= b.units
proc cmp*(a, b: Money): int {.inline.} = cmp(a.units, b.units)
proc isZero*(m: Money): bool {.inline.} = m.units == 0
proc isNegative*(m: Money): bool {.inline.} = m.units < 0

# --- aritmetika ----------------------------------------------------------------------------

proc `+`*(a, b: Money): Money =
  ## Penjumlahan; overflow int64 menaikkan `MoneyOverflowError`.
  if b.units > 0 and a.units > high(int64) - b.units:
    raise newException(MoneyOverflowError, "money overflow")
  elif b.units < 0 and a.units < low(int64) - b.units:
    raise newException(MoneyOverflowError, "money overflow")
  money(a.units + b.units)

proc `-`*(a, b: Money): Money =
  ## Pengurangan; overflow int64 menaikkan `MoneyOverflowError`.
  if b.units > 0 and a.units < low(int64) + b.units:
    raise newException(MoneyOverflowError, "money overflow")
  elif b.units < 0 and a.units > high(int64) + b.units:
    raise newException(MoneyOverflowError, "money overflow")
  money(a.units - b.units)

proc `-`*(m: Money): Money =
  ## Negasi; `low(int64)` menaikkan `MoneyOverflowError`.
  if m.units == low(int64):
    raise newException(MoneyOverflowError, "money overflow")
  money(-m.units)

proc abs*(m: Money): Money =
  ## Nilai absolut; `low(int64)` menaikkan `MoneyOverflowError`.
  if m.units == low(int64):
    raise newException(MoneyOverflowError, "money overflow")
  money(if m.units < 0: -m.units else: m.units)

proc sum*(xs: openArray[Money]): Money =
  ## Jumlahkan; konsisten dengan penjumlahan berurutan (asosiatif).
  result = zero()
  for x in xs:
    result = result + x

proc `*`*(m: Money, factor: int64): Money =
  ## Uang × skalar integer; overflow menaikkan `MoneyOverflowError`.
  money(mulInt64Checked(m.units, factor))

proc `div`*(m: Money, divisor: int64): Money =
  ## Uang ÷ integer, pembulatan half-to-even; bagi nol menaikkan `ValueError`.
  money(mulDivHalfEven(m.units, 1, divisor))

proc applyRate*(m: Money, r: Rate): Money =
  ## Uang × Rate (pecahan), pembulatan half-to-even; overflow menaikkan `MoneyOverflowError`.
  money(mulDivHalfEven(m.units, microUnits(r), 1_000_000))
