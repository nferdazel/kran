-- Hak akses role runtime untuk tabel baru `deposit.transfer` (T-088c).
--
-- `deposit/0006` memberi grant `ON ALL TABLES IN SCHEMA deposit` **saat itu** — hanya tabel yang
-- sudah ada pada seq 6. `deposit.transfer` dibuat belakangan (`deposit/0007`), jadi tanpa migrasi
-- ini `kran_runtime` mendapat "permission denied" pada tabel itu di produksi walau fitur lolos test
-- (test memakai role migrator). Pola dan idempotensinya sama dengan `0006`; no-op bila role belum
-- ada (dev/CI).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT USAGE ON SCHEMA deposit TO kran_runtime;
    GRANT SELECT, INSERT, UPDATE, DELETE ON deposit.transfer TO kran_runtime;
  END IF;
END
$$;
