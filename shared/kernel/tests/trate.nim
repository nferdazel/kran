import std/unittest
import kernel

suite "rate":
  test "parse persen":
    check rateFromPercentString("12.5").value.microUnits == 125_000
    check rateFromPercentString("12.5%").value.microUnits == 125_000
    check rateFromPercentString("0.125").value.microUnits == 1_250
    check rateFromPercentString("100").value.microUnits == 1_000_000
    check rateFromPercentString("0").value.microUnits == 0
    check rateFromPercentString("-0.5").value.microUnits == -5_000
    check rateFromPercentString(" 1.5 %").value.microUnits == 15_000

  test "parse menolak input tidak sah":
    check rateFromPercentString("").isErr
    check rateFromPercentString("%").isErr
    check rateFromPercentString("abc").isErr
    check rateFromPercentString("1.2.3").isErr
    check rateFromPercentString(".5").isErr
    check rateFromPercentString("12.55555").isErr # > 4 desimal
    check rateFromPercentString("9999999999").isErr # di luar batas kewarasan

  test "toPercentString kebalikan parse":
    check toPercentString(rateFromMicro(125_000)) == "12.5"
    check toPercentString(rateFromMicro(10_000)) == "1"
    check toPercentString(rateFromMicro(1_250)) == "0.125"
    check toPercentString(rateFromMicro(-5_000)) == "-0.5"
    check toPercentString(zeroRate()) == "0"
    for s in ["0", "1", "12.5", "0.125", "99.9999", "100"]:
      check toPercentString(rateFromPercentString(s).value) == s

  test "aritmetika dan perbandingan":
    check rateFromMicro(100) + rateFromMicro(50) == rateFromMicro(150)
    check rateFromMicro(100) - rateFromMicro(50) == rateFromMicro(50)
    check rateFromMicro(100) * 3 == rateFromMicro(300)
    check rateFromMicro(100) < rateFromMicro(101)
    check rateFromMicro(100) <= rateFromMicro(100)
    check cmp(rateFromMicro(101), rateFromMicro(100)) == 1
    check isZero(zeroRate())
    check isNegative(rateFromMicro(-1))
