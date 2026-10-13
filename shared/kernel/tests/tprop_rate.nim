## Property test `Rate` (spec §20) — invarian yang harus benar untuk semua masukan
## dalam rentang realistis.

import std/[unittest, random]
import kernel
import support/propgen

const rateBound = 1_000_000_000'i64 ## ±100.000% — cukup lebar, tetap di luar overflow

proc genRate(r: var Rand): Rate =
  rateFromMicro(r.rand(int(rateBound * 2)) - int(rateBound))

proc d(r: Rate): string =
  toPercentString(r) & "%"

proc genPair(r: var Rand): (Rate, Rate) =
  (genRate(r), genRate(r))

proc d2(t: (Rate, Rate)): string =
  d(t[0]) & " / " & d(t[1])

suite "property: rate":
  test "komutatif penjumlahan":
    check forAll("a+b == b+a", defaultIterations, genPair,
      proc(t: (Rate, Rate)): bool = t[0] + t[1] == t[1] + t[0], d2)

  test "invers aditif":
    check forAll("(a+b)-b == a", defaultIterations, genPair,
      proc(t: (Rate, Rate)): bool = (t[0] + t[1]) - t[1] == t[0], d2)

  test "round-trip persen":
    check forAll("parse(toPercentString(r)) == r", defaultIterations, genRate,
      proc(r: Rate): bool =
      let p = rateFromPercentString(toPercentString(r))
      p.isOk and p.value == r, d)

  test "overflow tidak pernah diam-diam":
    check forAll("Rate * faktor besar menaikkan error",
      defaultIterations,
      proc(r: var Rand): (Rate, int64) = (rateFromMicro(high(int64) div 2 + 1), r.rand(3) + 2),
      proc(t: (Rate, int64)): bool = overflowRaises(proc() = discard t[0] * t[1]),
      proc(t: (Rate, int64)): string = "rate tinggi x " & $t[1])

  test "penjumlahan nilai ekstrem menaikkan error":
    let big = rateFromMicro(high(int64) - 5)
    check overflowRaises(proc() = discard big + rateFromMicro(10))

  test "applyRate pada batas 0% dan 100%":
    check forAll("0% -> nol, 100% -> sama", defaultIterations,
      proc(r: var Rand): Money = money(r.rand(1_000_000_000)),
      proc(m: Money): bool =
      applyRate(m, zeroRate()) == zero() and
        applyRate(m, rateFromMicro(1_000_000)) == m,
      proc(m: Money): string = m.toDecimalString)

  test "applyRate tidak pernah melebihi nilai semula (0..100%)":
    check forAll("0 <= applyRate(m,r) <= m", defaultIterations,
      proc(r: var Rand): (Money, Rate) =
      (money(r.rand(1_000_000_000)), rateFromMicro(r.rand(1_000_001))),
      proc(t: (Money, Rate)): bool =
      let v = applyRate(t[0], t[1])
      not v.isNegative and v <= t[0],
      proc(t: (Money, Rate)): string = t[0].toDecimalString & " x " & d(t[1]))
