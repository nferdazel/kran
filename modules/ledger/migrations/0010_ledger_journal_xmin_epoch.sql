-- Guard `xmin` jurnal dibuat **sadar-epoch** (review T-073 putaran 2, O-086).
--
-- Pembanding lama `j.xmin::text::bigint = pg_current_xact_id()::text::bigint` mengasumsikan epoch
-- xid 0. Setelah 2^32 transaksi (atau restore dari cluster yang epoch-nya sudah maju), semua INSERT
-- baris jurnal yang sah akan ditolak. `xid` (32-bit, tanpa epoch) dibandingkan dengan cast
-- `xid8 → xid` dari `pg_current_xact_id()` — pada PG 18.6 terbukti `t` untuk transaksi berjalan dan
-- `f` untuk transaksi lain.
--
-- Larangan savepoint pada jalur tulis jurnal tetap berlaku: baris di bawah header yang di-INSERT
-- di dalam SAVEPOINT tetap ditolak (O-086). Migrasi ini hanya mengganti fungsi (expand-only).
CREATE OR REPLACE FUNCTION ledger.assert_line_same_transaction() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM ledger.journal j
       WHERE j.journal_id = NEW.journal_id
         AND j.xmin = pg_current_xact_id()::xid) THEN
    RAISE EXCEPTION
      'ledger: baris jurnal % hanya boleh ditambahkan dalam transaksi yang sama dengan header',
      NEW.journal_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION ledger.assert_line_same_transaction() IS
  'Baris jurnal hanya dalam transaksi header. Pembanding xid sadar-epoch (O-086); '
  'savepoint pada jalur tulis jurnal dilarang.';
