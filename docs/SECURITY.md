# KRAN - Security baseline

This document describes how the system is built to resist misuse, what it does not protect
against, and what an engineer must check before changing a security-relevant path. It is an
engineering baseline, not a certificate and not a marketing statement. It does not claim
conformance with any standard or regulation, and it does not replace `COMPLIANCE.md`, which
maps obligations to evidence.

Audit identifiers (`BE-SEC-*`, `BE-ISO-*`, `DB-*`, `SEC-*`, `C08`, `C09`, `C19`) refer to the
replanning audit findings. Task identifiers refer to `BACKLOG.md`.

---

## 1. How to read this document

Every control below is stated as one of:

- **Implemented**: present in code and covered by at least one test or an explicit runtime
  check.
- **Partial**: present but bounded by something named in the same paragraph.
- **Gap**: absent or defeated in a named condition. Each gap has an audit id and, where one
  exists, an owning task.

Two rules apply to any change:

1. A change touching authentication, authorization, audit, money movement or schema is a
   `HUMAN-REVIEW-REQUIRED` area and is reviewed by a clean-context reviewer (R-25). Do not
   self-approve it.
2. Reducing a control (removing a check, weakening a test, widening a linter allowlist, adding a
   bypass) requires a new owner-approved `D-xxx` entry. It is not a code-review decision.

---

## 2. Deployment shape and trust boundaries

A pilot deployment is one host:

| Component | Placement | Trust note |
|---|---|---|
| Caddy | Host, TLS termination | Serves the static SPA and proxies `/api/*` to loopback. No metrics endpoint exists; the example separate-API block refuses `/metrics`. |
| API (`kran-api --role=api`) | Container, `127.0.0.1:8095` | No direct public exposure. Trusts the proxy for transport security, not for identity. |
| Worker (`kran-api --role=worker`) | Container, same image | Consumes the outbox; no inbound socket. |
| Postgres | Container, `127.0.0.1:5432` | Same host. Intended separation: runtime role is not the schema owner (see gap G11). |
| `ctl` | Host binary | Needs DB access; used by deploy gates and operators. |
| Operator browser | Outside | Holds a session cookie. Same-origin calls only. |

The security boundary that matters most: **whoever can administer the host or the database can
read the data and can rewrite the audit chain**. The hash chain protects against application
paths and against silent row edits by a normal database user; it does not protect against a
host administrator who rewrites rows and recomputes hashes (audit `BE-SEC-12`). That is an
accepted limit, recorded in `ACCEPTED-LIMITS.md`.

The repository is public. Real host names, IP addresses, credentials and key material are not in
it; `ops/` mirrors structure and example values only.

---

## 3. Authentication and sessions

### 3.1 Passwords

**Implemented.**

- PBKDF2-HMAC-SHA256, iteration count from `platform.security.password_pbkdf2_iterations`
  (seeded at 600000; the seed itself is marked for human review, so treat the number as a
  cost setting, not a settled value), 32-byte random salt per user, no pepper.
- Minimum length and class rules from `platform.security.password_min_length` and
  `platform.security.password_min_classes`.
- History: the previous N hashes (`platform.security.password_history_count`) are checked so a
  password cannot be reused.
- Lockout: `platform.security.max_failed_logins` and `platform.security.lockout_minutes`. The
  failure counter is incremented before the key derivation, and the login guard applies a
  per-IP window plus a concurrency semaphore, so a password-spray attempt costs the server
  little.
- Enumeration resistance: an unknown account still pays a dummy hash of comparable cost, and
  the error is uniform.
- A forced password change (`must_change_password`) restricts the session to session, password
  and logout routes until the change is done.
- Changing a password revokes the user's other sessions and writes audit; the session in use
  stays valid by design.

### 3.2 Sessions

**Implemented, with limits.**

