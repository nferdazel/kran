## Unit + property test alokasi pembayaran angsuran `lending` (T-165).
##
## Golden: jadwal flat 12.000.000 / 12% p.a. / 12 bulan (pokok 1.000.000 dan bunga 120.000 per
## baris), sehingga pembagian bisa dihitung tangan. Dua urutan parameter yang berbeda harus
## menghasilkan pembagian **berbeda** — kalau hasilnya sama, urutannya hiasan, bukan aturan.
##
## Property: untuk setiap jadwal dan nominal wajar, `Σ alokasi == nominal` tepat, tidak ada
## komponen yang melebihi kewajibannya, dan baris yang sudah lunas tidak menerima alokasi lagi.

import std/[random, strutils, unittest]

import kernel/[money, rate, result]

import ../domain/[loan, payment, schedule]

proc mn(s: string): Money =
  let m = moneyFromString(s)
  doAssert m.isOk, "nilai uji tidak sah: " & s
  m.val

proc rate(s: string): Rate =
  let r = rateFromPercentString(s)
  doAssert r.isOk, "rate uji tidak sah: " & s
  r.val

proc flatRows(principal = "12000000.00"; annual = "12"; months = 12): seq[Installment] =
  let s = buildSchedule(mn(principal), rate(annual), months, smFlat, "2026-12-01")
  doAssert s.isOk, "jadwal gagal dibentuk"
  s.val

proc plan(rows: seq[Installment]; order: openArray[AllocationComponent];
    amount: string): PaymentPlan =
  let p = allocatePayment(rows, order, mn(amount))
  doAssert p.isOk, (if p.isOk: "" else: p.error.details)
  p.val

const
  interestFirst = [acInterest, acPrincipal, acPenalty]
  principalFirst = [acPrincipal, acInterest, acPenalty]

proc orderOf(items: array[3, AllocationComponent]): seq[AllocationComponent] =
  ## `orders` di property test butuh `seq` agar bisa diindeks acak; konstanta di atas tetap array
  ## supaya golden test terbaca sebagai urutan literal.
  @items

suite "lending payment: golden urutan parameter":
  let rows = flatRows()

  test "bunga dulu: 1.500.000 menutup bunga penuh lalu pokok dua baris":
    let p = plan(rows, interestFirst, "1500000.00")
    check p.lines == @[
      PaymentLine(installmentNo: 1, component: acInterest, amount: mn("120000.00")),
      PaymentLine(installmentNo: 1, component: acPrincipal, amount: mn("1000000.00")),
      PaymentLine(installmentNo: 2, component: acInterest, amount: mn("120000.00")),
      PaymentLine(installmentNo: 2, component: acPrincipal, amount: mn("260000.00")),
    ]
    check p.interest == mn("240000.00")
    check p.principal == mn("1260000.00")
    check p.penalty == zero()

  test "pokok dulu: nominal yang sama membagi ke komponen berbeda":
    let p = plan(rows, principalFirst, "1500000.00")
    check p.principal == mn("1380000.00")
    check p.interest == mn("120000.00")
    check p.penalty == zero()
    # Inti D-180 butir 4: urutan datang dari parameter, jadi hasilnya tidak boleh identik.
    check p.principal != plan(rows, interestFirst, "1500000.00").principal

  test "denda hanya dialokasikan setelah komponen sebelumnya tertutup":
    var withPenalty = rows
    withPenalty[0].penaltyDue = mn("5000.00")
    let p = plan(withPenalty, interestFirst, "1125000.00")
    check p.interest == mn("120000.00")
    check p.principal == mn("1000000.00")
    check p.penalty == mn("5000.00")
    # Denda tidak pernah lebih dulu: nominal yang sama tanpa denda tersisa di bunga/pokok.
    let withoutPenalty = plan(rows, interestFirst, "1125000.00")
    check withoutPenalty.penalty == zero()

