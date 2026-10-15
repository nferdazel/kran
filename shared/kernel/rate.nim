## Rate — tingkat bunga/nisbah **fixed-point**, tanpa float (AGENTS.md §1.3, ADR-011).
##
## Skala internal 10⁶ (micro): 12,5% = 125000. Tidak ada `float` di berkas ini.

import std/strutils
import ./result
import ./checkedint

type
  Rate* = object
    micro: int64 ## unit 1e-6 dari fraksi: 12,5% -> 0,125 -> 125000

const
  rateScale* = 6                    ## presisi internal (desimal)
  rateUnitsPerPercent* = 10_000'i64 ## 1% = 0,01 = 10_000 micro
  maxPercentWhole* = 1_000_000'i64  ## batas kewarasan input persen

proc rateFromMicro*(micro: int64): Rate {.inline.} =
  Rate(micro: micro)

proc microUnits*(r: Rate): int64 {.inline.} =
  r.micro

proc zeroRate*(): Rate {.inline.} =
  Rate(micro: 0)

proc isZero*(r: Rate): bool {.inline.} =
  r.micro == 0

proc isNegative*(r: Rate): bool {.inline.} =
  r.micro < 0

proc `==`*(a, b: Rate): bool {.inline.} =
  a.micro == b.micro

proc cmp*(a, b: Rate): int {.inline.} =
  system.cmp(a.micro, b.micro)

proc `<`*(a, b: Rate): bool {.inline.} =
  a.micro < b.micro

proc `<=`*(a, b: Rate): bool {.inline.} =
  a.micro <= b.micro

proc `+`*(a, b: Rate): Rate {.inline.} =
  Rate(micro: checkedAdd(a.micro, b.micro))

proc `-`*(a, b: Rate): Rate {.inline.} =
  Rate(micro: checkedSub(a.micro, b.micro))

proc `*`*(r: Rate, factor: int64): Rate {.inline.} =
  Rate(micro: checkedMul(r.micro, factor))

proc rateErr(msg: string, code = "KRAN-1001"): AppError {.inline.} =
  appError(code, "error.rate.invalid", aekValidation, msg)

proc rateFromPercentString*(s: string): AppResult[Rate] =
  ## Terima `"12.5"`, `"0.125"`, `"12.5%"`, `"-0.5"`.
  ## Presisi persen maksimum 4 desimal (batas presisi micro dari `Rate`); lebih dari itu
  ## **ditolak**, bukan dibulatkan diam-diam.
  var t = s.strip()
  if t.len > 0 and t[^1] == '%':
    t = t[0 ..< ^1].strip()
  if t.len == 0:
    return err[Rate, AppError](rateErr("string kosong"))

  var neg = false
  var i = 0
  if t[0] == '-' or t[0] == '+':
    neg = t[0] == '-'
    inc i

  let intStart = i
  var whole: int64 = 0
  while i < t.len and t[i] in {'0' .. '9'}:
    whole = whole * 10 + int64(ord(t[i]) - ord('0'))
    if whole > maxPercentWhole:
      return err[Rate, AppError](rateErr("nilai persen terlalu besar: " & s))
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
    return err[Rate, AppError](rateErr("karakter tidak dikenal: " & s))
  if intDigits == 0:
    return err[Rate, AppError](rateErr("bagian bulat wajib ada: " & s))
  if sawDot and frac.len == 0:
    return err[Rate, AppError](rateErr("titik tanpa angka desimal: " & s))
  if frac.len > 4:
    return err[Rate, AppError](rateErr(
      "presisi persen maksimum 4 desimal: " & s, "KRAN-1002"
    ))

  while frac.len < 4:
    frac.add('0')
  var fracUnits: int64 = 0
  for c in frac:
    fracUnits = fracUnits * 10 + int64(ord(c) - ord('0'))

  var micro = whole * rateUnitsPerPercent + fracUnits
  if neg:
    micro = -micro
  ok[Rate, AppError](rateFromMicro(micro))

proc toPercentString*(r: Rate): string =
  ## Kebalikan `rateFromPercentString`: 125000 -> "12.5", 10000 -> "1", 1250 -> "0.125".
  let neg = r.micro < 0
  let m = (if neg: -r.micro else: r.micro)
  let whole = m div rateUnitsPerPercent
  var frac = $(m mod rateUnitsPerPercent)
  while frac.len < 4:
    frac = "0" & frac
  while frac.len > 0 and frac[^1] == '0':
    frac.setLen(frac.len - 1)
  (if neg: "-" else: "") & $whole & (if frac.len > 0: "." & frac else: "")
