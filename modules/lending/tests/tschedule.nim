## Unit + property test mesin jadwal angsuran `lending` (T-162).
##
## Golden: satu tabel per metode untuk pokok 12.000.000, rate 12% p.a., 12 bulan. Angka harapan
## dihitung **manual** dari definisi metode (flat: bunga total / 12; efektif: 1% × saldo tersisa;
## anuitas: rumus `A = P·i/(1−(1+i)^−n)` dibulatkan ke sen), bukan disalin dari keluaran mesin ini.
##
## Property: invarian yang harus benar untuk setiap masukan wajar — jumlah pokok **tepat** sama
## dengan pokok pinjaman, tidak ada baris nol/negatif, tanggal jatuh tempo naik monoton, dan sisa
## pembulatan hanya boleh berada di baris terakhir.

import std/[random, sequtils, unittest]

import kernel/[money, rate, result]

import ../domain/[loan, schedule]

proc mn(s: string): Money =
  let m = moneyFromString(s)
  doAssert m.isOk, "nilai uji tidak sah: " & s
  m.val

proc rate(s: string): Rate =
  let r = rateFromPercentString(s)
  doAssert r.isOk, "rate uji tidak sah: " & s
  r.val

proc build(
    principal: Money; annual: Rate; months: int; scheduleMethod: ScheduleMethod
): seq[Installment] =
  let s = buildSchedule(principal, annual, months, scheduleMethod, "2026-12-01")
  doAssert s.isOk, "jadwal gagal dibentuk: " & (if s.isOk: "" else: s.error.details)
  s.val

proc amounts(rows: openArray[Installment]; f: proc(r: Installment): Money): seq[string] =
  for r in rows:
    result.add(toDecimalString(f(r)))

suite "lending schedule: flat (golden)":
  let rows = build(mn("12000000.00"), rate("12"), 12, smFlat)

  test "12 baris, pokok rata, bunga rata":
    check rows.len == 12
    check amounts(rows, proc(r: Installment): Money = r.principalDue) ==
      newSeqWith(12, "1000000.00")
    check amounts(rows, proc(r: Installment): Money = r.interestDue) ==
      newSeqWith(12, "120000.00")

  test "bunga total = pokok × rate × tenor/12 = 1.440.000,00":
    check totalDueOfSchedule(rows) == mn("13440000.00")

suite "lending schedule: efektif (golden)":
  let rows = build(mn("12000000.00"), rate("12"), 12, smEffective)

  test "pokok rata 1.000.000,00":
    check amounts(rows, proc(r: Installment): Money = r.principalDue) ==
      newSeqWith(12, "1000000.00")

  test "bunga = 1% saldo tersisa, menurun 10.000,00 per baris":
    let expected = @[
      "120000.00", "110000.00", "100000.00", "90000.00", "80000.00", "70000.00",
      "60000.00", "50000.00", "40000.00", "30000.00", "20000.00", "10000.00",
    ]
    check amounts(rows, proc(r: Installment): Money = r.interestDue) == expected
    check totalDueOfSchedule(rows) == mn("12780000.00")

suite "lending schedule: anuitas (golden)":
  let rows = build(mn("12000000.00"), rate("12"), 12, smAnnuity)

  test "angsuran tetap 1.066.185,47 (rumus baku dibulatkan ke sen)":
    # A = P·i/(1−(1+i)^−12) = 1.066.185,464…; sen terdekat = 1.066.185,46; angsuran terkecil
    # yang benar-benar menutup 12 baris dengan pembulatan per baris = 1.066.185,47.
    check rows[0].totalDue == mn("1066185.47")
    for k in 0 ..< 11:
      check toDecimalString(rows[k].totalDue) == "1066185.47"

  test "baris terakhir menutup sisa, bukan menambah angsuran":
    check rows[11].principalDue == mn("1055629.12")
    check rows[11].interestDue == mn("10556.29")
    # 6 sen selisih pembulatan berakhir di baris terakhir.
    check rows[11].totalDue == mn("1066185.41")

  test "pokok total tepat sama dengan pokok pinjaman":
    check principalOfSchedule(rows) == mn("12000000.00")
    check totalDueOfSchedule(rows) == mn("12000000.00") + mn("794225.58")

suite "lending schedule: tanggal jatuh tempo":
  test "jatuh tempo bulanan, bukan 30 hari":
    let s = buildSchedule(mn("1200000.00"), rate("0"), 3, smFlat, "2027-01-15")
    check s.isOk
    var dates: seq[string] = @[]
    for r in s.val:
      dates.add(r.dueOn)
    check dates == @["2027-01-15", "2027-02-15", "2027-03-15"]

  test "akhir bulan dijepit ke hari terakhir bulan tujuan":
    let s = buildSchedule(mn("1200000.00"), rate("0"), 4, smFlat, "2027-01-31")
    check s.isOk
    var dates: seq[string] = @[]
    for r in s.val:
      dates.add(r.dueOn)
    check dates == @["2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30"]

