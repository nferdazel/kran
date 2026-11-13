# DECISIONS

Living record of engineering and owner decisions for KRAN. English only (R-11).

Order of authority: owner rulings `R-xx` (section 1) outrank decisions `D-xxx` (section 2). A decision
that a ruling supersedes keeps its original text and is marked `superseded by R-xx ...` with a
pointer; it is never rewritten to look like it always meant the new thing. Proposals `P-xx` (section
4) are not in effect until the owner approves them (charter section 8).

Id policy: every `D-xxx` cited in code, tests, `task` or `tools` resolves to section 2 or section 3
of this file. Numbers are never reused or renumbered. Where an entry has no explicit date in the
source, the era label (`Fase 0`, `Fase 1`, and so on) is used instead of a guessed date.

Historical full text: `git log --follow -- docs/DECISIONS.md` (a frozen copy also exists in the
local planning archive outside the repository).

---

## 1. Owner rulings

Binding. Immutable; superseded only by a later ruling.

| ID | Date | Ruling |
|---|---|---|
| R-01 | 4 Nov 2026 | `plan/` is never tracked by git (implemented with `.git/info/exclude`). |
| R-02 | 4 Nov 2026 | Archive `docs/` to `plan/legacy-docs/`, then rebuild `docs/` clean. |
| R-03 | 4 Nov 2026 | Baseline is current `main` at `29d36c4`; replanning triggers no merge and no release. |
| R-04 | 4 Nov 2026 | Replan the whole project: Fase 0 to 4 become historical record with brief evidence, Fase 5 onward is fully replanned. |
| R-05 | 4 Nov 2026 | Replanning may propose superseding old decisions and AGENTS.md rules; only the owner approves changes. |
| R-06 | 4 Nov 2026 | Execute in waves (audit, experts, UI/UX, replan) and summarise each wave for owner correction. |
| R-07 | 4 Nov 2026 | Audits are exhaustive and deep, with file:line evidence, read-only on source. |
| R-08 | 4 Nov 2026 | Redesign deliverable is professional docs, a prototype and a full design system, per screen and per component. |
| R-09 | 4 Nov 2026 | Visual identity may be rebuilt freely; WCAG 2.2 AA, i18n id+en and dark/light stay mandatory. |
| R-10 | 4 Nov 2026 | Banking focus is the Koperasi MVP vertical slice; BPR, BPRS and syariah are not planned now. |
| R-11 | 4 Nov 2026 | All planning and `docs/` artifacts are in English; assistant to owner chat stays Indonesian. |
| R-12 | 4 Nov 2026 | Rewrite the PRD/TECHSPEC from scratch as part of the `docs/` rebuild. |
| R-13 | 4 Nov 2026 | The Fase 5 proposal is cancelled and becomes audit input only. |
| R-14 | 4 Nov 2026 | The UI prototype is HTML/CSS plus design tokens under `plan/design/` (no Figma MCP in this session). |
| R-15 | 4 Nov 2026 | Membership is a first-class aggregate in a new `coop` module: member number, status, join/exit, simpanan pokok/wajib obligation. |
| R-16 | 4 Nov 2026 | Time deposits are out of the MVP; savings return is SHU-based, not interest. |
| R-17 | 4 Nov 2026 | Lending runs on least-privilege `lending_maker`/`lending_checker`; no `platform_admin`-for-everything pilot. |
| R-18 | 4 Nov 2026 | Use cases move into `modules/*/application` before new MVP features; the handler layer is not ratified as the application layer. |
| R-19 | 4 Nov 2026 | MFA stays optional; the false "MFA required" claim is corrected and the risk recorded as an accepted limit. |
| R-20 | 4 Nov 2026 | Define audit/outbox retention; the hash-chain anchor stays on the host, off-host anchoring is explicitly deferred. |
| R-21 | 4 Nov 2026 | Teller terminal has a 15-minute client lock; draft and idempotency key survive re-authentication. |
| R-22 | 4 Nov 2026 | Printed slip/statement carries member identity, cashier, institution header, timestamp and timezone; exact fields are `NEEDS-COMPLIANCE-REVIEW`. |
| R-23 | 4 Nov 2026 | The pilot has two or more operators without server access, so user administration and the arrears view stay BLOCKER. |
| R-24 | 4 Nov 2026 | R-18 is per module: new modules build in `application/` from day one, legacy modules are extracted when touched, and the archcheck baseline may only shrink. |
| R-25 | 4 Nov 2026 | Review is narrowed to money, schema/migrations, authz and audit changes, capped at two rounds; other changes use self-review plus gates. Supersedes AGENTS.md section 4.7. |
| R-26 | 4 Nov 2026 | Retention is defined per record class; a manual daily head-hash copy plus written disclosure is the anchor minimum. Automated off-host anchoring stays deferred (amends R-20). |
| R-27 | 4 Nov 2026 | SHU basis is signed before P3 exit; calculation is automated, distribution is a checker-approved manual journal with a mandatory RAT decision record. |
| R-28 | 4 Nov 2026 | MVP report pack is the RAT set; health ratios, DPK and branch P&L are deferred with tags. |
| R-29 | 4 Nov 2026 | MFA stays optional (R-19 upheld); false claims are removed, the challenge is throttled, and compensating controls are named. |
| R-30 | 4 Nov 2026 | A second worker covers `apps/web`; web work may overlap backend work. Migrations, `kran_test`, gates and parameter seeds stay serial. |
| R-31 | 5 Nov 2026 | One risk vocabulary: `full` covers money, schema or migration, authz and audit; `standard` covers the rest. The task file names the concrete class. |
| R-32 | 5 Nov 2026 | A task is `READY` only when its task file exists and every DoR item is filled. The queue never marks a row `READY` from the plan table alone. |
| R-33 | 5 Nov 2026 | Every phase-exit gate fails when a named check is skipped: missing tooling, missing database, zero tests or an absent axe run is a failure, not a pass. |
| R-34 | 5 Nov 2026 | Cash instalment is in the MVP: one atomic contract posts the loan payment, the cash movement and the teller session effect. |
| R-35 | 5 Nov 2026 | SHU distribution posts per member (savings credit or paid receipt) and reconciles to the distribution journal. An aggregate-only journal is not acceptance. |
| R-36 | 5 Nov 2026 | Write-off allowance base is principal only. Interest and penalty are released by one explicit rule, and the reconciliation identity includes `released`. |
| R-37 | 5 Nov 2026 | Teller variance: a reason is mandatory, an approval is required above a parameterised tolerance, and EOD proceeds once the variance is posted and explained. |
| R-38 | 5 Nov 2026 | Restructure requires a checker, records the released arrears, and cannot be self-approved. |
| R-39 | 5 Nov 2026 | Backups stay local, single-host and unencrypted for the pilot (L-04). T-252 proves a restore from the local dump; an encrypted off-host copy is deferred with a trigger. |
| R-40 | 5 Nov 2026 | P6 is a serial tail after P5 for planning and dates. A second worker may overlap screens, but the critical path assumes one. |
| R-41 | 5 Nov 2026 | Design and antislop rules use the `AS-` and `DD-` prefixes. `R-` is reserved for owner rulings. |
| R-42 | 5 Nov 2026 | Credit origination controls (approval tiers, per-member exposure cap, arrears-at-origination block) are P1 scope, not deferred. |
| R-43 | 5 Nov 2026 | Membership exit includes refund computation from postings and checker approval in P3. The screen does not ship before the contract exists. |
| R-44 | 5 Nov 2026 | The RAT pack adds a cash-flow statement and notes, tagged `NEEDS-COMPLIANCE-REVIEW` until accounting sign-off. |

---

## 2. Active decisions

Full text for every decision that still constrains the code or the plan. Entries are grouped by era
so the historical order stays visible; an entry keeps its original number.

### 2.1 Foundation and delivery (Fase 0)

**D-001 (Fase 0) Single command entry point.** Decision: a POSIX `./task` script at the repo root is
the single gate entry point (`./task check`, `test`, `e2e`, `ci`). Reason: go-task and `just` were not
installed, and an installer would add tooling dependencies for simple orchestration. Consequence: every
command is written `./task ...` and the script must stay POSIX sh for dash in CI and sh on macOS.

**D-002 (Fase 0) One nimble package for the monorepo.** Decision: a single `kran.nimble` at the root,
with source directories passed with `-p:` by `./task`. Reason: a multi-package workspace adds concepts
for little value at this size; one dependency resolution means one lockfile and one nimcache.
Consequence: `nimble install -d -y` installs every dependency; module separation is enforced by
`archcheck`, not by package boundaries.

**D-003 (Fase 0) Nim dependencies pinned.** Decision: `db_connector` 0.1.0 and `yaml` 2.2.1 only; JSON,
regex and time come from the standard library and property tests use the in-repo harness. Reason: the
spec requires minimal dependencies and an ADR per dependency. Consequence: versions are pinned in
`kran.nimble`; `yaml` is used only by the build-time `tools/paramgen`, so its ecosystem risk stays out
of the API runtime.

**D-004 (13 Oct 2026) Dev and integration database on the server.** Decision: `kran_dev` plus the
`kran_dev` role live on the shared server and are reached from the laptop through an SSH tunnel
(`127.0.0.1:55432`); the URL is kept in `.local/dev.env` (mode 600, gitignored). CI does not use the
server and runs `postgres:18` as a service. Reason: the owner refused a local Postgres and the server
already had one. Consequence: integration tests skip themselves when `KRAN_DATABASE_URL` is empty, so
that run is not evidence; see D-179 for the later fail-closed behaviour.

**D-005 (Fase 0) Multi-statement SQL through `PQexec`.** Decision: `tools/dbtools` calls libpq `PQexec`
only for migration and bootstrap files; all application queries go through `db_connector`. Reason:
`PQexecParams` accepts one statement, while migration files contain many, including PL/pgSQL bodies.
Consequence: one low-level call site, confined to the migration runner.

**D-006 (Fase 0) Audit chain hash computed in the database.** Decision: trigger
`platform.audit_log_chain` fills `prev_hash` and `hash` with `pgcrypto.digest('sha256')` over a canonical
payload; the application never writes hash columns. Reason: no write path can bypass the chain and
verification does not depend on session timezone or `DateStyle`. Consequence: an advisory lock
serialises appends, which bounds audit write throughput (see accepted limits).

**D-007 (Fase 0) Dev tunnel must not die mid-session.** Decision: `tools/devdb.sh` accepts
`KRAN_DEVDB_PERSIST`, with 7200 seconds set in `.local/dev.env`. Reason: SSH `ControlPersist=600`
closed the tunnel after ten idle minutes and long test sessions failed with `Connection refused`.
Consequence: default repository behaviour is unchanged.

**D-008 (Fase 0) `SUPERSEDED` rows still answer past dates.** Decision: approval trims the old value's
`effective_to` and marks it `SUPERSEDED`, and the effective-value query includes both `ACTIVE` and
`SUPERSEDED`; the EXCLUDE constraint spans both statuses. Reason: filtering only `ACTIVE` created gaps
on historical dates. Consequence: one value per key, scope and date, and `PENDING`/`DRAFT`/`REJECTED`
never block activation.

**D-009 (Fase 0) Where paramgen seeds pack values.** Decision: `paramgen` seeds at `SEGMENT`
(`scope_id` = pack name) when the parameter allows it, otherwise at `GLOBAL`, and fails when neither
is allowed; pack values are written `ACTIVE` by two system UUIDs representing generator and reviewer.
Reason: inferring `scopes[0]` produced fake scope ids that no institution would ever match.
Consequence: a pack cannot seed `INSTITUTION`/`BRANCH`/`PRODUCT`-only parameters; that stays a human
decision.

**D-010 (Fase 0) `getRow` cannot express "not found".** Decision: modules use a `singleRow` helper over
`getAllRows` for optional single rows; `getRow` is not used in platform code. Reason: the driver returns
a row of empty columns for zero results, so `row.len == 0` is not a not-found signal. Consequence: one
small helper, documented in `MODULE.md`.

