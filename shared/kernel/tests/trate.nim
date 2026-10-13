import std/unittest

import kernel/rate

suite "rate":
  test "golden: 12.5% = 125000 micro":
    check rateFromMicro(125000).microUnits == 125000
    check toPercentString(rateFromMicro(125000)) == "12.5"

  test "parse persen (dengan/tanpa tanda %)":
    check rateFromPercentString("12.5").value.microUnits == 125000
    check rateFromPercentString("12.5%").value.microUnits == 125000
    check rateFromPercentString("0.125").value.microUnits == 1250
    check rateFromPercentString("0").value.isZero
    check rateFromPercentString("100").value.microUnits == 1_000_000

  test "parse menolak bentuk tak valid":
    check rateFromPercentString("").isErr
    check rateFromPercentString("abc").isErr
    check rateFromPercentString("1.2345678").isErr   # > 6 desimal
    check rateFromPercentString("1.2.3").isErr

  test "operasi dasar":
    check rateFromMicro(100) + rateFromMicro(200) == rateFromMicro(300)
    check rateFromMicro(300) - rateFromMicro(100) == rateFromMicro(200)
    check rateFromMicro(100) * 3 == rateFromMicro(300)
    check rateFromMicro(1) < rateFromMicro(2)
    check rateFromMicro(2) <= rateFromMicro(2)
    check zeroRate().isZero

  test "overflow menaikkan ValueError":
    expect ValueError:
      discard rateFromMicro(high(int64)) + rateFromMicro(1)
    expect ValueError:
      discard rateFromMicro(high(int64)) * 2
    expect ValueError:
      discard -rateFromMicro(low(int64))

  test "round-trip percent string":
    check toPercentString(rateFromMicro(1)) == "0.0001"
    check toPercentString(rateFromMicro(10)) == "0.001"
    check toPercentString(rateFromMicro(0)) == "0"
    check toPercentString(rateFromMicro(1_000_000)) == "100"
