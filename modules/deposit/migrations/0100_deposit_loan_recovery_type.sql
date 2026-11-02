-- Jenis baris subledger untuk pemulihan pasca hapus buku (O-122, T-176).
--
-- dbtools:contract berkas ini memuat `DROP CONSTRAINT`: CHECK `tx_type` hanya bisa dilonggarkan
--   dengan mengganti batasannya (pola `deposit/0074`, `0082`, dan `0086`).
-- dbtools:destructive satu `DROP CONSTRAINT` (`deposit_transaction_tx_type_chk`). Tidak ada tabel,
--   kolom, atau baris yang dihapus; penggantinya hanya menambah satu nilai, jadi baris lama sah.
--
-- **Kenapa bukan `LOAN_PAYMENT`.** Pinjaman ini sudah dihapusbukukan: tidak ada piutang yang
-- berkurang, dan uangnya dicatat sebagai pendapatan (409/401/403), bukan pelunasan pokok (`110`).
-- Memakai `LOAN_PAYMENT` akan membuat rekening koran anggota dan laporan pelunasan mengklaim
-- piutang yang sebenarnya sudah dibebankan. Arah saldo rekening: **−** (mengurangi).
ALTER TABLE deposit.transaction
  DROP CONSTRAINT deposit_transaction_tx_type_chk,
  ADD CONSTRAINT deposit_transaction_tx_type_chk CHECK (tx_type IN (
    'CASH_DEPOSIT', 'CASH_WITHDRAWAL',
    'MATURITY_OUT', 'MATURITY_IN', 'INTEREST_CREDIT',
    'INTEREST_PAID_EARLY', 'PENALTY_CHARGE',
    'LOAN_DISBURSEMENT', 'LOAN_PAYMENT', 'LOAN_RECOVERY'));
