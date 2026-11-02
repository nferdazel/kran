## Unit test laporan pinjaman `lending` (T-171).
##
## Yang diuji adalah **bentuk agregat**, bukan query: total per golongan, keranjang kosong yang tidak
## dicetak, urutan keparahan, dan dua identitas rekonsiliasi. Angka nyata dari DB dibuktikan
## `itapi_lending_reports`.

import std/unittest

import kernel/[ids, money]

import ../domain/[collectibility, report]

proc item(grade: Collectibility; dpd: int; principal, interest, penalty: int64): ArrearsItem =
  ArrearsItem(
    loanId: Id("01a199bc-0000-7000-8000-000000000001"),
    partyId: Id("01a199bc-0000-7000-8000-000000000002"),
    branchId: Id("01a199bc-0000-7000-8000-000000000003"),
    dpd: dpd,
    grade: grade,
    principal: money(principal),
    interest: money(interest),
    penalty: money(penalty),
  )

proc line(grade: Collectibility; base, allowance: int64; rateMicro = 0'i64): AllowanceLine =
  AllowanceLine(grade: grade, loans: 1, base: money(base), rateMicro: rateMicro,
    allowance: money(allowance))

suite "laporan pinjaman: agregat tunggakan":
  test "total = jumlah komponen, bukan angka yang dikirim terpisah":
    let report = ArrearsReport(items: @[
      item(colSpecialMention, 10, 100_00, 10_00, 0),
      item(colSubstandard, 100, 200_00, 20_00, 5_00),
    ], asOf: "2026-11-01")
    let total = report.combined
    check total.principal == money(300_00)
    check total.interest == money(30_00)
    check total.penalty == money(5_00)
    check total.total == money(335_00)

  test "aging mengikuti urutan keparahan dan melewati keranjang kosong":
    let report = ArrearsReport(items: @[
      item(colDoubtful, 150, 10_00, 0, 0),
      item(colSpecialMention, 5, 20_00, 0, 0),
    ], asOf: "2026-11-01")
    let aging = groupByGrade(report.items)
    check aging.len == 2
    check aging[0].grade == colSpecialMention
    check aging[1].grade == colDoubtful
    check aging[0].loans == 1
    check aging[0].total == money(20_00)

  test "urutan laporan: tunggakan terlama lebih dulu, lalu id":
    let sorted = byDpd(@[
      item(colSpecialMention, 5, 0, 0, 0),
      item(colDoubtful, 150, 0, 0, 0),
    ])
    check sorted[0].dpd == 150
    check sorted[1].dpd == 5

suite "laporan pinjaman: agregat penyisihan":
  test "total penyisihan dan dasar dijumlahkan terpisah":
    let report = AllowanceReport(asOf: "2026-11-01", lines: @[
      line(colSpecialMention, 1_000_00, 5_00),
      line(colLoss, 2_000_00, 2_000_00),
    ])
    check report.allowanceTotal == money(2_005_00)
    check report.allowanceBase == money(3_000_00)

  test "golongan dengan dua tarif ditandai, bukan dirata-ratakan diam-diam":
    let report = AllowanceReport(asOf: "2026-11-01", lines: @[
      line(colSubstandard, 100_00, 10_00, rateMicro = 100_000),
      line(colSubstandard, 100_00, 5_00, rateMicro = 50_000),
    ])
    check mixedRates(report) == @[colSubstandard]

  test "satu tarif per golongan bukan `mixedRates`":
    let report = AllowanceReport(asOf: "2026-11-01", lines: @[
      line(colSubstandard, 100_00, 10_00, rateMicro = 100_000),
      line(colLoss, 100_00, 100_00, rateMicro = 1_000_000),
    ])
    check mixedRates(report).len == 0

suite "laporan pinjaman: rekonsiliasi":
  test "seimbang saat GL sama dengan subledger":
    let recon = Reconciliation(
      loanReceivableGl: money(500_000_00),
      loanReceivableSubledger: money(500_000_00),
      allowanceGl: money(50_000_00),
      allowanceSubledger: money(50_000_00),
      allowanceWrittenOff: zero(),
    )
    check recon.receivableDiff.isZero
    check recon.allowanceDiff.isZero
    check recon.isBalanced

  test "penyisihan terpakai hapus buku mengurangi yang seharusnya tercatat":
    let recon = Reconciliation(
      loanReceivableGl: zero(),
      loanReceivableSubledger: zero(),
      allowanceGl: money(30_000_00),
      allowanceSubledger: money(50_000_00),
      allowanceWrittenOff: money(20_000_00),
    )
    check recon.allowanceExpected == money(30_000_00)
    check recon.allowanceDiff.isZero
    check recon.isBalanced

  test "selisih dilaporkan bertanda, bukan nilai absolut":
    let recon = Reconciliation(
      loanReceivableGl: money(999_00),
      loanReceivableSubledger: money(1_000_00),
      allowanceGl: zero(),
      allowanceSubledger: zero(),
      allowanceWrittenOff: zero(),
    )
    check recon.receivableDiff == money(-1_00)
    check not recon.isBalanced
