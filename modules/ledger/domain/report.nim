## Laporan buku besar (T-075): trial balance. Murni; sumber angka = jurnal.

import kernel/[ids, money]
import ./coa

type
  TrialBalanceLine* = object
    accountCode*: string
    accountName*: string
    accountType*: AccountType
    debit*: Money
    credit*: Money

  TrialBalance* = object
    periodId*: Id
    startsOn*: string
    endsOn*: string
    lines*: seq[TrialBalanceLine]

proc totalDebit*(tb: TrialBalance): Money =
  for l in tb.lines:
    result = result + l.debit

proc totalCredit*(tb: TrialBalance): Money =
  for l in tb.lines:
    result = result + l.credit

proc isBalanced*(tb: TrialBalance): bool =
  totalDebit(tb) == totalCredit(tb)
