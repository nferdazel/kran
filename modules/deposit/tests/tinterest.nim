## Unit test akrual bunga deposito (T-138c): satu pembulatan HALF_EVEN per rentang.
##
## Golden value dihitung dengan oracle independen (`decimal` Python, ROUND_HALF_EVEN), bukan
## dengan menyalin hasil implementasi. `HUMAN-REVIEW-REQUIRED` (AGENTS.md §8): rumus bunga adalah
## area kritis — angka di sini harus bisa dicocokkan manual oleh reviewer.

import std/unittest

import kernel/[money, rate, result]
import ../api

proc moneyOf(s: string): Money =
  let parsed = moneyFromString(s)
  doAssert parsed.isOk, s
  parsed.value()

proc rateOf(s: string): Rate =
  let parsed = rateFromPercentString(s)
  doAssert parsed.isOk, s
  parsed.value()

proc amount(principal, ratePercent: string; days, basisDays: int): string =
  let res = interestForRange(moneyOf(principal), rateOf(ratePercent), days, basisDays)
  doAssert res.isOk, "akrual gagal: " & principal
  res.value().toDecimalString

suite "bunga: golden value (ACT/365, ACT/360)":
  test "satu tahun penuh = rate × pokok":
    check amount("10000000.00", "2.5", 365, 365) == "250000.00"

  test "30 hari dari pokok 10 juta":
    # 10.000.000 × 2,5% × 30/365 = 20.547,945205… → 20.547,95
    check amount("10000000.00", "2.5", 30, 365) == "20547.95"

  test "satu hari, basis 365 vs 360":
    # 10.000.000 × 2,5% / 365 = 684,9315068… → 684,93
    check amount("10000000.00", "2.5", 1, 365) == "684.93"
    # 10.000.000 × 2,5% / 360 = 694,4444… → 694,44
    check amount("10000000.00", "2.5", 1, 360) == "694.44"

  test "pokok kecil tetap menghasilkan sen, bukan nol":
    # 1.000 × 2,5% / 365 = 0,06849… → 0,07
    check amount("1000.00", "2.5", 1, 365) == "0.07"

  test "pokok bersen dan rentang panjang":
    # 1.234.567,89 × 2,5% × 47/365 = 3.974,2868… → 3.974,29
    check amount("1234567.89", "2.5", 47, 365) == "3974.29"

  test "rate tinggi, basis 360":
    # 1.000.000 × 12,5% × 73/360 = 25.347,2222… → 25.347,22
    check amount("1000000.00", "12.5", 73, 360) == "25347.22"

  test "tahun kabisat tetap memakai basis perjanjian (366 hari, basis 365)":
    # 999.999.999.999,99 × 7,25% × 366/365 = 72.698.630.136,99…
    check amount("999999999999.99", "7.25", 366, 365) == "72698630136.99"

suite "bunga: pembulatan half-to-even":
  test "tepat 0,5 sen dibulatkan ke sen genap":
    # 100,00 × 1,825% / 365 = 0,005 tepat → 0,00 (0 genap)
    check amount("100.00", "1.825", 1, 365) == "0.00"
    # 300,00 × 1,825% / 365 = 0,015 tepat → 0,02 (2 genap)
    check amount("300.00", "1.825", 1, 365) == "0.02"

  test "di atas 0,5 sen selalu naik, di bawahnya selalu turun":
    check amount("499.99", "1.825", 1, 365) == "0.02" # 0,0249995 → 0,02
    check amount("200.01", "1.825", 1, 365) == "0.01" # 0,0100005 → 0,01

suite "bunga: masukan yang mustahil ditolak":
  test "hari/basis tidak masuk akal":
    expect ValueError:
      discard interestForRange(moneyOf("100.00"), rateOf("2.5"), 0, 365)
    expect ValueError:
      discard interestForRange(moneyOf("100.00"), rateOf("2.5"), 1, 0)

  test "pokok atau rate negatif bukan urusan akrual":
    expect ValueError:
      discard interestForRange(moneyOf("-100.00"), rateOf("2.5"), 1, 365)
    expect ValueError:
      discard interestForRange(moneyOf("100.00"), rateOf("-2.5"), 1, 365)

suite "bunga: batas & sifat":
  test "pokok nol atau rate nol = nol, tanpa pembulatan aneh":
    check amount("0.00", "2.5", 365, 365) == "0.00"
    check amount("1000000.00", "0", 365, 365) == "0.00"

  test "monoton terhadap jumlah hari untuk rate tetap":
    # Uang dibandingkan sebagai `Money`, bukan float: satu-satunya pembanding yang sah untuk
    # nominal (AGENTS.md §1.3).
    var previous = zero()
    for days in [1, 2, 7, 30, 31, 90, 180, 365]:
      let value = moneyOf(amount("1000000.00", "2.5", days, 365))
      check cmp(value, previous) >= 0
      previous = value

  test "rentang yang lebih panjang tidak pernah lebih kecil dari jumlah bagian pendek":
    let whole = moneyOf(amount("1000000.00", "2.5", 60, 365))
    let first = moneyOf(amount("1000000.00", "2.5", 30, 365))
    let second = moneyOf(amount("1000000.00", "2.5", 30, 365))
    # Selisih paling banyak satu sen: dua pembulatan terpisah vs satu pembulatan rentang penuh.
    check cmp(abs(whole - (first + second)), money(1)) <= 0

  test "pokok ekstrem dilaporkan sebagai galat, bukan angka aneh":
    # int64 sen tidak bisa menampung pokok × 366; harus jadi error result.
    let huge = interestForRange(money(high(int64) div 2), rateOf("100"), 366, 365)
    check huge.isErr
