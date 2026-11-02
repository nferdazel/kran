## Repositori `lending` (T-163). SQL murni; tidak ada aturan bisnis di sini.
##
## Modul ini sengaja tidak mengimpor internal `platform` (archcheck rule C): audit dan outbox
## ditulis pemanggil (composition root `apps/api`) dalam transaksi yang sama.

import std/[options, strutils]

import db_connector/db_postgres

import kernel/[ids, money, rate, result]
import ../domain/[loan, payment]

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

proc insertInstallment*(db: DbConn, inst: Installment; scheduleVersion = 1) =
  ## Satu baris jadwal. `paid_*` sengaja tidak dikirim: jadwal baru selalu belum dibayar, dan
  ## trigger DB menolak perubahan baris yang sudah dibayar. `scheduleVersion` > 1 hanya dipakai
  ## restrukturisasi (T-168).
  db.exec(sql"""
    INSERT INTO lending.installment
      (loan_id, no, due_on, principal_due, interest_due, penalty_due, schedule_version)
    VALUES (?, ?, ?::date, ?::numeric, ?::numeric, ?::numeric, ?)
  """, $inst.loanId, inst.no, inst.dueOn, toDecimalString(inst.principalDue),
      toDecimalString(inst.interestDue), toDecimalString(inst.penaltyDue), scheduleVersion)

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


proc installmentOf(row: Row): Installment =
  ## `paid_on` kosong selama baris belum lunas (`NULL`), jadi dibaca `coalesce`.
  Installment(
    loanId: Id(row[0]),
    no: parseInt(row[1]),
    dueOn: row[2],
    principalDue: moneyFromString(row[3]).value(),
    interestDue: moneyFromString(row[4]).value(),
    penaltyDue: moneyFromString(row[5]).value(),
    paidPrincipal: moneyFromString(row[6]).value(),
    paidInterest: moneyFromString(row[7]).value(),
    paidPenalty: moneyFromString(row[8]).value(),
    paidOn: row[9],
  )

proc installmentsForUpdate*(db: DbConn, loanId: Id): seq[Installment] =
  ## Jadwal **aktif** pinjaman, **tertua lebih dulu** (`due_on`, lalu `no`), baris dikunci supaya dua
  ## pembayaran bersamaan tidak mengalokasikan nominal yang sama dua kali dan tidak melewati
  ## `paid_* <= *_due` (CHECK DB adalah jaring terakhir, bukan alat alokasi).
  ##
  ## Baris yang sudah diarsipkan restrukturisasi (`superseded_on` terisi) tidak boleh menerima
  ## pembayaran: kewajibannya sudah digantikan jadwal baru, dan membayarnya akan menghitung utang dua
  ## kali.
  for row in db.getAllRows(sql"""
    SELECT loan_id::text, no, due_on::text, principal_due::text, interest_due::text,
           penalty_due::text, paid_principal::text, paid_interest::text, paid_penalty::text,
           coalesce(paid_on::text, '')
      FROM lending.installment
     WHERE loan_id = ? AND superseded_on IS NULL
     ORDER BY due_on, no
       FOR UPDATE""", $loanId):
    result.add installmentOf(row)

proc addInstallmentPayment*(db: DbConn, loanId: Id, installmentNo: int,
    component: AllocationComponent, amount: Money): bool =
  ## Menambah `paid_<komponen>` satu baris. `false` = baris tidak ada atau penambahan akan melewati
  ## kewajiban (balapan) — pemanggil menggagalkan transaksi, bukan memotong nominal diam-diam.
  ## Nama kolom berasal dari `case` di sini, bukan dari string masukan.
  let column =
    case component
    of acPrincipal: "paid_principal, principal_due"
    of acInterest: "paid_interest, interest_due"
    of acPenalty: "paid_penalty, penalty_due"
  let parts = column.split(", ")
  let sqlText = "UPDATE lending.installment SET " & parts[0] & " = " & parts[0] & " + ?::numeric" &
    " WHERE loan_id = ? AND no = ? AND " & parts[0] & " + ?::numeric <= " & parts[1]
  db.execAffectedRows(sql(sqlText), toDecimalString(amount), $loanId, installmentNo,
    toDecimalString(amount)) == 1

