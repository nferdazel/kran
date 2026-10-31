-- Status `DORMANT` untuk rekening tanpa aktivitas (T-138e, D-152 butir 4).
--
-- dbtools:contract berkas ini memuat `DROP CONSTRAINT`: CHECK `status` dari `0003` hanya menerima
--   `ACTIVE|CLOSED`, dan PostgreSQL tidak punya cara melonggarkan CHECK selain menggantinya.
--   Pola yang sama dipakai `0064` (CHECK `account_type`).
-- dbtools:destructive satu-satunya DDL merusak adalah `DROP CONSTRAINT account_status_check`.
--   Tidak ada tabel/kolom/baris yang dihapus; penggantinya lebih longgar dan kode yang sudah ada
--   hanya menulis `ACTIVE`/`CLOSED`, yang tetap lolos CHECK baru.
--
-- **Kenapa baru sekarang.** `0064` sengaja tidak menambahkan `DORMANT` selama aturan deteksinya
-- belum ada: nilai status yang tidak pernah ditulis (atau ditulis tanpa aturan reaktivasi) hanya
-- akan membuat laporan bingung. T-138e menetapkan aturannya (D-157): task `deposit.dormant`
-- menandai rekening ACTIVE yang aktivitas terakhirnya lebih lama dari
-- `deposit.dormant.after_months`, dan mengembalikan DORMANT ke ACTIVE begitu ada aktivitas lagi.
--
-- Akrual bunga (D-154) memakai predikat `status <> 'CLOSED'`, jadi DORMANT otomatis tetap
-- diakrualkan — status ini membatasi layanan, bukan perjanjian bunga.
--
-- Nama `account_status_check` adalah nama yang diberikan PostgreSQL untuk CHECK kolom tanpa nama di
-- `0003` (pola `<tabel>_<kolom>_check`, sama seperti `0064`). Bila kelak berbeda, migrasi ini gagal
-- keras alih-alih diam-diam meninggalkan CHECK lama.

ALTER TABLE deposit.account
  DROP CONSTRAINT account_status_check,
  ADD CONSTRAINT deposit_account_status_chk CHECK (status IN ('ACTIVE', 'CLOSED', 'DORMANT'));

COMMENT ON COLUMN deposit.account.status IS
  'Status rekening: ACTIVE, CLOSED, DORMANT (tanpa aktivitas > deposit.dormant.after_months; '
  'DORMANT tetap diakrualkan dan kembali ACTIVE saat ada aktivitas — D-157).';
