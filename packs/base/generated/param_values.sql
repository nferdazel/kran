-- JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
-- Seed segment pack: base
--
-- Prasyarat: packs/base/generated/param_definitions.sql sudah dijalankan.
-- Nilai di bawah ini NILAI AWAL untuk segmen ini, BUKAN fallback kode (spec §10.3).
-- Disemai sebagai ACTIVE oleh dua UUID sistem (pack generator & pack reviewer):
-- pack berasal dari repo yang di-review, bukan perubahan runtime.
-- NEEDS-COMPLIANCE-REVIEW: nilai yang menyentuh rate/ambang/denda wajib
-- diverifikasi compliance officer sebelum dipakai produksi (spec §1.8).
-- Idempotent: aman dijalankan berulang.

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.calendar.fiscal_year_start_month|base')::uuid, 'platform.calendar.fiscal_year_start_month', 'GLOBAL', NULL, '1'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'segment pack seed')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.password_min_length|base')::uuid, 'platform.security.password_min_length', 'GLOBAL', NULL, '12'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'segment pack seed')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.session_idle_minutes|base')::uuid, 'platform.security.session_idle_minutes', 'GLOBAL', NULL, '30'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'segment pack seed')
ON CONFLICT (param_value_id) DO NOTHING;

