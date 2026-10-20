## JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
##
## Ubah definisi di `modules/<m>/seeds/params.yaml`, lalu jalankan `./task paramgen-gen`.

import ../money
import ../paramkey
import std/json

const paramKeys*: seq[string] = @[
  "ledger.coa.code_pattern",
  "ledger.posting.batch_size",
  "ledger.posting.lease_seconds",
  "ledger.posting.max_attempts",
  "ledger.posting.poll_interval_ms",
  "ledger.posting.retry_backoff_seconds",
  "party.cif.format",
  "party.identity.doc_lengths",
  "party.identity.doc_types",
  "party.identity.number_max_length",
  "party.kyc.default_risk_level",
  "party.kyc.review_months",
  "party.kyc.risk_levels",
  "platform.calendar.fiscal_year_start_month",
  "platform.calendar.weekend_days",
  "platform.realtime.max_topic_len",
  "platform.realtime.max_topics",
  "platform.security.lockout_minutes",
  "platform.security.max_failed_logins",
  "platform.security.mfa.digits",
  "platform.security.mfa.drift_steps",
  "platform.security.mfa.enabled",
  "platform.security.mfa.issuer",
  "platform.security.mfa.period_seconds",
  "platform.security.password_history_count",
  "platform.security.password_min_classes",
  "platform.security.password_min_length",
  "platform.security.password_pbkdf2_iterations",
  "platform.security.session_absolute_minutes",
  "platform.security.session_idle_minutes",
  "product.savings.admin_fee",
  "product.savings.grace_period_days",
  "product.savings.min_balance",
]

const P_ledger_coa_code_pattern* = ParamKey[string]("ledger.coa.code_pattern")

const P_ledger_posting_batch_size* = ParamKey[int64]("ledger.posting.batch_size")

const P_ledger_posting_lease_seconds* = ParamKey[int64]("ledger.posting.lease_seconds")

const P_ledger_posting_max_attempts* = ParamKey[int64]("ledger.posting.max_attempts")

const P_ledger_posting_poll_interval_ms* = ParamKey[int64]("ledger.posting.poll_interval_ms")

const P_ledger_posting_retry_backoff_seconds* = ParamKey[int64]("ledger.posting.retry_backoff_seconds")

const P_party_cif_format* = ParamKey[string]("party.cif.format")

const P_party_identity_doc_lengths* = ParamKey[JsonNode]("party.identity.doc_lengths")

const P_party_identity_doc_types* = ParamKey[JsonNode]("party.identity.doc_types")

const P_party_identity_number_max_length* = ParamKey[int64]("party.identity.number_max_length")

const P_party_kyc_default_risk_level* = ParamKey[string]("party.kyc.default_risk_level")

const P_party_kyc_review_months* = ParamKey[JsonNode]("party.kyc.review_months")

const P_party_kyc_risk_levels* = ParamKey[JsonNode]("party.kyc.risk_levels")

const P_platform_calendar_fiscal_year_start_month* = ParamKey[int64]("platform.calendar.fiscal_year_start_month")

const P_platform_calendar_weekend_days* = ParamKey[JsonNode]("platform.calendar.weekend_days")

const P_platform_realtime_max_topic_len* = ParamKey[int64]("platform.realtime.max_topic_len")

const P_platform_realtime_max_topics* = ParamKey[int64]("platform.realtime.max_topics")

const P_platform_security_lockout_minutes* = ParamKey[int64]("platform.security.lockout_minutes")

const P_platform_security_max_failed_logins* = ParamKey[int64]("platform.security.max_failed_logins")

const P_platform_security_mfa_digits* = ParamKey[int64]("platform.security.mfa.digits")

const P_platform_security_mfa_drift_steps* = ParamKey[int64]("platform.security.mfa.drift_steps")

const P_platform_security_mfa_enabled* = ParamKey[bool]("platform.security.mfa.enabled")

