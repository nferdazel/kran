## Repositori pemulihan pasca hapus buku (O-122, T-176). SQL murni; batas kumulatif ada di domain.

import db_connector/db_postgres

import kernel/[ids, money, result]

import ../domain/recovery

proc toComponents(row: seq[string]): RecoveryComponents =
  RecoveryComponents(
    principal: moneyFromString(row[0]).value(),
    interest: moneyFromString(row[1]).value(),
    penalty: moneyFromString(row[2]).value(),
  )

proc writtenOffComponents*(db: DbConn; loanId: Id): RecoveryComponents =
  ## Nilai yang dihapusbukukan (`lending.writeoff`). Nol bila pinjaman tidak pernah dihapusbukukan.
  let rows = db.getAllRows(sql"""
    SELECT principal_amount::numeric(24,2)::text,
           interest_amount::numeric(24,2)::text,
           penalty_amount::numeric(24,2)::text
      FROM lending.writeoff WHERE loan_id = ?""", $loanId)
  if rows.len == 0:
    return components(zero(), zero(), zero())
  toComponents(rows[0])

proc recoveredComponents*(db: DbConn; loanId: Id): RecoveryComponents =
  ## Total yang sudah dipulihkan sebelumnya (bisa bertahap).
  let row = db.getRow(sql"""
    SELECT coalesce(sum(principal_amount), 0)::numeric(24,2)::text,
           coalesce(sum(interest_amount), 0)::numeric(24,2)::text,
           coalesce(sum(penalty_amount), 0)::numeric(24,2)::text
      FROM lending.recovery WHERE loan_id = ?""", $loanId)
  toComponents(row)

proc insertRecovery*(db: DbConn; recoveryId, loanId: Id; businessDate: string;
    accountId: Id; plan: RecoveryPlan; reason: string; actor: Id) =
  db.exec(sql"""
    INSERT INTO lending.recovery
      (recovery_id, loan_id, business_date, account_id, principal_amount, interest_amount,
       penalty_amount, total_amount, reason, created_by)
    VALUES (?, ?, ?::date, ?, ?::numeric, ?::numeric, ?::numeric, ?::numeric, ?, ?)""",
    $recoveryId, $loanId, businessDate, $accountId,
    toDecimalString(plan.request.principal), toDecimalString(plan.request.interest),
    toDecimalString(plan.request.penalty), toDecimalString(plan.total), reason, $actor)
