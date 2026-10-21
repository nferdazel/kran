## Laporan buku besar (T-075 trial balance, T-082 saldo GL). Murni; sumber angka = jurnal.

import std/tables

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

  BalanceSource* = enum
    ## Asal angka laporan saldo (D-096): dihitung dari jurnal, atau dibuktikan oleh cache
    ## `balance_snapshot` pada periode yang sudah CLOSED.
    bsLedger = "ledger"
    bsSnapshot = "snapshot"

  BalanceLine* = object
    ## Saldo satu akun untuk satu periode. Debit/kredit **terpisah** (bukan saldo bersih).
    ## `opening` = kumulatif sebelum periode; `period` = mutasi dalam rentang inklusif;
    ## `closing` = opening + period (turunan, lihat `closingDebit`/`closingCredit`).
    accountCode*: string
    accountName*: string
    accountType*: AccountType
    openingDebit*: Money
    openingCredit*: Money
    periodDebit*: Money
    periodCredit*: Money

  SnapshotTotal* = object
    ## Satu baris cache `balance_snapshot` pada satu `as_of` (kumulatif sampai tanggal itu).
    accountCode*: string
    debit*: Money
    credit*: Money

proc totalDebit*(tb: TrialBalance): Money =
  for l in tb.lines:
    result = result + l.debit

proc totalCredit*(tb: TrialBalance): Money =
  for l in tb.lines:
    result = result + l.credit

proc isBalanced*(tb: TrialBalance): bool =
  totalDebit(tb) == totalCredit(tb)

proc closingDebit*(l: BalanceLine): Money =
  l.openingDebit + l.periodDebit

proc closingCredit*(l: BalanceLine): Money =
  l.openingCredit + l.periodCredit

proc snapshotMatches*(lines: openArray[BalanceLine],
                      snapshot: openArray[SnapshotTotal]): bool =
  ## Gerbang rekonsiliasi D-096: cache kumulatif pada `endsOn` sama **per akun** dengan hasil
  ## jurnal (opening + mutasi). Setelah periode CLOSED, jurnal tidak bisa berubah; jadi
  ## kesamaan ini berarti snapshot boleh dipakai sebagai sumber (`source=snapshot`).
  ## Cacat data konservatif: himpunan akun dan nilainya harus cocok persis, kalau tidak → false.
  var cumulative = initTable[string, tuple[debit: Money, credit: Money]]()
  for l in lines:
    cumulative[l.accountCode] = (closingDebit(l), closingCredit(l))
  var matched = initTable[string, bool]()
  for s in snapshot:
    if not cumulative.hasKey(s.accountCode):
      return false
    let c = cumulative[s.accountCode]
    if c.debit != s.debit or c.credit != s.credit:
      return false
    matched[s.accountCode] = true
  # Setiap akun yang punya angka kumulatif ≠ 0 juga harus ada di snapshot.
  for code, c in cumulative:
    if (not c.debit.isZero or not c.credit.isZero) and not matched.getOrDefault(code, false):
      return false
  true
