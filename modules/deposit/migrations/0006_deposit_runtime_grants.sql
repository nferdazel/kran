-- Hak akses role runtime untuk schema `deposit` (T-088b).
--
-- GRANT di `docs/runbooks/db-roles.md` hanya mencakup schema yang sudah ada saat runbook ditulis
-- (platform, ledger, party, product). Tanpa grant ini, `kran_runtime` mendapat "permission denied"
-- pada tabel/sequence `deposit` di produksi walau fitur lolos test (test memakai role migrator).
--
-- Idempoten dan no-op bila role belum ada (dev/CI). `ALTER DEFAULT PRIVILEGES` sengaja tidak di
-- sini: itu milik role pembuat tabel (`kran_app`) dan dijaga runbook untuk instalasi baru.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT USAGE ON SCHEMA deposit TO kran_runtime;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA deposit TO kran_runtime;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA deposit TO kran_runtime;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA deposit TO kran_runtime;
  END IF;
END
$$;
