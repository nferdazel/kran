# OPEN ITEMS

Things that are still unresolved and must not be forgotten. An open item has an owner action and a
class, or it is not an open item. Closed items are dropped, except where code still cites the id:
section 2 keeps one line for each of those so the reference resolves.

Classes: `compliance` (needs a regulatory or accounting sign-off), `security` (a control gap),
`product` (a capability the plan does not yet deliver), `tooling` (a generator or gate that does not
exist), `operations` (an operational procedure or signal that is missing), `accepted` (tracked in
`ACCEPTED-LIMITS.md` until its trigger fires).

Every item that blocks pilot data stays a `BLOCKER` until closed. No item is closed by prose.

---

## 1. Still valid

| ID | Title | Why it is still open | Owner action | Class | Related |
|---|---|---|---|---|---|
| O-001 | Unverified regulatory values in section 4 | The values and article numbers that carry `V?`/`V!` have not been signed off. The pilot defaults are accepted without a compliance claim, and the tag is removed per institution, never globally. | Compliance review per institution before the first real member or client; record the rule number and access date in the change reason. | compliance | D-114, D-095, `docs/compliance/register.yaml` |
| O-019 | Readiness does not cover every producer | The deploy does not sync the migration root used by the readiness probe, the worker has no `PENDING`/`DEAD` age probe, and readiness lag covers the realtime pump only. | Fold the missing probes and the migration-root sync into the P7 observability task. | operations | P7, `/readyz`, audit C19 |
| O-024 | Headless UI components deferred | `packages/ui` still has no dialog, combobox or virtualised table; the trigger is the first business screen that needs one. | Reopen at the P6 screen that first needs a dialog or combobox. | product | D-176 |
| O-025 | In-process server teardown is unsafe | Building and serving the server must stay on one thread and `close()` is not called from another; production does not call it, the test harness does. | Keep the same-thread rule; revisit only if the harness shape changes. | accepted | D-031, audit C06 |
| O-026 | Contract fuzzing absent | `schemathesis` was deferred; the in-repo response validator knows a subset of JSON Schema. | Reopen when a new endpoint or client is no longer represented by the internal validator, or when a response-shape bug reaches a client. | tooling | D-176 |
| O-028 | Realtime send queue per connection is unbounded | A slow client can grow process memory; lost events are covered by the resume token. | Measure when a real slow-client complaint appears or when subscriber count makes queue memory material. | accepted | D-176, D-037 |
| O-041 | No general cross-key invariant engine | Only the session policy pair is checked; a second cross-key rule has no declarative mechanism. | Reopen when a second rule cannot be expressed as a small explicit check. | tooling | D-027, D-176 |
| O-071 | MFA remainder | Challenge attempts are not throttled, there are no recovery codes, an `ACTIVE` factor cannot be removed or replaced through the API, and there is no factor management UI. The login challenge exists behind a parameter that stays false. | Deliver throttling and recovery before any deployment that requires MFA; then factor removal and the UI. | security | R-29, D-063, D-200 |
| O-084 | Accrual values need confirmation | The accrual shape is fixed and the rate is a pilot value tagged `NEEDS-COMPLIANCE-REVIEW`; compliance has not confirmed the rate, basis or posting point for real member data. | Compliance sign-off before interest is accrued for a real member. | compliance | D-137, D-152, R-16 |
| O-098 | Vault downward adjustment has no path | A vault top-up is maker-checker, but a downward correction of a vault difference has no request or approval route. | Decide the correction policy; if approved, add a request with a reason, a second approver and a reversing journal. | product | D-132, D-134 |
| O-100 | Member dues rules undecided | Equity classification is settled (D-195), but the amount, cadence, arrears and exit treatment of `iuran` are not; there is no national tariff, so they belong to AD/ART and RAT. | Accounting owner and members decide through AD/ART; then parameterise and post. | compliance | R-15, D-195, REG-101 |
| O-101 | Branch master has no write route | Branches can be read over HTTP and created only with `ctl`; there is no create or update route or screen. | Add branch administration if pilot staffing requires it; otherwise keep `ctl` and document it. | product | D-130, P7 |
| O-104 | Account number final format | The number is three digit branch code plus seven digit sequence, with no check digit; a compliance requirement for a check digit or another format would need a new migration. | Decide before real member data; a new format means new numbers, never rewriting old ones. | compliance | D-130 |
| O-127 | No retroactive parameter date | A value that must apply to an already closed or frozen business date cannot be entered; the operator has no path to backdate a parameter. | Decide whether a dated correction path is allowed; it needs an ADR, reason, audit and a two-person approval. | product | D-146, D-149 |
| O-129 | Deploy log does not record build steps | After the first deploy the log stopped recording buildkit steps, so the memory manager and build flags can only be verified by inspecting the binary. | Record the build command and binary sha256 per release in `releases.txt`; until then verify with `nm`/`objdump`. | operations | D-143, D-201 |
| O-130 | Retention periods per record class are undefined | The mechanism exists (TTL, sweep, anchor) but the number of years per class (audit, outbox, inbox, transaction, identity) is not set, so T-282 cannot leave `BLOCKED`. | Compliance owner signs the periods in T-248; then T-282 encodes them as parameters and purge tasks. | compliance | R-20, R-26, T-248, T-282, audit C09 |
| O-131 | Privacy operations are missing | There is no consent record, no data-subject access path, no complaint register and no breach-notification runbook. T-206 adds consent fields; the deferred remainder is O-140 to O-142 under P-05. | Decide which remain product scope; the rest go to `OPERATIONS.md` and `COMPLIANCE.md`. | compliance | P-05, T-206, audit C19, `NEEDS-COMPLIANCE-REVIEW` |
| O-132 | Capability ledger is hand-maintained | `PARAMETERS.md` and `SCHEMA.md` are generated by `tools/docsgen`, but `CAPABILITIES.md` and `capabilities.yaml` are still edited by hand and can drift from the tests. | Add a capability generator or a check that every `delivered` row points at an existing test; until then, the DoD requires updating the ledger in the same task. | tooling | audit C06, P0 |
| O-134 | Role-authentic seed users absent | E2e and manual acceptance cannot sign in as `lending_maker` or `lending_checker`; the pilot also has fewer named operators than R-23 requires. | Create the seed users and the two named pilot operators before P8. | product | R-17, R-23, P8 |
| O-135 | No component test project | UI state machines are covered by e2e only; a DOM test environment and a second vitest project need an ADR. | Approve the ADR, then make component tests a P6 exit criterion. | tooling | P6, experts X8 |
| O-136 | No dependency audit in CI | There is no Dependabot configuration and no `pnpm` or Nimble audit step, so a known-vulnerable dependency does not fail a gate. | Add the audit to P0 and fail closed on a new high finding. | security | audit C06, P0 |
| O-137 | OpenAPI timestamps are untyped | Timestamp properties are plain strings in the contract, so the generated client cannot enforce a date-time shape. | Type them in the contract during P0 and regenerate the client. | tooling | audit BE-ISO-06, P0 |
| O-138 | No metrics endpoint | There is no Prometheus-style metrics surface for latency, errors, pool, outbox or close duration; operators have logs, `/readyz` and SQL. | Deliver a minimal `/metrics` and the retention/metrics tasks in P7. | operations | audit C19, P7 |
| O-139 | Applied migrations keep pre-rebuild doc paths | Seven migrations were deployed on 3 Nov 2026 and are checksummed by `migrate --check`. Their comments still point at task files that the docs rebuild removed; editing them makes the next deploy fail closed with a drift error. | Keep them frozen. New comments go in new migrations, never in an applied file. | operations | `docs/OPERATIONS.md` section 2, deploy log 5 Nov 2026 |
| O-140 | Subject access and breach runbook deferred | There is no subject-access export, correction or erase path, and no breach runbook with a drilled timeline. P-05 defers O4 to the first real pilot cohort. | Revisit before the first real member record or the first subject-access or breach event, whichever comes first; accept P-05 or schedule the work in P7. | compliance | P-05, REG-002, T-206, L-41 |
| O-141 | PMPJ daily cash aggregation absent | Cash movements are not aggregated per day for the PMPJ report; no route or query exists. P-05 defers O5 to the first real pilot cohort. | Revisit before the first real cash transaction or when daily cash reaches the PMPJ threshold; accept P-05 or schedule the report in P7. | compliance | P-05, REG-003, L-42 |
| O-142 | Complaint register absent | A member cannot file or track a complaint linked to a journal or slip; no table or route exists. P-05 defers O8 to the first real pilot cohort. | Revisit before the first real member record or the first complaint; accept P-05 or schedule the register in P7. | compliance | P-05, L-43 |
| O-143 | Encrypted off-host backup deferred | Backups stay local, single-host and unencrypted; the encrypted off-host copy and its credentials do not exist. P-06 accepts this with R-39 and L-04. | Revisit before the first real member record or when a second host and remote credentials exist; accept P-06 or schedule the encrypted copy before the pilot. | accepted | P-06, R-39, L-04, T-252 |
| O-144 | MFA anti-replay test fails on a TOTP step boundary | `apps/api/tests/itapi_mfa.nim:698` recomputes `codeFor(..., offset 0)` instead of reusing the literal code from the previous case. A run that crosses a step boundary posts a code for a newer step, which `itapi_mfa.nim:539` accepts by design, so the case expects 403 and gets 204. Observed once on CI run 42986811102 (08:29:00.018Z), green on rerun. Test defect, not an auth defect. | Post the same captured code string twice so the case is deterministic; do not loosen the assertion. | tooling | T-241, CI run 42986811102 |
| O-145 | P0a gate work sits behind P6 | The six P0a rows (T-173..T-178) were `READY` while no `docs/tasks/T-*.md` existed for them, so R-32 kept them out of the real queue; on 12 Nov 2026 they were set back to `TODO`. The lead's ordering call is to close P6 first: P6 is the phase closest to done (T-236 and T-294 in flight) and the application is already used in production, while P0a cannot start without a DoR that does not exist. | Finish P6, then write the six DoR files and run P0a; no P0a row returns to `READY` until its task file exists. | tooling | P0, P6, R-32, T-173-T-178 |

