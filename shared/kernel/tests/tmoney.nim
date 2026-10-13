import std/unittest

import kernel/money
import kernel/rate

suite "money":
  test "golden: 1500000.00 round-trip":
    let m = moneyFromString("1500000.00")
    check m.isOk
    check m.value.minorUnits == 15_000_000_000'i64
    check toDecimalString(m.value) == "1500000.0000"

  test "golden: applyRate 50%":
    check applyRate(money(1000), rateFromMicro(500000)) == money(500)

  test "pembulatan half-to-even pada 0.5/1.5/2.5":
    check (money(1) div 2) == money(0)   # 0.5 -> 0 (genap)
    check (money(3) div 2) == money(2)   # 1.5 -> 2 (genap)
    check (money(5) div 2) == money(2)   # 2.5 -> 2 (genap)
    check (money(7) div 2) == money(4)   # 3.5 -> 4 (genap)

  test "display 2 desimal half-to-even":
    check toDisplayString(money(50)) == "0.00"    # 0.0050 -> 0.00
    check toDisplayString(money(150)) == "0.02"   # 0.0150 -> 0.02
    check toDisplayString(money(250)) == "0.02"   # 0.0250 -> 0.02

  test "parse bentuk negatif dan nol":
    check moneyFromString("-12.5").value == money(-125000)
    check moneyFromString("0").value == money(0)
    check toDecimalString(money(-125000)) == "-12.5000"

  test "parse menolak bentuk tak valid":
    check moneyFromString("").isErr
    check moneyFromString("abc").isErr
    check moneyFromString("1.2.3").isErr
    check moneyFromString("1.23456").isErr   # > 4 desimal
    check moneyFromString(".5").isErr
    check moneyFromString("1.").isErr

  test "overflow menaikkan MoneyOverflowError":
    expect MoneyOverflowError:
      discard money(high(int64)) + money(1)
    expect MoneyOverflowError:
      discard money(low(int64)) - money(1)
    expect MoneyOverflowError:
      discard money(high(int64)) * 2
    expect MoneyOverflowError:
      discard -money(low(int64))

  test "bagi nol menaikkan ValueError":
    expect ValueError:
      discard money(10) div 0

  test "operasi dasar":
    check money(10) + money(5) == money(15)
    check money(10) - money(5) == money(5)
    check money(10) < money(11)
    check money(10) <= money(10)
    check sum(@[money(1), money(2), money(3)]) == money(6)
    check isZero(money(0))
    check isNegative(money(-1))
    check abs(money(-7)) == money(7)