**D-011 (Fase 0) `business_date` DDL corrected.** Decision: the column is `current_business_date`, scope
uniqueness is a unique expression index `(scope_type, COALESCE(scope_id, ''))`, and `scope_id` is
`text`. Reason: `current_date` is a reserved word and Postgres rejects expressions in `PRIMARY KEY`.
Consequence: later platform tables follow the same shape.

**D-012 (Fase 0) `weekend_days` seeded at GLOBAL.** Decision: scope list is `[GLOBAL, BRANCH]`; a branch
may override, segment variation is deferred. Reason: the old `[GLOBAL, BRANCH, SEGMENT]` list made the
seed land at `SEGMENT` where ordinary reads never saw it. Consequence: calendar consumers do not need
to know the pack name.

**D-013 (Fase 0) PBKDF2-HMAC-SHA256 via nimcrypto.** Decision: iteration count comes from
`platform.security.password_pbkdf2_iterations`, parameters are stored with the hash, comparison is
constant time, and session tokens are plain SHA-256 of 256-bit random values. Reason: the standard
library has no SHA-256/HMAC, and hand-written KDFs or native dependencies were worse trade-offs.
Consequence: `HUMAN-REVIEW-REQUIRED`; independent vectors live in `tpassword.nim`.

**D-014 (Fase 0) `platform.app_user`, not `platform.user`.** Decision: the table is `app_user`; the other
section 9.2 names are unchanged. Reason: `USER` is reserved in PostgreSQL and would need quoting
everywhere. Consequence: the spec text needs the same correction.

**D-015 (Fase 0) i18n catalogue shape.** Decision: one flat file per locale with namespace-prefixed
keys, and the Paraglide plugin vendored as a dev dependency. Reason: the per-namespace file pattern
compiled to zero messages, and a CDN plugin made builds network-dependent. Consequence: namespace
discipline is enforced by `tools/i18ncheck` over key names.

**D-016 (Fase 0) Theme and language as native radio groups.** Decision: `fieldset`, `legend` and native
radios instead of `<select>`. Reason: `page.keyboard` against `<select>` did not change the value in the
headless Chromium used for verification, so keyboard-only operation could not be proven. Consequence:
one tab stop per group; a large locale list may revisit this.

**D-017 (Fase 0) `task e2e` calls local binaries.** Decision: `./task e2e` invokes
`apps/web/node_modules/.bin/*` and `packages/ui/node_modules/.bin/vitest` directly. Reason: pnpm
re-installs on lockfile drift and could hang on an unreachable private registry. Consequence: still
correct in CI after `pnpm install`. The "no JS lockfile" part is superseded by D-018.

**D-018 (Fase 0) npm registry override and JS lockfile.** Decision: installs use
`pnpm_config_registry=https://registry.npmjs.org/` for that command only, `pnpm-lock.yaml` is committed
and CI uses `--frozen-lockfile`. Reason: the user level `.npmrc` pointed at an unreachable private
registry, and `npm_config_registry` does not affect pnpm. Consequence: the runbook is required for new
contributors and new dependencies.

**D-019 (14 Oct 2026) Mummy plus WebSocket for realtime (ADR-002).** Decision: Mummy serves HTTP/REST
and WebSocket serves realtime; the SSE to WS deviation was approved and the spec updated the same day.
Reason: measured throughput was highest, Mummy handlers may block, which suits the synchronous
`db_connector`, and it has no SSE API. Consequence: the realtime endpoint stays
`GET /api/v1/events/stream` with a resume token; this answers E-001.

**D-020 (Fase 0) Contract tooling.** Decision: `openapi-typescript` 7.13.0, `openapi-fetch` 0.17.0 and
Spectral 6.17.0 with `spectral:oas`, pinned exactly; the gate is `./task openapi`. Reason: writing a
generator or linter would add a parser to maintain. Consequence: the ruleset starts strict, and any
override must carry a written reason.

**D-021 (Fase 0) Realtime signal, resume token and deny-all topics.** Decision: an `AFTER INSERT`
trigger on `platform.outbox` calls `pg_notify('kran_outbox', outbox_id)`; the envelope id and resume
token are `outbox_id`, replay order uses `seq`, and the default topic policy denies everything until
session identity exists. Reason: notifying from the dispatcher would make the UI depend on a component
that did not exist, and an unauthorised stream violates the spec. Consequence: the UI uses an
`EventSource`-like shim over WS; protocol limits are transport configuration passed as
`SubscriptionLimits`.

**D-022 (Fase 0) Two gate bugs found by T-009.** Decision: the response validator checks for a missing
`additionalProperties` key instead of dereferencing nil, and Spectral's `operation-success-response`
rule is disabled for the single `/api/v1/events/stream` operation because a WebSocket upgrade answers
101. Reason: a validator must report findings, never crash, and 101 is a successful upgrade.
Consequence: the override stays narrow and documented in `.spectral.yaml`.

**D-023 (Fase 0) Dev and e2e users through `dbtools seed --dev`.** Decision: synthetic `dev.maker` and
`dev.checker` live in a dev seed marked DEV/TEST ONLY; the dev part runs only with `--dev`. Reason:
putting known passwords in a migration would ship them to production, and injecting rows in tests would
skip login and authorisation coverage. Consequence: production bootstrap is a separate decision
(D-034/D-035).

**D-024 (Fase 0) Realtime topics follow the session, no implicit wildcard.** Decision: requested topics
map to real permissions and must be named explicitly; `*` is always denied and denials are reported in
`subscribed.denied`. Reason: expanding `*` to "everything you may read" makes a subscription depend on
time and hides what the client needs. Consequence: clients send their topic list explicitly.

**D-025 (Fase 0) One origin, proxied `/api`, no CORS.** Decision: Vite proxies `/api`, `/healthz` and
`/readyz` to the API, including WebSocket upgrade; the web app always speaks same-origin and the API
has no CORS configuration. Reason: relaxing `SameSite=Strict` would weaken CSRF defence, and CORS plus
credentials adds a second code path to test. Consequence: production uses the same shape behind Caddy.

**D-026 (Fase 0) Playwright sources `.local/dev.env`.** Decision: the API command in
`playwright.config.ts` sources `.local/dev.env` itself and execs the binary, while still inheriting the
parent environment. Reason: dyld strips `DYLD_*` across the hardened intermediate shell, so libpq was
not found even though a manual run worked. Consequence: one machine-specific shell line, justified in
the file.

**D-027 (Fase 0) Double approval and session policy candidates.** Decision: activation moved to
`activatePending` with an optimistic `AND status = 'PENDING'` guard, and
`sessionPolicyCandidateProblem` evaluates a candidate at submission (400) and approval (409).
Reason: two checkers could both "succeed", and two individually valid values could combine into a
lockout. Consequence: 409 descriptions mention `invalid_combination`; a general cross-key engine is
deferred (O-041).

**D-028 (Fase 0) Session policy on a date set plus an advisory lock.** Decision: evaluate today, the
candidate's effective date and the start dates of other approved future values; take
`pg_advisory_xact_lock(hashtext('platform.security.session_policy'))` before evaluating. Reason: future
effective dates and two-key races both bypassed a single-date check. Consequence: one extra small read
and one lock, only for this parameter pair. Rejected attempts are not audited.

**D-029 (Fase 0) Session policy date set tightened.** Decision: `committedFromDates` includes
`SUPERSEDED`; a date where the other side has no value is skipped; the evaluation scope is the
application read scope; candidate periods are respected; every fix has a test that fails when the fix
is reverted. Reason: a missing date is an undetected lockout window, and a missing successor must stay
fixable through the normal flow. Consequence: one known gap remains, an active row with `effective_to`
and no successor (O-043, later addressed by D-056).

**D-030 (Fase 0) Realtime sessions are rechecked periodically.** Decision: `sweepSessions` checks each
client every `defaultSessionRecheckSeconds = 5`, outside the hub lock, using the same principal
resolution as the handshake; an invalid session gets a `REALTIME_SESSION_ENDED` error envelope and the
socket is closed. Reason: revocation and clock expiry have no event, so polling is the only mechanism
that covers all of them. Consequence: a window of up to five seconds; topic permission changes still
wait for the next `subscribe` (O-046).

**D-031 (Fase 0) Clean shutdown on signals.** Decision: `SIGINT`/`SIGTERM` set an atomic flag, the waiter
stops the realtime pump with a two second bound and exits 0; `server.close()` is not called. Reason:
`close()` crashed in the in-process harness, and a clean stop does not need it. Consequence: in-flight
requests were truncated until drain was added (O-047); see D-101 and accepted limits.

**D-032 (Fase 0) Outbox cursor invariant and threaded tests.** Decision: a transaction that writes an
outbox event must write its audit entry first, in the same transaction, and the audit chain lock then
makes commit order follow `seq`; tests compile with `--threads:on` and a two-connection race test
exists. Reason: `seq` is allocated at insert, so a later commit could be skipped by a `seq` cursor.
Consequence: the invariant is enforced by writer discipline, tests and `MODULE.md`, not by a database
constraint.

**D-033 (Fase 0) Process role CLI contract.** Decision: `--role=migrate [--check|--up] [--root]` uses
the same `dbtools` library as `./task dbtools`; `--role=ctl` holds read-only commands; exit codes are
0 success, 1 bad result, 2 misuse, 3 recognised but not implemented. Reason: ops scripts already
depended on those calls and needed a stable contract testable without the server. Consequence: changing
these codes requires updating the ops scripts. `daycloser-status`, `worker`, `--contract` and `--down`
now exist through D-040 and D-148; the code contract is unchanged.

**D-034 (15 Oct 2026) Four owner decisions.** Decision: (1) a one-shot `bootstrap-admin` prints a random
password once and forces a change; (2) `locked`/`inactive` are revealed only after a correct password,
with a dummy PBKDF2 of equal cost for unknown accounts; (3) `requires_approval: false` is rejected by
`paramgen` until its semantics are decided (later D-042); (4) an empty scope id is explicitly
`some("")`, not "not requested". Reason: these were blocking production bootstrap, account
enumeration, parameter governance and scope resolution. Consequence: the change-password endpoint was
delivered with the same work.

**D-035 (15 Oct 2026) First admin, RBAC catalogue and forced password change.** Decision: the permission
and system role catalogue moved from a dev seed to migration `0008`; the must-change guard lives in
`requirePermission` and `sessionCanWork`; a wrong old password answers 403; changing a password revokes
other sessions but not the current one; `bootstrap-admin` refuses when an admin already exists.
Reason: production bootstrap otherwise created an admin with no permissions, and a flag can be skipped
while data state cannot. Consequence: `bootstrap-admin` is the only writing `ctl` command.

**D-037 (Fase 0) Mummy version bound and upgrade checklist.** Decision: `mummy >= 0.4.8 & < 0.5.0`,
because `events.nim` relies on cross-thread `send` and `close`; the checklist includes the WebSocket,
realtime and e2e suites plus re-reading Mummy internals. Reason: those are implementation details that
a minor upgrade can change without a compile error. Consequence: the outbound queue stays unbounded
(O-028) and cannot be inspected without using internals again.

**D-039 (15 Oct 2026) All technical identifiers use KRAN.** Decision: binaries, env prefix, NOTIFY
channel, systemd units, webhook name, npm scope, CSS classes, localStorage key, error codes and the
server app directory all use KRAN. `cbs-core` and the `cbs.qouver.com` hostname are not renamed.
Reason: doing it before any production process existed was the cheapest moment. Consequence: ops
scripts and units use `kran-*`; DNS remains an owner decision.

**D-040 (Fase 0) Two-stage migrations.** Decision: contract files carry `-- dbtools:contract <reason>`;
`--up` skips them, `--contract` applies only them, `--check` does not count them as pending, and `--down`
removes the `schema_migration` row after a successful revert. Reason: without rollout there was no
schema rollback at all, while counting contract as pending would make every later deploy fail.
Consequence: no in-database history of a reverted migration; the file pair and operator log are the
record.

