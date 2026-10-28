-- Tipe transaksi perpindahan jatuh tempo deposito berjangka (T-138d, D-155).
--
-- dbtools:contract berkas ini memuat `DROP CONSTRAINT`: CHECK `tx_type` dari `0004` hanya menerima
--   `CASH_DEPOSIT|CASH_WITHDRAWAL`, dan PostgreSQL tidak punya cara melonggarkan CHECK selain
--   menggantinya. Aturan yang sama sudah dipakai `0064` untuk CHECK `account_type`.
-- dbtools:destructive dua `DROP CONSTRAINT`: `transaction_tx_type_check` (CHECK `tx_type` bawaan
--   `0004`) dan `deposit_transaction_journal_uq` (UNIQUE `journal_id`). Tidak ada tabel/kolom/baris
--   yang dihapus, dan penggantinya lebih longgar: biner lama tetap jalan karena ia hanya menulis
--   `CASH_*` dan satu baris per jurnal, yang tetap lolos batasan baru.
--
-- **Kenapa jenis baru diperlukan.** Saat jatuh tempo tidak ada kas yang bergerak: pokok berpindah
-- dari deposito ke rekening simpanan anggota (D 202 / K 201), bunga akrual dibayar ke rekening
-- (D 204 / K 201) atau dikapitalisasi menjadi pokok (D 204 / K 202). Memakai `CASH_DEPOSIT` /
-- `CASH_WITHDRAWAL` untuk baris itu akan **berbohong** di rekening koran anggota (seolah ada setoran
-- atau penarikan tunai di teller) dan membuat laporan kas melihat mutasi yang tidak pernah terjadi.
-- `reconcile-deposits` merekonstruksi saldo **dari baris subledger ini** (D-155), jadi jenisnya harus
-- jujur; tanpa nilai baru, rekonsiliasi tidak punya cara menghitung tanda yang benar. Pemetaan tanda
-- hidup di `infrastructure/reconcile_repo.nim`, bukan di CHECK ini.
--
-- `MATURITY_OUT`  pokok keluar dari deposito berjangka (ARO `NONE`).
-- `MATURITY_IN`   pokok masuk ke rekening simpanan anggota (ARO `NONE`).
-- `INTEREST_CREDIT` bunga masuk ke rekening anggota: simpanan (ARO `NONE`/`PRINCIPAL`) atau
--                 deposito itu sendiri saat bunga dikapitalisasi (ARO `PRINCIPAL_AND_INTEREST`).
--
-- **Kenapa UNIQUE `journal_id` dilonggarkan menjadi `(journal_id, account_id)`.** Satu perpindahan
-- pokok saat ARO `NONE` adalah **satu** fakta buku besar (D 202 / K 201) tetapi dua baris subledger:
-- `MATURITY_OUT` di deposito dan `MATURITY_IN` di rekening simpanan. Dengan UNIQUE lama, salah satu
-- baris harus menunjuk jurnal kedua — dan jurnal kedua itu menggandakan perpindahan GL; atau baris
-- kedua tidak boleh ada — dan `reconcile-deposits` lalu melaporkan selisih palsu. Batasan yang
-- dipertahankan tetap yang bermakna: satu jurnal **tidak boleh** dicatat dua kali untuk rekening yang
-- sama, dan setiap baris tetap wajib menunjuk tepat satu jurnal (FK + NOT NULL tidak berubah).
-- **HUMAN-REVIEW-REQUIRED**: perubahan batasan ini menyentuh area kritis (AGENTS.md §8).
--
-- Nama `transaction_tx_type_check` adalah nama yang diberikan PostgreSQL untuk CHECK kolom tanpa nama
-- di `0004` (pola `<tabel>_<kolom>_check`, sama seperti `0064`). Berkas `0004` immutable (dijaga
-- checksum), jadi namanya stabil; bila kelak berbeda, migrasi ini gagal keras alih-alih diam-diam
-- meninggalkan CHECK lama.

ALTER TABLE deposit.transaction
  DROP CONSTRAINT transaction_tx_type_check,
  ADD CONSTRAINT deposit_transaction_tx_type_chk CHECK (tx_type IN (
    'CASH_DEPOSIT', 'CASH_WITHDRAWAL',
    'MATURITY_OUT', 'MATURITY_IN', 'INTEREST_CREDIT'));

ALTER TABLE deposit.transaction
  DROP CONSTRAINT deposit_transaction_journal_uq,
  ADD CONSTRAINT deposit_transaction_journal_account_uq UNIQUE (journal_id, account_id);

COMMENT ON COLUMN deposit.transaction.tx_type IS
  'CASH_* = transaksi tunai teller; MATURITY_OUT/MATURITY_IN/INTEREST_CREDIT = perpindahan jatuh '
  'tempo deposito berjangka tanpa kas (T-138d, D-155).';
COMMENT ON TABLE deposit.transaction IS
  'Transaksi subledger simpanan (T-088b, T-138d): satu baris = satu jurnal per rekening '
  '(UNIQUE (journal_id, account_id); satu jurnal boleh mencatat dua rekening untuk perpindahan '
  'jatuh tempo). Nominal numeric(24,2) > 0; tanpa float. Koreksi = jurnal pembalik, bukan ubah/hapus.';
