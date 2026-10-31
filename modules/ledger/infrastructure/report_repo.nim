## Query laporan (T-075). Trial balance dihitung dari `journal_line` (sumber kebenaran), bukan
## dari cache `balance_snapshot`.

import std/[options, strutils]

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

proc balancesFromLedger*(db: DbConn, startsOn, endsOn: string): seq[BalanceLine] =
  ## Laporan saldo GL dari `journal_line` dalam **satu** query agregasi (D-096): opening =
  ## kumulatif jurnal sebelum `startsOn`, period = mutasi dalam rentang **inklusif**.
  ## Baris = akun bergerak di periode atau bersaldo awal ≠ 0; akun lain tidak muncul.
  ## `closing` tidak dikembalikan DB — ia turunan `opening + period` (lihat domain `report`).
  for row in db.getAllRows(sql"""
      SELECT code, name, account_type,
             opening_debit::text, opening_credit::text,
             period_debit::text, period_credit::text
        FROM (
          SELECT a.code, a.name, a.account_type,
                 coalesce(sum(l.debit) FILTER (WHERE j.business_date < ?::date), 0)
                   AS opening_debit,
                 coalesce(sum(l.credit) FILTER (WHERE j.business_date < ?::date), 0)
                   AS opening_credit,
                 coalesce(sum(l.debit)
                   FILTER (WHERE j.business_date BETWEEN ?::date AND ?::date), 0)
                   AS period_debit,
                 coalesce(sum(l.credit)
                   FILTER (WHERE j.business_date BETWEEN ?::date AND ?::date), 0)
                   AS period_credit
            FROM ledger.coa_account a
            LEFT JOIN ledger.journal_line l ON l.gl_account = a.code
            LEFT JOIN ledger.journal j ON j.journal_id = l.journal_id
           GROUP BY a.code, a.name, a.account_type
        ) t
       WHERE opening_debit <> 0 OR opening_credit <> 0
          OR period_debit <> 0 OR period_credit <> 0
       ORDER BY code""", startsOn, startsOn, startsOn, endsOn, startsOn, endsOn):
    let accountType = parseAccountType(row[2])
    if accountType.isNone:
      raise newException(ValueError, "account_type di DB tidak dikenal: " & row[2])
    result.add BalanceLine(
      accountCode: row[0],
      accountName: row[1],
      accountType: accountType.get(),
      openingDebit: moneyOf(row[3]),
      openingCredit: moneyOf(row[4]),
      periodDebit: moneyOf(row[5]),
      periodCredit: moneyOf(row[6]))

proc snapshotBalances*(db: DbConn, asOf: string): seq[SnapshotTotal] =
  ## Cache kumulatif pada satu tanggal, dalam `Money` (gerbang rekonsiliasi T-082).
  for row in db.getAllRows(sql"""
      SELECT account_code, debit_total::text, credit_total::text
        FROM ledger.balance_snapshot WHERE as_of = ?::date ORDER BY account_code""", asOf):
    result.add SnapshotTotal(accountCode: row[0], debit: moneyOf(row[1]),
      credit: moneyOf(row[2]))


proc rebuildSnapshot*(db: DbConn, asOf: string) =
  ## Fungsi SQL mengembalikan satu baris (void); `exec` pada SELECT yang mengembalikan hasil
  ## menghasilkan error kosong di driver, jadi hasilnya dibaca lewat `getValue` dan dibuang.
  discard db.getValue(sql"SELECT ledger.rebuild_balance_snapshot(?::date)", asOf)

proc latePostings*(db: DbConn, businessDate, frozenAtIso: string;
                   idLimit = 20): tuple[count: int64, ids: seq[string]] =
  ## Jurnal bertanggal `businessDate` yang **direkam setelah** tanggal dibekukan. Gerbang HTTP
  ## adalah cek-lalu-jalan (TOCTOU): permintaan yang lolos sebelum freeze bisa commit sesudahnya.
  ## Gate ini yang menangkapnya, bukan asumsi bahwa race tidak terjadi.
  for row in db.getAllRows(sql"""
      SELECT journal_id::text, count(*) OVER ()::text
        FROM ledger.journal
       WHERE business_date = ?::date
         AND recorded_at > ?::timestamptz
         -- Jurnal yang dibuat task penutupan itu sendiri (`ledger/0072`): akrual dan perpindahan
         -- jatuh tempo memang direkam setelah freeze, dan itu bukan tulisan terlambat.
         AND daycloser_run_id IS NULL
       ORDER BY recorded_at, journal_id
       LIMIT ?""", businessDate, frozenAtIso, idLimit):
    result.ids.add row[0]
    result.count = parseBiggestInt(row[1]).int64