- A 256-bit random opaque token, delivered only in an `HttpOnly`, `Secure`, `SameSite=Strict`
  cookie. The database stores `SHA-256(token)`, never the token; a database read does not yield
  a usable session.
- Idle and absolute expiry are enforced server-side from
  `platform.security.session_idle_minutes` (seed 30) and
  `platform.security.session_absolute_minutes` (seed 480). Session rows carry `expires_at` and
  `absolute_expires_at` with a consistency check.
- The principal is resolved from the database on every request; roles and grants are not cached
  in the token. Revoking a role or disabling an account takes effect on the next request.
- Logout revokes the session row and clears the cookie.

Limits and gaps:

- **No client-side idle lock.** A shared teller terminal keeps member data on screen until the
  server-side idle expiry fires. R-21 requires a 15-minute client lock with a preserved draft
  and idempotency key; it is not built (audit `FE-SEC-04`, blocker B2, task T-231).
- **The session expiry hard-reloads the page.** An unposted cash form and its idempotency key
  are lost (B2, T-231).
- **CSRF relies on `SameSite=Strict` alone.** There is no `Origin`/`Referer` check, and
  bodyless POSTs need no CORS preflight; a plain HTML form can reach several state-changing
  endpoints in a same-site context (audit `BE-SEC-06`, rated MAJOR on the frontend side,
  task T-260).
- **No per-endpoint rate limiting and no JSON nesting-depth limit.** Body size is capped (Caddy
  1 MB, API parser limits) but a cheap CPU/memory denial-of-service path remains
  (`BE-SEC-05`).
- **Account lockout is itself a denial-of-service vector** against a known account name
  (`BE-SEC-07`). The alerting and unlock path (`ctl unlock-user`) exist; there is no automatic
  mitigation.

---

## 4. Authorization

### 4.1 Model

**Implemented.**

- Permissions are codes shaped `module.resource.action`. Roles are rows, and the permission
  catalogue plus system roles are created by migrations, not by ad hoc SQL.
- Every route except login, health, readiness and the WebSocket handshake requires a resolved
  principal and a permission check. Handlers that act on a specific object also check the
  object's branch (`authorizedAtBranch`).
- Branch scope is explicit on the role: `platform.role.scope` is `INSTITUTION` or `BRANCH`.
  A branch-scoped role without a branch is refused when assigned; an institution-scoped role
  with a branch is also refused.
- Realtime topics fail closed: a subscription is allowed only if the principal holds the
  matching permission on at least one branch, and events are filtered per subscription scope.
- Segregation of duties: `platform.role_conflict` holds the seeded conflicting pairs, checked
  on assignment; a conflict is refused with `sod_conflict`.

### 4.2 Maker-checker

**Partial.**

- Money and parameter operations that require two people enforce it in the domain
  (`assertDistinctActors`) and, for vault top-ups, in the database
  (`vault_topup_self_approval_chk`). The checker is a different `user_id`, and the pair is
  audited.
- Product version approval, parameter change and vault top-up are covered.
- Lending and journal-correction pairs are not ratified as a complete matrix; the draft is
  owned by the design work, not by this document.
- A distinct account is not a distinct person. The control is only real if the institution
  staffs separate operators and reviews the day's approvals; see `COMPLIANCE.md` O7.

### 4.3 User administration

**Partial.**

- Granting a role is bounded by the actor's own grants: an actor cannot grant a permission it
  does not hold (`grant_exceeds_actor`), and self-grant is refused.
- The last `platform_admin` cannot be revoked or disabled.
- **Revoke and disable are not bounded by the actor's grants** (audit `BE-SEC-03`, task T-262).
  A lower-privileged account manager can remove a more senior account. Until T-262 lands, user
  administration is a privileged, reviewed operation, not a routine one.
- There is no unified approvals view; evidence of who approved what is assembled from audit
  rows and object columns.

---

## 5. MFA: current state and accepted limit

**Partial, and deliberately optional.**

