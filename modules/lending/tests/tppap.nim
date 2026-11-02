## Unit test penyisihan PPAP `lending` (T-167).
##
## Yang diuji adalah **mesinnya**, bukan angkanya: tarif datang dari parameter `lending.ppap.rates`
## (seed `NEEDS-COMPLIANCE-REVIEW`, REG-204 `V!`), jadi test memakai tarif yang dipilih supaya hasilnya
## bisa dihitung tangan. Parameter rusak harus **gagal**, bukan menyisihkan nol: nol terlihat seperti
## "tidak ada penyisihan" dan lolos ke laporan tanpa suara.

import std/[json, sequtils, unittest]

import kernel/[money, rate, result]

import ../domain/[collectibility, ppap]

proc mn(s: string): Money =
  let m = moneyFromString(s)
  doAssert m.isOk, "nilai uji tidak sah: " & s
  m.val

proc pct(s: string): Rate =
  let r = rateFromPercentString(s)
  doAssert r.isOk, "persen uji tidak sah: " & s
  r.val

const seedRates = ["0.5", "3", "10", "50", "100"]

suite "lending ppap: tarif parameter":
  test "lima tarif seed terbaca dengan satuan mikro yang benar":
    let parsed = parsePpapRates(%*seedRates)
    check parsed.isOk
    check parsed.val.len == gradeCount()
    check parsed.val.mapIt(microUnits(it)) == @[5_000'i64, 30_000, 100_000, 500_000, 1_000_000]

  test "tarif dipetakan menurut urutan golongan, bukan dicari":
    let rates = parsePpapRates(%*seedRates).val
    check microUnits(rateFor(rates, colCollectible)) == 5_000
    check microUnits(rateFor(rates, colSpecialMention)) == 30_000
    check microUnits(rateFor(rates, colSubstandard)) == 100_000
    check microUnits(rateFor(rates, colDoubtful)) == 500_000
    check microUnits(rateFor(rates, colLoss)) == 1_000_000

  test "kebijakan lain benar-benar dipakai, bukan tarif bawaan":
    let rates = parsePpapRates(%*["0", "1", "2", "3", "4"]).val
    check microUnits(rateFor(rates, colLoss)) == 40_000

  test "bentuk rusak ditolak, bukan dianggap nol":
    check not parsePpapRates(%*["0", "0.5", "10", "50"]).isOk # kurang satu golongan
    check not parsePpapRates(%*["0", 0.5, "10", "50", "100"]).isOk # bukan string (desimal eksak)
    check not parsePpapRates(%*["0", "0.5", "10", "50", "101"]).isOk # melebihi 100%
    check not parsePpapRates(%*["0", "-1", "10", "50", "100"]).isOk # negatif
    check not parsePpapRates(%*["0", "abc", "10", "50", "100"]).isOk # bukan persen
    check not parsePpapRates(%*{"rates": seedRates}).isOk
    check not parsePpapRates(newJNull()).isOk

suite "lending ppap: penyisihan satu pinjaman":
  test "dasar × tarif dengan pembulatan sekali":
    check allowanceFor(mn("12000000.00"), pct("0")) == zero()
    check allowanceFor(mn("12000000.00"), pct("0.5")) == mn("60000.00")
    check allowanceFor(mn("12000000.00"), pct("10")) == mn("1200000.00")
    check allowanceFor(mn("12000000.00"), pct("100")) == mn("12000000.00")

  test "dasar nol tidak menyisihkan apa pun":
    check allowanceFor(zero(), pct("100")) == zero()

  test "pembulatan half-to-even, bukan selalu ke atas":
    # 0,01 × 50% = 0,005 → 0,00 (genap); 0,03 × 50% = 0,015 → 0,02 (genap).
    check allowanceFor(mn("0.01"), pct("50")) == zero()
    check allowanceFor(mn("0.03"), pct("50")) == mn("0.02")

  test "selisih penyisihan bertanda, siap dijurnal sebagai menambah atau membalik":
    check provisionDelta(mn("40000.00"), mn("100000.00")) == mn("60000.00")
    check provisionDelta(mn("100000.00"), mn("40000.00")) == mn("-60000.00")
    check provisionDelta(mn("50000.00"), mn("50000.00")) == zero()
