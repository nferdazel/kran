-- Pengetatan jurnal dari review T-073. Expand-only; tidak mengubah migrasi 0003 yang sudah ada.
--
--   1. Satu jurnal asal hanya boleh punya **satu** pembalik. Sebelumnya `reversalExistsFor` adalah
--      check-then-insert yang bisa dilewati dua permintaan bersamaan. Indeks unik parsial adalah
--      jaminannya di DB; handler memetakan pelanggarannya ke 409.
--   2. Header jurnal tanpa baris tidak boleh COMMIT. Constraint trigger dulu hanya terpasang pada
--      `journal_line`, sehingga header kosong lolos tanpa pemeriksaan. Sekarang header juga
--      diperiksa (deferred): minimal 2 baris dan seimbang.
--   3. Baris jurnal hanya boleh masuk bila periode tanggal bisnis **header** masih OPEN. Sebelumnya
--      trigger periode hanya pada header, sehingga baris bisa disisipkan setelah periode ditutup.

CREATE UNIQUE INDEX journal_reversal_uq
  ON ledger.journal (reversal_of) WHERE reversal_of IS NOT NULL;

COMMENT ON INDEX ledger.journal_reversal_uq IS
  'Satu jurnal asal hanya boleh dibalik sekali (T-073); pelanggaran = 409 di API.';

CREATE FUNCTION ledger.assert_journal_header_complete() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  n bigint;
  diff numeric(24,4);
BEGIN
  SELECT count(*), coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
    INTO n, diff
    FROM ledger.journal_line l
   WHERE l.journal_id = NEW.journal_id;
  IF n < 2 THEN
    RAISE EXCEPTION 'ledger: jurnal % harus punya minimal 2 baris', NEW.journal_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF diff <> 0 THEN
    RAISE EXCEPTION 'ledger: jurnal % tidak seimbang (selisih %)', NEW.journal_id, diff
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER journal_header_complete
  AFTER INSERT ON ledger.journal
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION ledger.assert_journal_header_complete();

CREATE OR REPLACE FUNCTION ledger.assert_line_account_postable() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  bd date;
BEGIN
  SELECT j.business_date INTO bd FROM ledger.journal j WHERE j.journal_id = NEW.journal_id;
  IF bd IS NULL THEN
    RAISE EXCEPTION 'ledger: jurnal % tidak ada', NEW.journal_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM ledger.period p
       WHERE p.status = 'OPEN' AND bd BETWEEN p.starts_on AND p.ends_on) THEN
    RAISE EXCEPTION 'ledger: periode tanggal bisnis % sudah ditutup', bd
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM ledger.coa_account a
       WHERE a.code = NEW.gl_account AND a.postable AND a.status = 'ACTIVE') THEN
    RAISE EXCEPTION 'ledger: akun % tidak postable atau tidak aktif', NEW.gl_account
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;
