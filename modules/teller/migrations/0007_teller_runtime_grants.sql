-- Hak akses role runtime untuk schema `teller` (T-093).
--
-- GRANT di `docs/runbooks/db-roles.md` hanya mencakup schema yang sudah ada saat runbook ditulis
-- (platform, ledger, party, product, deposit). Tanpa grant ini, `kran_runtime` mendapat
-- "permission denied" pada tabel/sequence `teller` di produksi walau fitur lolos test (test memakai
-- role migrator). Pola dan idempotensinya sama dengan `deposit/0006`/`deposit/0008`.
--
-- `ON ALL TABLES` hanya mencakup tabel yang ada **saat migrasi ini berjalan**; migrasi teller
-- berikutnya yang menambah tabel wajib migrasi grant sendiri. `ALTER DEFAULT PRIVILEGES` sengaja
-- tidak di sini: itu milik role pembuat tabel (`kran_app`) dan dijaga runbook untuk instalasi baru.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT USAGE ON SCHEMA teller TO kran_runtime;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA teller TO kran_runtime;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA teller TO kran_runtime;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA teller TO kran_runtime;
  END IF;
END
$$;
