## `Rate` — fixed-point skala 10⁶ (micro unit), **tanpa float** (spec §9.1(2), §12.1).
##
## `12.5%` = pecahan 0.125 = `125000` micro. Semua aritmetika integer; tidak ada `float`.
## String persen: `"12.5"`, `"12.5%"`, `"0.125"` (maks 6 desimal).

import ./result

export result

type
  ## Rate sebagai pecahan diskalakan 10⁶ (micro unit). Field privat.
  Rate* = object
    micro: int64

proc rateFromMicro*(micro: int64): Rate {.inline.} =
  ## Rate dari micro unit (12.5% = 125000).
  Rate(micro: micro)

proc microUnits*(r: Rate): int64 {.inline.} =
  ## Micro unit (12.5% mengembalikan 125000).
  r.micro

proc zeroRate*(): Rate {.inline.} =
  ## Rate nol (0%).
  Rate(micro: 0)

proc `==`*(a, b: Rate): bool {.inline.} = a.micro == b.micro
proc `<`*(a, b: Rate): bool {.inline.} = a.micro < b.micro
proc `<=`*(a, b: Rate): bool {.inline.} = a.micro <= b.micro
proc cmp*(a, b: Rate): int {.inline.} = cmp(a.micro, b.micro)
proc isZero*(r: Rate): bool {.inline.} = r.micro == 0

proc `+`*(a, b: Rate): Rate =
  ## Penjumlahan; overflow int64 menaikkan `ValueError`.
  if b.micro > 0 and a.micro > high(int64) - b.micro:
    raise newException(ValueError, "rate overflow")
  elif b.micro < 0 and a.micro < low(int64) - b.micro:
    raise newException(ValueError, "rate overflow")
  rateFromMicro(a.micro + b.micro)

proc `-`*(a, b: Rate): Rate =
  ## Pengurangan; overflow int64 menaikkan `ValueError`.
  if b.micro > 0 and a.micro < low(int64) + b.micro:
    raise newException(ValueError, "rate overflow")
  elif b.micro < 0 and a.micro > high(int64) + b.micro:
    raise newException(ValueError, "rate overflow")
  rateFromMicro(a.micro - b.micro)

proc `-`*(r: Rate): Rate =
  ## Negasi; overflow hanya bila micro = low(int64).
  if r.micro == low(int64):
    raise newException(ValueError, "rate overflow")
  rateFromMicro(-r.micro)

