-- Saldo turunan + trial balance (T-075, spec §9.1(4): saldo = turunan, cache yang bisa
-- direkonstruksi).
--
-- `ledger.balance_snapshot` adalah **cache**, bukan sumber kebenaran: sumbernya tetap
-- `journal_line` (jurnal immutable). Tidak ada jalur tulis saldo selain dari jurnal; fungsi
-- `rebuild_balance_snapshot` menghitung ulang cache dari jurnal, dan trial balance di API
-- dihitung langsung dari `journal_line` supaya cache yang basi tidak pernah jadi angka laporan.

CREATE TABLE ledger.balance_snapshot (
  account_code  text NOT NULL REFERENCES ledger.coa_account(code),
  as_of         date NOT NULL,
  debit_total   numeric(24,4) NOT NULL DEFAULT 0 CHECK (debit_total >= 0),
  credit_total  numeric(24,4) NOT NULL DEFAULT 0 CHECK (credit_total >= 0),
  journal_count bigint NOT NULL DEFAULT 0 CHECK (journal_count >= 0),
  computed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_code, as_of)
);

COMMENT ON TABLE ledger.balance_snapshot IS
  'Cache saldo per akun per tanggal (T-075). Sumber kebenaran = journal_line;'
  ' rekonstruksi lewat ledger.rebuild_balance_snapshot(as_of).';

CREATE FUNCTION ledger.rebuild_balance_snapshot(p_as_of date) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM ledger.balance_snapshot WHERE as_of = p_as_of;
  INSERT INTO ledger.balance_snapshot
    (account_code, as_of, debit_total, credit_total, journal_count, computed_at)
  SELECT l.gl_account, p_as_of, coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0),
         count(DISTINCT l.journal_id), now()
    FROM ledger.journal_line l
    JOIN ledger.journal j ON j.journal_id = l.journal_id
   WHERE j.business_date <= p_as_of
   GROUP BY l.gl_account;
END;
$$;