**D-041 (15 Oct 2026) Typed scope lookup.** Decision: `ScopeValueLookup` returns `Option[string]`, where
`some("")` means root institution (`scope_id` NULL) and `none` means the type was not requested.
Reason: one `string` meant both things, so institution values were unreachable. Consequence: no
implicit fallback between levels was added (D-046 item 6); changing the type forced every call site to
be reviewed.

**D-042 (16 Oct 2026) `requires_approval: false` disallowed.** Decision: every parameter value change
goes through maker-checker, so `paramgen` rejects definitions with `false` (exit 2), and the predicate
is named `disallowedApprovalSemantics`. Reason: the owner chose the strict reading. Consequence: the
parser and emitter still handle `false` so the column plumbing is not deleted if a fast path is ever
approved.

**D-043 (16 Oct 2026) KRAN replaces the old containers in place.** Decision: `kran-api` takes
`127.0.0.1:8095` and `kran-web` takes `3005`, the ports the old containers held; the domain stays
`cbs.qouver.com`. Reason: the old HTTP service only answered monitoring probes. Consequence: cutover
means swapping the Caddy upstream; old images, the old app directory and the `cbs` database were kept
as rollback.

**D-044 (16 Oct 2026) Proprietary license, public repository.** Decision: the repo stays public and
`LICENSE` is proprietary/all rights reserved; reading and auditing are allowed, reuse is not. Push to
`main` is allowed through the deploy hook, other branches remain rejected by the ref guard. Reason:
permissive licensing would let anyone resell the product, and the default without a license is already
all rights reserved. Consequence: the Nimble `license` field states Proprietary; changing the license
means changing one file.

**D-045 (16 Oct 2026) CSP from a meta hash, header only `frame-ancestors`.** Decision: SvelteKit emits
`csp: { mode: "hash" }` into a `meta` tag and Caddy sends only `frame-ancestors 'none'`. Reason: two
policies intersect, and a header `script-src` without the per-build hash would block hydration.
Consequence: `style-src` still allows `unsafe-inline` because Svelte injects styles at runtime.

**D-046 (16 Oct 2026) Owner decision batch.** Decision: (1) unverified section 4 values stay tagged and
compliance review precedes dependent features; (2) pilot is one cooperative, one branch, under 5,000
members; (3) the old `cbs` data is synthetic; (4) the backup filter excludes non-production databases;
(5) old containers were removed with images and data kept; (6) no silent parameter fallback between
levels; (7) GLOBAL parameters are always visible and cross-branch reads are audited; (8) `effective_to`
requires a successor; (9) old-password failures are audited and limited, history is five, no expiry;
(10) MFA stays off by default with a framework only; (11) the SoD matrix waits for compliance;
(12) the KEK stays a separate mode 600 file; (13) ADR-002 is closed with Mummy. Reason: these items
needed a human decision, not more code. Consequence: D-047 onward implement the parameter and password
items; `mfa.enabled=false` is a written risk acceptance, not a compliance claim.

**D-047 (16 Oct 2026) Candidates only for readable scopes.** Decision: a submitter may only propose a
value for a scope the submitter may read, using the same rule as parameter visibility. Reason: two
rules for read and write are harder to audit than one. Consequence: the permission test must cover
submission, not only reading.

**D-048 (Fase 0) Field encryption envelope and blind index (ADR-017).** Decision: KEK in a separate mode
600 file, per-table DEK derived with HMAC-SHA256, AES-256-GCM ciphertext `kran:enc:v1:<kid>:<nonce>:...`
with the table name as AAD, and a separately keyed blind index. Reason: no key material in database
dumps and no new dependency. Consequence: KEK rotation re-encrypts everything and invalidates blind
indexes; losing the KEK loses the data; `HUMAN-REVIEW-REQUIRED`.

**D-049 (Fase 0) Login link in the header.** Decision: a static `Masuk` link to `/login` is the second
header nav item and `keyboard.spec.ts` locks the new tab order; no logout link in the header. Reason: a
static link does not force every page to read the session. Consequence: the link is visible when already
signed in; `/login` handles that.

**D-051 (Fase 0) shellcheck warning blocks, and a DB test job.** Decision: `shellcheck -S warning`
blocks and is fail-closed when the tool is missing (escape hatch `KRAN_SKIP_SHELLCHECK=1`); CI gets a
`db-tests` job with `postgres:18`, migrations, seed and `./task test`. Reason: reported-only warnings
and integration tests that never ran were two forms of false green. Consequence: database names in CI
must end in `_test` or `_dev`.

**D-052 (Fase 0) Parameters read per request, no cross-process cache.** Decision: `settingsOf` reads six
single rows per auth request; no cache is built. Revisit only if one measured trigger is hit: more than
10 percent of p95 database time, more than 50 auth requests per second per process, more than one API
replica, or more than 10 parameters per request. Reason: `NOTIFY` is not guaranteed delivery and an
untimed cache would serve stale security values without an error. Consequence: O-018 is closed as a
decision; the unused `param_cache` remains test-only until P2.

**D-053 (17 Oct 2026) `svelte-check` warnings block; ESLint deferred.** Decision: `./task e2e` uses
`svelte-check --fail-on-warnings`, and ESLint was not added at that time. Reason: the a11y rules mostly
duplicate compiler diagnostics, and the real gap was that warnings never blocked. Consequence: the axe
threshold was not changed. Part (b) is superseded by D-139, which installs ESLint.

**D-054 (Fase 0) Append-only audit assertions use `.first()`.** Decision: the e2e assertion tolerates
duplicate audit rows across runs while still requiring the row to be visible. Reason: the audit log is
append-only by design, so clearing old rows is forbidden. Consequence: e2e can run repeatedly on a
developer machine; no assertion or threshold was removed.

**D-055 (Fase 0) Parameter visibility per scope and submission authority.** Decision: the grant to scope
rule lives once in `readableScopeFilter`; filtering happens in SQL before `LIMIT`; GLOBAL is visible to
any holder of the read permission, INSTITUTION only to grants without a branch limit, BRANCH only for
covered branches, and PRODUCT/SEGMENT/ROLE fail closed; submission checks `mayReadScope` first and
answers 403; each cross-branch read writes `param.read_cross_branch`. Reason: a second rule for writes
and post-limit filtering both leak or hide rows. Consequence: the fail-closed membership decision is
`HUMAN-REVIEW-REQUIRED`.

**D-056 (Fase 0) `effectiveTo` without a successor is rejected at both doors.** Decision: a successor is
another row on the same key and scope, in `ACTIVE`, `SUPERSEDED` or `PENDING`, starting at or after the
candidate's start and effective on its end date; the check runs at submission (400) and approval (409)
through one function. Reason: a successor can disappear between the two steps. Consequence: a value
cannot yet be ended without a successor (O-064 later added the explicit end path); the startup check is
the backstop.

**D-057 (Fase 0) Old-password failures counted and audited.** Decision: `changePassword` increments the
same failure counter as login, using the existing `max_failed_logins` and `lockout_minutes`, and writes
`user.password_change.failure` without password material. Reason: a holder of a valid session must not
be able to guess the old password without limit, and a second policy would be another surface to keep
in sync. Consequence: the account can lock; the current session is not revoked on failure.

**D-058 (Fase 0) Password classes and history as parameters, no expiry.** Decision:
`password_min_classes` (base 3) and `password_history_count` (base 5) are parameters; superseded hashes
live in `platform.user_password_history` and are pruned on write; expiry is not built. Reason: the
owner asked for parameterised quality and a history window, not rotation. Consequence:
`HUMAN-REVIEW-REQUIRED`; new parameters must be seeded before the code runs (O-066).

**D-059 (17 Oct 2026) Branch scoping enabled on the HTTP path.** Decision: branch-only grants start to
work on HTTP, audit rows from HTTP start carrying `branch_id`, and the plan must state per endpoint
which branch is the target and where attribution comes from. Reason: activating later would change
authorisation after data and habits existed. Consequence: a deliberate behaviour change, delivered as
its own task, `HUMAN-REVIEW-REQUIRED`.

**D-061 (17 Oct 2026) Audit verification follows `prev_hash`, not `seq` order.** Decision: `link_ok`
means `prev_hash` is the genesis sentinel or another row has that hash, plus a check that no other row
shares the same `prev_hash`, with supporting indexes. Reason: `seq` is allocated before the chain lock,
so a valid chain can commit out of `seq` order. Consequence: the old corruption tests still fail as
before; branching is detected; a whole-tail rewrite is only detectable through the anchor (D-108).

**D-062 (19 Oct 2026) Two levels of HTTP permission gate and audit branch attribution.** Decision: list
routes use `authorizeAnyBranch` and filter per row; single-object routes add `authorizedAtBranch`; audit
branch attribution comes from the object touched, not the actor's home branch; non-UUID ids are not
cast into a UUID column. Reason: one branch cannot represent a list request, and an auditor cares about
the branch of the row. Consequence: `branch_not_allowed` appears on 403 for submit and approve;
non-UUID branch ids stay unattributed (O-017).

**D-063 (19 Oct 2026) MFA TOTP framework, not activated.** Decision: TOTP RFC 6238 with RFC test vectors,
an encrypted 160-bit secret in `platform.user_mfa`, per-row digits and period, anti-replay step, five
GLOBAL parameters with `enabled` false, and three self-service routes; the login flow is unchanged.
Reason: the owner wanted the framework prepared without enabling it. Consequence: routes answer 403
`mfa_disabled` while the feature is off; removal and recovery are O-071; `HUMAN-REVIEW-REQUIRED`.

**D-064 (Fase 0) Connections through conninfo with a timeout and keepalive.** Decision: `pqconnectdb` with
`connect_timeout` from `KRAN_DB_CONNECT_TIMEOUT_MS` and explicit TCP keepalive; error shape unchanged.
Reason: `pqsetdbLogin` had no client timeout, so a peer that accepted TCP and stayed silent blocked
`acquire` without bound. Consequence: a query on a live connection through a frozen middlebox still
needed D-065.

**D-065 (Fase 0) Database work deadline via a socket monitor.** Decision: one monitor thread tracks
`(fd, deadline)` per work block and shuts the socket down when the deadline passes; the bound covers
`withConn`/`withTx` as one block; a timed-out connection is discarded; `KRAN_DB_QUERY_DEADLINE_MS`
defaults to `statement_timeout + 5000` and must exceed `statement_timeout`. Reason: `statement_timeout`
cannot help when the query never reaches the server. Consequence: effective bound is about 20 seconds,
not 5; long use cases must fit or raise the value.

**D-066 (19 Oct 2026) API and worker run as quadlet containers.** Decision: one image, two roles via
`--role`, units in `ops/systemd`, deployed with `cmp`, `.prev` and restore, native units with the same
name are refused, the host binary remains for freeze and migration gates, only `modules/` is mounted,
the container binds `0.0.0.0`, and rollback restores `:prev`, units and binary. Reason: operation
should match the other services on the host, and a same-named native unit silently wins over a quadlet.
Consequence: spec section 21.5 changes; `is-enabled` reports `generated`, which is normal.

**D-067 (Fase 1) CIF pattern is a parameter, the check digit is code.** Decision: `party.cif.format` holds
literals and `{seq:N}`/`{check}`, while Luhn mod 10 lives in `domain/cif.nim`; a bad configuration is a
500, not a 400. Reason: storing an algorithm in a parameter would be storing code in the database.
Consequence: changing the algorithm needs code and an ADR; CIF numbers may have gaps.

