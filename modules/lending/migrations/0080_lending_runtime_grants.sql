-- Hak akses role runtime untuk schema `lending` (T-161), pola `deposit/0006`.
--
-- GRANT di `docs/OPERATIONS.md` hanya mencakup schema yang ada saat runbook ditulis; tanpa
-- grant ini `kran_runtime` mendapat "permission denied" di produksi walau fitur lolos test (test
-- memakai role migrator). Idempoten dan no-op bila role belum ada (dev/CI).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT USAGE ON SCHEMA lending TO kran_runtime;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA lending TO kran_runtime;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA lending TO kran_runtime;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA lending TO kran_runtime;
  END IF;
END
$$;