proc markSettledRows*(db: DbConn, loanId: Id; businessDate: string) =
  ## Stempel tanggal lunas untuk baris yang **seluruh** komponennya tertutup. `paid_on` hanya
  ## ditulis sekali: tanggal pelunasan adalah fakta, bukan nilai yang ikut berubah saat pembayaran
  ## berikutnya.
  discard db.execAffectedRows(sql"""
    UPDATE lending.installment
       SET paid_on = ?::date
     WHERE loan_id = ? AND paid_on IS NULL
       AND paid_principal = principal_due
       AND paid_interest = interest_due
       AND paid_penalty = penalty_due""", businessDate, $loanId)

proc insertPayment*(db: DbConn, payment: Payment, actor: Id) =
  db.exec(sql"""
    INSERT INTO lending.payment
      (payment_id, loan_id, account_id, amount, principal_paid, interest_paid, penalty_paid,
       business_date, created_by)
    VALUES (?, ?, ?, ?::numeric, ?::numeric, ?::numeric, ?::numeric, ?::date, ?)
  """, $payment.paymentId, $payment.loanId, $payment.accountId,
      toDecimalString(payment.amount), toDecimalString(payment.principalPaid),
      toDecimalString(payment.interestPaid), toDecimalString(payment.penaltyPaid),
      payment.businessDate, $actor)

proc insertPaymentAllocation*(db: DbConn, paymentId: Id, line: PaymentLine) =
  db.exec(sql"""
    INSERT INTO lending.payment_allocation (payment_id, installment_no, component, amount)
    VALUES (?, ?, ?, ?::numeric)
  """, $paymentId, line.installmentNo, $line.component, toDecimalString(line.amount))

proc decreaseLoanBalance*(db: DbConn, loanId: Id, principal, interest, penalty: Money): bool =
  ## Cache saldo pinjaman berkurang sebesar yang dibayar. `false` = cache tidak ada atau pokok akan
  ## negatif (CHECK `>= 0`), yang berarti jadwal dan cache tidak sinkron — bug, bukan data pengguna.
  ##
  ## `interest_overdue`/`penalty_outstanding` adalah **tunggakan**, bukan bunga/denda berjalan: yang
  ## mengisinya adalah regrading kolektibilitas (T-166), dan pada T-164 keduanya masih nol. Karena
  ## itu pengurangannya dijepit `GREATEST(…, 0)`: membayar bunga berjalan yang tidak pernah masuk
  ## cache tidak boleh membuat cache negatif (dan tidak boleh pula menutupi tunggakan yang belum
  ## pernah dihitung — itu pekerjaan T-166 yang membaca jadwal, bukan cache).
  db.execAffectedRows(sql"""
    UPDATE lending.loan_balance
       SET principal_outstanding = principal_outstanding - ?::numeric,
           interest_overdue = greatest(interest_overdue - ?::numeric, 0),
           penalty_outstanding = greatest(penalty_outstanding - ?::numeric, 0),
           updated_at = now()
     WHERE loan_id = ?
  """, toDecimalString(principal), toDecimalString(interest), toDecimalString(penalty),
      $loanId) == 1

proc principalOutstanding*(db: DbConn, loanId: Id): Money =
  ## Sisa pokok dari cache. Baris cache wajib ada untuk pinjaman `ACTIVE`; hilang = data rusak,
  ## bukan nol (nol akan menampilkan pinjaman yang seolah lunas).
  let rows = db.getAllRows(sql"""
    SELECT principal_outstanding::text FROM lending.loan_balance WHERE loan_id = ?""", $loanId)
  if rows.len == 0:
    raise newException(ValueError,
      "saldo pinjaman tidak ditemukan untuk " & $loanId & " (cache hilang)")
  let parsed = moneyFromString(rows[0][0])
  if not parsed.isOk:
    raise newException(ValueError, "saldo pinjaman tersimpan bukan nominal sah")
  parsed.val
