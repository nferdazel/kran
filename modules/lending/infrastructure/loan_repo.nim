## Repositori `lending` (T-163). SQL murni; tidak ada aturan bisnis di sini.
##
## Modul ini sengaja tidak mengimpor internal `platform` (archcheck rule C): audit dan outbox
## ditulis pemanggil (composition root `apps/api`) dalam transaksi yang sama.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/[ids, money, rate, result]
import ../domain/loan

proc scheduleMethodOrRaise(raw: string): ScheduleMethod =
  let parsed = scheduleMethodOf(raw)
  if not parsed.isOk:
    # Nilai kolom dijaga CHECK DB; kalau ini terjadi, skema dan domain tidak sinkron — bug, bukan
    # kesalahan data pengguna.
    raise newException(ValueError, parsed.error.details)
  parsed.val

proc allocationOrderOrRaise(raw: string): seq[AllocationComponent] =
  let parsed = parseAllocationOrder(raw)
  if not parsed.isOk:
    raise newException(ValueError, parsed.error.details)
  parsed.val

proc productVersionById*(db: DbConn, versionId: Id): Option[LoanProductVersion] =
  ## Versi produk beserta atributnya. Status ikut dibaca: hanya `ACTIVE` yang boleh dipakai akad.
  # `getRow` mengembalikan Row berisi kolom kosong bila hasilnya nol baris (jebakan db_connector),
  # jadi "tidak ditemukan" dideteksi lewat `getAllRows` — sama seperti `partyById`.
  let rows = db.getAllRows(sql"""
    SELECT version_id::text, product_id::text, version_no, status, schedule_method, tenor_months,
           annual_rate, allocation_order
      FROM lending.loan_product_version
     WHERE version_id = ?
  """, $versionId)
  if rows.len == 0:
    return none(LoanProductVersion)
  let row = rows[0]
  let status = if row[3] == "ACTIVE": pvsActive else: pvsDraft
  some(LoanProductVersion(
    versionId: Id(row[0]),
    productId: Id(row[1]),
    versionNo: parseInt(row[2]),
    status: status,
    scheduleMethod: scheduleMethodOrRaise(row[4]),
    tenorMonths: parseInt(row[5]),
    annualRate: rateFromMicro(parseBiggestInt(row[6])),
    allocationOrder: allocationOrderOrRaise(row[7]),
  ))

proc insertLoan*(db: DbConn, loan: Loan) =
  ## Pengajuan baru. `approved_by` sengaja tidak dikirim: kolom itu hanya diisi saat approve, dan
  ## CHECK DB menolak penyetuju yang sama dengan pembuat.
  db.exec(sql"""
    INSERT INTO lending.loan
      (loan_id, party_id, product_version_id, branch_id, principal, status, disbursed_on,
       maturity_on, applied_by)
    VALUES (?, ?, ?, ?, ?::numeric, ?, NULLIF(?, '')::date, NULLIF(?, '')::date, ?)
  """, $loan.loanId, $loan.partyId, $loan.productVersionId, $loan.branchId,
      toDecimalString(loan.principal), $loan.status, loan.disbursedOn, loan.maturityOn,
      $loan.appliedBy)

proc loanById*(db: DbConn, loanId: Id; forUpdate = false): Option[Loan] =
  ## `forUpdate` dipakai approve: dua penyetuju bersamaan harus antre di baris yang sama, bukan
  ## sama-sama membaca `APPLIED` lalu satu di antaranya menimpa.
  let suffix = if forUpdate: " FOR UPDATE" else: ""
  let rows = db.getAllRows(sql(
    """
    SELECT loan_id::text, party_id::text, product_version_id::text, branch_id::text,
           principal::text, status, coalesce(disbursed_on::text, ''),
           coalesce(maturity_on::text, ''), applied_by::text, coalesce(approved_by::text, '')
      FROM lending.loan
     WHERE loan_id = ?
    """ & suffix), $loanId)
  if rows.len == 0:
    return none(Loan)
  let row = rows[0]
  let status =
    case row[5]
    of "APPLIED": lsApplied
    of "APPROVED": lsApproved
    of "ACTIVE": lsActive
    of "CLOSED": lsClosed
    of "WRITTEN_OFF": lsWrittenOff
    else: raise newException(ValueError, "status pinjaman tidak dikenal: " & row[5])
  let principal = moneyFromString(row[4])
  if not principal.isOk:
    raise newException(ValueError, "pokok pinjaman tersimpan bukan nominal sah: " & row[4])
  some(Loan(
    loanId: Id(row[0]),
    partyId: Id(row[1]),
    productVersionId: Id(row[2]),
    branchId: Id(row[3]),
    principal: principal.val,
    status: status,
    disbursedOn: row[6],
    maturityOn: row[7],
    appliedBy: Id(row[8]),
    approvedBy: (if row[9].len == 0: Id("") else: Id(row[9])),
  ))

proc approveLoan*(db: DbConn, loanId: Id; approver: Id): bool =
  ## `false` = pengajuan sudah diputuskan pihak lain (balapan), bukan galat. Penyetuju disimpan
  ## sekali; CHECK DB menolak penyetuju yang sama dengan pembuat walau handler lupa memeriksanya.
  db.execAffectedRows(sql"""
    UPDATE lending.loan
       SET status = 'APPROVED', approved_by = ?
     WHERE loan_id = ? AND status = 'APPLIED'
  """, $approver, $loanId) == 1

proc insertInstallment*(db: DbConn, inst: Installment) =
  ## Satu baris jadwal. `paid_*` sengaja tidak dikirim: jadwal baru selalu belum dibayar, dan
  ## trigger DB menolak perubahan baris yang sudah dibayar.
  db.exec(sql"""
    INSERT INTO lending.installment
      (loan_id, no, due_on, principal_due, interest_due, penalty_due)
    VALUES (?, ?, ?::date, ?::numeric, ?::numeric, ?::numeric)
  """, $inst.loanId, inst.no, inst.dueOn, toDecimalString(inst.principalDue),
      toDecimalString(inst.interestDue), toDecimalString(inst.penaltyDue))

proc installmentCountOf*(db: DbConn, loanId: Id): int =
  parseInt(db.getValue(sql"SELECT count(*) FROM lending.installment WHERE loan_id = ?", $loanId))

proc insertBalance*(db: DbConn, loanId: Id, principalOutstanding: Money) =
  ## Cache saldo awal saat pencairan: pokok penuh, belum ada tunggakan bunga/denda.
  db.exec(sql"""
    INSERT INTO lending.loan_balance
      (loan_id, principal_outstanding, interest_overdue, penalty_outstanding)
    VALUES (?, ?::numeric, 0, 0)
  """, $loanId, toDecimalString(principalOutstanding))

proc markDisbursed*(db: DbConn, loanId: Id; disbursedOn, maturityOn: string): bool =
  ## `APPROVED → ACTIVE` dengan tanggal cair dan jatuh tempo. `false` = pengajuan sudah berubah
  ## (balapan/keputusan lain), bukan galat: pemanggil menjawab 409.
  db.execAffectedRows(sql"""
    UPDATE lending.loan
       SET status = 'ACTIVE', disbursed_on = ?::date, maturity_on = ?::date
     WHERE loan_id = ? AND status = 'APPROVED'
  """, disbursedOn, maturityOn, $loanId) == 1
