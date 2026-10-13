-- JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
-- Definisi parameter (pack-independent). Jalankan lebih dulu daripada
-- packs/<pack>/generated/param_values.sql. Idempotent.
--
-- NEEDS-COMPLIANCE-REVIEW: referensi regulasi & nilai default di sini belum
-- diverifikasi compliance officer (spec §1.8, §4).

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.calendar.fiscal_year_start_month', 'platform', 'integer', '{"minimum":1,"maximum":12}'::jsonb, ARRAY['GLOBAL'], 'param.platform.calendar.fiscal_year_start_month', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.password_min_length', 'platform', 'integer', '{"minimum":8,"maximum":64}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.password_min_length', ARRAY[]::text[], 'CRITICAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.session_idle_minutes', 'platform', 'integer', '{"minimum":1,"maximum":1440}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.session_idle_minutes', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

