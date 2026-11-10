# ACCEPTED LIMITS

Register of things this product deliberately does not do. A row exists only if it has (a) a real
impact, (b) a way to detect that the impact has become a problem, (c) an owner and (d) the decision
that accepts it. A row without detection is forgotten work, not an accepted limit.

The register is written against the replanned product (R-10, KSP MVP). Time deposits and
interest-bearing savings are out of MVP scope (R-16); where existing code still implements them, the
limit says so and names the phase that removes it. Nothing in this file is a claim that a limit is
fixed.

Owner column: `owner` is the repo owner; `ops` is the person with server access (currently the same
person); the other values are roles from the plan.

---

## 1. Product and compliance limits

| ID | What is not done | Why accepted | How it is detected | Owner | Accepted by |
|---|---|---|---|---|---|
| L-01 | MFA is optional. There is no mandatory second factor, and an account without an `ACTIVE` factor still signs in fully, recorded as `mfa_enrolment_missing`. | R-19 and R-29: no recovery or administrative path exists, so enforcing would lock out every account that has not enrolled, including the first admin. | Count of `platform.user_mfa` rows with status `ACTIVE` against `platform.app_user`; audit `auth.login.success` with the missing-enrolment marker. | owner | R-19, R-29, D-063, D-200 |
| L-02 | MFA compensating controls are procedural, not technical: named accounts per role, daily audit review, no remote administration without network-level MFA, break-glass book and next-day report. | R-29 asks for named compensating controls instead of a false claim of mandatory MFA. | Account roster against `platform.user_role`; break-glass book entries; audit review sign-off; break-glass use count above three per month. | owner | R-29, D-131, D-134 |
| L-03 | The audit chain anchor stays on the host. There is no automated off-host anchoring; a manual daily head-hash copy plus written disclosure is the minimum. | R-20 and R-26: the automated surface was not costed, and the manual copy closes the disclosure requirement. | Anchor file exists for each business day; `ctl verify-audit` plus a head match; the backup script copies the anchor directory. There is no remote target. | owner | R-26, D-108, D-198 |
| L-04 | Backups are local, single-host and unencrypted. There is no off-host copy and no point-in-time recovery, only daily, weekly and monthly dumps on the same host. | R-39 accepts the local backup for the pilot; the remote, credentials and encryption key do not exist (P-06). | `ls -l` on the dump directory; absence of an `offsite:` remote; T-252 proves a restore from the local dump, not an encrypted off-host copy. | owner, ops | D-198, R-26, R-39, P-06 |
| L-05 | Health ratios, DPK and branch P&L reports are not built. | R-28 limits the MVP report pack to the RAT set; these reports need data and definitions that are not in the MVP. | The report route list contains nine RAT keys and none of the deferred keys; the gap is named in `ROADMAP.md`. | product | R-28 |
| L-06 | Non-member savings are out of scope. Only members hold savings; there is no non-member saver path. | DD-07: KSP practice, and keeping the member aggregate mandatory closes the CIF-versus-member split. The bylaw detail is `NEEDS-COMPLIANCE-REVIEW`. | Account opening requires a member; no non-member party type or route exists. | product | DD-07, R-15 |
| L-07 | Time deposits are not offered in the MVP. The existing `TIME_DEPOSIT` code, catalogue entries and claims are removed in P4. | R-16: the product is out of scope, and keeping a half-reachable stack invites false claims. | Catalogue and route inventory in P4; the P4 exit criterion requires removal, not hiding. | product | R-16, D-152 |
| L-08 | Savings do not earn interest. The return is SHU-based. | R-16. | No interest posting rule applies to savings accounts; SHU is the only return path. | product | R-16 |
| L-09 | SHU distribution is not automated. Calculation is automated; posting is a checker-approved manual journal with a mandatory RAT decision record. | R-27: distribution changes real money a few times a year and needs a recorded decision, not a batch. | RAT decision record exists; the distribution journal has a checker; no distribution task is registered. | finance | R-27 |
| L-10 | Member dues (`iuran`) are not enforced: no amount, cadence, arrears or exit refund. | R-15 requires the membership aggregate, but there is no national tariff; dues belong to AD/ART and RAT. | No obligation rows for dues; O-100 is still open; the parameter catalogue has no dues amount. | accounting | R-15, O-100 |
| L-11 | Printed output is browser print only: no server PDF, no stored PDF, no signature, no archive, no institution letterhead. Exact slip fields remain `NEEDS-COMPLIANCE-REVIEW`. | D-127 chose browser print to unblock Fase 2; a PDF engine needs an ADR and a letterhead needs an institution master. | Print routes call the browser; no PDF storage or hash exists; the statement has no running balance. | product | R-22, D-127 |
| L-41 | Subject access, correction, erasure and breach notification are not implemented: no export, no erase path, no breach runbook or drilled timeline. | P-05 defers O4 to the first real pilot cohort; REG-002 is `NEEDS-COMPLIANCE-REVIEW`. | No subject-request route or export; no breach runbook or incident log; T-206 records consent only. | compliance | P-05, REG-002, O-140 |
| L-42 | PMPJ daily cash aggregation and reporting are not built: cash movements are not aggregated per day for the PMPJ report. | P-05 defers O5 to the first real pilot cohort; REG-003 is `NEEDS-COMPLIANCE-REVIEW`. | No PMPJ route or daily aggregate query; cash totals appear only in teller and ledger reports. | compliance | P-05, REG-003, O-141 |
| L-43 | There is no complaint register: a member cannot file or track a complaint linked to a journal or slip. | P-05 defers O8 to the first real pilot cohort; the register needs an owner decision on handling and evidence. | No complaint table or route; O-142 stays open. | compliance | P-05, O-142 |

