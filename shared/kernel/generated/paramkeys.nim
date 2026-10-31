## JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml
##
## Ubah definisi di `modules/<m>/seeds/params.yaml`, lalu jalankan `./task paramgen-gen`.

import ../money
import ../paramkey
import ../rate
import std/json

const paramKeys*: seq[string] = @[
  "daycloser.auto.enabled",
  "daycloser.auto.run_at",
  "daycloser.auto.utc_offset_minutes",
  "daycloser.chunk_size",
  "daycloser.max_attempts",
  "daycloser.postcheck.subledger_gl_accounts",
  "daycloser.precheck.suspense_accounts",
  "daycloser.retry_backoff_seconds",
  "daycloser.txn_policy_during_close",
  "deposit.dormant.after_months",
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
  "party.person.sex_values",
  "platform.calendar.fiscal_year_start_month",
  "platform.calendar.weekend_days",
  "platform.idempotency.ttl_hours",
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
  "platform.ui.shortcut.deposit",
  "platform.ui.shortcut.transfer",
  "platform.ui.shortcut.withdrawal",
  "product.savings.admin_fee",
  "product.savings.day_count_basis",
  "product.savings.early_withdrawal_penalty",
  "product.savings.interest_posting",
  "product.savings.interest_rate",
  "product.savings.min_balance",
  "product.savings.rollover_tenor_days",
  "product.savings.rounding_mode",
  "product.savings.rounding_scale",
  "teller.cash.limit_deposit",
  "teller.cash.limit_opening_float",
  "teller.cash.limit_withdrawal",
  "teller.vault.cash_account",
  "teller.vault.limit_topup_per_request",
]

const P_daycloser_auto_enabled* = ParamKey[bool]("daycloser.auto.enabled")

const P_daycloser_auto_run_at* = ParamKey[string]("daycloser.auto.run_at")

const P_daycloser_auto_utc_offset_minutes* = ParamKey[int64]("daycloser.auto.utc_offset_minutes")

const P_daycloser_chunk_size* = ParamKey[int64]("daycloser.chunk_size")

const P_daycloser_max_attempts* = ParamKey[int64]("daycloser.max_attempts")

const P_daycloser_postcheck_subledger_gl_accounts* = ParamKey[JsonNode]("daycloser.postcheck.subledger_gl_accounts")

const P_daycloser_precheck_suspense_accounts* = ParamKey[JsonNode]("daycloser.precheck.suspense_accounts")

const P_daycloser_retry_backoff_seconds* = ParamKey[int64]("daycloser.retry_backoff_seconds")

const P_daycloser_txn_policy_during_close* = ParamKey[string]("daycloser.txn_policy_during_close")

const P_deposit_dormant_after_months* = ParamKey[int64]("deposit.dormant.after_months")

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

const P_party_person_sex_values* = ParamKey[JsonNode]("party.person.sex_values")

const P_platform_calendar_fiscal_year_start_month* = ParamKey[int64]("platform.calendar.fiscal_year_start_month")

const P_platform_calendar_weekend_days* = ParamKey[JsonNode]("platform.calendar.weekend_days")

const P_platform_idempotency_ttl_hours* = ParamKey[int64]("platform.idempotency.ttl_hours")

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

const P_platform_ui_shortcut_deposit* = ParamKey[string]("platform.ui.shortcut.deposit")

const P_platform_ui_shortcut_transfer* = ParamKey[string]("platform.ui.shortcut.transfer")

const P_platform_ui_shortcut_withdrawal* = ParamKey[string]("platform.ui.shortcut.withdrawal")

const P_product_savings_admin_fee* = ParamKey[Money]("product.savings.admin_fee")

const P_product_savings_day_count_basis* = ParamKey[string]("product.savings.day_count_basis")

const P_product_savings_early_withdrawal_penalty* = ParamKey[Rate]("product.savings.early_withdrawal_penalty")

const P_product_savings_interest_posting* = ParamKey[string]("product.savings.interest_posting")

const P_product_savings_interest_rate* = ParamKey[Rate]("product.savings.interest_rate")

const P_product_savings_min_balance* = ParamKey[Money]("product.savings.min_balance")