---

## 2. Closed, still cited

One line per closed id that still appears in code, tests or tooling. The line exists so the reference
resolves; the closure story is in git history and `docs/DECISIONS.md`.

| ID | Closed by | Resolution |
|---|---|---|
| O-002 | D-046 item 4 | The backup script excludes non-production databases. |
| O-006 | D-048, ADR-017 | Field encryption uses a separate mode 600 KEK file outside the database backup. |
| O-008 | D-176 | Belongs to the host, not this repository; host-level work is tracked outside the repo. |
| O-009 | D-108 | A daily audit anchor command exists; the off-host copy is R-26, not this item. |
| O-010 | D-110 | The runtime role cannot update audit rows; grants were extended by `platform/0042`. |
| O-011 | T-033 | Pool concurrency is tested and connection validation is real. |
| O-012 | D-041 | Scope lookup is `Option[string]`, so "not requested" and "empty id" differ. |
| O-013 | D-148 | `ctl daycloser-status` returns a real exit code used by the deploy gate. |
| O-014 | D-051 | `shellcheck -S warning` blocks and fails closed when the tool is absent. |
| O-016 | D-113, D-131 | The seeded separation-of-duties pairs are sufficient for the pilot. |
| O-017 | D-103 | Application branch ids are UUIDs; `scope_id` remains text by design. |
| O-018 | D-052 | Reading parameters per request is the decision; no cross-process cache is built, so the item is closed as a decision. |
| O-022 | D-177 | A Linux visual baseline is committed and compared by the e2e job. |
| O-027 | D-199 | The traceability gate reads the repository register. |
| O-029 | T-029 | The realtime pump reconnects with backoff and is visible in `/readyz`. |
| O-030 | T-053 | Realtime protocol limits are parameters. |
| O-031 | D-034, D-035 | Production bootstrap is a one-shot `bootstrap-admin` with a forced password change. |
| O-032 | D-062 | HTTP requests carry branch attribution and list routes filter per row. |
| O-034 | D-034 | Account enumeration is closed by password-first checks and a dummy KDF. |
| O-035 | T-022 | Malformed input is answered 400 or 404, not 500. |
| O-036 | D-030 | Realtime subscriptions end with the session, not with the socket. |
| O-037 | D-032 | The outbox cursor invariant is written in `MODULE.md` and covered by a two-connection test. |
| O-038 | D-061 | Audit verification follows `prev_hash` and also detects a branched chain. |
| O-039 | D-042 | `requires_approval: false` is rejected by `paramgen`. |
| O-040 | D-032 | The double-approve race test runs with `--threads:on`. |
| O-042 | T-053 | Tests read schema bounds from parameter definitions or the generated artefact. |
| O-043 | D-056 | `effectiveTo` without a successor is rejected at submission and approval. |
| O-044 | D-171 | Candidate values are checked only where login actually reads them. |
| O-045 | T-053 | Stable `params.reason` codes are mapped to messages in the UI. |
| O-046 | T-030 | Approved realtime topics are rechecked when permissions change. |
| O-047 | T-032 | SIGTERM drains in-flight requests with a ten second bound. |
| O-048 | D-040 | Contract and `--down` migrations exist in the binary and the ops script. |
| O-049 | D-037 | The two Mummy internals in use are bounded by a version range and regression tests. |
| O-050 | D-057 | Wrong old passwords increment the login counter and write an audit entry. |
| O-051 | T-151 | The password policy is readable through its own endpoint. |
| O-052 | D-058 | Character classes and history are parameters; expiry is deliberately absent. |
| O-053 | Closed 3 Nov 2026 | Role and permission name keys are present in the catalogue. |
| O-056 | D-046 item 6 | There is no silent fallback between parameter levels. |
| O-057 | T-048 | The startup check uses the same visibility rule as runtime resolution. |
| O-059 | T-045 | There is no Nim lockfile; dependencies are pinned exactly in `kran.nimble`. |
| O-060 | Closed 21 Oct 2026 | The worker role exists and runs the posting loop. |
| O-061 | D-045 | CSP uses meta hashes; the header carries only `frame-ancestors`. |
| O-062 | T-045 | The dev seed refuses a database whose name does not end in `_dev` or `_test`. |
| O-063 | D-044 | `LICENSE` states proprietary, all rights reserved. |
| O-064 | Closed 3 Nov 2026 | Parameter values can be ended through a maker-checker end request. |
| O-065 | D-109 | A checker can reject a pending parameter submission with a reason. |
| O-066 | D-095, D-121 | Seed provenance is a generated artefact with an explicit class per key. |
| O-067 | D-171 | A GLOBAL value can close a branch-scoped period. |
| O-068 | T-060 | Password KDF cost has a measured budget and a benchmark command. |
| O-070 | D-173 | `param.changed` is filtered per subscriber branch. |
| O-073 | D-111 | KEK rotation is forbidden until a blind-index reindex command exists. |
| O-074 | D-102 | The pool stress test has a purpose-based wait budget; assertions are unchanged. |
| O-075 | D-193 | Contra accounts are not modelled; CKPN stays on a credited asset account. |
| O-076 | Closed 21 Oct 2026 | A period-close race test proves the blocked branch and the 409. |
| O-078 | Closed 21 Oct 2026 | Reversal idempotency races are covered by three two-connection tests. |
| O-079 | D-105 | Reversal is rejected when the source account is inactive. |
| O-080 | D-107 | Posting rule changes remain migrations until a maker-checker API is designed. |
| O-081 | D-101 | The worker writes a heartbeat and `/readyz` checks it. |
| O-086 | Closed 20 Oct 2026 | The journal `xmin` guard is replaced or documented; savepoint behaviour is known. |
| O-087 | D-172 | JSON parameter values are depth-limited and reject `null`. |
| O-088 | T-152 | The local test reset drops extensions, so the empty-database path is exercised. |
| O-089 | D-091 | A concurrent period close blocks journal insertion through the row lock. |
| O-090 | D-092 | Base parameters are seeded in the migration path before units restart. |
| O-092 | Closed 21 Oct 2026 | An external alert script and timer cover `/readyz` and dead outbox rows. |
| O-093 | D-118, D-175, L-15 | Idempotency response bodies keep PII until TTL expiry; no masking is added and the residual risk is the accepted limit L-15. |
| O-094 | Closed 3 Nov 2026 | Automatic day close is enabled at 23:30 WIB and the first close completed. |
| O-096 | Closed 22 Oct 2026 | Test suites reset all schemas and reapply every migration. |
| O-097 | D-132 | Teller and vault cash have accounts and posting rules. |
| O-099 | D-133 | Opening float, deposit, withdrawal and top-up have parameter limits. |
| O-105 | D-134 | The opening vault balance is a journal against `203 TITIPAN PENGURUS`. |
| O-107 | T-152 | Axe scans have a longer timeout; the flow test keeps the shorter one. |
| O-108 | D-164, D-168 | Early withdrawal works for cash and for outgoing transfer, with penalty rows. |
| O-109 | D-165 | The second ARO cycle uses a paid-cumulative baseline and a product rollover tenor. |
| O-110 | D-167 | One journal may carry two subledger rows when the accounts differ; no schema change was needed. |
| O-111 | D-170 | The unused `last_activity` column was dropped by a contract migration. |
| O-112 | D-161 | Maturity and cash deposit serialise on the same account row. |
| O-113 | D-170 | Dormant status changes write one audit entry per chunk. |
| O-114 | D-174 | Zero-balance dormant accounts close after 24 months. |
| O-115 | D-163 | Non-critical day-close failures raise an external alert. |
| O-116 | D-162 | Every valid session receives the institutional business date. |
| O-118 | D-166 | The axe threshold moved to `moderate` after the screen migration, so the deferral is closed. |
| O-119 | D-178 | CI check names are a contract with `CI_EXPECTED` in `deploy-vps.sh`; renames land with the gate change. |
| O-120 | Closed 2 Nov 2026 | The CI gate uses an authenticated token. |
| O-121 | D-193 | CKPN stays on account `111`; no contra type is added. |
| O-122 | D-191 | Recovery after write-off posts income per component with a cumulative cap. |
| O-123 | D-197 | A restructured loan is grade-capped until the clean-period count is met. |
| O-124 | D-198, P-06, L-04 | Off-host backup and anchor copy are accepted limits for the pilot, tracked in `ACCEPTED-LIMITS.md`. |
| O-126 | `lending/0102` | The runtime role received grants for the seven lending tables; new tables still need their own grant migration. |
| O-128 | D-201 | Binaries use `atomicArc`; the crash is not proven fixed and stays an accepted limit. |
| O-133 | DOC-03 | `capabilities.yaml` and `CAPABILITIES.md` exist; the table is hand-maintained and O-132 tracks the drift risk. |