**D-069 (Fase 1) Identity documents: ciphertext, blind index and masked form.** Decision:
`party.identity_doc` stores `number_enc`, `number_bidx` (HMAC, hex 64) and `number_last2`; numbers are
normalised before hashing; uniqueness is per document type; unmasking is a separate endpoint with
`party.identity_doc.read`, a mandatory reason and audit; without a KEK the endpoint answers 501.
Reason: search and duplicate detection must work without storing plaintext. Consequence: KEK rotation
must precede blind-index reindexing (O-073, D-111); `HUMAN-REVIEW-REQUIRED`.

**D-070 (Fase 1) COA and periods.** Decision: `ledger.coa.code_pattern` is a parameter matched against the
whole code; normal side is code by account type and enforced by CHECK; periods are inclusive ranges
with a GiST EXCLUDE constraint; the base COA arrives through an idempotent migration, tagged
`NEEDS-COMPLIANCE-REVIEW`. Reason: normal side is an accounting invariant, not a business value, and a
dev seed never reaches production. Consequence: changing the pattern affects new accounts only; COA
and period actions are institution actions with two gates.

**D-071 (20 Oct 2026) Standing owner permissions.** Decision: migrations may always be executed with the
existing safety rules, pushes are allowed but batched, and independent tasks may run in parallel while
tasks sharing hot files stay serial. Reason: the owner wanted the loop to stop waiting for obvious
confirmations. Consequence: independent review stays required before `DONE`. Push and parallelism parts
are superseded by D-198 (push only through release) and R-30 (second worker, serial database work); the
migration permission stands.

**D-072 (Fase 1) Journals unpartitioned in Fase 1.** Decision: `ledger.journal` is a plain table at pilot
volume; partitioning is a later expand/contract migration. Reason: pilot volume does not need it, and
partitions complicate foreign keys and deferred balance triggers. Consequence: partition and archive
must be revisited before any high-volume deployment; `journal_business_date_idx` already supports
date queries.

**D-073 (Fase 1) Posting rules as data plus a ledger outbox consumer.** Decision: mapping lives in
`ledger.posting_rule`/`posting_rule_line`; the most specific rule wins, ties go to the lowest
`priority`, and a remaining tie becomes visible failure (`DEAD`), not a silent pick; accounting events
carry an `accounting: true` header; idempotency uses `platform.inbox` plus
`journal.idempotency_key = outbox:<eventId>`; a batch lease lets another worker reclaim stuck events.
Reason: business modules must not write journals, and redelivery must not duplicate them. Consequence:
rule changes still go through migrations (O-080); an event without a rule becomes `DEAD`.

**D-074 (Fase 1) Trial balance from journals; snapshot is only a cache.** Decision: trial balance reads
`journal_line` for the period; `ledger.balance_snapshot` is written only by
`rebuild_balance_snapshot(as_of)`. Reason: reports must not depend on a stale cache. Consequence: cost
grows with period volume; the snapshot may be read only after a reconciled close.

**D-076 (Fase 1) Product table and version semantics.** Decision: identity lives in `product`, versions in
`product_version` with inclusive ranges and an EXCLUDE constraint; versions are immutable; attributes
are parameter bindings, sealed per version and a full snapshot (no inheritance); permission
`product.catalog.read|manage`; `ProductPublished` per version. Reason: corrections must be a new
version, not an edit. Consequence: maker-checker and DRAFT status arrived later (D-099/D-119).

**D-077 (20 Oct 2026) Fast lane for the development loop.** Decision: `./task verify` and `./task
check-fast` exist for the daily loop; `./task check` keeps full `nim check`; `nim check` runs in
parallel shards (`KRAN_LINT_JOBS`); test filtering prefers an exact file name. Reason: the full gate was
too slow for every iteration while the final gate had to stay whole. Consequence: Definition of Done is
unchanged; `./task ci` must still be green before `DONE`.

### 2.2 Ledger, deposit, teller (Fase 1 and Fase 2)

**D-091 (Fase 1) Period close locks the period row.** Decision: the journal trigger takes `SELECT ... FOR
SHARE` on the period row and close uses `FOR NO KEY UPDATE`, so posting waits and then sees `CLOSED`.
Reason: reading status alone let a posting commit into a period closed by an uncommitted transaction.
Consequence: one lock per journal until commit; lock order is period then audit.

**D-092 (Fase 1) Base parameter seed runs in the migration path.** Decision: `--role=migrate --seed`
applies generated pack SQL and deploy calls it after swapping the binary and before restarting units.
Reason: the worker exited when posting parameters were absent, and the deploy looked successful.
Consequence: a conflicting generated seed fails the deploy closed; the seed does not prove the worker
is healthy.

**D-093 (Fase 1) Cheap KDF in tests only.** Decision: dev and test seeds use 1000 PBKDF2 iterations and
password-changing suites lower the parameter to 1000 in the test database; production stays at 600,000.
Reason: login verification alone made two suites take 170 and 49 seconds. Consequence: production
policy is unchanged and KDF cost is tested separately.

**D-094 (Fase 1) Accrual parameter shape without values.** Decision: five keys
(`interest_rate`, `day_count_basis`, `rounding_mode`, `rounding_scale`, `interest_posting`) are defined
with no `default_pack`, tagged `NEEDS-COMPLIANCE-REVIEW`. Reason: adding keys later would force a new
product version, and a default would be an unapproved rate. Consequence: reading them fails fast until
a product version binds them.

**D-095 (Fase 1) Seed base classification.** Decision: every seeded value has a class: technical,
internal policy, commercial-conservative, no-meaning-yet, or regulation-not-seeded. Reason: the pilot
had to run on explicit provenance rather than prose. Consequence: rate, ratio, tax, PPAP and LPS keys
are not seeded; `mfa.enabled=false` is a written risk acceptance.

**D-096 (Fase 1) GL balances are a separate report; trial balance stays movements.** Decision:
`GET /ledger/balances?periodId=` returns opening, period and closing debit/credit per account in one
query, with `source` and `computedAt`; the snapshot is used only for a closed, reconciled period.
Reason: a balance column on the trial balance mixes movement and position. Consequence: teller balances
remain a deposit concern, not GL.

**D-098 (Fase 1) Idempotency on object-creating endpoints.** Decision: `Idempotency-Key` is mandatory on
business object POSTs, starting with parties, risk rating, parameter submit and teller money endpoints;
rows are written in the business transaction; same key and hash replays 200 with
`Idempotent-Replayed`, a different hash or operation is 409, an unfinished row is 409 with
`Retry-After`; 5xx rolls back. Reason: a generic middleware cannot distinguish login, MFA and logout or
avoid storing error responses. Consequence: see D-117 for concurrent duplicates; see D-175 for
retention.

**D-099 (Fase 1) Product maker-checker.** Decision: `product_version` gets `DRAFT|ACTIVE`, maker,
checker and timestamps; bindings seal at approval; `ProductPublished` fires on approval; self-approval
is rejected by a CHECK; permission `product.catalog.approve`. Reason: catalogue changes must have four
eyes. Consequence: a single-operator pilot is blocked until a second approver exists. Amended by D-119
(adds `REJECTED`).

**D-100 (Fase 1) Password reset through `ctl reset-password`.** Decision: the command generates a random
password with the production iteration parameter, forces a change, clears lockout, revokes all
sessions, writes `user.password_reset` in the same transaction, and prints the password once. Reason: a
manual SQL update would bypass audit, session revocation and policy. Consequence: operator with server
access can reset any known username; the audit actor is the system.

**D-101 (Fase 1) Worker health through a heartbeat.** Decision: the worker writes
`platform.worker_heartbeat` at most every 15 seconds, at the start of a loop and between events in a
batch; `/readyz` fails when the heartbeat is older than 180 seconds or never arrived after a 180 second
grace period, and reports `DEAD` count in detail without failing readiness. Reason: backlog length
neither proves life nor death. Consequence: a fast crash-loop that writes a heartbeat can still look
healthy; external alerting is a separate item.

**D-102 (Fase 1) Stress test wait budget follows the test's purpose.** Decision: the pool stress test
waits up to 60 seconds per acquisition; assertions and iteration counts are unchanged. Reason: the
15 second bound was measuring tunnel latency, not a pool leak. Consequence: a future timeout must be
investigated as a leak or dead connection, not silenced by raising the bound again.

**D-103 (Fase 1) Branch ids are UUIDs; `scope_id` stays text.** Decision: application-created branch ids
are UUIDs, while generic `platform.*.scope_id` stays `text`; handlers parse UUIDs before writing.
Reason: scope is a generic pair, not a foreign key. Consequence: non-UUID test fixtures remain valid as
fixtures only; audit already requires UUID.

**D-104 (Fase 1) Reversal into a closed period is rejected.** Decision: corrections are made with an
adjusting or reversing journal in the current period, with a reference to the original, a reason and
audit. Reason: reversing in a closed period would breach immutability and change reported figures.
Consequence: cross-period correction stays a recorded manual procedure.

**D-105 (Fase 1) Reversal rejected when the source account is inactive.** Decision: the trigger keeps
requiring `postable AND ACTIVE` for reversal lines too. Reason: fail-closed is the safe reading.
Consequence: operations must not deactivate an account still referenced by journals.

**D-106 (Fase 1) Contra accounts deferred.** Decision: the COA uses the normal side implied by account
type; contra accounts are not modelled and must not be forced into LIABILITY. Reason: no product or
accounting requirement existed, and REG-011 is unresolved. Consequence: superseded by D-193, which
confirms CKPN stays on a credited asset account.

**D-107 (Fase 1) Posting rule changes through migrations.** Decision: there is no write API for posting
rules; changes go through reviewed migrations or seeds. Reason: no multi-product need existed and a
write API needs maker-checker and effective dating first. Consequence: every mapping change is a repo
change plus deploy.

**D-108 (Fase 1) Daily audit anchor through `ctl audit-anchor`.** Decision: the command prints
`time seq hash` of the chain head and optionally appends it to a file outside the database; verification
means `ctl verify-audit` plus matching the anchored head. Reason: without an anchor a whole-tail rewrite
is undetectable. Consequence: scheduling and off-host copies are host actions; see R-26.

**D-109 (Fase 1) Parameter rejection endpoint.** Decision: `POST /params/changes/{id}/reject` by a
checker changes `PENDING` to `REJECTED`, requires a reason of at most 500 characters, and writes audit
plus event in one transaction; a second rejection is 409. Reason: a wrong submission must not be left
pending or fixed by SQL. Consequence: rejection has the same audit trail as approval.

**D-110 (Fase 1) Database role separation.** Decision: the runtime role has only `SELECT` and `INSERT` on
`platform.audit_log`, with `kran_app` as owner for migrations; deploy uses a separate migration env file.
Reason: append-only must not depend on triggers alone. Consequence: new immutable tables must revoke
runtime rights in their own migration; applied in production and extended by `platform/0042`.

**D-111 (Fase 1) KEK rotation banned while blind indexes exist.** Decision: rotation of the identity KEK
is forbidden until a reindex command exists; the emergency procedure is documented in the field
encryption runbook. Reason: after rotation old blind indexes no longer match, so duplicate detection
fails open. Consequence: rotation is a risky snapshot-based operation, not routine.

**D-112 (Fase 1) Party detail is a separate feature.** Decision: Fase 1 stops at CIF, basic identity, KYC
profile and risk rating; `party_person`, `party_org` and `address` are their own task with crypto per
column and human review. Reason: adding PII late in a batch tends to produce half-finished schema and
crypto. Consequence: delivered later as T-078; it never blocked Fase 0 or 1 closure.

**D-113 (Fase 1) Separation of duties for parameter maker and checker.** Decision: one seeded conflict
pair, `param_maker` and `param_checker`; `grantRole` refuses the second role and `authorize` rejects a
holder of both. Reason: it was the only pair with real roles and complementary permissions. Consequence:
extended by D-131 with five more pairs; new roles need a pair and a test.