suite "lending schedule: kasus tepi":
  test "rate 0% tetap menghasilkan jadwal sah":
    for m in [smFlat, smEffective, smAnnuity]:
      let rows = build(mn("600000.00"), rate("0"), 6, m)
      check rows.len == 6
      check principalOfSchedule(rows) == mn("600000.00")
      check totalDueOfSchedule(rows) == mn("600000.00")

  test "tenor 1 bulan: seluruh pokok di satu baris":
    for m in [smFlat, smEffective, smAnnuity]:
      let rows = build(mn("2500000.00"), rate("9.5"), 1, m)
      check rows.len == 1
      check rows[0].penaltyDue == zero()

  test "masukan tidak sah ditolak, bukan menghasilkan jadwal kosong":
    check not buildSchedule(mn("1000000.00"), rate("12"), 0, smFlat, "2026-12-01").isOk
    check not buildSchedule(mn("0.00"), rate("12"), 12, smFlat, "2026-12-01").isOk
    check not buildSchedule(mn("1000000.00"), rate("-1"), 12, smFlat, "2026-12-01").isOk
    check not buildSchedule(mn("1000000.00"), rate("12"), 12, smFlat, "2026-13-01").isOk

suite "lending schedule: property":
  const
    methods = [smFlat, smEffective, smAnnuity]
    tenors = [1, 2, 3, 6, 12, 24, 36, 60, 120, 180, 360]

  proc randomCase(r: var Rand): tuple[p: Money; rateMicro: int64; months: int] =
    # Pokok 100.000,00 … 10.000.000.000,00 dan rate 0 … 30% p.a. — rentang wajar KRAN, dan
    # cukup lebar untuk memaksa sisa pembulatan muncul.
    let
      p = money(r.rand(1_000_000_000_000'i64 - 10_000_000'i64) + 10_000_000'i64)
      rateMicro = int64(r.rand(300_001))
      months = tenors[r.rand(tenors.high)]
    (p, rateMicro, months)

  test "invarian jadwal berlaku untuk 300 kasus acak deterministik":
    var r = initRand(20261101)
    var failures: seq[string] = @[]
    for _ in 0 ..< 300:
      let c = randomCase(r)
      for scheduleMethod in methods:
        let s = buildSchedule(c.p, rateFromMicro(c.rateMicro), c.months, scheduleMethod, "2026-11-01")
        if not s.isOk:
          failures.add("gagal bentuk: " & s.error.details)
          continue
        let rows = s.val
        let tag = toDecimalString(c.p) & "/" & $c.rateMicro & "/" & $c.months & "/" & $scheduleMethod
        if rows.len != c.months:
          failures.add("panjang " & $rows.len & " != " & $c.months & " (" & tag & ")")
        if principalOfSchedule(rows) != c.p:
          failures.add("pokok total tidak sama: " & tag)
        var previous = ""
        for row in rows:
          if row.principalDue.isNegative or row.interestDue.isNegative:
            failures.add("baris negatif: " & tag)
          if not totalDue(row).isPositive:
            failures.add("baris tanpa kewajiban: " & tag)
          if previous.len > 0 and row.dueOn <= previous:
            failures.add("tanggal tidak naik: " & previous & " -> " & row.dueOn & " (" & tag & ")")
          previous = row.dueOn
    check failures.len == 0
    if failures.len > 0:
      echo "  kasus gagal pertama: ", failures[0]

  test "sisa pembulatan hanya di baris terakhir (flat & efektif: pokok rata)":
    var r = initRand(20261102)
    for _ in 0 ..< 50:
      let c = randomCase(r)
      for scheduleMethod in [smFlat, smEffective]:
        let rows = build(c.p, rateFromMicro(c.rateMicro), c.months, scheduleMethod)
        if rows.len < 2:
          continue
        # Pokok rata di semua baris kecuali terakhir, dan baris terakhir menyerap sisa
        # pembulatan — besarnya paling banyak 1 sen per baris.
        let first = rows[0].principalDue
        for k in 0 ..< rows.len - 1:
          check rows[k].principalDue == first
        check minorUnits(abs(rows[^1].principalDue - first)) <= int64(rows.len)

  test "anuitas: angsuran tetap kecuali baris terakhir":
    var r = initRand(20261103)
    for _ in 0 ..< 50:
      let c = randomCase(r)
      let rows = build(c.p, rateFromMicro(c.rateMicro), c.months, smAnnuity)
      if rows.len < 2:
        continue
      let total = rows[0].totalDue
      for k in 0 ..< rows.len - 1:
        check rows[k].totalDue == total
      check rows[^1].totalDue <= total

  test "efektif: bunga tidak pernah naik":
    var r = initRand(20261104)
    for _ in 0 ..< 50:
      let c = randomCase(r)
      let rows = build(c.p, rateFromMicro(c.rateMicro), c.months, smEffective)
      for k in 1 ..< rows.len:
        check rows[k].interestDue <= rows[k - 1].interestDue
