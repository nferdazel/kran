## Property test kernel (spec §20) — invarian yang harus benar untuk **semua** masukan
## dalam rentang realistis, bukan hanya contoh pilihan.
##
## Rentang sengaja dibatasi ke nilai besar yang wajar untuk KRAN (|nilai| ≤ 10¹² unit
## = 100 juta rupiah) supaya penjumlahan tiga nilai tidak menyentuh batas int64.

import std/[unittest, random]
import kernel
import support/propgen

const moneyBound = 1_000_000_000_000'i64

proc genMoney(r: var Rand): Money =
  money(r.rand(int(moneyBound * 2)) - int(moneyBound))

proc genTriple(r: var Rand): (Money, Money, Money) =
  (genMoney(r), genMoney(r), genMoney(r))

proc genPair(r: var Rand): (Money, Money) =
  (genMoney(r), genMoney(r))

proc d(t: (Money, Money, Money)): string =
  t[0].toDecimalString & " / " & t[1].toDecimalString & " / " & t[2].toDecimalString

proc d2(t: (Money, Money)): string =
  t[0].toDecimalString & " / " & t[1].toDecimalString

proc genRate(r: var Rand): Rate =
  ## 0% … 100% dalam micro (0 … 1_000_000). Nilai bisnis sesungguhnya datang dari
  ## parameter DB; di sini hanya rentang fisik.
  rateFromMicro(r.rand(1_000_001))

suite "property: money":
  test "asosiatif penjumlahan":
    check forAll("(a+b)+c == a+(b+c)", defaultIterations, genTriple,
      proc(t: (Money, Money, Money)): bool = (t[0] + t[1]) + t[2] == t[0] + (t[1] + t[2]),
      d)

  test "komutatif penjumlahan":
    check forAll("a+b == b+a", defaultIterations, genPair,
      proc(t: (Money, Money)): bool = t[0] + t[1] == t[1] + t[0], d2)

  test "invers aditif":
    check forAll("a + (-a) == 0", defaultIterations, genMoney,
      proc(m: Money): bool = m + (-m) == zero(), proc(m: Money): string = m.toDecimalString)

  test "sum konsisten dengan lipatan berurutan":
    check forAll("sum([a,b,c]) == (a+b)+c", defaultIterations, genTriple,
      proc(t: (Money, Money, Money)): bool =
      sum(@[t[0], t[1], t[2]]) == (t[0] + t[1]) + t[2], d)

  test "urutan konsisten dengan selisih":
    check forAll("a < b  <=>  (b - a) positif", defaultIterations, genPair,
      proc(t: (Money, Money)): bool =
      if t[0] < t[1]: (t[1] - t[0]).isPositive
      elif t[0] == t[1]: (t[1] - t[0]).isZero
      else: (t[1] - t[0]).isNegative, d2)

  test "parse(format(a)) == a":
    check forAll("round-trip string", defaultIterations, genMoney,
      proc(m: Money): bool =
      let s = m.toDecimalString
      moneyFromString(s).isOk and moneyFromString(s).value == m,
      proc(m: Money): string = m.toDecimalString)

  test "applyRate tidak melampaui nilai semula untuk rate 0..100%":
    check forAll("|applyRate(m, r)| <= |m|", defaultIterations,
      proc(r: var Rand): (Money, Rate) = (genMoney(r), genRate(r)),
      proc(t: (Money, Rate)): bool = abs(applyRate(t[0], t[1])) <= abs(t[0]),
      proc(t: (Money, Rate)): string = t[0].toDecimalString & " x " & microUnits(t[1]).`$`)

  test "applyRate menjaga tanda (rate >= 0)":
    check forAll("sign(applyRate(m,r)) == sign(m)", defaultIterations,
      proc(r: var Rand): (Money, Rate) = (genMoney(r), genRate(r)),
      proc(t: (Money, Rate)): bool =
      let v = applyRate(t[0], t[1])
      (t[0].isZero and v.isZero) or (t[0].isPositive and not v.isNegative) or
        (t[0].isNegative and not v.isPositive),
      proc(t: (Money, Rate)): string = t[0].toDecimalString)

  test "applyRate: galat pembulatan <= 0,5 unit terkecil":
    # Catatan penting (jangan "diperbaiki" tanpa berpikir): linearitas TIDAK berlaku —
    # applyRate(m, 2r) != 2 * applyRate(m, r) — karena pembulatan terjadi pada setiap
    # penerapan. Invarian yang benar adalah batas galat pembulatan terhadap hasil eksak:
    #   |hasil * 10^6 - m.units * micro| <= 500_000  (0,5 unit terkecil)
    check forAll("|hasil*1e6 - m*r| <= 0,5 unit", defaultIterations,
      proc(r: var Rand): (Money, Rate) = (genMoney(r), genRate(r)),
      proc(t: (Money, Rate)): bool =
      let res = applyRate(t[0], t[1])
      let lhs = res.minorUnits * 1_000_000'i64
      let rhs = t[0].minorUnits * microUnits(t[1])
      abs(lhs - rhs) <= 500_000'i64,
      proc(t: (Money, Rate)): string = t[0].toDecimalString & " x " & microUnits(t[1]).`$`)
