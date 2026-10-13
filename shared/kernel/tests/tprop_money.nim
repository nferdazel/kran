## Property test `Money` (spec §12.1, §20): invarian aljabar, round-trip, pembulatan, overflow.

import std/unittest
import std/random

import kernel/money
import kernel/rate
import ./support/propgen

const unitLo = -1_000_000_000_000_000'i64
const unitHi = 1_000_000_000_000_000'i64

proc propAddLaws(rng: var Rand) =
  let a = money(rng.rand(unitLo .. unitHi))
  let b = money(rng.rand(unitLo .. unitHi))
  let c = money(rng.rand(unitLo .. unitHi))
  checkProp((a + b) + c == a + (b + c),
            "asosiatif " & $a.minorUnits & "," & $b.minorUnits & "," & $c.minorUnits)
  checkProp(a + b == b + a, "komutatif")
  checkProp(a + (-a) == money(0), "invers aditif " & $a.minorUnits)
  checkProp(sum(@[a, b, c]) == (a + b) + c, "sum konsisten")

proc propNoOverflowRealistis(rng: var Rand) =
  # Rentang realistis: |unit| <= 10^15 (Rp 100 miliar). Penjumlahan tidak boleh overflow.
  let a = money(rng.rand(unitLo .. unitHi))
  let b = money(rng.rand(unitLo .. unitHi))
  let out = a + b
  checkProp(out.minorUnits == a.minorUnits + b.minorUnits, "hasil salah")

proc propOverflowMenaikkan(rng: var Rand) =
  let a = money(rng.rand(1'i64 .. high(int64)))
  let b = money(high(int64) - a.minorUnits + 1)
  var raised = false
  try:
    discard a + b
  except MoneyOverflowError:
    raised = true
  checkProp(raised, "overflow tidak terdeteksi untuk a=" & $a.minorUnits)

proc propParseRoundTrip(rng: var Rand) =
  let u = rng.rand(unitLo .. unitHi)
  let back = moneyFromString(toDecimalString(money(u)))
  checkProp(back.isOk, "parse gagal untuk " & $u)
  checkProp(back.value.minorUnits == u, "round-trip beda: " & $u & " -> " & $back.value.minorUnits)

proc propApplyRateHalfEven(rng: var Rand) =
  let units = rng.rand(0'i64 .. 1_000_000_000_000'i64)
  let micro = rng.rand(0'i64 .. 1_000_000'i64)
  let out = applyRate(money(units), rateFromMicro(micro))
  # Rate 0..100% atas nilai non-negatif tidak boleh melebihi nilai asal.
  checkProp(out >= money(0), "negatif: " & $out.minorUnits)
  checkProp(out <= money(units), "menggelembung: " & $out.minorUnits & " > " & $units)
  # Tepi pembulatan half-to-even pada 0.5 unit harus ke bilangan genap.
  checkProp(applyRate(money(1), rateFromMicro(500000)) == money(0), "0.5 -> 0")
  checkProp(applyRate(money(3), rateFromMicro(500000)) == money(2), "1.5 -> 2")
  checkProp(applyRate(money(5), rateFromMicro(500000)) == money(2), "2.5 -> 2")

suite "property money":
  test "hukum penjumlahan + sum":
    runProp("add-laws", propAddLaws)

  test "tidak overflow pada rentang realistis":
    runProp("no-overflow", propNoOverflowRealistis)

  test "overflow menaikkan MoneyOverflowError":
    runProp("overflow", propOverflowMenaikkan)

  test "parse -> format round-trip":
    runProp("round-trip", propParseRoundTrip)

  test "applyRate half-to-even":
    runProp("apply-rate", propApplyRateHalfEven)
