import std/unittest
import kernel

suite "money":
  test "parse dan format kanonik (selalu 2 desimal)":
    # 1.500.000,00 -> 1_500_000 * 10^2 = 150_000_000 unit terkecil (sen)
    check moneyFromString("1500000.00").value.minorUnits == 150_000_000
    check moneyFromString("1500000").value.toDecimalString == "1500000.00"
    check moneyFromString("-12.5").value.toDecimalString == "-12.50"
    check moneyFromString("0").value.toDecimalString == "0.00"
    check moneyFromString("+0.01").value.minorUnits == 1
    check moneyFromString(" 7.25 ").value.minorUnits == 725
    # Nol tambahan di belakang koma = nilai sama (D-138); bukan pembulatan.
    check moneyFromString("25000.0000").value.toDecimalString == "25000.00"
    check moneyFromString("0.0000").value.toDecimalString == "0.00"
    check moneyFromString("1.2300").value.minorUnits == 123

  test "parse menolak bentuk tidak sah (tanpa pembulatan diam-diam)":
    check moneyFromString("").isErr
    check moneyFromString("1.234").isErr # > 2 desimal dan ada digit bukan-nol
    check moneyFromString("1.23456").isErr
    check moneyFromString("1.2301").isErr # sub-sen tetap ditolak
    check moneyFromString("12,5").isErr
    check moneyFromString("abc").isErr
    check moneyFromString("1.2.3").isErr
    check moneyFromString(".5").isErr
    check moneyFromString("5.").isErr
    check moneyFromString("1e3").isErr
    check moneyFromString("99999999999999999999").isErr # overflow -> error, bukan crash

  test "aritmetika dasar":
    check money(1) + money(2) == money(3)
    check money(1) - money(3) == money(-2)
    check -money(3) == money(-3)
    check money(3) - money(3) == zero()
    check money(2) * 3 == money(6)
    check sum(@[money(1), money(2), money(3)]) == money(6)
    check sum(newSeq[Money]()) == zero()

  test "perbandingan dan tanda":
    check money(1) < money(2)
    check money(2) <= money(2)
    check money(2) > money(1)
    check cmp(money(1), money(2)) == -1
    check isZero(zero())
    check isNegative(money(-1))
    check isPositive(money(1))
    check abs(money(-5)) == money(5)

  test "pembagian half-to-even":
    check divRoundHalfEven(5, 2) == 2 # 2,5 -> 2 (genap)
    check divRoundHalfEven(7, 2) == 4 # 3,5 -> 4 (genap)
    check divRoundHalfEven(1, 2) == 0 # 0,5 -> 0 (genap)
    check divRoundHalfEven(3, 2) == 2 # 1,5 -> 2 (genap)
    check divRoundHalfEven(-5, 2) == -2
    check divRoundHalfEven(-7, 2) == -4
    check divRoundHalfEven(-1, 2) == 0
    check divRoundHalfEven(4, 2) == 2
    check money(7) div 2 == money(4)
    check money(-7) div 2 == money(-4)
    expect ValueError:
      discard money(1) div 0

  test "overflow tidak pernah diam-diam":
    expect MoneyOverflowError:
      discard money(high(int64)) + money(1)
    expect MoneyOverflowError:
      discard money(low(int64)) - money(1)
    expect MoneyOverflowError:
      discard money(high(int64)) * 2
    expect MoneyOverflowError:
      discard -money(low(int64))

  test "applyRate - golden values":
    check applyRate(money(1000), rateFromMicro(500_000)) == money(500) # 50%
    check applyRate(money(1_000_000), rateFromPercentString("12.5").value) == money(125_000)
    check applyRate(money(0), rateFromMicro(500_000)) == zero()
    check applyRate(money(1000), zeroRate()) == zero()
    # pembulatan half-to-even pada unit terkecil (rate 0,05% = 500 micro)
    check applyRate(money(1000), rateFromMicro(500)) == money(0) # 0,5 -> 0
    check applyRate(money(3000), rateFromMicro(500)) == money(2) # 1,5 -> 2
    check applyRate(money(5000), rateFromMicro(500)) == money(2) # 2,5 -> 2 (genap)
    check applyRate(money(7000), rateFromMicro(500)) == money(4) # 3,5 -> 4 (genap)
    check applyRate(money(1), rateFromMicro(500_000)) == money(0) # 0,5 -> 0
    check applyRate(money(3), rateFromMicro(500_000)) == money(2) # 1,5 -> 2
    # nilai besar tidak overflow (dekomposisi q·micro + rem·micro/1e6)
    check applyRate(money(1_000_000_000_000), rateFromPercentString("100").value) ==
      money(1_000_000_000_000)
