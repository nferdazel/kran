-- Jenis baris subledger untuk pencairan pinjaman ke rekening simpanan (T-164).
--
-- dbtools:contract berkas ini memuat `DROP CONSTRAINT`: CHECK `tx_type` hanya bisa dilonggarkan
--   dengan mengganti batasannya (pola `deposit/0074`).
-- dbtools:destructive satu `DROP CONSTRAINT` (`deposit_transaction_tx_type_chk`). Tidak ada tabel,
--   kolom, atau baris yang dihapus; penggantinya hanya menambah satu nilai, jadi baris lama sah.
--
-- **Kenapa jenis baru, bukan `CASH_DEPOSIT`.** Pencairan pinjaman tidak menggerakkan kas: yang
-- bertambah adalah kewajiban simpanan (201) dan piutang pembiayaan (110). Memakai `CASH_DEPOSIT`
-- akan membuat rekening koran anggota berbohong ("setoran tunai") dan membuat rekonsiliasi laci
-- teller menghitung uang yang tidak pernah masuk laci.
--
-- Uang tunai tetap keluar lewat jalur yang sudah ada: `CASH_WITHDRAWAL` dari rekening yang baru
-- dikreditkan. Dengan begitu invarian `expected_cash`/variance penutupan kas tidak berubah.
ALTER TABLE deposit.transaction
  DROP CONSTRAINT deposit_transaction_tx_type_chk,
  ADD CONSTRAINT deposit_transaction_tx_type_chk CHECK (tx_type IN (
    'CASH_DEPOSIT', 'CASH_WITHDRAWAL',
    'MATURITY_OUT', 'MATURITY_IN', 'INTEREST_CREDIT',
    'INTEREST_PAID_EARLY', 'PENALTY_CHARGE',
    'LOAN_DISBURSEMENT'));

COMMENT ON COLUMN deposit.transaction.tx_type IS
  'CASH_* = transaksi tunai teller; MATURITY_* = perpindahan jatuh tempo; INTEREST_CREDIT = bunga '
  'masuk (jatuh tempo/kapitalisasi); INTEREST_PAID_EARLY = bunga pencairan dini masuk ke rekening '
  'tujuan PB; PENALTY_CHARGE = penalti pencairan dini yang memotong dana di rekening tujuan '
  '(T-148, D-164); LOAN_DISBURSEMENT = pencairan pinjaman dikreditkan ke rekening simpanan '
  '(T-164, D-182).';
