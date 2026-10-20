-- JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
-- Definisi parameter (pack-independent). Jalankan lebih dulu daripada
-- packs/<pack>/generated/param_values.sql. Idempotent.
--
-- NEEDS-COMPLIANCE-REVIEW: referensi regulasi & nilai default di sini belum
-- diverifikasi compliance officer (spec §1.8, §4).

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