suite "lending payment: batas dan kesalahan":
  let rows = flatRows()

  test "nominal melebihi sisa kewajiban ditolak, bukan dikreditkan diam-diam":
    let total = totalOutstanding(rows)
    let over = allocatePayment(rows, interestFirst, total + mn("0.01"))
    check not over.isOk
    check over.error.details.contains("melebihi sisa kewajiban")

  test "nominal nol/negatif ditolak":
    check not allocatePayment(rows, interestFirst, zero()).isOk
    check not allocatePayment(rows, interestFirst, mn("-1.00")).isOk

  test "urutan tidak lengkap atau duplikat ditolak":
    check not allocatePayment(rows, [acInterest, acPrincipal], mn("1000.00")).isOk
    check not allocatePayment(rows, [acInterest, acInterest, acPrincipal], mn("1000.00")).isOk
    check not allocatePayment(rows, [acInterest, acPrincipal, acPenalty, acPenalty],
      mn("1000.00")).isOk

  test "baris yang sudah lunas tidak menerima alokasi":
    var paid = rows
    paid[0].paidInterest = paid[0].interestDue
    paid[0].paidPrincipal = paid[0].principalDue
    let p = plan(paid, interestFirst, "120000.00")
    check p.lines.len == 1
    check p.lines[0].installmentNo == 2
    check p.lines[0].component == acInterest
    # Dua sen lebih: sisa bunga baris 2 sudah tertutup sebagian, jadi potongan berikutnya jatuh ke
    # pokok baris 2 — bukan kembali ke baris 1 yang sudah lunas.
    let more = plan(paid, interestFirst, "120000.02")
    check more.lines[1] == PaymentLine(installmentNo: 2, component: acPrincipal,
      amount: mn("0.02"))

suite "lending payment: pelunasan penuh":
  test "membayar sisa kewajiban menutup setiap baris tepat":
    var rows = flatRows(principal = "600000.00", annual = "0", months = 3)
    let total = totalOutstanding(rows)
    let p = plan(rows, interestFirst, toDecimalString(total))
    applyPlan(rows, p)
    for row in rows:
      check row.isSettled
    check totalPaid(rows[0]) + totalPaid(rows[1]) + totalPaid(rows[2]) == total
    check totalOutstanding(rows) == zero()

  test "pembayaran bertahap sampai lunas tidak menyisakan selisih":
    var rows = flatRows(principal = "3600000.00", annual = "12", months = 6)
    let total = totalOutstanding(rows)
    var paidSoFar = zero()
    # Tiga cicilan tidak rata; sisanya dilunasi pada pembayaran terakhir.
    for chunk in ["100000.00", "250000.50", "999.50"]:
      let p = plan(rows, principalFirst, chunk)
      applyPlan(rows, p)
      paidSoFar = paidSoFar + mn(chunk)
    let rest = total - paidSoFar
    let p = plan(rows, principalFirst, toDecimalString(rest))
    applyPlan(rows, p)
    check totalOutstanding(rows) == zero()
    for row in rows:
      check row.isSettled

suite "lending payment: property":
  const
    tenors = [1, 2, 3, 6, 12, 24, 36]
    orders = [orderOf(interestFirst), orderOf(principalFirst),
              orderOf([acPenalty, acInterest, acPrincipal])]

  test "invarian alokasi berlaku untuk 200 kasus acak deterministik":
    var r = initRand(20261105)
    var failures: seq[string] = @[]
    for _ in 0 ..< 200:
      let
        principal = money(r.rand(900_000_000'i64) + 100_000'i64) # 1.000,00 … 9.000.000,00
        annual = rateFromMicro(int64(r.rand(300_001)))
        months = tenors[r.rand(tenors.high)]
        scheduleMethod = ScheduleMethod(r.rand(ord(high(ScheduleMethod))))
        order = orders[r.rand(orders.high)]
      let built = buildSchedule(principal, annual, months, scheduleMethod, "2026-11-01")
      if not built.isOk:
        failures.add("jadwal gagal: " & built.error.details)
        continue
      var rows = built.val
      let total = totalOutstanding(rows)
      if not total.isPositive:
        continue
      let amount = money(r.rand(int(minorUnits(total))) + 1)
      let allocated = allocatePayment(rows, order, amount)
      let tag = toDecimalString(principal) & "/" & $annual & "/" & $months & "/" & $scheduleMethod
      if not allocated.isOk:
        failures.add("alokasi gagal: " & allocated.error.details & " (" & tag & ")")
        continue
      let p = allocated.val
      let sum = p.principal + p.interest + p.penalty
      if sum != amount:
        failures.add("total alokasi " & toDecimalString(sum) & " != " & toDecimalString(amount) &
          " (" & tag & ")")
      applyPlan(rows, p)
      for row in rows:
        if row.paidPrincipal > row.principalDue or row.paidInterest > row.interestDue or
           row.paidPenalty > row.penaltyDue:
          failures.add("komponen melebihi kewajiban (" & tag & ")")
        if row.paidPrincipal.isNegative or row.paidInterest.isNegative or
           row.paidPenalty.isNegative:
          failures.add("komponen negatif (" & tag & ")")
      if totalOutstanding(rows) != total - amount:
        failures.add("sisa kewajiban tidak turun tepat sebesar nominal (" & tag & ")")
    check failures.len == 0
    if failures.len > 0:
      echo "  kasus gagal pertama: ", failures[0]