**D-114 (Fase 1) Pilot parameter defaults accepted; per-institution gate.** Decision: current seeded
values are accepted for the internal pilot without a compliance claim; before the first real member or
client, the client's institution scope must be validated with the rule and date in the change reason,
and the tag is removed per institution. Reason: the pilot can run, but a repository default is never a
valid number for a client. Consequence: breaching the gate is a compliance risk, not a technical one.

**D-116 (Fase 2) Ledger table region stays focusable.** Decision: the ledger table uses
`aria-activedescendant` on a `grid` with one composite tab stop, and the region itself is not a tab
stop. Reason: keyboard scrolling is required by WCAG 2.1.1 without adding a tab stop per cell.
Consequence: no `svelte-ignore` remains for the old pattern.

**D-117 (Fase 2) Concurrent duplicate idempotency keys wait then replay.** Decision: a duplicate that
arrives while the winner runs waits on the unique index and replays 200 after commit; an in-flight row
is a defensive branch only, with `Retry-After` capped at 60 seconds; timestamps use one application
clock and are checked. Reason: the claim and completion share one transaction, so an in-flight committed
row should not exist. Consequence: the duplicate holds a pool connection for the winner's duration,
which is accepted for short object creation.

**D-118 (Fase 2) Idempotency `response_body` stored as-is.** Decision: successful responses are stored
verbatim, including `displayName`; access is limited to the application role; retention follows
`expires_at` and a day-close sweep. Reason: replay must return the original body without re-reading the
object. Consequence: this is not a closure of O-093; masking or encryption is required before real
member data. Refined by D-175.

**D-119 (22 Oct 2026) Product `REJECTED` status and seal at decision.** Decision: version status is
`DRAFT|ACTIVE|REJECTED`; rejection requires a reason and deletes nothing; `sealed` is set at approve or
reject; `maker` is filled at insert with a rolling-deploy fallback; `checker <> maker` applies to
rejection too. Reason: a rejected draft must stay visible for audit. Consequence: amends D-099;
`published_at` keeps its historical name.

**D-120 (Fase 2) Contract auto-apply through an allowlist.** Decision: deploy may run contract migrations
only for ids listed in `ops/migrations/contract-auto.txt`; contract is checked on every deploy; an id
outside the list stops the deploy; a pre-contract dump is mandatory. Reason: push equals deploy, so a
contract waiting for a manual step would redden every later deploy. Consequence: a deliberate deviation
from spec section 21.4, plus one review step per new contract.

**D-121 (Fase 2) Seed provenance as a generated artefact.** Decision: every definition carries a
`provenance.class`; `paramgen` enforces which classes may or must not have `default_pack`; the
provenance table is `packs/base/generated/param_provenance.md`, verified byte for byte by
`./task check`; the meaningless `grace_period_days` was removed from the seed and deprecated in the
catalogue. Reason: a prose comment cannot be machine-verified. Consequence: adding a parameter without
a class fails the gate.

**D-122 (Fase 2) New module migration seq must exceed the FK target.** Decision: a migration that
references another module's table takes a higher sequence number, verified with `dbtools validate`.
Reason: global order is `(seq, module, file)`, so `deposit/0002` ran before `product/0002` and failed on
an empty database. Consequence: gaps in module numbering are intentional.

**D-124 (Fase 2) Transfers use `deposit.transfer`.** Decision: transfers have their own table with
source, destination, amount and a unique journal id; the GL journal is `D 201 / K 201`, net zero; event,
journal and audit are attributed to the source branch. Reason: adding a transfer type to
`deposit.transaction` needed a contract change, and one account-level journal cannot represent a
transfer. Consequence: reconciliation must read `deposit.transfer`; destination branch attribution is
missing (recorded as an accepted limit).

**D-125 (Fase 2) Teller cash session.** Decision: cash transactions require an `OPEN` session for the
caller in the account branch on the same business date (409 otherwise); the gate sits inside
`withIdempotency` and reads the session `FOR KEY SHARE`; `cash_movement` has two types; one open session
per branch and teller; the vault can never go negative; closing adds counted cash. Reason: expected
cash and EOD gate have no meaning without a session and a drawer flow. Consequence: every cash path must
write a movement; PB does not require a session.

**D-126 (Fase 2) Account lookup by number through the list endpoint.** Decision: exactly one of
`partyId` or `accountNo` is required; not found or not permitted returns `200` with an empty list, never
403/404; the number shape is not validated because the format is provisional. Reason: a teller has the
number, not the UUID, and an error would reveal another branch's account. Consequence: there is no rate
limit on search, noted for real data.

**D-127 (Fase 2) Printing uses browser print.** Decision: slips and statements print from the browser; no
server PDF, no stored PDF, no signature; a reprint reads the transaction endpoint; the statement is a
subledger view without a running balance; the template lives in code. Reason: a server PDF engine was
undecided and blocked printing. Consequence: no print audit and no letterhead until an institution
header exists; R-22 fields are `NEEDS-COMPLIANCE-REVIEW`.

**D-128 (Fase 2) Cooperative savings classification.** Decision: `savings_kind` is nullable
`POKOK|WAJIB|SUKARELA|TABUNGAN` on savings products and is immutable; NULL means unclassified and is
treated as generic savings; pokok/wajib deposits post to equity `301.1`/`301.2`; withdrawals and
transfers touching them are blocked; dues rules are not enforced. Reason: adding an account type would
force a destructive CHECK change. Consequence: account numbers and the equity classification were
provisional; D-195 confirms the equity classification.

**D-129 (23 Oct 2026) Pilot branch and opening vault.** Decision: the pilot branch uses fixed UUID
`b0000000-0000-4000-8000-000000000001` until a branch master exists; the opening vault float is
Rp10,000,000, created once by SQL; later top-ups use the API. Reason: a stable branch id was needed
before the first cash session. Consequence: the balance sheet did not reflect cash until D-132/D-134;
the id is not an organisational fact.

**D-130 (24 Oct 2026) Account number is branch code plus sequence.** Decision: `platform.branch.code` is
exactly three digits and unique; account number is the three digit code plus a globally unique seven
digit sequence; the branch must be registered; branch codes cannot change once used; branches are
created with `ctl create-branch`. Reason: the number must show the opening branch. Consequence: existing
pilot numbers were rewritten by migration; a check digit remains open (O-104).

**D-131 (24 Oct 2026) Narrow admin roles and seeded SoD pairs.** Decision: `platform/0032` adds
`ops_admin`, `ledger_admin`, `cash_admin` and `product_maker`; five conflict pairs are seeded, two
mandatory and three nice-to-have; `platform_admin` stays break-glass with a written procedure; the
last-user guard counts holders of `platform.user.manage`, not role codes. Reason: one all-powerful
admin made separation of duties impossible. Consequence: production needs separate accounts per role
before SoD is effective; `platform_admin` is deliberately not paired.

**D-132 (24 Oct 2026) Teller and vault cash are journalled; vault top-up is maker-checker.** Decision:
COA `101` becomes a non-postable parent with `101.1` vault, `101.2` till and `101.9` differences;
posting rules cover session open, close and variance; session handlers post synchronously in the same
transaction; top-up is a request plus a different approver, with a journal, audit and event. Reason:
cash moved with no ledger trail and one permission could inject cash. Consequence: account mapping is
a pilot proposal tagged `NEEDS-COMPLIANCE-REVIEW`.

**D-133 (24 Oct 2026) Cash limits are parameters.** Decision: opening float 2,000,000, deposit
10,000,000, withdrawal 5,000,000 and vault top-up per request 25,000,000 are `money` parameters; checks
run in the handler; a missing parameter is 500; violation is 409; exactly at the limit is accepted.
Reason: the numbers are owner policy, not regulation. Consequence: daily accumulation, vault balance
caps and variance tolerance were not adopted.

**D-134 (24 Oct 2026) Remaining T-118 decisions.** Decision: minimum three daily operators plus one
sealed `platform_admin`; break-glass needs the book, next-day report and a three-use monthly threshold;
top-up evidence is the request row plus a structured note and ten year physical retention (tagged); the
`101.1`/`101.2`/`101.9` mapping is confirmed for the pilot; `teller` holds neither vault permission;
the opening balance is a liability `203 TITIPAN PENGURUS` posted once by `ctl post-opening-balance`.
Reason: the owner delegated the remaining items under the no-invented-regulation rule. Consequence: all
compliance tags stay; the legacy `101` balance is reconciled by adding it to `101.1`.

**D-135 (Fase 2) Subledger journals cannot be reversed through the ledger.** Decision: reversal answers
409 `journal_owned_by_subledger` when a deposit, transfer, session or vault request row points at the
journal; detection is data-based plus four explicit session events; the cross-schema query lives in the
composition root. Reason: a ledger-only reversal leaves the subledger unchanged, and a later
reconciliation would call that "clean". Consequence: correction goes through the originating module;
the general correction path is still future work.

**D-136 (24 Oct 2026) Money is two decimals everywhere.** Decision: `moneyScale = 2`, columns are
`numeric(24,2)`, the parser rejects sub-cent digits, API values are two-decimal strings, and frontend
formatters default to two; `Rate` stays 1e-6; `Money * Rate` rounds to the cent. Reason: pilot values
are whole rupiah and operators should see exactly what is stored. Consequence: accrual rounding must be
decided before interest is written; a 4-decimal idempotency hash will not replay; `HUMAN-REVIEW-REQUIRED`.

**D-137 (24 Oct 2026) Accrual parameter shape locked, values still pending.** Decision: `rounding_scale`
is 0 to 2, `rounding_mode` is `HALF_EVEN` only, `day_count_basis` is the three spec values,
`interest_posting` becomes a bounded string, and `interest_rate` stays a rate. Reason: the kernel only
implements half-to-even and the old upper bound of four was stale after D-136. Consequence: a new
rounding mode or day count basis needs kernel code and a decision; product bindings fail closed until
compliance seeds values.

**D-138 (24 Oct 2026) Money parser accepts trailing zeros.** Decision: `moneyFromString` accepts digits
beyond the scale only when they are all zero (`"25000.0000"` reads as `"25000.00"`); non-zero sub-cent
digits are still rejected. Reason: parameter and product binding values are JSON strings and sealed
versions cannot be rewritten. Consequence: old pilot values read without migration; new values are
written with two decimals.

**D-139 (24 Oct 2026) Static TS/Svelte lint installed.** Decision: `eslint` 10.13.0, `eslint-plugin-svelte`
3.23.1 and `typescript-eslint` 8.72.0 pinned exactly; one flat config at the root; `svelte/a11y-*` is
left to `svelte-check --fail-on-warnings`; `svelte/no-navigation-without-resolve` is disabled until the
navigation migration (T-125); the gate runs in `./task lint-web`, `./task ci` and the `web-e2e` job,
not `./task check`. Reason: `nim-check` does not run `pnpm install`, so a web gate there would always
skip. Consequence: supersedes D-053 part (b); `packages/ui` has its own `svelte-check`.

**D-140 (24 Oct 2026) Login limiter is a process capacity constant.** Decision: four concurrent logins,
ten attempts per minute and a 60 second window live in `login_guard.nim`, marked `nomagic:ok`. Reason:
this is server capacity, not institution policy, and a wrong value cannot mispost money. Consequence:
changing it needs a deploy; the escape path is to move the values to `platform.security.*` parameters
with the usual seed and audit.

**D-141 (24 Oct 2026) Period close is final; opening vault balance through `ctl`.** Decision: the period
trigger allows only `OPEN` to `CLOSED`; closing refuses open sessions in the range; closing a session
checks for a closed period first; `ctl post-opening-balance` writes the journal and the vault balance in
one transaction and refuses a vault that already has a balance. Reason: reopening periods and editing
the vault were the only available "fixes" and both hid the ledger. Consequence: cancelling a close would
be a new product decision with audit and correction journals.