- A TOTP factor can be enrolled and verified. The parameters are
  `platform.security.mfa.enabled` and `platform.security.mfa.require_login`, both seeded
  `false`; issuer, digits, period and drift are parameters as well.
- Enabling `require_login` does **not** force a second factor for every account. An account
  without an `ACTIVE` factor still receives a full session; the condition is audited as
  `mfa_enrolment_missing` (audit `BE-SEC-02`, task T-261).
- The challenge endpoint has no attempt limiter and no recovery codes. An attacker holding the
  password can guess TOTP codes at request rate (`BE-SEC-01`, task T-261).
- Therefore the product must **not** claim "MFA required", "two-factor authentication" or
  "strong authentication" anywhere: UI, specification, sales material or audit response.
- R-19 and R-29 keep MFA optional and require the false claim to be removed, the challenge to be
  throttled, and compensating controls to be named. T-261 implements the throttle and the
  factorless-account policy; the claim is removed from this rebuild.

Compensating controls, which the institution must actually operate:

1. **Unique named accounts, never shared.** One account per person; `platform_admin` is sealed
   break-glass with a written procedure and a physical book.
2. **Maker-checker on money and parameters**, used with different people, reviewed daily.
3. **Daily or weekly audit review by the pengurus**, with a signed review sheet. At this
   institution size this is the highest-value compensating control.
4. **Physical controls**: locked terminal and screen, cash dual-count at open and close, locked
   cabinet for identity documents, server access limited to one person.
5. **Least privilege in practice**: the seeded `ops_admin`, `ledger_admin`, `cash_admin` and
   `teller` roles are compensating only if those accounts exist and `platform_admin` stays idle.
6. **Remote access**: if any operator reaches the system from outside the office, that path
   needs MFA at the network layer (VPN or SSO) or it should not exist.

State plainly to the pengurus, in writing: with MFA optional, a stolen password is a full
session. The fix that removes that sentence is permission-level enforcement (privileged
permissions require an active factor), not a global switch. This is recorded as an accepted
limit in `ACCEPTED-LIMITS.md`.

---

## 6. Audit trail and retention

### 6.1 Chain

**Implemented.**

- `platform.audit_log` is append-only by trigger. Each row carries `prev_hash` and a SHA-256
  hash over a canonical payload pinned to UTC, so the chain is independent of local time
  formatting.
- A `pg_advisory_xact_lock` around each insert serialises writers, which guarantees a single
  chain but caps write throughput (`BE-PERF-10`, `C09`; review task T-267).
- Verification is available as SQL (`platform.audit_verify()`) and as
  `kran-api --role=ctl verify-audit`, which exits 1 on a broken entry.
- Database privileges are the second layer: the runtime role is granted `SELECT` and `INSERT`
  on the audit table and denied `UPDATE`, `DELETE` and `TRUNCATE`. The grant set is applied by
  migration for the known append-only tables, but the role split itself is a manual setup
  procedure whose live state has not been verified (`BE-ISO-13`, finding X3). The privilege
  test (T-251) and the immutable-grant migration (T-263) close this.
- A daily anchor writes `UTC-time seq=<n> hash=<hash>` to a file on the host
  (`kran-audit-anchor.timer`, 23:50 host time). The file must be copied off the host; the timer
  does not do that.

What the chain proves: no application path and no ordinary database user changed or deleted an
audit row without detection. What it does not prove: that a host administrator did not rewrite
rows and recompute the chain. The chain is computed inside the database, and the anchor starts
on the same host (`BE-SEC-12`, R-20). R-26 therefore requires a manual daily head-hash copy plus
a written disclosure to the pengurus and the auditor. A statement that the anchor is automated
off-host is false.

Investigation is also limited: the audit viewer shows a short unfiltered list and raw actor
UUIDs; `/audit` has no cursor (audit `FE-EFF-11`, `C18`). Finding a member's history requires
SQL. That is a reporting gap, not a chain-integrity gap.