proc `*`*(r: Rate, factor: int64): Rate =
  ## Rate × skalar integer; overflow int64 menaikkan `ValueError`.
  if factor == 0 or r.micro == 0:
    return zeroRate()
  let a = r.micro
  # Penjaga sebelum perkalian (overflow checks Nim menaikkan Defect, bukan error).
  let ua = (if a < 0: uint64(-(a + 1)) + 1'u64 else: uint64(a))
  let ub = (if factor < 0: uint64(-(factor + 1)) + 1'u64 else: uint64(factor))
  if ua > (1'u64 shl 63) div ub:
    raise newException(ValueError, "rate overflow")
  let prod = ua * ub
  let neg = (a < 0) xor (factor < 0)
  if neg:
    rateFromMicro(if prod == (1'u64 shl 63): low(int64) else: -int64(prod))
  else:
    if prod > uint64(high(int64)):
      raise newException(ValueError, "rate overflow")
    rateFromMicro(int64(prod))

proc pow10u(n: int): uint64 {.inline.} =
  result = 1'u64
  for _ in 0 ..< n:
    result = result * 10'u64

proc rateFromPercentString*(s: string): AppResult[Rate] =
  ## Parse nilai persen: `"12.5"`, `"12.5%"`, `"0.125"` (maks 6 desimal).
  ## `12.5` berarti 12.5% = `125000` micro. Mengembalikan error validasi bila bentuk salah.
  var t = s
  if t.len > 0 and t[^1] == '%':
    t.setLen(t.len - 1)
  if t.len == 0:
    return err[Rate, AppError](
      appError("KRN-1101", "kernel.rate.invalid", aekValidation, "string kosong"))

  var i = 0
  var neg = false
  if t[i] == '-' or t[i] == '+':
    neg = t[i] == '-'
    inc i
  if i >= t.len or t[i] notin {'0' .. '9'}:
    return err[Rate, AppError](
      appError("KRN-1101", "kernel.rate.invalid", aekValidation, s))

  var intMag: uint64 = 0
  while i < t.len and t[i] in {'0' .. '9'}:
    let d = uint64(ord(t[i]) - ord('0'))
    if intMag > (high(uint64) - d) div 10'u64:
      return err[Rate, AppError](
        appError("KRN-1102", "kernel.rate.overflow", aekValidation, s))
    intMag = intMag * 10'u64 + d
    inc i

  var fracMag: uint64 = 0
  var fracDigits = 0
  if i < t.len and t[i] == '.':
    inc i
    if i >= t.len or t[i] notin {'0' .. '9'}:
      return err[Rate, AppError](
        appError("KRN-1101", "kernel.rate.invalid", aekValidation, s))
    while i < t.len and t[i] in {'0' .. '9'}:
      if fracDigits >= 6:
        return err[Rate, AppError](
          appError("KRN-1101", "kernel.rate.invalid", aekValidation, "lebih dari 6 desimal"))
      fracMag = fracMag * 10'u64 + uint64(ord(t[i]) - ord('0'))
      inc fracDigits
      inc i
  if i != t.len:
    return err[Rate, AppError](
      appError("KRN-1101", "kernel.rate.invalid", aekValidation, s))

  var mag = intMag
  for _ in 0 ..< fracDigits:
    if mag > high(uint64) div 10'u64:
      return err[Rate, AppError](
        appError("KRN-1102", "kernel.rate.overflow", aekValidation, s))
    mag = mag * 10'u64
  mag = mag + fracMag

  # micro = nilai_persen × 10⁴. Untuk desimal > 4, bulatkan half-to-even.
  var microMag: uint64
  if fracDigits <= 4:
    microMag = mag
    for _ in 0 ..< (4 - fracDigits):
      if microMag > high(uint64) div 10'u64:
        return err[Rate, AppError](
          appError("KRN-1102", "kernel.rate.overflow", aekValidation, s))
      microMag = microMag * 10'u64
  else:
    let divisor = pow10u(fracDigits - 4)
    let q = mag div divisor
    let rem = mag mod divisor
    microMag = q
    if rem * 2'u64 > divisor:
      inc microMag
    elif rem * 2'u64 == divisor and (microMag and 1'u64) == 1'u64:
      inc microMag

  let lim = (if neg: (1'u64 shl 63) else: uint64(high(int64)))
  if microMag > lim:
    return err[Rate, AppError](
      appError("KRN-1102", "kernel.rate.overflow", aekValidation, s))
  let micro = if neg:
                (if microMag == (1'u64 shl 63): low(int64) else: -int64(microMag))
              else:
                int64(microMag)
  ok[Rate, AppError](rateFromMicro(micro))

proc toPercentString*(r: Rate): string =
  ## Persen tanpa '%', hingga 4 desimal, nol di belakang dipangkas (`125000` → `"12.5"`).
  let neg = r.micro < 0
  let mag = if neg: uint64(-(r.micro + 1)) + 1'u64 else: uint64(r.micro)
  let intPart = mag div pow10u(4)
  let frac = mag mod pow10u(4)
  result = ""
  if neg:
    result.add '-'
  result.add $intPart
  if frac != 0:
    var fs = $frac
    while fs.len < 4:
      fs = "0" & fs
    while fs.len > 0 and fs[^1] == '0':
      fs.setLen(fs.len - 1)
    result.add '.'
    result.add fs