**D-142 (24 Oct 2026) HTTP workers follow pool size; `X-Forwarded-For` only from loopback.** Decision:
`serverThreads = max(1, poolSize - 1)`; `/readyz` uses the process pool; `X-Forwarded-For` is trusted
only from loopback and only for a valid address of at most 45 characters. Reason: more workers than
connections only creates queue timeouts, and a trusted header from anyone lets a client forge audit IPs.
Consequence: if the API ever moves off the proxy host, a trusted proxy list is mandatory.

**D-143 (24 Oct 2026) Release artefact is one manifest line.** Decision: base image digest is pinned and
the Nim tarball is SHA-256 verified; there are no per-commit image tags and no `releases/<sha>/`
directory; each deploy appends time, revision, image id and binary sha256 to `releases.txt`. Reason: a
tag per commit conflicts with the `:local`/`:prev` retention contract and doubles storage. Consequence:
rollback reaches one version back; the manifest exposes non-reproducible builds.

**D-144 (24 Oct 2026) Login limits can be overridden by environment.** Decision:
`KRAN_LOGIN_MAX_CONCURRENCY` and `KRAN_LOGIN_ATTEMPTS_PER_MINUTE` override the constants; invalid values
are ignored. Reason: e2e runs dozens of logins from loopback and hit 429. Consequence: a bad environment
can weaken the limiter, so the variables exist only in `playwright.config.ts` and are not in ops
examples.

**D-145 (25 Oct 2026) Media type and response declarations are checked in the wrapper.** Decision:
`requestHandler` answers 415 for a non-JSON body before routing; the contract declares 405 on every
operation, 501 and 503 on secured operations and 415 on operations with a body, enforced by
`tools/openapi`. Reason: both are properties of the layer wrapping all routes, not of one handler.
Consequence: clients that omitted `Content-Type` now get 415; a new `ProblemKind` and i18n key exist.

**D-146 (25 Oct 2026) Numeric bounds apply to decimal strings too.** Decision: when a value is a decimal
string, `minimum`/`maximum` are enforced; other string shapes are not compared. Reason: `{"minimum": 0}`
did not stop `"-1.00"` from becoming a cash limit. Consequence: comparison uses `parseFloat` only for
comparison, never for money arithmetic; values beyond 15 significant digits can round when compared.

**D-147 (25 Oct 2026) Request body limit in Caddy; configuration change is a restart.** Decision:
`request_body { max_size 1MB }` plus transport timeouts on the API proxy; no `Content-Length` matcher,
because Go strips that header from request headers; configuration changes use
`systemctl restart caddy`. Reason: the admin API is off, so `caddy reload` fails. Consequence: oversized
requests get 413 (chunked) or 502 (with length); the body never reaches the API.

### 2.3 Day close, deposits, lending (Fase 3 and Fase 4)

**D-148 (28 Oct 2026) `daycloser` framework shape.** Decision: `CloseLevel` lives in
`shared/kernel/dayclose.nim`; the parameter snapshot is inline JSON with a hash; `scope_id` is text with
a `control` column; one short connection per operation with a separate advisory-lock connection; chunks
run sequentially with no per-task timeout; `SIMULATION` was not implemented at that point; the deploy
freeze gate uses the `ctl daycloser-status` exit code; run completion and its audit share one
transaction; the registry is validated against the frozen run snapshot; resume clears `PAUSE` but keeps
`CANCEL`. Reason: several spec sketch columns could not be used as written. Consequence: large EOD runs
cannot use cores yet; the status command must stay cheap.

**D-149 (28 Oct 2026) Business date cycle.** Decision: the run freezes its own date after all prechecks;
seal is one transaction covering completion, audit, `CLOSING` to `CLOSED`, date rollover and the
`BusinessDateOpened` event; `CLOSING` to `OPEN` is an abort, never a reopen; while `CLOSING` every
non-auth write is 409; a database read failure in the gate fails open, a missing policy parameter fails
closed; the first date row needs `--bootstrap`; cancel with no live process applies immediately; the
contract declares 409 on every non-auth write. Reason: a cancelled close otherwise freezes the
institution forever. Consequence: one extra `business_date` query per write; branch close is not
supported.

**D-150 (28 Oct 2026) Pre-close and post-close gates.** Decision: a failing `PRECHECK` or `POSTCHECK`
task yields `BLOCKED`, a failing `PROCESS` or `REPORT` task yields `FAILED`; gates only read; prechecks
run before freeze; evidence metrics are stored on failure; account lists are parameters; balances are
judged by COA account type; late journals are detected with microsecond precision; gate tasks and their
chunks are reset on resume; missing or inactive accounts make a gate fail; late-journal coverage is
limited to transactions started after freeze. Reason: a run could "complete" with an unbalanced
subledger, and a gate certificate could go stale while paused. Consequence: six cumulative aggregate
queries per close; per-product subledger mapping is still missing.

**D-151 (28 Oct 2026) Ledger day-close tasks.** Decision: `ledger.daily_snapshot` rebuilds and then
proves the snapshot, storing a SHA-256 fingerprint; period close depends on the snapshot; system close
writes `closed_by` NULL; a month end without a period fails `DAY-324`; snapshot and period close are
idempotent per business date; open cash sessions block the close. Reason: a close that cannot be
reopened must have proof of balances first. Consequence: periods are still created manually; period
close is a post-close task and requires contract migration `0060`.

**D-152 (28 Oct 2026) Accrual, time deposit and dormant model.** Decision: `TIME_DEPOSIT` becomes an
account type with maturity date, ARO instruction and activity fields; interest accrues daily as
`D 501 / K 204` and posts as `D 204 / K 201`; provisional values are 2.5 percent per year, ACT/365,
half-even, scale 2, posting at maturity; dormant after 12 months with no automatic closure. Reason: the
accrual, maturity and dormant tasks could not be built without a data model. Consequence: time deposit
principal sits in `202`; the rates are provisional and tagged. R-16 removes time deposits from the MVP
plan, so this model governs current code until P4 deletes it.

**D-153 (28 Oct 2026) Day-close actions over HTTP.** Decision: orchestration runs synchronously inside
the request using the same service as `ctl`; there is no `Idempotency-Key`, because the claim cannot
wrap a multi-transaction run, and duplicate clicks are stopped by the advisory lock, the one-run-per-date
index and intent-only pause/cancel; `dayclose.run.read` and `dayclose.run.manage` are separate; the
`/api/v1/dayclose/` prefix is exempt from the `CLOSING` gate. Reason: a `202` design adds a state owner
without a proven need. Consequence: a request holds a worker and the client must treat a timeout as
unknown and read status.

**D-154 (28 Oct 2026) Daily interest accrual.** Decision: accrue for `ACTIVE` and `DORMANT` accounts
(`status <> 'CLOSED'`); a failure is critical and blocks the close; rounding applies once to the
cumulative interest and the day's journal is the difference; journals are written synchronously in the
chunk transaction and `InterestAccrued` carries no accounting header. Reason: rounding per day drifts
from the promised maturity amount and cannot be corrected after posting. Consequence: one `withTx` per
chunk; a 30/360 short range can produce a zero day; `HUMAN-REVIEW-REQUIRED`.

**D-155 (28 Oct 2026) Time deposit maturity and ARO.** Decision: the last interest day is the day before
`maturity_date`; `NONE` moves principal and interest to savings; `PRINCIPAL` renews principal and pays
interest out; `PRINCIPAL_AND_INTEREST` capitalises interest into principal; renewal tenor equals the
original tenor; late processing adds no extra interest. Reason: each choice changes the amount posted.
Consequence: a target savings account is required or the task stops with a code; a new transaction type
and reconciliation mapping are needed.

**D-156 (28 Oct 2026) Time deposit principal is locked mid-tenor.** Decision: cash withdrawal and
transfers touching a `TIME_DEPOSIT` account answer 409 `time_deposit_locked`; cash deposit is allowed.
Reason: reducing principal makes cumulative interest smaller than already posted, and a transfer would
park a term liability in the savings account. Consequence: early withdrawal required a separate decision
(D-164); `HUMAN-REVIEW-REQUIRED`.

**D-157 (28 Oct 2026) Dormant detection.** Decision: activity comes from `deposit.transaction` and
`deposit.transfer`, using `opened_on` as the lower bound; the threshold comparison is strict; a dormant
account with new activity reactivates on the next close; deposits are accepted but withdrawals and
transfers are rejected; the task is non-critical; a missing threshold fails `DAY-351` without blocking
the run; the status update repeats the predicate inside the statement; a dormant savings account is a
valid maturity target. Reason: the `last_activity` column was never written, and reactivation must be
possible. Consequence: no per-account audit; no automatic closure (D-174 adds zero-balance closure).

**D-158 (28 Oct 2026) Day-close journal provenance.** Decision: `ledger.journal.daycloser_run_id` is
nullable and set by day-close tasks; `latePostings` ignores those journals. Reason: the close's own
accrual and maturity journals made every close with a time deposit end `BLOCKED`. Consequence: business
journals remain subject to the gate; new close tasks must pass `ctx.runId`.

**D-159 (28 Oct 2026) `SIMULATION` is plan-level dry run.** Decision: `--mode=SIMULATION` runs the same
planning and prints `"writes": false`, creating no run, journal, balance, event or date change. Reason:
tasks write through their own pool transactions, and an outer rollback would not undo outbox, files or
anchors. Consequence: it does not prove a task will succeed; state rejections are still evaluated.

**D-160 (31 Oct 2026) Design direction v2.** Decision: cool neutral base with one plum accent, IBM Plex
Sans only, ENERGY 2 / RHYTHM 2 / MOTION 2 with zero-duration numbers, and structural commitments
(one focus per screen, grouped navigation, settings out of the content tab order, teller as a
workstation). Reason: the UI audit found a structure and adoption failure, not a wrong palette.
Consequence: supersedes D-075 and D-115; contrast matrices must be extended before tokens are used;
the teller screen needs a missing transactions endpoint. DD-01 upholds this identity.

**D-161 (31 Oct 2026) Account row locks for teller and maturity.** Decision: teller cash, transfers and
the maturity task lock `deposit.account` `FOR UPDATE` and re-read state after the lock; the lock order
is account, balance row, then cash session. Reason: a deposit could commit after maturity closed the
account, and transfer plus cash could deadlock. Consequence: task and teller serialise on one row; a
losing deposit gets 409 `account_not_active`; `HUMAN-REVIEW-REQUIRED`.

**D-162 (31 Oct 2026) Business date on `GET /auth/session`.** Decision: `SessionInfo.businessDate` is
sent to every valid session with three states: object when the row exists, `null` when the institution
has no row, field absent when the read failed. Reason: tellers do not hold `dayclose.run.read` but need
the date. Consequence: one request fewer per page; adding contract fields requires strict clients to
update their schema.

**D-163 (31 Oct 2026) Alert on non-critical day-close failures.** Decision: `kran-alert.sh` probes failed
non-critical tasks in the latest `COMPLETED` institutional run and includes task, error code and chunk
count; a failing probe reports `?` and bad status. Reason: a failed dormant task could stop detection
for days while `/readyz` stayed healthy. Consequence: the alert clears when the next close is clean;
`/readyz` and the deploy gate are unchanged.

**D-164 (31 Oct 2026) Early time deposit withdrawal.** Decision: early withdrawal is open for cash and
outgoing transfer; penalty is a percentage of principal bound per product version, and a missing binding
rejects the withdrawal; interest is paid up to the withdrawal date; penalty posts as revenue `403`.
Reason: without a penalty number, opening the path meant inventing a business rule. Consequence: three
journals per early withdrawal; the account `403` mapping is a pilot structure; `HUMAN-REVIEW-REQUIRED`.

**D-165 (31 Oct 2026) Accrual baseline per ARO cycle.** Decision: the account stores
`interest_paid_cumulative`; the maturity task pays `cumulative - paid` and then raises the baseline;
renewal tenor comes from the product attribute `product.savings.rollover_tenor_days` and fails when
unbound. Reason: the second cycle paid the first cycle's interest again and doubled the tenor.
Consequence: the first cycle is unchanged; old accounts start at zero; `opened_on` is never changed.

