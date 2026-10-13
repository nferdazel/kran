-- 0005: kalender kerja & business date (spec §9.3, §11.2).
--
-- Deviasi yang disengaja dari contoh DDL spec §9.3 (keduanya tidak valid di PostgreSQL 18,
-- sudah diverifikasi langsung ke DB — lihat docs/DECISIONS.md D-011):
--   1. `current_date` sebagai nama kolom tanpa kutip = syntax error (bentrok kata kunci
--      CURRENT_DATE) → kolom dinamai `current_business_date`.
--   2. `PRIMARY KEY (scope_type, COALESCE(scope_id, ''))` tidak didukung (ekspresi tidak boleh
--      di kolom PRIMARY KEY) → keunikan dijaga UNIQUE INDEX dengan ekspresi yang sama dan
--      `scope_id` tetap NULL untuk scope akar (institusi).
--
-- `scope_id` bertipe `text` (bukan uuid seperti contoh §9.3) supaya seragam dengan
-- `platform.param_value.scope_id` (spec §10.2) dan pemetaan scope di kode.
--
-- Expand-only: hanya CREATE.

CREATE TABLE platform.holiday (
  holiday_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_type       text NOT NULL DEFAULT 'INSTITUTION',
  scope_id         text,
  holiday_date     date NOT NULL,
  name_key         text NOT NULL,
  recurring_annual boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT holiday_scope_chk CHECK (scope_type IN ('INSTITUTION', 'BRANCH')),
  CONSTRAINT holiday_root_scope_chk CHECK (scope_type = 'INSTITUTION' OR scope_id IS NOT NULL),
  CONSTRAINT holiday_name_key_chk CHECK (length(btrim(name_key)) > 0)
);

COMMENT ON TABLE platform.holiday IS
  'Hari libur kalender (spec §9.2). `name_key` = kunci i18n (tidak ada teks hardcode); recurring_annual = berulang setiap tahun pada bulan/tanggal yang sama.';

CREATE UNIQUE INDEX holiday_scope_date_uq
  ON platform.holiday (scope_type, COALESCE(scope_id, ''), holiday_date);

CREATE TABLE platform.business_date (
  scope_type            text NOT NULL DEFAULT 'INSTITUTION',
  scope_id              text,
  current_business_date date NOT NULL,
  state                 text NOT NULL,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid,
  CONSTRAINT business_date_scope_chk CHECK (scope_type IN ('INSTITUTION', 'BRANCH')),
  CONSTRAINT business_date_state_chk CHECK (state IN ('OPEN', 'CLOSING', 'CLOSED')),
  CONSTRAINT business_date_root_scope_chk CHECK (scope_type = 'INSTITUTION' OR scope_id IS NOT NULL)
);

COMMENT ON TABLE platform.business_date IS
  'Tanggal buku sistem per scope (spec §9.3, §11.2). Transisi sah hanya OPEN → CLOSING → CLOSED; rollover mengubah current_business_date pada baris CLOSED (bukan reopen).';

CREATE UNIQUE INDEX business_date_scope_uq
  ON platform.business_date (scope_type, COALESCE(scope_id, ''));

CREATE INDEX business_date_state_idx ON platform.business_date (state);