const P_platform_security_mfa_issuer* = ParamKey[string]("platform.security.mfa.issuer")

const P_platform_security_mfa_period_seconds* = ParamKey[int64]("platform.security.mfa.period_seconds")

const P_platform_security_password_history_count* = ParamKey[int64]("platform.security.password_history_count")

const P_platform_security_password_min_classes* = ParamKey[int64]("platform.security.password_min_classes")

const P_platform_security_password_min_length* = ParamKey[int64]("platform.security.password_min_length")

const P_platform_security_password_pbkdf2_iterations* = ParamKey[int64]("platform.security.password_pbkdf2_iterations")

const P_platform_security_session_absolute_minutes* = ParamKey[int64]("platform.security.session_absolute_minutes")

const P_platform_security_session_idle_minutes* = ParamKey[int64]("platform.security.session_idle_minutes")

const P_product_savings_admin_fee* = ParamKey[Money]("product.savings.admin_fee")

const P_product_savings_grace_period_days* = ParamKey[int64]("product.savings.grace_period_days")

const P_product_savings_min_balance* = ParamKey[Money]("product.savings.min_balance")

const paramDefinitions*: seq[ParamDefinition] = @[
  ParamDefinition(
    key: "ledger.coa.code_pattern",
    module: "ledger",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.ledger.coa.code_pattern",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "ledger.posting.batch_size",
    module: "ledger",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.ledger.posting.batch_size",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "ledger.posting.lease_seconds",
    module: "ledger",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.ledger.posting.lease_seconds",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "ledger.posting.max_attempts",
    module: "ledger",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.ledger.posting.max_attempts",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "ledger.posting.poll_interval_ms",
    module: "ledger",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.ledger.posting.poll_interval_ms",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "ledger.posting.retry_backoff_seconds",
    module: "ledger",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.ledger.posting.retry_backoff_seconds",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "party.cif.format",
    module: "party",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.cif.format",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "party.identity.doc_lengths",
    module: "party",
    valueType: pvtJson,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.identity.doc_lengths",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "party.identity.doc_types",
    module: "party",
    valueType: pvtJson,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.identity.doc_types",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "party.identity.number_max_length",
    module: "party",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.identity.number_max_length",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "party.kyc.default_risk_level",
    module: "party",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.kyc.default_risk_level",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "party.kyc.review_months",
    module: "party",
    valueType: pvtJson,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.kyc.review_months",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "party.kyc.risk_levels",
    module: "party",
    valueType: pvtJson,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.kyc.risk_levels",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.calendar.fiscal_year_start_month",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.calendar.fiscal_year_start_month",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.calendar.weekend_days",
    module: "platform",
    valueType: pvtJson,
    scopes: {pstGlobal, pstBranch},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.calendar.weekend_days",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.realtime.max_topic_len",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.realtime.max_topic_len",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.realtime.max_topics",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.realtime.max_topics",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.lockout_minutes",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.lockout_minutes",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.max_failed_logins",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.max_failed_logins",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.mfa.digits",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.mfa.digits",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.mfa.drift_steps",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.mfa.drift_steps",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.mfa.enabled",
    module: "platform",
    valueType: pvtBool,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.mfa.enabled",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.mfa.issuer",
    module: "platform",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.mfa.issuer",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.mfa.period_seconds",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.mfa.period_seconds",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.password_history_count",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.password_history_count",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.password_min_classes",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psCritical,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.password_min_classes",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.password_min_length",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psCritical,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.password_min_length",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.password_pbkdf2_iterations",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.password_pbkdf2_iterations",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.session_absolute_minutes",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.session_absolute_minutes",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.security.session_idle_minutes",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.security.session_idle_minutes",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.admin_fee",
    module: "product",
    valueType: pvtMoney,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.admin_fee",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.grace_period_days",
    module: "product",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.grace_period_days",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.min_balance",
    module: "product",
    valueType: pvtMoney,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.min_balance",
    sinceVersion: "0.1.0",
  ),
]
