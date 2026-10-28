-- JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
-- Definisi parameter (pack-independent). Jalankan lebih dulu daripada
-- packs/<pack>/generated/param_values.sql. Idempotent.
--
-- NEEDS-COMPLIANCE-REVIEW: referensi regulasi & nilai default di sini belum
-- diverifikasi compliance officer (spec §1.8, §4).

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.auto.enabled', 'daycloser', 'bool', '{}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.auto.enabled', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.auto.run_at', 'daycloser', 'string', '{"minLength":5,"maxLength":5}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.auto.run_at', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.auto.utc_offset_minutes', 'daycloser', 'integer', '{"minimum":-840,"maximum":840}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.auto.utc_offset_minutes', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.chunk_size', 'daycloser', 'integer', '{"minimum":1,"maximum":100000}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.chunk_size', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.max_attempts', 'daycloser', 'integer', '{"minimum":1,"maximum":10}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.max_attempts', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.postcheck.subledger_gl_accounts', 'daycloser', 'json', '{"type":"array"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.postcheck.subledger_gl_accounts', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.precheck.suspense_accounts', 'daycloser', 'json', '{"type":"array"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.precheck.suspense_accounts', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.retry_backoff_seconds', 'daycloser', 'integer', '{"minimum":0,"maximum":300}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.retry_backoff_seconds', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('daycloser.txn_policy_during_close', 'daycloser', 'enum', '{"enum":["REJECT","ALLOW"],"description":"REJECT = semua perubahan HTTP ditolak 409 saat CLOSING; ALLOW = layanan tetap jalan (risiko race ditanggung institusi)"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.daycloser.txn_policy_during_close', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('deposit.dormant.after_months', 'deposit', 'integer', '{"minimum":1,"maximum":120}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.deposit.dormant.after_months', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('ledger.coa.code_pattern', 'ledger', 'string', '{"minLength":5,"maxLength":120}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.ledger.coa.code_pattern', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('ledger.posting.batch_size', 'ledger', 'integer', '{"minimum":1,"maximum":500}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.ledger.posting.batch_size', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('ledger.posting.lease_seconds', 'ledger', 'integer', '{"minimum":30,"maximum":3600}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.ledger.posting.lease_seconds', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('ledger.posting.max_attempts', 'ledger', 'integer', '{"minimum":1,"maximum":100}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.ledger.posting.max_attempts', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('ledger.posting.poll_interval_ms', 'ledger', 'integer', '{"minimum":50,"maximum":60000}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.ledger.posting.poll_interval_ms', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('ledger.posting.retry_backoff_seconds', 'ledger', 'integer', '{"minimum":1,"maximum":86400}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.ledger.posting.retry_backoff_seconds', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.cif.format', 'party', 'string', '{"minLength":5,"maxLength":24}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.cif.format', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.identity.doc_lengths', 'party', 'json', '{"type":"object"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.identity.doc_lengths', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.identity.doc_types', 'party', 'json', '{"type":"array"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.identity.doc_types', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.identity.number_max_length', 'party', 'integer', '{"minimum":4,"maximum":64}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.identity.number_max_length', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.kyc.default_risk_level', 'party', 'string', '{"minLength":1,"maxLength":32}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.kyc.default_risk_level', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.kyc.review_months', 'party', 'json', '{"type":"object"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.kyc.review_months', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.kyc.risk_levels', 'party', 'json', '{"type":"array"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.kyc.risk_levels', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('party.person.sex_values', 'party', 'json', '{"type":"array"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.party.person.sex_values', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

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
VALUES ('platform.calendar.weekend_days', 'platform', 'json', '{"type":"array"}'::jsonb, ARRAY['GLOBAL', 'BRANCH'], 'param.platform.calendar.weekend_days', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.idempotency.ttl_hours', 'platform', 'integer', '{"minimum":1,"maximum":8760}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.idempotency.ttl_hours', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.realtime.max_topic_len', 'platform', 'integer', '{"minimum":1,"maximum":4096}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.realtime.max_topic_len', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.realtime.max_topics', 'platform', 'integer', '{"minimum":1,"maximum":1000}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.realtime.max_topics', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.lockout_minutes', 'platform', 'integer', '{"minimum":1,"maximum":1440}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.lockout_minutes', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.max_failed_logins', 'platform', 'integer', '{"minimum":1,"maximum":100}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.max_failed_logins', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.mfa.digits', 'platform', 'integer', '{"minimum":6,"maximum":8}'::jsonb, ARRAY['GLOBAL'], 'param.platform.security.mfa.digits', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.mfa.drift_steps', 'platform', 'integer', '{"minimum":0,"maximum":5}'::jsonb, ARRAY['GLOBAL'], 'param.platform.security.mfa.drift_steps', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.mfa.enabled', 'platform', 'bool', '{}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.mfa.enabled', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.mfa.issuer', 'platform', 'string', '{"minLength":1,"maxLength":64}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.mfa.issuer', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.mfa.period_seconds', 'platform', 'integer', '{"minimum":15,"maximum":300}'::jsonb, ARRAY['GLOBAL'], 'param.platform.security.mfa.period_seconds', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.password_history_count', 'platform', 'integer', '{"minimum":0,"maximum":24}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.password_history_count', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.password_min_classes', 'platform', 'integer', '{"minimum":1,"maximum":4}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.password_min_classes', ARRAY[]::text[], 'CRITICAL', true, '0.1.0')
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
VALUES ('platform.security.password_pbkdf2_iterations', 'platform', 'integer', '{"minimum":1000,"maximum":5000000}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.password_pbkdf2_iterations', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.security.session_absolute_minutes', 'platform', 'integer', '{"minimum":5,"maximum":1440}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.security.session_absolute_minutes', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
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

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.ui.shortcut.deposit', 'platform', 'string', '{"maxLength":16}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.ui.shortcut.deposit', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.ui.shortcut.transfer', 'platform', 'string', '{"maxLength":16}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.ui.shortcut.transfer', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('platform.ui.shortcut.withdrawal', 'platform', 'string', '{"maxLength":16}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.platform.ui.shortcut.withdrawal', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('product.savings.admin_fee', 'product', 'money', '{"minimum":0}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.product.savings.admin_fee', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('product.savings.day_count_basis', 'product', 'enum', '{"enum":["ACT_365","ACT_360","THIRTY_360"],"description":"basis hari bernama spec §10.5 (act/360, 30/360, act/365); menambah basis lain = ubah definisi ini, bukan nilai bebas"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.product.savings.day_count_basis', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('product.savings.interest_posting', 'product', 'string', '{"maxLength":32,"description":"domain nilai sengaja dibuka: spec/D-094 tidak menetapkan kapan bunga diposting, jadi enum lama [NONE, MONTH_END] ditarik; enum ditetapkan bersama mesin akrual (Fase 3)"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.product.savings.interest_posting', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('product.savings.interest_rate', 'product', 'rate', '{"maxLength":32,"description":"persen sebagai string; presisi maksimum 4 desimal dan batas kewajaran ditegakkan kernel (rateFromPercentString), bukan di sini"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.product.savings.interest_rate', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('product.savings.min_balance', 'product', 'money', '{"minimum":0}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.product.savings.min_balance', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('product.savings.rounding_mode', 'product', 'enum', '{"enum":["HALF_EVEN"],"description":"hanya HALF_EVEN: kernel hanya mengimplementasikan half-to-even (checkedint.divRoundHalfEven; Money.div & applyRate). Mode lain butuh kode + keputusan lebih dulu"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.product.savings.rounding_mode', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('product.savings.rounding_scale', 'product', 'integer', '{"type":"integer","minimum":0,"maximum":2,"description":"0..moneyScale (2): penyimpanan uang adalah sen (D-136), jadi hasil pembulatan > 2 desimal tidak punya tempat menyimpan"}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.product.savings.rounding_scale', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('teller.cash.limit_deposit', 'teller', 'money', '{"minimum":0}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.teller.cash.limit_deposit', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('teller.cash.limit_opening_float', 'teller', 'money', '{"minimum":0}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.teller.cash.limit_opening_float', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('teller.cash.limit_withdrawal', 'teller', 'money', '{"minimum":0}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.teller.cash.limit_withdrawal', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('teller.vault.cash_account', 'teller', 'string', '{"minLength":1,"maxLength":32}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.teller.vault.cash_account', ARRAY[]::text[], 'CRITICAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

INSERT INTO platform.param_definition
  (key, module, value_type, json_schema, allowed_scopes, description_key,
   regulatory_refs, sensitivity, requires_approval, since_version)
VALUES ('teller.vault.limit_topup_per_request', 'teller', 'money', '{"minimum":0}'::jsonb, ARRAY['GLOBAL', 'INSTITUTION'], 'param.teller.vault.limit_topup_per_request', ARRAY[]::text[], 'NORMAL', true, '0.1.0')
ON CONFLICT (key) DO UPDATE SET
  module = EXCLUDED.module, value_type = EXCLUDED.value_type,
  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,
  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,
  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,
  since_version = EXCLUDED.since_version;

