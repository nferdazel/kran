-- Perbaikan dari review T-074 (expand-only).
--
--   1. Baris jurnal hanya boleh ditambahkan **dalam transaksi yang sama** dengan header. Sebelumnya
--      header yang sudah COMMIT masih bisa ditambah dua baris berpasangan (debit=kredit), sehingga
--      nominal jurnal final bisa "diubah" lewat INSERT dan lolos semua trigger keseimbangan.
--      Dibandingkan lewat `xmin` baris header vs transaksi berjalan; ini menutup jalur append,
--      bukan sekadar konvensi.
--   2. Komentar: reclaim event `IN_FLIGHT` yang terdampar ditangani di `claimBatch` (lease), bukan
--      di sini — lihat `modules/platform/infrastructure/outbox_repo.nim` dan parameter
--      `ledger.posting.lease_seconds`.

CREATE FUNCTION ledger.assert_line_same_transaction() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM ledger.journal j
       WHERE j.journal_id = NEW.journal_id
         AND j.xmin::text::bigint = pg_current_xact_id()::text::bigint) THEN
    RAISE EXCEPTION
      'ledger: baris jurnal % hanya boleh ditambahkan dalam transaksi yang sama dengan header',
      NEW.journal_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER journal_line_same_transaction
  BEFORE INSERT ON ledger.journal_line
  FOR EACH ROW EXECUTE FUNCTION ledger.assert_line_same_transaction();