const P_product_savings_rollover_tenor_days* = ParamKey[int64]("product.savings.rollover_tenor_days")

const P_product_savings_rounding_mode* = ParamKey[string]("product.savings.rounding_mode")

const P_product_savings_rounding_scale* = ParamKey[int64]("product.savings.rounding_scale")

const P_teller_cash_limit_deposit* = ParamKey[Money]("teller.cash.limit_deposit")

const P_teller_cash_limit_opening_float* = ParamKey[Money]("teller.cash.limit_opening_float")

const P_teller_cash_limit_withdrawal* = ParamKey[Money]("teller.cash.limit_withdrawal")

const P_teller_vault_cash_account* = ParamKey[string]("teller.vault.cash_account")

const P_teller_vault_limit_topup_per_request* = ParamKey[Money]("teller.vault.limit_topup_per_request")

const paramDefinitions*: seq[ParamDefinition] = @[
  ParamDefinition(
    key: "daycloser.auto.enabled",
    module: "daycloser",
    valueType: pvtBool,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.auto.enabled",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.auto.run_at",
    module: "daycloser",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.auto.run_at",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.auto.utc_offset_minutes",
    module: "daycloser",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.auto.utc_offset_minutes",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.chunk_size",
    module: "daycloser",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.chunk_size",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.max_attempts",
    module: "daycloser",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.max_attempts",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.postcheck.subledger_gl_accounts",
    module: "daycloser",
    valueType: pvtJson,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.postcheck.subledger_gl_accounts",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.precheck.suspense_accounts",
    module: "daycloser",
    valueType: pvtJson,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.precheck.suspense_accounts",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.retry_backoff_seconds",
    module: "daycloser",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.retry_backoff_seconds",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "daycloser.txn_policy_during_close",
    module: "daycloser",
    valueType: pvtEnum,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.daycloser.txn_policy_during_close",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "deposit.dormant.after_months",
    module: "deposit",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.deposit.dormant.after_months",
    sinceVersion: "0.1.0",
  ),
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
    key: "party.person.sex_values",
    module: "party",
    valueType: pvtJson,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.party.person.sex_values",
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
    key: "platform.idempotency.ttl_hours",
    module: "platform",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.idempotency.ttl_hours",
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
    key: "platform.ui.shortcut.deposit",
    module: "platform",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.ui.shortcut.deposit",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.ui.shortcut.transfer",
    module: "platform",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.ui.shortcut.transfer",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "platform.ui.shortcut.withdrawal",
    module: "platform",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.platform.ui.shortcut.withdrawal",
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
    key: "product.savings.day_count_basis",
    module: "product",
    valueType: pvtEnum,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.day_count_basis",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.early_withdrawal_penalty",
    module: "product",
    valueType: pvtRate,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.early_withdrawal_penalty",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.interest_posting",
    module: "product",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.interest_posting",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.interest_rate",
    module: "product",
    valueType: pvtRate,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.interest_rate",
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
  ParamDefinition(
    key: "product.savings.rollover_tenor_days",
    module: "product",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.rollover_tenor_days",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.rounding_mode",
    module: "product",
    valueType: pvtEnum,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.rounding_mode",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "product.savings.rounding_scale",
    module: "product",
    valueType: pvtInteger,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.product.savings.rounding_scale",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "teller.cash.limit_deposit",
    module: "teller",
    valueType: pvtMoney,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.teller.cash.limit_deposit",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "teller.cash.limit_opening_float",
    module: "teller",
    valueType: pvtMoney,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.teller.cash.limit_opening_float",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "teller.cash.limit_withdrawal",
    module: "teller",
    valueType: pvtMoney,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.teller.cash.limit_withdrawal",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "teller.vault.cash_account",
    module: "teller",
    valueType: pvtString,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psCritical,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.teller.vault.cash_account",
    sinceVersion: "0.1.0",
  ),
  ParamDefinition(
    key: "teller.vault.limit_topup_per_request",
    module: "teller",
    valueType: pvtMoney,
    scopes: {pstGlobal, pstInstitution},
    sensitivity: psNormal,
    requiresApproval: true,
    regulatoryRefs: @[],
    descriptionKey: "param.teller.vault.limit_topup_per_request",
    sinceVersion: "0.1.0",
  ),
]
