## Unit test laporan `ledger` (T-075): penjumlahan & keseimbangan di layer domain.

import std/unittest

import kernel/[ids, money]
import ../api

proc line(code: string, debit, credit: int64): TrialBalanceLine =
  TrialBalanceLine(accountCode: code, accountName: code, accountType: atAsset,
    debit: money(debit), credit: money(credit))

suite "report: total & keseimbangan":
  test "TB kosong dianggap seimbang":
    let tb = TrialBalance(periodId: Id("11111111-1111-7111-8111-111111111111"),
      startsOn: "2026-10-01", endsOn: "2026-10-31")
    check tb.totalDebit.isZero
    check tb.totalCredit.isZero
    check tb.isBalanced

  test "total menjumlahkan seluruh baris":
    let tb = TrialBalance(periodId: Id("11111111-1111-7111-8111-111111111111"),
      startsOn: "2026-10-01", endsOn: "2026-10-31",
      lines: @[line("101", 250_0000, 0), line("201", 0, 200_0000), line("202", 0, 50_0000)])
    check tb.totalDebit == money(250_0000)
    check tb.totalCredit == money(250_0000)
    check tb.isBalanced

  test "selisih terdeteksi":
    let tb = TrialBalance(periodId: Id("11111111-1111-7111-8111-111111111111"),
      startsOn: "2026-10-01", endsOn: "2026-10-31",
      lines: @[line("101", 250_0000, 0), line("201", 0, 249_9999)])
    check not tb.isBalanced