---

## 2. Security and data limits

| ID | What is not done | Why accepted | How it is detected | Owner | Accepted by |
|---|---|---|---|---|---|
| L-12 | There is no Nim lockfile. Dependencies are pinned to exact versions in `kran.nimble`, but the git revision of a dependency is not locked. | O-059 records that `nimble lock` broke the build with the local `nimbledeps` layout; exact pins were the working compromise. | Compare the binary sha256 in `releases.txt` for two builds of the same revision; a difference means the resolution drifted. | backend | D-003, O-059 |
| L-13 | A whole-tail rewrite of the audit chain is not detectable from the host alone. A branched chain is detected, but a complete rewrite that recomputes every hash is only caught by the anchor. | D-006 and D-060: the chain is computed in the database, and the off-host proof is R-26. | Today `ctl verify-audit` detects a branched or edited chain. The head match against the manual anchor copy is available after T-249; until then, only the local chain check runs. | ops | R-20, D-060, D-061, T-249 |
| L-14 | Audited writes are serialised by an advisory lock held to commit. Throughput has a ceiling. | D-006: serialising the chain is the price of a stable hash order. | `pg_locks` shows advisory waits; audited write latency rises with concurrency. | schema | D-006 |
| L-15 | `platform.idempotency_key.response_body` may contain PII until the row expires. There is no masking or column encryption. | D-118 accepts it for the pilot; D-175 bounds retention by TTL and a sweep. | `SELECT max(expires_at)`; sweep task status in `daycloser.run_task`; a stopped sweep means retention is not maintained. | backend | D-118, D-175 |
| L-16 | MFA challenge attempts are not throttled, there are no recovery codes, and an `ACTIVE` factor cannot be removed or replaced through the API. | O-071: the framework was delivered without the recovery path; enforcing before recovery would lock accounts. | No attempt counter exists for the challenge; an `ACTIVE` factor can only be changed by direct database work. | security | R-29, D-063, O-071 |
| L-17 | `X-Forwarded-For` is trusted only from loopback. A trusted-proxy list is not implemented. | D-142: the API and Caddy run on one host, and trusting the header from anyone would let clients forge audit IPs. | If the API moves to a separate host, every audit IP equals the proxy address. | ops | D-142 |
| L-18 | Content Security Policy still allows `style-src 'unsafe-inline'`, because Svelte injects styles at runtime. | D-045: script injection is the material risk; hashing runtime styles was not worth the breakage. | Inspect the `meta` policy in the built page; `style-src` contains `unsafe-inline`. | frontend | D-045 |
| L-19 | Mummy 0.4.8 exposes no HTTP keep-alive or idle timeout. A client can hold a socket and a 4 KiB receive buffer for the process lifetime. | D-037 bounds the version; the framework offers no knob. | Compare `ESTABLISHED` connections to the API with the number of real clients. | backend | D-037 |
| L-20 | API parser limits are pinned in code (8 KiB headers, 1 MiB body, 64 KiB WebSocket message), not inherited or configurable. An oversized request is dropped before the handler and the client sees a closed connection, not 413. | D-037 and T-044 pin the values so a Mummy upgrade cannot change them silently. | `apps/api/tests/tapi_limits.nim` fails when a limit is changed; the log records `Dropped connection, body too long`. | backend | D-037, D-044 |
| L-21 | Non-UUID branch identifiers cannot be attributed to `platform.audit_log.branch_id`; those audit rows carry no branch. | D-062 and O-017: forcing a cast would turn a valid request into a 500, and the identifier stays in `resource_id`. | Query audit rows for a known non-UUID branch id; `branch_id` is NULL. | schema | D-062, D-103 |
| L-22 | The runtime database role has grants for existing tables; a new table does not inherit them. Revocation and grant remain a migration step. | D-110 and O-126: default privileges cannot exclude a table, and the failure has occurred twice. | `has_table_privilege` over every table for `kran_runtime`; a missing grant surfaces as a permission error during a close or first write. | schema | D-110, O-126 |

