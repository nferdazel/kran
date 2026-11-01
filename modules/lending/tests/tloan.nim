## Unit test domain `lending` (T-161): urutan alokasi, total jadwal, penyelesaian baris.
##
## Yang diuji hanya invarian struktural: tidak ada angka bisnis di sini (D-180), jadi tidak ada
## yang bisa "lulus karena angkanya kebetulan cocok".

import std/[strutils, unittest]

import kernel/[money, rate, result]

import ../domain/loan

suite "lending domain: metode jadwal":
  test "tiga metode yang dijual dikenali (D-180 butir 1)":
    check scheduleMethodOf("FLAT").val == smFlat
    check scheduleMethodOf("EFFECTIVE").val == smEffective
    check scheduleMethodOf("ANNUITY").val == smAnnuity

  test "metode tak dikenal ditolak, bukan jatuh ke default":
    let r = scheduleMethodOf("BALLOON")
    check not r.isOk
    check r.error.kind == aekValidation

suite "lending domain: urutan alokasi pembayaran":
  test "urutan lengkap diterima apa adanya":
    let r = parseAllocationOrder("INTEREST,PRINCIPAL,PENALTY")
    check r.isOk
    check r.val == @[acInterest, acPrincipal, acPenalty]

  test "spasi di sekitar koma tidak mengubah arti":
    let r = parseAllocationOrder(" PRINCIPAL , INTEREST , PENALTY ")
    check r.isOk
    check r.val == @[acPrincipal, acInterest, acPenalty]

  test "komponen hilang ditolak (uang tidak boleh tanpa tujuan)":
    let r = parseAllocationOrder("PRINCIPAL,INTEREST")
    check not r.isOk
    check r.error.details.find("tidak lengkap") >= 0

  test "komponen duplikat ditolak":
    let r = parseAllocationOrder("PRINCIPAL,PRINCIPAL,INTEREST,PENALTY")
    check not r.isOk
    check r.error.details.find("duplikat") >= 0

  test "komponen tak dikenal ditolak":
    let r = parseAllocationOrder("PRINCIPAL,INTEREST,PENALTY,TAX")
    check not r.isOk

  test "komponen kosong ditolak":
    check not parseAllocationOrder("").isOk
    check not parseAllocationOrder("PRINCIPAL,,INTEREST,PENALTY").isOk

  test "round-trip string":
    let order = @[acPenalty, acPrincipal, acInterest]
    check parseAllocationOrder(allocationOrderString(order)).val == order

suite "lending domain: baris jadwal":
  proc inst(p, i, pen, pp, pi, ppen: int64): Installment =
    Installment(
      principalDue: money(p),
      interestDue: money(i),
      penaltyDue: money(pen),
      paidPrincipal: money(pp),
      paidInterest: money(pi),
      paidPenalty: money(ppen),
    )

  test "total kewajiban = pokok + bunga + denda":
    check totalDue(inst(100, 20, 5, 0, 0, 0)) == money(125)

  test "lunas hanya bila setiap komponen tertutup":
    check isSettled(inst(100, 20, 5, 100, 20, 5))
    check not isSettled(inst(100, 20, 5, 100, 25, 0))

  test "total terbayar sama tidak berarti lunas":
    let i = inst(100, 20, 5, 105, 20, 0)
    check totalPaid(i) == totalDue(i)
    check not isSettled(i)

suite "lending domain: produk versi":
  test "versi produk membawa metode, tenor, dan rate tanpa float":
    let v = LoanProductVersion(
      scheduleMethod: smAnnuity, tenorMonths: 24, annualRate: rateFromMicro(150_000)
    )
    check v.scheduleMethod == smAnnuity
    check microUnits(v.annualRate) == 150_000