**D-166 (31 Oct 2026) Axe threshold stays `serious|critical` until screen migration finishes.** Decision:
do not raise the threshold until the teller screen is migrated, then raise to `moderate` and fix all
findings in one task. Reason: raising early would surface legacy findings on unmigrated screens.
Consequence: O-118 stayed open with an explicit order of work; the later migration closed it at
`moderate`.

**D-167 (31 Oct 2026) One journal may carry two subledger rows.** Decision: a GL journal may have several
subledger rows when the accounts differ; one account may not appear twice for the same journal; reports
that aggregate per journal must read the account column. Reason: ARO `NONE` needs an outgoing and an
incoming row pointing at one journal. Consequence: O-110 is closed with no schema change.

**D-168 (31 Oct 2026) Early withdrawal by transfer.** Decision: `deposit.transfer.amount` stays principal;
two new signed transaction rows sit on the destination account (`INTEREST_PAID_EARLY`,
`PENALTY_CHARGE`); three posting rules have their own event types; the statement kind is
`EARLY_WITHDRAWAL`; a full withdrawal ignores product `min_balance`. Reason: parking the penalty on
interest credit is only correct when interest exceeds the penalty. Consequence: the penalty sign is
correct in reconciliation; account mapping remains a pilot structure.

**D-169 (31 Oct 2026) Teller branch chosen in the panel.** Decision: the session panel shows a branch
picker; loading an account fills the branch; a mismatch closes the form with an explicit message.
Reason: opening cash must not depend on loading a member account. Consequence: `teller` gets
`platform.branch.read`; no API contract change.

**D-170 (31 Oct 2026) Drop `last_activity`; audit dormant changes per chunk.** Decision: contract
migration `deposit/0075` drops the unused column; one `deposit.dormant.chunk` audit entry per chunk
carries date, threshold, chunk number and the account lists, written in the same transaction. Reason:
two sources of "last activity" disagree, and per-account audit would write 100k rows. Consequence:
future readers must aggregate the subledger; `updated_at` records the change time.

**D-171 (31 Oct 2026) `effectiveTo` successor may be GLOBAL; session candidates only where login
reads.** Decision: a valid successor is the same scope or GLOBAL, in `ACTIVE`, `SUPERSEDED` or `PENDING`,
and still effective on the end date; session policy checks apply only to `GLOBAL` or `INSTITUTION` with
an empty scope id. Reason: evaluation must match what the application actually reads. Consequence:
changes nobody reads are no longer rejected for a confusing reason.

**D-172 (31 Oct 2026) JSON parameter shape limits.** Decision: `jsonFormProblem` enforces depth 8, rejects
`null` everywhere and rejects non-finite numbers, and is called from every write path including product
bindings. Reason: an unconstrained JSON value is ambiguous between "empty" and "absent". Consequence:
depth is a technical bound marked `nomagic:ok`; raising it needs a new decision.

**D-173 (31 Oct 2026) `param.changed` filtered per subscriber branch.** Decision: the topic gate uses
`authorizedAnyBranch`; `EventScope` is computed once per `subscribe`; only `BRANCH`-scoped parameter
events are filtered; an empty scope receives nothing; replay uses the same filter; `eventScope` is
mandatory. Reason: opening the topic without filtering would send every branch's events to everyone.
Consequence: grant changes apply at the next `subscribe`; revoked sessions still close through
`sessionValid`.

**D-174 (31 Oct 2026) Automatic dormant closure.** Decision: `deposit.dormant_close` closes only accounts
still `DORMANT`, with zero balance, and no activity beyond `deposit.dormant_close.after_months`
(default 24); audit per chunk; no money moves. Reason: dormant accounts otherwise accumulate with no
closure path, and a balance cannot be closed unattended. Consequence: notification and member rights
stay `NEEDS-COMPLIANCE-REVIEW`; the threshold is a parameter.

**D-175 (31 Oct 2026) Idempotency response retention.** Decision: retention equals
`platform.idempotency.ttl_hours` (default 24), enforced by the day-close sweep; 30 days is a hard upper
bound. Reason: the row can hold PII, and the default already covers replay needs. Consequence: no
masking was added; if the sweep stops, retention is not maintained.

**D-176 (31 Oct 2026) Deferred items with triggers.** Decision: O-026, O-028, O-053, O-064, O-075, O-071,
O-024 and O-041 are deferred, each with a stated trigger to reopen; O-100 keeps its equity tag; O-008
belongs to the host, not this repo. Reason: an indefinite deferral hides work. Consequence: no item may
return without its trigger or an owner decision.

**D-177 (31 Oct 2026) Visual regression on a Linux baseline.** Decision: `visual.spec.ts` runs only on
Linux, covers four deterministic screens in both themes, masks the business date, and compares against
a committed baseline generated by the same runner; `maxDiffPixelRatio` is 0.01. Reason: screenshots
depend on OS font rendering. Consequence: macOS never produces a baseline; UI changes require the
baseline workflow and an artefact review.

**D-178 (1 Nov 2026) Single version, tagged release, CI gate on deploy.** Decision: `VERSION` is the only
version source and is stamped into generated API and web files by `./task build`; `./task release`
derives the bump from Conventional Commits, updates `CHANGELOG.md`, runs gates, commits and creates an
annotated tag; a tag is a marker, not a deploy trigger; deploy waits for the four CI check runs and
fails closed when a check is missing; the deploy lock waits (`flock -w`, default 900 seconds).
Reason: production served a six day old web bundle while `main` was green. Consequence: deploys can
wait about 15 minutes; job names are a contract with `CI_EXPECTED` (O-119).

**D-179 (1 Nov 2026) Gates must not lie about skipped integration.** Decision: `./task test` fails when
the selection includes integration tests and no database URL exists; `./task e2e` fails without a
database; skipping requires an explicit `KRAN_ALLOW_NO_DB=1`. Reason: both commands could report green
while running a small subset. Consequence: unit-only CI jobs must state the flag; daily local commands
are unchanged when `.local/dev.env` exists.

**D-180 (1 Nov 2026) Lending methods, bands, provisioning and allocation.** Decision: flat, effective and
annuity schedules are all built and covered by golden tests; DPD bands are 0, 1 to 90, 91 to 120, 121 to
180, above 180; PPAP rates are provisional and tagged; payment allocation order is the parameter
`lending.allocation_order`, seeded `INTEREST,PRINCIPAL,PENALTY`. Reason: the phase could not start
without numbers, and a hard-coded allocation order would be a business rule in code. Consequence: the
DPD bands and rates are `NEEDS-COMPLIANCE-REVIEW`. The rate table is superseded by D-196.

**D-181 (1 Nov 2026) Login limiter test does not depend on the 60 second window.** Decision: the specific
test builds a guard with `KRAN_LOGIN_ATTEMPTS_PER_MINUTE=2` and proves two 401s then a 429 with
`Retry-After`; window behaviour is tested with injected time. Reason: dummy KDF cost put ten attempts at
the edge of the window, so a slow machine failed for the wrong reason. Consequence: no flakiness; the
production default stays 10 per minute.

**D-182 (1 Nov 2026) Disbursement credits a savings account; cash goes through the teller.** Decision:
disbursement always credits the member's savings account and, if cash is wanted, the teller withdraws it;
a new subledger type `LOAN_DISBURSEMENT` marks the row; the journal `D 110 / K 201` comes from a posting
rule in the same transaction; the target account must belong to the borrower, be in the same branch and
be active; `Idempotency-Key` is mandatory. Reason: `cash_movement.transaction_id` and
`deposit.transaction.account_id` make a loan-only cash path a schema and expected-cash change.
Consequence: the member history shows two steps; account `110` mapping is tagged.

**D-183 (1 Nov 2026) Installment payment allocates per parameter, one journal per component.** Decision:
one journal per non-zero component (`LoanPrincipalPaid`, `LoanInterestPaid`, `LoanPenaltyPaid`); one
subledger row per component; the schedule mutation trigger is loosened, not removed, so paid amounts
only increase and core fields freeze; overpayment is 409; a paid-off loan does not auto-close. Reason:
the posting template forces one debit and one credit, and the old trigger made installments impossible.
Consequence: a statement shows several lines per payment; account `403` is tagged.

**D-184 (1 Nov 2026) Collectibility stored per business date, task non-critical.** Decision:
`lending.collectibility_snapshot` is the per-date source of truth and `lending.loan.collectibility` is
the latest value; DPD comes from the oldest unpaid installment due date; the task does not block the
close; bands come only from `lending.collectibility.dpd_bounds`, expected count derived from the enum.
Reason: a single mutable column cannot distinguish "processed" from "reprocessed" and has no per-date
history. Consequence: adding a grade needs an enum value and a parameter band.

**D-185 (1 Nov 2026) CKPN is a credited asset account `111`.** Decision: `111 PENYISIHAN KERUGIAN
PIUTANG` is an asset with debit normal side, credited by provision journals; `503` is the expense; rules
are `PpapProvisioned` and `PpapReleased`; a negative difference uses a reversing journal; provisioning
is net per branch per chunk; a loan leaving `ACTIVE` with provision left fails visibly (`DAY-384`).
Reason: the COA cannot model a contra account and forced LIABILITY was forbidden. Consequence: gross
asset reports must separate gross and net; account names are tagged.

**D-186 (1 Nov 2026) Restructure and write-off.** Decision: restructuring creates a new schedule
version and archives the old one, with installment numbers continuing; the new basis is remaining
principal and old interest/penalty arrears are released; collectibility returns to current (superseded
by D-197); write-off requires `ACTIVE` and `LOSS`, clears all remaining obligations, uses provision
first and expense for the shortfall; duties split between `lending_maker` and `lending_checker`.
Reason: the schedule trigger forbids editing a paid schedule and allocation rows carry no version.
Consequence: recovery after write-off was missing until D-191; restructuring cannot change the rate.

**D-187 (2 Nov 2026) e2e applies contract migrations.** Decision: `./task e2e` runs `--contract` with the
freshly built binary after `dbtools migrate` and before seeding. Reason: e2e ran on the pre-contract
schema and a production-valid path failed with 500. Consequence: e2e proves contract files apply in
order; deploy remains expand-only.

**D-188 (2 Nov 2026) PPAP prerequisites checked while the chunk runs.** Decision: chunk count comes from
the population of `ACTIVE` loans, while `DAY-383` is checked at the start of the chunk, after
dependencies ran; `DAY-384` stays at planning. Reason: the check ran before regrading, so every EOD with
loans failed on day one. Consequence: fail-closed behaviour is unchanged, only the timing.

**D-189 (2 Nov 2026) Narrow gitleaks allowlist.** Decision: one regex `'''it168-[a-z]+-'''` in
`.gitleaks.toml`, with a reason and a pointer; no file, directory or rule exclusion. Reason: a test
idempotency-key prefix tripped the generic API key rule, and rewriting history again was refused.
Consequence: a fake token still produces a finding; a future gitleaks version needs the plural
allowlists form and both tests repeated.

**D-190 (2 Nov 2026) Three credential guardrail layers.** Decision: a local pre-commit hook (blocking
key-shaped files and staged secrets, warning when gitleaks is absent), the existing per-push CI scan,
and a weekly full-history scan. Reason: a leak enters history once and cannot be fixed by a later
commit. Consequence: the hook is local and cannot be enforced; CI remains the main guard and
`--no-verify` stays forbidden.

**D-191 (2 Nov 2026) Recovery after write-off is income per component.** Decision:
`POST /lending/loans/{id}/recovery` posts principal to `409`, interest to `401` and penalty to `403`,
each with its own journal; cumulative recovery cannot exceed the write-off amounts; over-recovery is
409; the source account must be the member's, in the loan branch and active; `lending.loan.recovery`
is held by `lending_checker` and not `lending_maker`. Reason: the receivable no longer exists, so a
later receipt is income, not settlement. Consequence: account `409` is a pilot structure tagged
`NEEDS-COMPLIANCE-REVIEW`; the loan stays `WRITTEN_OFF`.