---

## 3. Operations limits

| ID | What is not done | Why accepted | How it is detected | Owner | Accepted by |
|---|---|---|---|---|---|
| L-23 | Single host, single API process, single pool, one worker. There is no HA, no second instance and no load balancer failover. | R-10 pilot is one cooperative; multi-instance needs shared session and lock design that is not in scope. | One process and one pool in `podman ps` and `/readyz`; a host loss stops the service. | owner | R-10, P7/P8 |
| L-24 | Rollback returns the previous image, not the previous schema. A contract migration that already ran is not undone. | D-040 and D-119: schema rollback would need a rehearsed down path for real data. | `kran-api --role=migrate --check` after a rollback; compare `platform.schema_migration` with the deployed revision. | ops | D-040, D-119 |
| L-25 | `--down` has never been rehearsed against real data; there is no `.down.sql` for the real migrations. | D-040: the mechanism is proven only on synthetic files in the development database. | Absence of paired down files; the only exercise is the T-035 harness. | ops | D-040 |
| L-26 | The deploy log does not record build steps after the first deploy, so the memory manager and build flags cannot be read from it. | O-129: the log stopped capturing buildkit output; the binary was verified by forensic inspection instead. | `nm`/`objdump` on the deployed binary; `releases.txt` records only revision, image id and sha256. | ops | D-143, O-129 |
| L-27 | There is no metrics endpoint. Latency, error rate, pool use, outbox age and close duration are not exported. | Audit C19; the pilot is operated with logs, `/readyz` and SQL until P7. | `/metrics` returns 404; an operator must query logs or the database. | ops | audit C19, P7 |
| L-28 | The performance target is measured on a laptop, not on the VPS. The 100k-account benchmark is an optimistic upper bound. | T-140 and T-172 ran locally; entry-level VPS hardware was not available for the benchmark. | `./task bench-eod --accounts N` on the workstation; there is no production benchmark. | backend | audit C11, T-140 |
| L-29 | A `SIGTERM` can still truncate connections that were accepted but had not reached the handler; realtime sockets close with the process. | T-032: draining everything needs a listener-level handoff that the framework does not expose. | Log line `permintaan berjalan selesai (drain)` and the count of requests still running at exit. | backend | D-031, O-047 |
| L-30 | Cyclic garbage can leak under `atomicArc`, and the allocator crash is not proven fixed. | D-201 removed the cross-thread cycle bookkeeping, but there is no reproducer, so the fix is a design change, not a proof. | RSS trend over days; the CI step that classifies an API crash separately from assertion failures. | backend | D-201, O-128 |
| L-31 | Retention periods per record class are not set. The mechanism exists, but the number of years is undefined, so no purge task can be correct. | R-20 and R-26 define the mechanism; the periods are `NEEDS-COMPLIANCE-REVIEW` and O-130. | Table size growth for audit, outbox and inbox; no purge task runs. | compliance | R-20, R-26, O-130 |
| L-32 | There is no point-in-time recovery. Only full dumps exist, so the recovery point is the last dump, not the last transaction. | D-198 accepts the single-host backup state; WAL archiving was not built. | Restore drill restores a dump and reports the gap between dump time and the incident time. | ops | D-198, R-26 |

