-- Posting rule: event bisnis → template jurnal (T-074, spec §8.1/§10.5). Expand-only.
--
-- Modul bisnis memancarkan accounting event; `ledger` memetakannya ke jurnal. Mapping adalah
-- **data** (tabel + seed pack), bukan kode: mengubah akun tujuan tidak butuh deploy.
--
--   * `conditions` (jsonb) dicocokkan sebagai **subset** payload event (containment). Semakin
--     banyak kunci kondisi, semakin spesifik rule; resolver memilih yang paling spesifik, lalu
--     `priority` terkecil. Dua rule sama spesifik = ambigu → event gagal terlihat, bukan dipilih
--     diam-diam.
--   * Template `posting_rule_line`: Fase 1 hanya mendukung **satu DEBIT + satu CREDIT** dengan
--     nominal = `payload.amount`. Split multi-baris menunggu produk/akad (T-076).
--   * `status`/`effective_*` memungkinkan rule dinonaktifkan tanpa menghapus jejak.

CREATE TABLE ledger.posting_rule (
  rule_id        uuid PRIMARY KEY,
  event_type     text NOT NULL CHECK (length(btrim(event_type)) BETWEEN 1 AND 100),
  product_code   text,
  conditions     jsonb NOT NULL DEFAULT '{}'::jsonb,
  priority       int NOT NULL DEFAULT 100,
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'INACTIVE')),
  effective_from date,
  effective_to   date,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid NOT NULL,
  CONSTRAINT posting_rule_effective_chk CHECK (
    effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from)
);

CREATE INDEX posting_rule_lookup_idx
  ON ledger.posting_rule (event_type, status, priority) WHERE status = 'ACTIVE';

COMMENT ON TABLE ledger.posting_rule IS
  'Mapping accounting event → template jurnal (T-074). Kondisi = subset payload; pemilihan rule '
  'paling spesifik, tie-break priority, ambigu = gagal terlihat.';

CREATE TABLE ledger.posting_rule_line (
  rule_id    uuid NOT NULL REFERENCES ledger.posting_rule(rule_id),
  line_no    int NOT NULL CHECK (line_no BETWEEN 1 AND 999),
  side       text NOT NULL CHECK (side IN ('DEBIT', 'CREDIT')),
  gl_account text NOT NULL REFERENCES ledger.coa_account(code),
  PRIMARY KEY (rule_id, line_no)
);

COMMENT ON TABLE ledger.posting_rule_line IS
  'Template baris posting rule (T-074). Fase 1: tepat satu DEBIT + satu CREDIT per rule.';
