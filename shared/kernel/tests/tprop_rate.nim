## Property test `Rate` + interaksi `applyRate` (spec §12.1, §20).

import std/unittest
import std/random

import kernel/rate
import kernel/money
import ./support/propgen

const microLo = -1_000_000_000_000_000'i64
const microHi = 1_000_000_000_000_000'i64

proc propAddLaws(rng: var Rand) =
  let a = rateFromMicro(rng.rand(microLo .. microHi))
  let b = rateFromMicro(rng.rand(microLo .. microHi))
  checkProp(a + b == b + a, "komutatif " & $a.microUnits & "," & $b.microUnits)
  checkProp((a + b) - b == a, "invers " & $a.microUnits)

proc propRoundTrip(rng: var Rand) =
  let micro = rng.rand(microLo .. microHi)
  let parsed = rateFromPercentString(toPercentString(rateFromMicro(micro)))
  checkProp(parsed.isOk, "parse gagal untuk " & $micro)
  checkProp(parsed.value.microUnits == micro,
            "round-trip beda: " & $micro & " -> " & $parsed.value.microUnits)

proc propMulOverflow(rng: var Rand) =
  let micro = rng.rand(high(int64) div 2 + 1 .. high(int64))
  let f = rng.rand(2'i64 .. 10'i64)
  var raised = false
  try:
    discard rateFromMicro(micro) * f
  except ValueError:
    raised = true
  checkProp(raised, "overflow tidak terdeteksi micro=" & $micro & " f=" & $f)

proc propApplyRateBatas(rng: var Rand) =
  let units = rng.rand(0'i64 .. 1_000_000_000_000'i64)
  let micro = rng.rand(0'i64 .. 1_000_000'i64)
  let out = applyRate(money(units), rateFromMicro(micro))
  checkProp(out >= money(0), "negatif")
  checkProp(out <= money(units), "menggelembung")
  checkProp(applyRate(money(units), zeroRate()) == money(0), "rate 0 -> 0")
  checkProp(applyRate(money(units), rateFromMicro(1_000_000)) == money(units), "rate 100%")

suite "property rate":
  test "hukum penjumlahan":
    runProp("rate-add-laws", propAddLaws)

  test "percent string round-trip":
    runProp("rate-round-trip", propRoundTrip)

  test "perkalian overflow menaikkan ValueError":
    runProp("rate-mul-overflow", propMulOverflow)

  test "applyRate batas & tepi":
    runProp("apply-rate-bounds", propApplyRateBatas)
