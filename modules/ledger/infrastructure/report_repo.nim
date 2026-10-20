## Query laporan (T-075). Trial balance dihitung dari `journal_line` (sumber kebenaran), bukan
## dari cache `balance_snapshot`.

import std/options

import kernel/[ids, money]

import db_connector/db_postgres

import ../domain/[coa, report]
import ./journal_repo

proc trialBalance*(db: DbConn, periodId: Id): Option[TrialBalance] =
  ## Agregasi debit/kredit per akun untuk rentang periode. Akun tanpa pergerakan tidak muncul.
  ## `none` = periode tidak ada (404); kerusakan data tetap `ValueError` (500).
  let rows = db.getAllRows(sql"""
    SELECT to_char(starts_on, 'YYYY-MM-DD'), to_char(ends_on, 'YYYY-MM-DD')
      FROM ledger.period WHERE period_id = ?""", $periodId)
  if rows.len == 0:
    return none(TrialBalance)
  result = some(TrialBalance(periodId: periodId, startsOn: rows[0][0], endsOn: rows[0][1]))
  for row in db.getAllRows(sql"""
      SELECT a.code, a.name, a.account_type,
             sum(l.debit)::text, sum(l.credit)::text
        FROM ledger.journal_line l
        JOIN ledger.journal j ON j.journal_id = l.journal_id
        JOIN ledger.coa_account a ON a.code = l.gl_account
       WHERE j.business_date BETWEEN ?::date AND ?::date
       GROUP BY a.code, a.name, a.account_type
       ORDER BY a.code""", result.get().startsOn, result.get().endsOn):
    let accountType = parseAccountType(row[2])
    if accountType.isNone:
      raise newException(ValueError, "account_type di DB tidak dikenal: " & row[2])
    result.get().lines.add TrialBalanceLine(
      accountCode: row[0],
      accountName: row[1],
      accountType: accountType.get(),
      debit: moneyOf(row[3]),
      credit: moneyOf(row[4]))

proc snapshotTotals*(db: DbConn, asOf: string): seq[tuple[accountCode: string,
    debit: int64, credit: int64]] =
  ## Isi cache (untuk test rekonsiliasi). Bukan dipakai jalur laporan.
  for row in db.getAllRows(sql"""
      SELECT account_code, debit_total::text, credit_total::text
        FROM ledger.balance_snapshot WHERE as_of = ?::date ORDER BY account_code""", asOf):
    result.add (row[0], moneyOf(row[1]).minorUnits, moneyOf(row[2]).minorUnits)

proc rebuildSnapshot*(db: DbConn, asOf: string) =
  ## Fungsi SQL mengembalikan satu baris (void); `exec` pada SELECT yang mengembalikan hasil
  ## menghasilkan error kosong di driver, jadi hasilnya dibaca lewat `getValue` dan dibuang.
  discard db.getValue(sql"SELECT ledger.rebuild_balance_snapshot(?::date)", asOf)
