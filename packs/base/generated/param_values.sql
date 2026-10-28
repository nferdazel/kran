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
  (md5('daycloser.auto.enabled|base')::uuid, 'daycloser.auto.enabled', 'GLOBAL', NULL, 'false'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.auto.run_at|base')::uuid, 'daycloser.auto.run_at', 'GLOBAL', NULL, '"23:30"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.auto.utc_offset_minutes|base')::uuid, 'daycloser.auto.utc_offset_minutes', 'GLOBAL', NULL, '0'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.chunk_size|base')::uuid, 'daycloser.chunk_size', 'GLOBAL', NULL, '1000'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.max_attempts|base')::uuid, 'daycloser.max_attempts', 'GLOBAL', NULL, '3'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.postcheck.subledger_gl_accounts|base')::uuid, 'daycloser.postcheck.subledger_gl_accounts', 'GLOBAL', NULL, '["201","202"]'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.precheck.suspense_accounts|base')::uuid, 'daycloser.precheck.suspense_accounts', 'GLOBAL', NULL, '["101.9"]'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.retry_backoff_seconds|base')::uuid, 'daycloser.retry_backoff_seconds', 'GLOBAL', NULL, '5'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('daycloser.txn_policy_during_close|base')::uuid, 'daycloser.txn_policy_during_close', 'GLOBAL', NULL, '"REJECT"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('ledger.coa.code_pattern|base')::uuid, 'ledger.coa.code_pattern', 'GLOBAL', NULL, '"^[0-9]{1,3}(\\.[0-9]{1,3})*$"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('ledger.posting.batch_size|base')::uuid, 'ledger.posting.batch_size', 'GLOBAL', NULL, '50'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('ledger.posting.lease_seconds|base')::uuid, 'ledger.posting.lease_seconds', 'GLOBAL', NULL, '300'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('ledger.posting.max_attempts|base')::uuid, 'ledger.posting.max_attempts', 'GLOBAL', NULL, '10'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('ledger.posting.poll_interval_ms|base')::uuid, 'ledger.posting.poll_interval_ms', 'GLOBAL', NULL, '500'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('ledger.posting.retry_backoff_seconds|base')::uuid, 'ledger.posting.retry_backoff_seconds', 'GLOBAL', NULL, '30'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.cif.format|base')::uuid, 'party.cif.format', 'GLOBAL', NULL, '"{seq:6}{check}"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.identity.doc_lengths|base')::uuid, 'party.identity.doc_lengths', 'GLOBAL', NULL, '{"KTP":16,"NPWP":15,"PASSPORT":9}'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.identity.doc_types|base')::uuid, 'party.identity.doc_types', 'GLOBAL', NULL, '["KTP","NPWP","PASSPORT"]'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.identity.number_max_length|base')::uuid, 'party.identity.number_max_length', 'GLOBAL', NULL, '32'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.kyc.default_risk_level|base')::uuid, 'party.kyc.default_risk_level', 'GLOBAL', NULL, '"LOW"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.kyc.review_months|base')::uuid, 'party.kyc.review_months', 'GLOBAL', NULL, '{"LOW":36,"MEDIUM":12,"HIGH":6}'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.kyc.risk_levels|base')::uuid, 'party.kyc.risk_levels', 'GLOBAL', NULL, '["LOW","MEDIUM","HIGH"]'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('party.person.sex_values|base')::uuid, 'party.person.sex_values', 'GLOBAL', NULL, '["MALE","FEMALE"]'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.calendar.fiscal_year_start_month|base')::uuid, 'platform.calendar.fiscal_year_start_month', 'GLOBAL', NULL, '1'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.calendar.weekend_days|base')::uuid, 'platform.calendar.weekend_days', 'GLOBAL', NULL, '[6,7]'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.idempotency.ttl_hours|base')::uuid, 'platform.idempotency.ttl_hours', 'GLOBAL', NULL, '24'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.realtime.max_topic_len|base')::uuid, 'platform.realtime.max_topic_len', 'GLOBAL', NULL, '128'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.realtime.max_topics|base')::uuid, 'platform.realtime.max_topics', 'GLOBAL', NULL, '32'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.lockout_minutes|base')::uuid, 'platform.security.lockout_minutes', 'GLOBAL', NULL, '30'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.max_failed_logins|base')::uuid, 'platform.security.max_failed_logins', 'GLOBAL', NULL, '5'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.mfa.digits|base')::uuid, 'platform.security.mfa.digits', 'GLOBAL', NULL, '6'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.mfa.drift_steps|base')::uuid, 'platform.security.mfa.drift_steps', 'GLOBAL', NULL, '1'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.mfa.enabled|base')::uuid, 'platform.security.mfa.enabled', 'GLOBAL', NULL, 'false'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.mfa.issuer|base')::uuid, 'platform.security.mfa.issuer', 'GLOBAL', NULL, '"KRAN"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.mfa.period_seconds|base')::uuid, 'platform.security.mfa.period_seconds', 'GLOBAL', NULL, '30'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.password_history_count|base')::uuid, 'platform.security.password_history_count', 'GLOBAL', NULL, '5'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.password_min_classes|base')::uuid, 'platform.security.password_min_classes', 'GLOBAL', NULL, '3'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.password_min_length|base')::uuid, 'platform.security.password_min_length', 'GLOBAL', NULL, '12'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.password_pbkdf2_iterations|base')::uuid, 'platform.security.password_pbkdf2_iterations', 'GLOBAL', NULL, '600000'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.session_absolute_minutes|base')::uuid, 'platform.security.session_absolute_minutes', 'GLOBAL', NULL, '480'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.security.session_idle_minutes|base')::uuid, 'platform.security.session_idle_minutes', 'GLOBAL', NULL, '30'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.ui.shortcut.deposit|base')::uuid, 'platform.ui.shortcut.deposit', 'GLOBAL', NULL, '"F4"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.ui.shortcut.transfer|base')::uuid, 'platform.ui.shortcut.transfer', 'GLOBAL', NULL, '"F9"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('platform.ui.shortcut.withdrawal|base')::uuid, 'platform.ui.shortcut.withdrawal', 'GLOBAL', NULL, '"F5"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('product.savings.admin_fee|base')::uuid, 'product.savings.admin_fee', 'GLOBAL', NULL, '"0.00"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('product.savings.min_balance|base')::uuid, 'product.savings.min_balance', 'GLOBAL', NULL, '"0.00"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('teller.cash.limit_deposit|base')::uuid, 'teller.cash.limit_deposit', 'GLOBAL', NULL, '"10000000.00"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('teller.cash.limit_opening_float|base')::uuid, 'teller.cash.limit_opening_float', 'GLOBAL', NULL, '"2000000.00"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('teller.cash.limit_withdrawal|base')::uuid, 'teller.cash.limit_withdrawal', 'GLOBAL', NULL, '"5000000.00"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('teller.vault.cash_account|base')::uuid, 'teller.vault.cash_account', 'GLOBAL', NULL, '"101.1"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

INSERT INTO platform.param_value
  (param_value_id, key, scope_type, scope_id, value, effective_from, status,
   maker, checker, reason)
VALUES
  (md5('teller.vault.limit_topup_per_request|base')::uuid, 'teller.vault.limit_topup_per_request', 'GLOBAL', NULL, '"25000000.00"'::jsonb, DATE '1970-01-01', 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2', 'pack seed: base @ GLOBAL')
ON CONFLICT (param_value_id) DO NOTHING;