### 6.2 Retention

**Undecided in code, ruled in principle.**

- R-20 requires retention to be defined; R-26 requires it per record class, with a manual daily
  head-hash copy and a written disclosure, and defers automated off-host anchoring.
- No purge exists for `platform.audit_log`, `platform.outbox` or `platform.inbox` today
  (`BE-ISO-12`, `C09`). The only retention jobs are the session purge and the idempotency TTL
  (24 hours default, hard cap 30 days, and the stored response can contain member data).
- The per-class retention task is T-248; the manual head-hash copy is T-249. Until both land, do
  not tell an auditor that a retention period is enforced.
- The audit chain must never be shorter than the financial postings it explains. `journal` and
  `journal_line` are immutable and have no purge path.

### 6.3 What must not be done

- Do not disable the audit triggers, edit audit rows, or rebuild the chain on a live database.
  A broken chain is preserved and escalated to the owner.
- Do not run `TRUNCATE` on audit, journal or outbox tables as a maintenance shortcut.
- Do not delete the anchor file or leave it as the only copy on the host.

---

## 7. Cryptography and data protection

### 7.1 Field-level encryption

**Implemented; rotation blocked.**

- Identity document numbers are stored as ciphertext: AES-256-GCM with a per-table DEK derived
  from the KEK, and the table name as AAD. Format and key derivation are documented in
  `OPERATIONS.md` section 6.1 and in `adr/017-field-level-encryption.md`.
- Equality search uses a blind index (HMAC of the normalised digits). There is no range or
  substring search on encrypted values, by design.
- The KEK file is outside the repo, mode 600, mounted read-only into the containers. A missing,
  corrupt or over-permissive key file refuses startup; an unset key file lets the application
  start but every encrypt/decrypt call fails explicitly.
- Values are masked by default in list and detail responses. Unmasking needs a distinct
  permission, a reason, and writes an audit row that does not contain the value.
- **KEK rotation is prohibited while identity data exists**, because there is no blind-index
  reindex command. Rotating anyway silently breaks duplicate-NIK detection
  (`ACCEPTED-LIMITS.md`, `OPERATIONS.md` section 6.2).
- Losing the KEK file makes the encrypted columns unreadable. There is no recovery path; the KEK
  must be backed up separately from the database, encrypted or offline.

### 7.2 Transport