**D-192 (2 Nov 2026) `lending_maker` has no savings account read.** Decision: do not grant
`deposit.account.read` to `lending_maker`; the UI distinguishes a 403 from a failure and disables
review until the list is ready. Reason: granting it would let every loan maker see all member balances.
Consequence: disbursement and collection also require `teller` or `platform_admin`; this is the known
cause of audit B11.

**D-193 (2 Nov 2026) CKPN stays on `111`; no contra account type.** Decision: do not loosen
`coa_normal_side_chk` and do not add a contra type; gross and net reports compute from `110` and `111`.
Reason: loosening the core COA constraint touches every balance sheet and validation, and the benefit
is presentation only. Consequence: supersedes D-106 and closes O-121; a regulator requiring a contra
account needs an ADR and a constraint migration.

**D-194 (2 Nov 2026) `ci-fast` for the daily loop; e2e moves to `ci` and `release`.** Decision:
`./task ci-fast` is `check` plus openapi, `lint-web` and `test`, without e2e; `./task ci` keeps every
gate plus e2e; `./task release` runs `check-fast`, build, test and e2e before the release commit.
Reason: the daily gate paid for a database reset and browser suite on every small change, while the
last gate before a deploy was the thinnest. Consequence: UI changes must be green at `ci` or `release`;
`--skip-check` also skips test and e2e and is recorded in the release notes.

**D-195 (2 Nov 2026) Simpanan pokok and wajib stay equity.** Decision: `301.1` and `301.2` remain equity;
no COA or posting change; only member savings (tabungan, sukarela, berjangka) are liabilities. Reason:
Permenkop UKM 2/2024 Annex I, equity policy 5.1 states that pokok and wajib savings are presented in
equity. Consequence: the "move to liabilities" question is closed; only the dues rule remains under
O-100. The source and quotation are in `docs/compliance/register-validation.md`; compliance owner
sign-off is still required.

**D-196 (2 Nov 2026) PPAP rates adopt POJK 1/2024.** Decision: `lending.ppap.rates` becomes
`["0.5","3","10","50","100"]`, class `kebijakan`, tagged `NEEDS-COMPLIANCE-REVIEW`. Reason: the old
`["0","0.5","10","50","100"]` formed no general allowance and under-provided for special mention.
Consequence: pilot profit falls and CKPN is more conservative; changing a running database is a
governance action, not a migration; `HUMAN-REVIEW-REQUIRED`.

**D-197 (2 Nov 2026) Post-restructure grade is capped, not reset.** Decision: store `restructured_on`,
`grade_before_restructure` and `grade_cap`; `lending.dpd_regrade` holds the grade at or below the cap
until `lending.restructure.clean_periods` (default 3) consecutive installments are paid on time; a loan
never graded uses the conservative substandard cap; downgrades stay allowed. Reason: a reset released
provision immediately on a restructured loan, contrary to POJK 1/2024. Consequence: amends D-186 item 3;
loans restructured before the migration are not backfilled; `HUMAN-REVIEW-REQUIRED`.

**D-198 (2 Nov 2026) Solo workflow; off-host backup accepted as residual risk.** Decision: commits may
go directly to `main`, but push happens only through `./task release`; feature branches remain available
for large changes; O-124 (off-host backup and anchor copy) is not a blocker and stays a residual pilot
risk. Reason: the owner works alone and every push deploys, so a PR adds no protection beyond the
release gate. Consequence: review evidence comes from gates and task reviewers, not PRs; losing the host
before a remote exists loses the only copy. Supersedes the push and parallelism parts of D-071.

**D-199 (2 Nov 2026) Traceability reads the repository register, not a database table.** Decision:
`docs/compliance/register.yaml` is validated by `./task traceability`; an `active` requirement needs a
control and a test, parameter references must exist in seeds, modules and test files must exist and
contain the named test; `deferred` rows are not content-checked. Reason: the gate must run without
Postgres and be reviewable in a diff. Consequence: coverage is limited to the traced section 4 rows;
the gate checks links, not compliance.

**D-200 (3 Nov 2026) MFA challenge behind its own parameter; factorless accounts still sign in.**
Decision: `platform.security.mfa.require_login` is separate from `mfa.enabled` and defaults false;
verification uses a half session that every route rejects except challenge and logout, and realtime
also rejects it; accounts without an `ACTIVE` factor still sign in fully and the audit records
`mfa_enrolment_missing`. Reason: there is no recovery or administrative path, so enforcing would lock
everyone out. Consequence: such accounts are password-only; the remaining MFA work stays open (O-071).

**D-201 (3 Nov 2026) API and test binaries use `--mm:atomicArc`.** Decision: build with `atomicArc`;
YRC was rejected because Mummy 0.4.8 refuses it at compile time, and `useMalloc` was rejected because it
only hides the symptom. Reason: ORC is not thread-safe for cycles that cross threads, and Mummy passes
requests from the loop thread to worker threads. Consequence: cyclic garbage can leak, measured flat at
about 24 MB over 20,000 requests; the SIGSEGV is not proven fixed because there is no reproducer.

**D-202 (10 Nov 2026) Design system v2 tokens and shell ratified (ADR-1..ADR-5).** Decision, authorised
by the owner in the redesign session on 10 Nov 2026: adopt the five open design questions as one
package. (1) Shell base 13px, login, long forms and print 14px. (2) Table rows 40px, compact 36px;
field height 40px; toolbar actions stay 32px, so ADR-2 splits into two values instead of one.
(3) A detail panel is a 520px drawer, never a modal. (4) Below 1024px the sidebar becomes an
off-canvas panel with a focus trap and Escape, not a top-nav clone. (5) The dark accent becomes
`#C292BE` and `#D9A0D4` retires. Reason: the mockup measured axe 0 violations across nine
combinations, `packages/ui/tests/tokens.contrast.test.ts` covers every pair in SPEC 1.1-1.2, and the
owner asked for implementation to start after two review rounds. Consequence: supersedes the 34px row
and 32px field values in DESIGN section 4; every screen inherits the new scale; `--line-strong`
`#c8cdd3` is not adopted because 1.48:1 fails the 3:1 control-boundary minimum, so control borders
keep `--color-border`; any further change to these values needs a new decision.

**D-203 (10 Nov 2026) The ledger table leaves the ARIA grid; the wrapper is the one tab stop.**
Decision: `/app/ledger` stops using `role="grid"`, `tabindex`, `aria-activedescendant`, cell ids and
the Arrow/Home/End handler on the table. `.kran-table-wrap` carries `role="region"`, `tabindex="0"`
and the accessible name, matching `DataTable`, and the table returns to a plain native table with
`th scope` and `<caption>`; arrow keys and Home/End scroll the focused region natively. Reason: it is
the only table in the app that does not use the shared wrapper, the cells are read-only so grid
semantics buy no operation beyond scrolling, and one model for every table is cheaper to gate.
Consequence: supersedes D-116 and the `aria-activedescendant` clause for tables in DESIGN section 10;
T-294 part 2 implements it and updates `DESIGN.md` in the same commit.

**D-204 (13 Nov 2026) Passwords the repo publishes are denied, and the audit IP comes from one named proxy.**
Decision: `passwordProblems` rejects any password that matches an entry in
`modules/platform/domain/password_denylist.txt` (case-insensitive, both sides normalised), which
holds every password the repo publishes in `packs/base/seed/*.sql` plus a short common-password
list; the list is data in its own file, not a Nim literal. Separately, `identity.clientIpFrom` trusts
`X-Forwarded-For` from loopback plus exactly the CIDRs in `KRAN_TRUSTED_PROXY_CIDRS`, and reads the
chain right to left, taking the rightmost entry that is not itself a trusted proxy. Reason: a
credential published in the seed passed the policy and reached production through the normal
change-password route (K-01, 13 Nov 2026), and the loopback-only rule made every request behind
Caddy plus podman arrive as the bridge gateway, so the login limiter was one shared bucket and the
audit `inet` column identified nobody. The variable has **no code default**: the `qouver` network is
shared with sds-api and majadu-api, so "anything in 10.89.0.0/16" is a co-tenant foothold, not the
proxy, and an unset variable must fail closed. Consequence: supersedes L-17 in `ACCEPTED-LIMITS.md`
and narrows D-142 to "loopback plus the configured ranges"; seeds are unaffected because they write
hashes directly, `tauthz` fails when a seed file that creates accounts is not in its known list, and
`deploy-vps.sh` plus the API start log both warn when the variable is empty. T-298 implements it;
`ops/env/kran-prod.env.example` names `10.89.0.1/32` as the value to set, and the real
`kran-prod.env` on qouver must carry it.

---

## 3. Archive index

Superseded or obsolete decisions. Full text stays in git history and in
`plan/legacy-docs/docs/DECISIONS.md`; nothing here is deleted or renumbered; the frozen local archive and git history hold the originals.

| ID | Title | Status |
|---|---|---|
| D-036 | Product name KRAN, technical identifiers left as `cbs` | superseded by D-039 (all technical identifiers renamed) |
| D-038 | Package file `kran.nimble`, other identifiers left as `cbs` | superseded by D-039 (rename completed; the file name stands) |
| D-050 | Deploy installs systemd units from the repo | superseded by D-066 (quadlet containers) |
| D-060 | O-009 postponed; T-052 narrowed to O-038 | obsolete: the anchor command shipped (D-108) and `daycloser` now exists (D-148) |
| D-075 | Visual direction v1: ledger, warm skin | superseded by D-160 (design v2) |
| D-090 | Owner authorisation for Fase 1 production steps | obsolete: one-off go-live authorisation, completed 20 Oct 2026 |
| D-097 | Four decimals in tables, two for cash | superseded by D-136 (two decimals everywhere) |
| D-115 | D-075 ratified, T-079 started | superseded by D-160 (design v2) |
| D-123 | Provisional account number, ten digits, no check digit | superseded by D-130 (branch code plus sequence) |

---

## 4. Proposals

Proposals are not decisions. Each takes effect only when the owner approves it (charter section 8),
at which point it is copied into section 2 as a new `D-xxx`.

| ID | Proposal | Status | What the owner must decide |
|---|---|---|---|
| P-01 | English is the language of all internal `docs/**`, replacing the "internal docs may be Indonesian" convention; supersedes AGENTS.md section 9 (last bullet) and the parent workspace rule 5.6 | Approved in principle by R-11; AGENTS.md edit lands with this rebuild | Confirm the AGENTS.md and parent workspace wording change, and that operator vocabulary in Indonesian stays allowed in `DOMAIN.md` and the UI |
| P-02 | Cancel the old Fase 5 proposal (archived in git history) as an authoritative plan and fold its content into the new roadmap; supersedes its status in the backlog | Approved in principle by R-13 | Confirm the proposal is archived and its backlog row is closed, with no residual "Fase 5" scope |
| P-03 | Uphold the D-160 visual direction and redesign structure, flows and component coverage instead of replacing the identity | Proposed; adopted by DD-01, design work proceeding in Wave 3 | Confirm at the design checkpoint that the identity is kept, or name the replacement |
| P-04 | No proposal text was ever written; the log reserved a fourth row for Wave 3 | Empty slot | Close the slot or provide the proposal text; no decision is pending under this id |
| P-05 | Defer the privacy, AML and complaint obligations (O4 subject access and breach runbook, O5 PMPJ daily cash aggregation, O8 complaint register) to the first real pilot cohort | Proposed; recorded with triggers in `OPEN_ITEMS.md` and `ACCEPTED-LIMITS.md` | Accept the deferral and its triggers, or schedule one or more of them in P7 |
| P-06 | Defer the encrypted off-host backup and keep L-04 (local, single-host, unencrypted) for the pilot | Proposed; matches R-39 | Accept the accepted limit, or schedule the encrypted off-host copy before the pilot |
