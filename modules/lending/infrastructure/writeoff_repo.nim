## Repositori hapus buku (T-168). SQL murni; pembagian penyisihan vs beban ada di domain.

import db_connector/db_postgres

import kernel/[ids, money, result]

import ../domain/writeoff

type
  Outstanding* = object
    principal*: Money
    interest*: Money
    penalty*: Money

proc activeOutstanding*(db: DbConn; loanId: Id): Outstanding =
  ## Sisa kewajiban dari **jadwal aktif** (baris superseded tidak dihitung: jadwalnya sudah
  ## digantikan restrukturisasi).
  let row = db.getRow(sql"""
    SELECT coalesce(sum(greatest(principal_due - paid_principal, 0)), 0)::numeric(24,2)::text,
           coalesce(sum(greatest(interest_due - paid_interest, 0)), 0)::numeric(24,2)::text,
           coalesce(sum(greatest(penalty_due - paid_penalty, 0)), 0)::numeric(24,2)::text
      FROM lending.installment
     WHERE loan_id = ? AND superseded_on IS NULL""", $loanId)
  Outstanding(
    principal: moneyFromString(row[0]).value(),
    interest: moneyFromString(row[1]).value(),
    penalty: moneyFromString(row[2]).value(),
  )

proc latestAllowance*(db: DbConn; loanId: Id): Money =
  ## Penyisihan terakhir yang dibentuk untuk pinjaman ini (0 bila belum pernah disisihkan). Yang
  ## dipakai adalah saldo `111` milik pinjaman, bukan tarif: hapus buku memakai dana yang benar-benar
  ## sudah dibentuk, bukan yang seharusnya dibentuk.
  let rows = db.getAllRows(sql"""
    SELECT allowance::numeric(24,2)::text FROM lending.ppap_snapshot
     WHERE loan_id = ? ORDER BY business_date DESC LIMIT 1""", $loanId)
  if rows.len == 0:
    return zero()
  moneyFromString(rows[0][0]).value()

proc collectibilityOf*(db: DbConn; loanId: Id): string =
  ## Golongan terkini menurut regrading terakhir. `""` = belum pernah dinilai.
  db.getValue(sql"SELECT coalesce(collectibility, '') FROM lending.loan WHERE loan_id = ?",
    $loanId)

proc markWrittenOff*(db: DbConn; loanId: Id; businessDate, reason: string; actor: Id): bool =
  ## `ACTIVE → WRITTEN_OFF` dengan jejak lengkap (CHECK DB memaksa ketiganya terisi).
  ## `false` = pinjaman tidak lagi `ACTIVE` (balapan) atau sudah dihapusbukukan.
  db.execAffectedRows(sql"""
    UPDATE lending.loan
       SET status = 'WRITTEN_OFF', written_off_on = ?::date, written_off_by = ?,
           written_off_reason = ?
     WHERE loan_id = ? AND status = 'ACTIVE'""", businessDate, $actor, reason, $loanId) == 1

proc insertWriteoff*(db: DbConn; loanId: Id; businessDate: string; split: WriteOffSplit;
    actor: Id) =
  db.exec(sql"""
    INSERT INTO lending.writeoff
      (loan_id, business_date, principal_amount, interest_amount, penalty_amount,
       allowance_applied, expense_amount, created_by)
    VALUES (?, ?::date, ?::numeric, ?::numeric, ?::numeric, ?::numeric, ?::numeric, ?)""",
    $loanId, businessDate, toDecimalString(split.principal), toDecimalString(split.interest),
    toDecimalString(split.penalty), toDecimalString(split.allowanceApplied),
    toDecimalString(split.expense), $actor)

proc zeroLoanBalance*(db: DbConn; loanId: Id) =
  ## Setelah hapus buku tidak ada kewajiban tersisa. `principal_outstanding` nol juga membuat PPAP
  ## tidak menyisihkan pinjaman ini bila statusnya kelak dibaca ulang.
  db.exec(sql"""
    UPDATE lending.loan_balance
       SET principal_outstanding = 0, interest_overdue = 0, penalty_outstanding = 0,
           updated_at = now()
     WHERE loan_id = ?""", $loanId)

proc allowanceAppliedOf*(db: DbConn; loanId: Id): Money =
  ## Berapa penyisihan yang sudah dipakai hapus buku. Dipakai pemeriksaan "penyisihan menggantung"
  ## (`DAY-384`): pinjaman tidak aktif hanya dianggap beres bila penyisihannya sudah terpakai.
  let rows = db.getAllRows(sql"""
    SELECT allowance_applied::numeric(24,2)::text FROM lending.writeoff WHERE loan_id = ?""",
    $loanId)
  if rows.len == 0:
    return zero()
  moneyFromString(rows[0][0]).value()
