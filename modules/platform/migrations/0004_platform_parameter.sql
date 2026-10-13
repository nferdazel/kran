-- 0004: parameter framework — definisi & nilai effective-dated (spec §10.2).
--
-- Aturan emas (spec §10.1): **tidak ada nilai bisnis di kode**. Tabel ini sumbernya; akses di
-- kode hanya lewat key hasil generate (`shared/kernel/generated/paramkeys.nim`).
--
-- Invarian yang ditegakkan skema:
--   - Satu periode per (key, scope) untuk baris disetujui (ACTIVE/SUPERSEDED): EXCLUDE gist
--     dengan daterange `[)` (butuh ekstensi btree_gist). Riwayat disimpan sebagai SUPERSEDED
--     dengan `effective_to` dipangkas, sehingga tanggal lampau tetap punya nilai tunggal.
--   - Baris ACTIVE/SUPERSEDED **wajib** punya `checker` (4-eyes; spec §10.2, §13).
--   - Baris GLOBAL tidak boleh punya `scope_id`.
--
-- Expand-only: hanya CREATE.

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE platform.param_definition (
  key              text PRIMARY KEY,
  module           text NOT NULL,
  value_type       text NOT NULL,
  json_schema      jsonb NOT NULL,
  allowed_scopes   text[] NOT NULL,
  description_key  text NOT NULL,
  regulatory_refs  text[] NOT NULL DEFAULT '{}',
  sensitivity      text NOT NULL DEFAULT 'NORMAL',
  requires_approval boolean NOT NULL DEFAULT true,
  change_window    text,
  since_version    text NOT NULL,
  deprecated       boolean NOT NULL DEFAULT false,
  CONSTRAINT param_definition_value_type_chk CHECK (value_type IN
    ('integer','decimal','string','bool','json','enum','money','rate','date')),
  CONSTRAINT param_definition_sensitivity_chk CHECK (sensitivity IN ('NORMAL','CRITICAL')),
  CONSTRAINT param_definition_scopes_chk CHECK (
    array_length(allowed_scopes, 1) >= 1 AND
    allowed_scopes <@ ARRAY['GLOBAL','INSTITUTION','BRANCH','PRODUCT','SEGMENT','ROLE']::text[])
);

COMMENT ON TABLE platform.param_definition IS
  'Definisi parameter (skema + governance). Diisi seed dari modules/<m>/seeds/params.yaml via tools/paramgen.';
COMMENT ON COLUMN platform.param_definition.change_window IS
  'Batasan jendela perubahan (mis. hanya di luar jam batch); ditegakkan aplikasi, bukan skema.';

CREATE TABLE platform.param_value (
  param_value_id uuid PRIMARY KEY,
  key            text NOT NULL REFERENCES platform.param_definition(key),
  scope_type     text NOT NULL,
  scope_id       text,
  value          jsonb NOT NULL,
  effective_from date NOT NULL,
  effective_to   date,
  status         text NOT NULL,
  maker          uuid NOT NULL,
  checker        uuid,
  reason         text NOT NULL,
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT param_value_status_chk CHECK
    (status IN ('DRAFT','PENDING','ACTIVE','SUPERSEDED','REJECTED')),
  CONSTRAINT param_value_scope_chk CHECK
    (scope_type IN ('GLOBAL','INSTITUTION','BRANCH','PRODUCT','SEGMENT','ROLE')),
  CONSTRAINT param_value_global_scope_chk CHECK ((scope_type = 'GLOBAL') = (scope_id IS NULL)),
  CONSTRAINT param_value_period_chk CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT param_value_reason_chk CHECK (length(btrim(reason)) > 0),
  CONSTRAINT param_value_checker_chk CHECK (status NOT IN ('ACTIVE','SUPERSEDED') OR checker IS NOT NULL),
  CONSTRAINT param_value_no_self_approval_chk CHECK (checker IS NULL OR checker <> maker),
  -- EXCLUDE berlaku untuk baris yang sudah "disetujui" (ACTIVE **dan** SUPERSEDED) supaya
  -- riwayat effective-dated tidak bisa dibuat ambigu oleh aktivasi baru yang menimpanya.
  EXCLUDE USING gist (key WITH =, scope_type WITH =, COALESCE(scope_id, '') WITH =,
                      daterange(effective_from, effective_to, '[)') WITH &&)
    WHERE (status IN ('ACTIVE', 'SUPERSEDED'))
);

COMMENT ON TABLE platform.param_value IS
  'Nilai parameter effective-dated + maker-checker. Hanya satu ACTIVE per (key, scope, periode); SUPERSEDED menyimpan riwayat.';

CREATE INDEX param_value_lookup_idx
  ON platform.param_value (key, scope_type, effective_from)
  WHERE status = 'ACTIVE';

CREATE INDEX param_value_pending_idx
  ON platform.param_value (status, recorded_at)
  WHERE status IN ('DRAFT','PENDING');
