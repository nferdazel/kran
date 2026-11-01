-- Jenis baris subledger untuk pembayaran angsuran dari rekening simpanan (T-165).
--
-- dbtools:contract berkas ini memuat `DROP CONSTRAINT`: CHECK `tx_type` hanya bisa dilonggarkan
--   dengan mengganti batasannya (pola `deposit/0074` dan `0082`).
-- dbtools:destructive satu `DROP CONSTRAINT` (`deposit_transaction_tx_type_chk`). Tidak ada tabel,
--   kolom, atau baris yang dihapus; penggantinya hanya menambah satu nilai, jadi baris lama sah.
--
-- **Kenapa bukan `CASH_WITHDRAWAL`.** Pembayaran angsuran mengurangi saldo rekening tanpa uang
-- tunai keluar dari laci: yang berpindah adalah kewajiban simpanan (201) ke piutang (110) dan
-- pendapatan bunga/denda (401/403). Memakai `CASH_WITHDRAWAL` akan membuat rekening koran anggota
-- melaporkan penarikan tunai yang tidak pernah ia terima, dan membuat rekonsiliasi laci teller
-- menghitung kas yang tidak ada. Arah saldo rekening: **−** (mengurangi).
ALTER TABLE deposit.transaction
  DROP CONSTRAINT deposit_transaction_tx_type_chk,
  ADD CONSTRAINT deposit_transaction_tx_type_chk CHECK (tx_type IN (
    'CASH_DEPOSIT', 'CASH_WITHDRAWAL',
    'MATURITY_OUT', 'MATURITY_IN', 'INTEREST_CREDIT',
    'INTEREST_PAID_EARLY', 'PENALTY_CHARGE',
    'LOAN_DISBURSEMENT', 'LOAN_PAYMENT'));

COMMENT ON COLUMN deposit.transaction.tx_type IS
  'CASH_* = transaksi tunai teller; MATURITY_* = perpindahan jatuh tempo; INTEREST_CREDIT = bunga '
  'masuk (jatuh tempo/kapitalisasi); INTEREST_PAID_EARLY = bunga pencairan dini masuk ke rekening '
  'tujuan PB; PENALTY_CHARGE = penalti pencairan dini yang memotong dana di rekening tujuan '
  '(T-148, D-164); LOAN_DISBURSEMENT = pencairan pinjaman dikreditkan ke rekening simpanan '
  '(T-164, D-182); LOAN_PAYMENT = pembayaran angsuran dari rekening simpanan (T-165, D-182).';
