-- Jurnal double-entry immutable (T-073, spec §9.1(3), §9.3). Expand-only: hanya CREATE.
--
-- Aturan yang ditegakkan **di DB**, bukan hanya di aplikasi:
--   * `journal`/`journal_line` tidak boleh diubah atau dihapus (trigger). Koreksi = jurnal pembalik.
--   * `SUM(debit) = SUM(credit)` per jurnal, minimal 2 baris — constraint trigger DEFERRABLE supaya
--     penyisipan baris satu per satu dalam satu transaksi tetap sah dan diperiksa saat COMMIT.
--   * Tanggal bisnis harus jatuh di periode OPEN (T-072). Belum ada periode = tidak bisa posting
--     (gagal-tertutup), bukan diam-diam diterima.
--   * Akun GL harus `postable` dan `ACTIVE` — menutup batas T-072 yang masih konvensi.
--
-- **Tanpa partisi** `RANGE (business_date)` pada Fase 1 (spec §9.3 menyebut DDL-nya *acuan, bukan
-- final*): volume pilot kecil, dan FK/constraint trigger lebih sederhana. Keputusan + alasan:
-- D-072. Wajib ditinjau sebelum go-live bervolume besar.

CREATE TABLE ledger.journal (
  journal_id      uuid PRIMARY KEY,
  business_date   date NOT NULL,
  value_date      date NOT NULL,
  source_event    text NOT NULL CHECK (length(btrim(source_event)) BETWEEN 1 AND 100),
  source_ref      uuid NOT NULL,
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 200),
  reversal_of     uuid REFERENCES ledger.journal(journal_id),
  created_by      uuid NOT NULL,
  recorded_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT journal_idempotency_uq UNIQUE (idempotency_key),
  CONSTRAINT journal_reversal_not_self_chk CHECK (reversal_of IS NULL OR reversal_of <> journal_id)
);

CREATE INDEX journal_business_date_idx ON ledger.journal (business_date, recorded_at);
CREATE INDEX journal_source_idx ON ledger.journal (source_event, source_ref);
CREATE INDEX journal_reversal_idx ON ledger.journal (reversal_of) WHERE reversal_of IS NOT NULL;

COMMENT ON TABLE ledger.journal IS
  'Jurnal immutable (T-073). UPDATE/DELETE ditolak trigger; koreksi = jurnal pembalik. '
  'idempotency_key unik mencegah posting ganda dari event yang sama.';

CREATE TABLE ledger.journal_line (
  journal_id uuid NOT NULL REFERENCES ledger.journal(journal_id),
  line_no    int NOT NULL CHECK (line_no BETWEEN 1 AND 999),
  gl_account text NOT NULL REFERENCES ledger.coa_account(code),
  branch_id  uuid NOT NULL,
  debit      numeric(24,4) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit     numeric(24,4) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  PRIMARY KEY (journal_id, line_no),
  CONSTRAINT journal_line_one_side_chk CHECK ((debit = 0) <> (credit = 0))
);

COMMENT ON TABLE ledger.journal_line IS
  'Baris jurnal (T-073). Tepat satu sisi > 0 per baris; total debit = total kredit per jurnal '
  '(constraint trigger deferred).';

CREATE FUNCTION ledger.reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ledger: % pada % ditolak (immutable; pakai jurnal pembalik)',
    TG_OP, TG_TABLE_NAME
    USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE TRIGGER journal_immutable
  BEFORE UPDATE OR DELETE ON ledger.journal
  FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();

CREATE TRIGGER journal_no_truncate
  BEFORE TRUNCATE ON ledger.journal
  FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();

CREATE TRIGGER journal_line_immutable
  BEFORE UPDATE OR DELETE ON ledger.journal_line
  FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();

CREATE TRIGGER journal_line_no_truncate
  BEFORE TRUNCATE ON ledger.journal_line
  FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();

CREATE FUNCTION ledger.assert_journal_period_open() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM ledger.period p
       WHERE p.status = 'OPEN'
         AND NEW.business_date BETWEEN p.starts_on AND p.ends_on) THEN
    RAISE EXCEPTION 'ledger: tidak ada periode OPEN untuk tanggal %', NEW.business_date
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER journal_period_open
  BEFORE INSERT ON ledger.journal
  FOR EACH ROW EXECUTE FUNCTION ledger.assert_journal_period_open();

CREATE FUNCTION ledger.assert_line_account_postable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM ledger.coa_account a
       WHERE a.code = NEW.gl_account AND a.postable AND a.status = 'ACTIVE') THEN
    RAISE EXCEPTION 'ledger: akun % tidak postable atau tidak aktif', NEW.gl_account
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER journal_line_account_postable
  BEFORE INSERT ON ledger.journal_line
  FOR EACH ROW EXECUTE FUNCTION ledger.assert_line_account_postable();

CREATE FUNCTION ledger.assert_journal_balanced() RETURNS trigger
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

CREATE CONSTRAINT TRIGGER journal_balanced
  AFTER INSERT ON ledger.journal_line
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION ledger.assert_journal_balanced();