---

## 4. Engineering and test limits

| ID | What is not done | Why accepted | How it is detected | Owner | Accepted by |
|---|---|---|---|---|---|
| L-33 | `ledger.journal` is not partitioned. | D-072: pilot volume does not need it, and partitions complicate foreign keys and deferred balance triggers. | Table size and query time; a partition conversion is a separate expand/contract migration. | schema | D-072 |
| L-34 | Trial balance and balance gates read the whole journal history for the period. | Audit C11: the cost is acceptable at pilot size and a snapshot-backed read needs a reconciled close first. | Query duration and `EXPLAIN` on the gate path; the close takes longer as history grows. | backend | D-074, audit C11 |
| L-35 | Parameters are read from the database per request; there is no cross-process cache. | D-052: a `NOTIFY` cache could serve a stale security value without an error. | `settingsOf` share of p95 database time; more than 50 auth requests per second per process is the stated trigger. | backend | D-052 |
| L-36 | CI does not build the API container image. | Audit OPS-13: an image-only regression appears at deploy, not in CI. | The deploy health gate and the local `podman build`; there is no CI image job. | ops | audit C19 |
| L-37 | There is no component test project for the web app; UI state machines are covered by e2e only. | O-135 and experts X8: a DOM test environment needs its own ADR before it is added. | `vitest` runs unit tests only; a broken screen state is caught by e2e or by a user. | frontend | O-135, P6 |
| L-38 | The test harness duplicates helpers (23 `freePort` copies, 21 `serveInThread` copies). | Audit C07: consolidating them is cheap but touches many files; it is scheduled with the extraction, not before. | `rg -c 'proc freePort'` and the same for the server helper; the count does not fall. | backend | audit C07, P2 |
| L-39 | Capped list endpoints do not return a total, and some caps are silent (200, 100, 50 rows). | Audit C13: the pilot data fits, and pagination plus totals is a P5 contract change. | Response schema has no total; an operator cannot tell that a row is missing. | API | audit C13, P5 |
| L-40 | A cross-branch transfer is attributed to the source branch in audit, journal and event. The destination branch's GL does not show a temporary credit. | D-124: one journal per transfer is net zero at GL, and per-account movement lives in `deposit.transfer`. | Compare `deposit.transfer` by branch with `journal_line` account `201` per branch; they differ by the transfer amount. | accounting | D-124 |

---

## 5. How to use this register

- A new limit found during a task is added here with all six columns; it is not kept in a task file.
- Removing a row requires a decision id that changes the acceptance, not an implementation note.
- A row whose detection can no longer be run is a defect in the register, not a closed limit.
- This file does not claim the product is bug free, compliant, capacity proven or recoverable beyond
  the stated drills. Those claims require evidence that does not exist yet.
