# Security Policy

## Supported versions

Only the latest release is supported. `VERSION` at the repository root is the single source of the
version number; tags are annotated `vX.Y.Z` and published on the
[releases page](https://github.com/nferdazel/kran/releases). Older tags receive no fixes, and there
is no long-term-support branch.

## Reporting a vulnerability

**Do not open a public issue, pull request, or discussion for a security problem.**

Use GitHub private vulnerability reporting:
<https://github.com/nferdazel/kran/security/advisories/new> (the repository's **Security** tab →
**Report a vulnerability**). Advisory drafts stay private until they are published.

A useful report includes:

- the affected version (output of `./task version`) or commit;
- the component (module, endpoint, CLI role, or deploy script);
- a reproduction against your own instance with synthetic data;
- the impact you believe it has;
- any suggested fix, if you have one.

Do not include real credentials, personal data, or a dump from a live system.

The repository is maintained by one person. There is no formal response SLA and no bug bounty.
Reports are acknowledged and investigated as capacity allows, and fixes are coordinated in the
advisory so you have time to update before details become public.

Do not test against the production deployment. The VPS, webhook secret, Caddy/TLS configuration,
and backups are not in this repository (`ops/` mirrors only a subset), so we cannot grant access to
them.

## In scope

This is core banking software, so the following are security-relevant:

- **Authentication and sessions** - PBKDF2-HMAC-SHA256 password hashing, login lockout, forced
  password change, password history, session tokens stored only as hashes, idle/absolute session
  limits, and the TOTP MFA framework. (MFA is present but not enabled by default; see the accepted
  limits below.)
- **Authorization** - permission codes (`module.resource.action`), branch scoping, and
  segregation-of-duties checks that fail closed.
- **Ledger integrity** - the immutable journal, reversal-only corrections, balance computation, and
  the reconciliation commands (`ctl reconcile-deposits`, trial balance, day-close gates).
- **Audit trail** - the append-only `platform.audit_log` hash chain, its daily anchor
  (`kran-api --role=ctl audit-anchor`), and the database privileges that prevent the runtime role
  from rewriting or deleting rows.
- **Personal data protection** - field-level encryption for identity data (envelope KEK→DEK,
  AES-256-GCM, blind index), masking of sensitive values in logs, and retention of idempotency
  response bodies that may contain customer data.
- **Deployment pipeline** - webhook authentication, the guard that accepts only pushes to
  `main`, the CI check-run gate before a build, image rollback, and secret handling in
  [`ops/`](ops). Real values live on the server; the repository contains templates only.

## Out of scope

- **Dev seed credentials.** Users such as `dev.maker`, `dev.checker`, `dev.cashmaker`, and
  `dev.console` with password `rahasia-panjang-123` in
  [`packs/base/seed/0001_dev_users.sql`](packs/base/seed/0001_dev_users.sql) are intentionally
  public. They exist only in dev/test databases created by `./task dbtools seed --dev`, and anyone
  who can reach such a database is already allowed in. A deployed system running on dev seed users
  is a deployment problem, not a vulnerability in the seed.
- **Synthetic pilot data.** The pilot deployment holds synthetic data only. Personal data found
  there was generated for testing; report it as a bug, not as a breach.
- **Documented, accepted limits.** [`docs/ACCEPTED-LIMITS.md`](docs/ACCEPTED-LIMITS.md) lists
  known gaps with impact, detection, and owner (for example MFA not yet enabled, single-instance
  deployment, no metrics, and KEK rotation being prohibited until reindexing exists). Repeating a
  listed limit is not a new finding, but a concrete exploit of one is.
- **Spam, automated scanner output without a demonstrated impact, and social engineering.**

## Secrets never live in the repository

Real credentials, keys, and database URLs never enter git. `.local/` and `*.env` are gitignored;
only `*.env.example` templates are tracked, and `ops/env/kran-prod.env.example` contains
placeholders. CI runs gitleaks in its `security` job for pushes to `main` and for pull requests
(docs-only changes do not trigger CI). If you find a committed secret,
report it privately through the advisory link above and do not paste the value into an issue.
