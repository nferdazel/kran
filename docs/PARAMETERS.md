<!-- GENERATED FILE: do not edit by hand. -->
<!-- Source: modules/*/seeds/params.yaml -->
<!-- Regenerate: python3 tools/docsgen/docsgen.py params -->
<!-- Drift check: python3 tools/docsgen/docsgen.py params --check -->

# Parameters

Every policy, rate and limit is read from the database; no business value lives in
code (spec §10). This page is generated from the seed definitions and intentionally
does not repeat seeded values, so approving a new value does not touch this file.

- Definitions: **66** across **8** modules (`daycloser`, `deposit`, `ledger`, `lending`, `party`, `platform`, `product`, `teller`).
- Definitions with no seeded value (callers must fail fast): **7**.
- Definitions carrying a review marker: **32**.
- Cross-checked against `packs/base/generated/param_provenance.md` (66 keys).

`Class` is the provenance class from `paramgen` (D-095). `Scope` lists the scopes a
value may be stored in. `Seed pack` names the pack that ships a starting value; `-`
means the definition has none. The marker column repeats `provenance.compliance`
verbatim (`NEEDS-COMPLIANCE-REVIEW`, `HUMAN-REVIEW-REQUIRED`, or `-`), so
`NEEDS-COMPLIANCE-REVIEW` always means the value is provisional and must not be
quoted as a regulatory requirement.

| Key | Class | Scope | Unit/type | Seed pack | Value seeded | Review marker | Source |
|---|---|---|---|---|---|---|---|
| `daycloser.auto.enabled` | kebijakan | GLOBAL, INSTITUTION | bool | base | yes | - | `modules/daycloser/seeds/params.yaml` |
| `daycloser.auto.run_at` | kebijakan | GLOBAL, INSTITUTION | string 5..5 | base | yes | - | `modules/daycloser/seeds/params.yaml` |
| `daycloser.auto.utc_offset_minutes` | teknis | GLOBAL, INSTITUTION | integer -840..840 | base | yes | - | `modules/daycloser/seeds/params.yaml` |
| `daycloser.chunk_size` | teknis | GLOBAL, INSTITUTION | integer 1..100000 | base | yes | - | `modules/daycloser/seeds/params.yaml` |
| `daycloser.max_attempts` | teknis | GLOBAL, INSTITUTION | integer 1..10 | base | yes | - | `modules/daycloser/seeds/params.yaml` |
| `daycloser.postcheck.subledger_gl_accounts` | kebijakan | GLOBAL, INSTITUTION | json (array) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/daycloser/seeds/params.yaml` |
| `daycloser.precheck.suspense_accounts` | kebijakan | GLOBAL, INSTITUTION | json (array) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/daycloser/seeds/params.yaml` |
| `daycloser.retry_backoff_seconds` | teknis | GLOBAL, INSTITUTION | integer 0..300 | base | yes | - | `modules/daycloser/seeds/params.yaml` |
| `daycloser.txn_policy_during_close` | kebijakan | GLOBAL, INSTITUTION | enum: REJECT\|ALLOW | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/daycloser/seeds/params.yaml` |
| `deposit.dormant.after_months` | kebijakan | GLOBAL, INSTITUTION | integer 1..120 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/deposit/seeds/params.yaml` |
| `deposit.dormant_close.after_months` | kebijakan | GLOBAL, INSTITUTION | integer 1..120 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/deposit/seeds/params.yaml` |
| `ledger.coa.code_pattern` | teknis | GLOBAL, INSTITUTION | string 5..120 | base | yes | - | `modules/ledger/seeds/params.yaml` |
| `ledger.posting.batch_size` | teknis | GLOBAL, INSTITUTION | integer 1..500 | base | yes | - | `modules/ledger/seeds/params.yaml` |
| `ledger.posting.lease_seconds` | teknis | GLOBAL, INSTITUTION | integer 30..3600 | base | yes | - | `modules/ledger/seeds/params.yaml` |
| `ledger.posting.max_attempts` | teknis | GLOBAL, INSTITUTION | integer 1..100 | base | yes | - | `modules/ledger/seeds/params.yaml` |
| `ledger.posting.poll_interval_ms` | teknis | GLOBAL, INSTITUTION | integer 50..60000 | base | yes | - | `modules/ledger/seeds/params.yaml` |
| `ledger.posting.retry_backoff_seconds` | teknis | GLOBAL, INSTITUTION | integer 1..86400 | base | yes | - | `modules/ledger/seeds/params.yaml` |
| `lending.allocation_order` | kebijakan | GLOBAL, INSTITUTION | string 1..64 | base | yes | - | `modules/lending/seeds/params.yaml` |
| `lending.collectibility.dpd_bounds` | kebijakan | GLOBAL, INSTITUTION | json (array) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/lending/seeds/params.yaml` |
| `lending.loan.max_principal` | komersial-konservatif | GLOBAL, INSTITUTION | money >= 0.01 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/lending/seeds/params.yaml` |
| `lending.ppap.rates` | kebijakan | GLOBAL, INSTITUTION | json (array) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/lending/seeds/params.yaml` |
| `lending.restructure.clean_periods` | kebijakan | GLOBAL, INSTITUTION | integer 1..12 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/lending/seeds/params.yaml` |
| `party.cif.format` | kebijakan | GLOBAL, INSTITUTION | string 5..24 | base | yes | - | `modules/party/seeds/params.yaml` |
| `party.identity.doc_lengths` | kebijakan | GLOBAL, INSTITUTION | json (object) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/party/seeds/params.yaml` |
| `party.identity.doc_types` | kebijakan | GLOBAL, INSTITUTION | json (array) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/party/seeds/params.yaml` |
| `party.identity.number_max_length` | kebijakan | GLOBAL, INSTITUTION | integer 4..64 | base | yes | - | `modules/party/seeds/params.yaml` |
| `party.kyc.default_risk_level` | kebijakan | GLOBAL, INSTITUTION | string 1..32 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/party/seeds/params.yaml` |
| `party.kyc.review_months` | kebijakan | GLOBAL, INSTITUTION | json (object) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/party/seeds/params.yaml` |
| `party.kyc.risk_levels` | kebijakan | GLOBAL, INSTITUTION | json (array) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/party/seeds/params.yaml` |
| `party.person.sex_values` | kebijakan | GLOBAL, INSTITUTION | json (array) | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/party/seeds/params.yaml` |
| `platform.calendar.fiscal_year_start_month` | kebijakan | GLOBAL | integer 1..12 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.calendar.weekend_days` | kebijakan | GLOBAL, BRANCH | json (array) | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.idempotency.ttl_hours` | teknis | GLOBAL, INSTITUTION | integer 1..8760 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.realtime.max_topic_len` | teknis | GLOBAL, INSTITUTION | integer 1..4096 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.realtime.max_topics` | teknis | GLOBAL, INSTITUTION | integer 1..1000 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.lockout_minutes` | kebijakan | GLOBAL, INSTITUTION | integer 1..1440 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.max_failed_logins` | kebijakan | GLOBAL, INSTITUTION | integer 1..100 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.mfa.digits` | teknis | GLOBAL | integer 6..8 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.mfa.drift_steps` | teknis | GLOBAL | integer 0..5 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.mfa.enabled` | teknis | GLOBAL, INSTITUTION | bool | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/platform/seeds/params.yaml` |
| `platform.security.mfa.issuer` | teknis | GLOBAL, INSTITUTION | string 1..64 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.mfa.period_seconds` | teknis | GLOBAL | integer 15..300 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.mfa.require_login` | kebijakan | GLOBAL, INSTITUTION | bool | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/platform/seeds/params.yaml` |
| `platform.security.password_history_count` | kebijakan | GLOBAL, INSTITUTION | integer 0..24 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.password_min_classes` | kebijakan | GLOBAL, INSTITUTION | integer 1..4 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.password_min_length` | kebijakan | GLOBAL, INSTITUTION | integer 8..64 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.password_pbkdf2_iterations` | teknis | GLOBAL, INSTITUTION | integer 1000..5000000 | base | yes | `HUMAN-REVIEW-REQUIRED` | `modules/platform/seeds/params.yaml` |
| `platform.security.session_absolute_minutes` | kebijakan | GLOBAL, INSTITUTION | integer 5..1440 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.security.session_idle_minutes` | kebijakan | GLOBAL, INSTITUTION | integer 1..1440 | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.ui.shortcut.deposit` | kebijakan | GLOBAL, INSTITUTION | string <= 16 chars | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.ui.shortcut.transfer` | kebijakan | GLOBAL, INSTITUTION | string <= 16 chars | base | yes | - | `modules/platform/seeds/params.yaml` |
| `platform.ui.shortcut.withdrawal` | kebijakan | GLOBAL, INSTITUTION | string <= 16 chars | base | yes | - | `modules/platform/seeds/params.yaml` |
| `product.savings.admin_fee` | komersial-konservatif | GLOBAL, INSTITUTION | money >= 0 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.day_count_basis` | regulasi-tidak-disemai | GLOBAL, INSTITUTION | enum: ACT_365\|ACT_360\|THIRTY_360 | - | no | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.early_withdrawal_penalty` | kebijakan | GLOBAL, INSTITUTION | rate | - | no | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.interest_posting` | regulasi-tidak-disemai | GLOBAL, INSTITUTION | string <= 32 chars | - | no | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.interest_rate` | regulasi-tidak-disemai | GLOBAL, INSTITUTION | rate | - | no | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.min_balance` | komersial-konservatif | GLOBAL, INSTITUTION | money >= 0 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.rollover_tenor_days` | kebijakan | GLOBAL, INSTITUTION | integer 1..3650 | - | no | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.rounding_mode` | regulasi-tidak-disemai | GLOBAL, INSTITUTION | enum: HALF_EVEN | - | no | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `product.savings.rounding_scale` | regulasi-tidak-disemai | GLOBAL, INSTITUTION | integer 0..2 | - | no | `NEEDS-COMPLIANCE-REVIEW` | `modules/product/seeds/params.yaml` |
| `teller.cash.limit_deposit` | kebijakan | GLOBAL, INSTITUTION | money >= 0 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/teller/seeds/params.yaml` |
| `teller.cash.limit_opening_float` | kebijakan | GLOBAL, INSTITUTION | money >= 0 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/teller/seeds/params.yaml` |
| `teller.cash.limit_withdrawal` | kebijakan | GLOBAL, INSTITUTION | money >= 0 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/teller/seeds/params.yaml` |
| `teller.vault.cash_account` | kebijakan | GLOBAL, INSTITUTION | string 1..32 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/teller/seeds/params.yaml` |
| `teller.vault.limit_topup_per_request` | kebijakan | GLOBAL, INSTITUTION | money >= 0 | base | yes | `NEEDS-COMPLIANCE-REVIEW` | `modules/teller/seeds/params.yaml` |

## Definitions per class

| Class | Definitions |
|---|---|
| kebijakan | 39 |
| komersial-konservatif | 3 |
| regulasi-tidak-disemai | 5 |
| teknis | 19 |
