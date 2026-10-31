-- Jenis baris subledger untuk PB pencairan dini deposito berjangka (T-148, D-164).
--
-- dbtools:contract berkas ini memuat `DROP CONSTRAINT`: CHECK `tx_type` hanya bisa dilonggarkan
--   dengan mengganti batasannya (pola `deposit/0068`).
-- dbtools:destructive satu `DROP CONSTRAINT` (`deposit_transaction_tx_type_chk`). Tidak ada tabel,
--   kolom, atau baris yang dihapus; penggantinya hanya menambah dua nilai, jadi baris lama tetap sah.
--
-- **Kenapa dua jenis baru.** Pada PB pencairan dini, rekening tujuan menerima
-- `pokok + bunga − penalti`, sedangkan `deposit.transfer.amount` tetap **pokok** (itu kewajiban yang
-- benar-benar berpindah `202 → 201` pada jurnal pokok). Bunga dan penalti karena itu butuh baris
-- subledger sendiri di rekening tujuan, dan masing-masing punya tanda berbeda:
--
--   INTEREST_PAID_EARLY  bunga akrual dibayar ke rekening tujuan          (menambah saldo)
--   PENALTY_CHARGE       penalti dipotong dari dana yang dikreditkan      (mengurangi saldo)
--
-- Menumpangkan keduanya pada `INTEREST_CREDIT` hanya benar bila bunga ≥ penalti; kalau penalti
-- lebih besar, rekonsiliasi melihat saldo lebih tinggi daripada subledger tanpa suara. Memakai
-- `MATURITY_*` juga salah: ini bukan jatuh tempo, dan label rekening koran harus jujur.
--
-- `deposit.transfer` **tidak** diubah. Rekonstruksi saldo (`reconcile_repo`): sumber `−pokok`,
-- tujuan `+pokok (transfer) +bunga (baris ini) −penalti (baris ini)`.

ALTER TABLE deposit.transaction
  DROP CONSTRAINT deposit_transaction_tx_type_chk,
  ADD CONSTRAINT deposit_transaction_tx_type_chk CHECK (tx_type IN (
    'CASH_DEPOSIT', 'CASH_WITHDRAWAL',
    'MATURITY_OUT', 'MATURITY_IN', 'INTEREST_CREDIT',
    'INTEREST_PAID_EARLY', 'PENALTY_CHARGE'));

COMMENT ON COLUMN deposit.transaction.tx_type IS
  'CASH_* = transaksi tunai teller; MATURITY_* = perpindahan jatuh tempo; INTEREST_CREDIT = bunga '
  'masuk (jatuh tempo/kapitalisasi); INTEREST_PAID_EARLY = bunga pencairan dini masuk ke rekening '
  'tujuan PB; PENALTY_CHARGE = penalti pencairan dini yang memotong dana di rekening tujuan '
  '(T-148, D-164).';
