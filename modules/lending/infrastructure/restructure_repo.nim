## Repositori restrukturisasi (T-168). SQL murni; bentuk jadwal baru ada di domain.
##
## Versi jadwal dicatat di `lending.loan_schedule`, baris jadwal lama diberi `superseded_on` (tidak
## dihapus), dan nomor angsuran versi baru melanjutkan nomor terakhir — lihat alasan penomoran di
## `lending/0093` dan `domain/restructure.nim`.

import std/strutils

import db_connector/db_postgres

import kernel/ids

proc nextInstallmentNo*(db: DbConn; loanId: Id): int =
  ## Nomor angsuran berikutnya lintas versi. `payment_allocation` menunjuk nomor tanpa versi, jadi
  ## nomor tidak boleh dipakai ulang.
  parseInt(db.getValue(sql"""
    SELECT coalesce(max(no), 0) + 1 FROM lending.installment WHERE loan_id = ?""", $loanId))

proc nextScheduleVersion*(db: DbConn; loanId: Id): int =
  parseInt(db.getValue(sql"""
    SELECT coalesce(max(version_no), 0) + 1 FROM lending.loan_schedule WHERE loan_id = ?""",
    $loanId))

proc insertScheduleVersion*(db: DbConn; loanId: Id; versionNo: int; createdOn, reason: string;
    actor: Id) =
  db.exec(sql"""
    INSERT INTO lending.loan_schedule (loan_id, version_no, created_on, reason, created_by)
    VALUES (?, ?, ?::date, ?, ?)""", $loanId, versionNo, createdOn, reason, $actor)

proc supersedeActiveSchedule*(db: DbConn; loanId: Id; businessDate: string): int =
  ## Mengarsipkan jadwal yang masih aktif. Baris yang sudah dibayar tetap utuh: trigger `0089`
  ## membekukan kewajiban dan `paid_*`, dan `superseded_on` bukan salah satunya.
  db.execAffectedRows(sql"""
    UPDATE lending.installment
       SET superseded_on = ?::date
     WHERE loan_id = ? AND superseded_on IS NULL""", businessDate, $loanId)

proc updateMaturity*(db: DbConn; loanId: Id; maturityOn: string): bool =
  ## Jatuh tempo akad mengikuti angsuran terakhir versi baru. `false` = pinjaman tidak lagi `ACTIVE`
  ## (balapan) — pemanggil menggagalkan transaksi.
  db.execAffectedRows(sql"""
    UPDATE lending.loan SET maturity_on = ?::date
     WHERE loan_id = ? AND status = 'ACTIVE'""", maturityOn, $loanId) == 1
