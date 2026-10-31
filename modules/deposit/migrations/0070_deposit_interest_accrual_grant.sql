-- Hak akses role runtime untuk tabel `deposit.interest_accrual` (T-138c).
--
-- `deposit/0006` memberi `GRANT ... ON ALL TABLES IN SCHEMA deposit` **saat itu** (seq 6); tabel
-- yang lahir kemudian tidak tercakup, karena itu setiap tabel baru butuh migrasi grant sendiri
-- (preseden `deposit/0008` untuk `deposit.transfer`, aturan yang sama ditulis di `teller/0007`).
-- `0066` membuat tabel ini tanpa grant; di produksi `kran_runtime` akan mendapat "permission
-- denied" dan task day-close kritis berhenti setiap malam, sementara test tetap hijau karena
-- test memakai role migrator.
--
-- Hanya `SELECT, INSERT`: task akrual membaca halaman rekening dan menyisipkan satu baris per
-- rekening+tanggal, tidak pernah mengubah atau menghapus baris (koreksi = jurnal pembalik). No-op
-- bila role belum ada (dev/CI).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT USAGE ON SCHEMA deposit TO kran_runtime;
    GRANT SELECT, INSERT ON deposit.interest_accrual TO kran_runtime;
  END IF;
END
$$;