- TLS terminates at Caddy. HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`
  and a `frame-ancestors 'none'` CSP header are set; the full CSP comes from the build-time
  meta policy with hashes. Do not add `script-src` to the header: two CSPs intersect and the
  page stops hydrating.
- The API listens on loopback only and is reached through the proxy. There is no CORS policy
  because the browser uses one origin.
- The API connects to Postgres without TLS. Database and application share the host, so the
  connection does not cross a network boundary; this is a documented deployment assumption, not
  a transport control (`BE-SEC-13`). Moving the database off-host requires TLS and a review.

### 7.3 Logs and error bodies

**Implemented, with two leaks fixed by review.**

- Logs are JSON lines with a sensitive-key mask and a request correlation id taken from a
  sanitised header. Identity values, passwords and tokens are not logged.
- Audit rows record the action, actor, resource and reason, not the secret value.
- Gaps: `/readyz` exposes check details without authentication (`BE-SEC-10`); a 500 body can
  echo configuration text (`BE-SEC-11`, task T-185); the `ctl` password reset path prints the
  password to stdout by design, so the operator must protect the terminal (`BE-SEC-17`).
- Idempotency responses may contain member data for up to the TTL; see the accepted limit and do
  not raise the cap.

---

## 8. Secrets

### 8.1 Rules

- Real secrets never enter git. Only `*.env.example` templates are tracked, with placeholders.
  `.local/` and `*.env` are ignored, as are key and certificate file patterns.
- A secret is passed through a mode-600 file or stdin, never as a command argument (`ps` shows
  arguments).
- The webhook accepts only `push` events, verifies HMAC-SHA256, checks the repository name, and
  uses a secret generated on the server. The deploy key is read-only.
- The KEK is never in the image, the repo, or a database dump.
- Locations and rotation steps are in `OPERATIONS.md` section 6.

### 8.2 Scanning

- `gitleaks` runs per push in the `security` job and weekly over the full history in a separate
  workflow.
- The allowlist in `.gitleaks.toml` is narrow and each entry needs a written reason. Widening it
  to make a scan pass is gate weakening; change the value instead.
- The history contains one old test string that resembles a credential (`SEC-05`). It is not a
  secret: it was a test fixture, and the fixture text was changed at the source. Full-history
  scans may still report it until the narrow allowlist entry is accepted; do not paste the
  string into an issue.

### 8.3 Handling a suspected leak

1. Do not paste the value anywhere. Note the file, commit and variable name.
2. Rotate the credential (DB password, webhook secret, deploy key, CI token) using
   `OPERATIONS.md`; rotate the KEK only if encrypted data is not yet in use, because rotation is
   blocked otherwise.
3. Report privately (section 12). If the value is in git history, decide with the owner whether
   to rewrite history; deleting the file does not remove the blob.

---

## 9. Dependencies and supply chain

**Implemented policy; partial tooling.**

- Nim dependency versions are pinned in `kran.nimble`; Node dependency versions are pinned
  exactly in `package.json` and locked in `pnpm-lock.yaml`, installed with
  `--frozen-lockfile`.
- The API base image is pinned by digest, the Nim toolchain archive is verified by SHA-256, and
  the pnpm configuration sets a minimum release age and denies install scripts for named
  packages.
- There is **no dependency CVE scan** yet (audit `BE-ISO-10`, `BE-SEC-15`, `FE-SEC-06`; task
  T-177). A vulnerable transitive package is found by reading release notes, not by CI.
- There is **no Nim lockfile**, so two builds of the same commit can embed different transitive
  revisions (`BE-ISO-11`). Recorded as an accepted limit.
- GitHub Actions are pinned to major tags, not commit SHAs (`SEC-06`). That is a supply-chain
  exposure; pinning to SHAs is a workflow change with its own review.
- Policy: a new dependency or a new scanner needs a short ADR. Do not add a tool that cannot run
  offline in CI, and do not make an advisory-only scan a deploy gate without deciding what a
  red result means.

---

## 10. Verification and change control

### 10.1 Gates

| Gate | Covers |
|---|---|
| `./task check` | Format, lint, architecture rules, magic-number rules, parameter generation, i18n, version consistency |
| `./task check-fast` | The same without the full `nim check` pass |
| `./task ci-fast` | `check`, OpenAPI, web lint, backend tests; web typecheck and unit tests are added in P0 |
| `./task ci` | `ci-fast` plus e2e, axe in two themes and locales, visual baseline on Linux |
| `./task traceability` | Every `active` requirement in `compliance/register.yaml` has a control and a matching test name |
| Deploy CI gate | The four named check-runs must be green for the deployed SHA |

### 10.2 What the gates cannot see

Stated because a green gate is often read as a security statement:

- `archcheck` and `lint-nomagic` cover `modules/`, not `apps/api/src`, until P0. The HTTP
  layer holds money code that no structural gate inspects (`C01`, `C06`).
- `ci-fast` does not typecheck `apps/web` or run its unit tests until P0; `svelte-check
  --fail-on-warnings` runs only inside `e2e`.
- `nim check` warnings are discarded on success, so a new warning does not fail the build.
- No test asserts query counts, dependency versions, bundle size or database privileges.
- The append-only guarantee after a fresh deploy is trigger-only until the privilege test
  (T-251) and grant migration (T-263) land.
- No request-level security test suite exists: there is no automated CSRF, rate-limit or
  authorization-matrix test.

### 10.3 Review classes

R-25 narrows mandatory clean-context review to money, schema/migrations, authorization and
audit changes, capped at two rounds. Those changes are also `HUMAN-REVIEW-REQUIRED` where they
cannot be proven by a test: interest/accrual/PPAP/SHU/tax formulas, reconciliation, encryption
and key management, authorization rules, and the audit chain. Other changes use self-review
plus the gates.

---

## 11. Known gaps

Severity reflects security impact, not the audit's original severity.

| ID | Severity | Gap | Audit / task |
|---|---|---|---|
| G1 | MAJOR | MFA challenge has no attempt limiter and no recovery codes | `BE-SEC-01`, T-261 |
| G2 | MAJOR | `require_login` does not challenge accounts without an `ACTIVE` factor | `BE-SEC-02`, T-261 |
| G3 | MAJOR | Revoke and disable are not bounded by the actor's grants | `BE-SEC-03`, T-262 |
| G4 | MAJOR | CSRF for bodyless POSTs relies on `SameSite` only | `BE-SEC-06`, T-260 |
| G5 | MAJOR | No dependency CVE scanning; no Nim lockfile | `BE-ISO-10`, `BE-SEC-15`, T-177 |
| G6 | MAJOR | Backups are unencrypted and on the same host; no PITR | `BE-ISO-05`, T-252 |
| G7 | MAJOR | Audit/outbox/inbox retention is undefined and unenforced | `BE-ISO-12`, T-248 |
| G8 | MAJOR | Anchor is host-local; chain is computed in the database | `BE-SEC-12`, R-26, T-249 |
| G9 | MAJOR | Consent, data-subject export and breach workflow do not exist | `BE-ISO-15`, `NEEDS-COMPLIANCE-REVIEW` |
| G10 | MAJOR | Worker ignores SIGTERM; in-flight batch killed at stop | `BE-ISO-03` |
| G11 | MINOR | Runtime-role privilege state is unverified; grants are a runbook step | `BE-ISO-13`, X3, T-251, T-263 |
| G12 | MINOR | No deadlock/serialization retry at the transaction boundary | `BE-ISO-08` |
| G13 | MINOR | `/readyz` check detail is unauthenticated | `BE-SEC-10` |
| G14 | MINOR | 500 bodies can echo configuration text | `BE-SEC-11`, T-185 |
| G15 | MINOR | Actions pinned to major tags, not SHAs | `SEC-06` |
| G16 | MINOR | No per-endpoint rate limits or JSON depth limit | `BE-SEC-05` |
| G17 | MINOR | Account lockout can be used to deny access to a known account | `BE-SEC-07` |

Accepted limits that are **not** gaps to be re-reported: optional MFA (R-19/R-29), host-local
anchor (R-20/R-26), single-instance deployment, no metrics before P7, KEK rotation blocked, and
the non-reproducible Nim build. See `ACCEPTED-LIMITS.md` for impact, detection and owner per
row.

---

## 12. Reporting a vulnerability

Do not open a public issue, pull request or discussion. Use the repository's private
vulnerability reporting: GitHub Security tab, "Report a vulnerability"
(`https://github.com/nferdazel/kran/security/advisories/new`). The policy, in-scope component
list and out-of-scope items are in the root `SECURITY.md`; that file remains the entry point.

A useful report includes the version (`./task version`) or commit, the component (module,
endpoint, CLI role, deploy script), a reproduction against your own instance with synthetic
data, the impact you believe it has, and a suggested fix if you have one. Do not include real
credentials, personal data, or a dump from a live system. Do not test against the production
deployment.

The repository is maintained by one person. There is no formal response SLA and no bug bounty.
Reports are acknowledged and investigated as capacity allows, and fixes are coordinated in the
advisory so the reporter has time to update before details become public. If a report concerns
the audit chain, key management or authorization, it is escalated to the owner before any code
change is proposed.
