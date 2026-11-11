# BACKLOG - KRAN

Queue for the replanned product. Phase definitions, exit criteria and the critical path live in
`ROADMAP.md`. A task is taken only when its status is `READY`, in phase order, one at a time per
worker. Serial rules are in `ROADMAP.md` section 4.

Status: `TODO` - `READY` - `IN_PROGRESS` - `DONE` - `BLOCKED`.

Risk class (R-31): `full` = independent review required (money, schema or migration, authz, audit);
`standard` = self-review plus gates. Review cap is 2 rounds (R-25).

Every task file follows `tasks/_TEMPLATE.md`. A row becomes `READY` only when its file exists with
every DoR item filled (R-32). The planning review of 5 Nov 2026 is in `review/2026-11-05.md`; its
findings are folded into the rows below and into the task files at DoR time.

## P0a - Gates see the money code

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-173 | `archcheck` handlers and tests categories + shrink-only baselines | M | - | standard | READY |
| T-174 | `lint-nomagic` covers `apps/api/src` + baseline | M | T-173 | standard | READY |
| T-175 | `nim check` warnings fatal or shrink-only | S | - | standard | READY |
| T-176 | `ci-fast` web arm fail-closed + `packages/ui` tests | S | - | standard | READY |
| T-177 | Dependency and lockfile audit | S | T-176 | standard | READY |
| T-178 | `fmt-check` dispatch arm (Nim only) | S | - | standard | READY |
| T-281 | Typed OpenAPI timestamps | S | T-178 | standard | TODO |
| T-278 | Role-authentic test fixtures (kasir, maker, checker) | S | T-173 | standard | TODO |
| T-179 | Baseline documentation + frozen green record | S | T-173, T-174, T-175, T-176, T-177, T-178, T-281, T-278 | standard | TODO |

## P0b - Web primitives (worker B)

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-230 | Primitive: idempotency | S | T-176 | standard | TODO |
| T-231 | Primitive: 15-minute session lock | S | T-230 | standard | TODO |
| T-232 | Primitive: identity/member reference (baseline) | S | T-230 | standard | TODO |
| T-233 | Primitive: `Money` adoption | S | T-230 | standard | TODO |
| T-279 | Primitive: `DataTable<T>` generic | M | T-230 | standard | TODO |
| T-235 | Component-test tooling ADR | S | T-176 | standard | TODO |

## P1 - Financial correctness

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-180 | Journal ownership + reversal denial (B3) | M | T-173, T-174 | full | TODO |
| T-181 | Write-off allowance release + `DAY-384` remediation (B4) | M | T-180 | full | TODO |
| T-186 | Write-off component split: one definition, one reconciliation test (R-36) | S | T-181 | full | TODO |
| T-182 | `payment_allocation` FK + deferred sum trigger (B5/DB-01) | M | T-181 | full | TODO |
| T-187 | Reconciliation gates for daily close (GL 110/111, allocation sum) | M | T-180, T-181, T-182 | full | TODO |
| T-268 | EOM `daycloser` task registered + preconditions | M | T-182 | full | TODO |
| T-183 | HTTP period close preconditions (BE-LOGIC-04) | S | T-268 | standard | TODO |
| T-184 | One business date + `utc_offset_minutes=420` (C04) | S | T-183 | full | TODO |
| T-185 | Stable `params.reason` + error mapping (C02) | S | T-183 | standard | TODO |
| T-269 | Restructure checker + released-arrears treatment (R-38) | S | T-181 | full | TODO |
| T-270 | Late penalty assessment + waiver with checker | M | T-182 | full | TODO |
| T-271 | Origination controls: tiers, exposure cap, arrears block (R-42) | M | T-182 | full | TODO |
| T-251 | Privilege test for the runtime DB role | M | T-182 | full | TODO |
| T-188 | Characterization net + harness consolidation | M | T-173 | standard | TODO |

## P1b - Security and data integrity

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-260 | Origin/CSRF enforcement for bodyless POSTs | S | T-173 | full | TODO |
| T-261 | MFA challenge throttle + factorless policy | S | T-260 | full | TODO |
| T-262 | Grant/revoke bounds for user administration | S | T-260 | full | TODO |
| T-263 | Immutable-table DB grants | M | T-182 | full | TODO |
| T-264 | Schema integrity batch (`NOT VALID` then `VALIDATE`) | M | T-263 | full | TODO |
| T-265 | Wire the parameter cache (after-commit invalidation) | M | T-184 | standard | TODO |
| T-266 | Snapshot-backed balances | M | T-187 | standard | TODO |
| T-267 | Audit lock and index review | M | T-263 | full | TODO |

## P2a - Coop-facing extraction

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-189 | `deposit` extraction | M | T-188 | standard | TODO |
| T-190 | `ledger` extraction | L | T-189 | standard | TODO |
| T-191 | `party` extraction | L | T-190 | standard | TODO |
| T-192 | Platform slice: params, user, audit read models | L | T-191 | standard | TODO |
| T-193 | Per-module gate shrink | S | T-189, T-190, T-191, T-192 | standard | TODO |
| T-194 | Behaviour-preservation proof per module | S | T-189, T-190, T-191, T-192 | standard | TODO |
| T-195 | Extraction ADR recording the seam | S | T-189, T-190, T-191, T-192 | standard | TODO |

## P2b - Remaining extraction

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-196 | `product` extraction | M | T-195 | standard | TODO |
| T-197 | `teller` extraction | L | T-196 | standard | TODO |
| T-198 | `daycloser` extraction | M | T-197 | standard | TODO |
| T-199 | `lending` extraction | L | T-197, T-182 | full | TODO |
| T-200 | Platform completion (`handlers_branches`, reports) | L | T-199 | standard | TODO |
| T-201 | Delete `hello` | S | T-200 | standard | TODO |
| T-202 | Handler shrink verification (imports, not path text) | M | T-196, T-197, T-198, T-199, T-200 | standard | TODO |
| T-203 | Docs update for extraction | S | T-202 | standard | TODO |
| T-273 | Deposit read models for teller screens | M | T-189 | standard | TODO |
| T-280 | Loan schedule preview + admissibility contract (K-12) | M | T-199 | full | TODO |

## P3 - Membership aggregate (`coop`)

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-204 | `coop` schema + member aggregate | M | T-195 | full | TODO |
| T-205 | Member number, status, join/exit | M | T-204 | standard | TODO |
| T-206 | Minimal KYC record (consent fields per O4) | S | T-205 | standard | TODO |
| T-207 | Obligations derived from postings | M | T-206 | standard | TODO |
| T-208 | Obligation generation rules | M | T-207 | standard | TODO |
| T-209 | API surface + contract (pay, waive with checker) | M | T-208 | full | TODO |
| T-210 | Backfill from `party` | M | T-209 | full | TODO |
| T-211 | SHU basis decision + proof of derivation | M | T-207, T-208 | standard | TODO |
| T-272 | Member exit: eligibility, refund, offset, closure, statement (R-43) | M | T-210, T-214 | full | TODO |

## P4 - Coop product model: savings + EOY/SHU

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-212 | Remove time deposits (code, catalogue, claims, params) | M | T-196 | full | TODO |
| T-213 | Savings kinds + SHU-based return | M | T-212 | standard | TODO |
| T-214 | Pokok/wajib obligation posting + arrears | M | T-209, T-213 | full | TODO |
| T-215 | EOY `daycloser` task: closing entries, closed periods, TB zero | M | T-212, T-268 | full | TODO |
| T-216 | SHU computation without seeded defaults | L | T-211, T-215 | full | TODO |
| T-217 | RAT decision record | S | T-216 | standard | TODO |
| T-218 | Distribution journal with checker | M | T-217 | full | TODO |
| T-275 | SHU distribution per member + reconciliation (R-35) | M | T-218 | full | TODO |
| T-274 | Cash instalment contract (atomic) (R-34) | M | T-199, T-214 | full | TODO |
| T-219 | Parameter skeleton + `NEEDS-COMPLIANCE-REVIEW` tags | S | T-216 | standard | TODO |

## P5 - Reporting and list contracts

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-220 | List contract: pagination + totals | M | T-195 | standard | TODO |
| T-221 | Balance sheet | M | T-220 | standard | TODO |
| T-222 | Income statement | M | T-221 | full | TODO |
| T-223 | Equity statement | S | T-222 | standard | TODO |
| T-276 | Cash-flow statement + notes to the financial statements (R-44) | M | T-223 | full | TODO |
| T-224 | Member register | M | T-209 | standard | TODO |
| T-225 | Savings arrears | M | T-214 | standard | TODO |
| T-226 | Loan exposure and arrears | M | T-187 | standard | TODO |
| T-227 | Cash recap | M | T-220 | standard | TODO |
| T-228 | Close certificate | M | T-268, T-220 | standard | TODO |
| T-229 | SHU statement per member | M | T-275, T-220 | standard | TODO |
| T-277 | Audit viewer filters + cursor | S | T-220 | standard | TODO |

## P6 - UI rebuild

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-236 | Component: MoneyInput (Input/Select delivered by T-286) | S | T-235 | full | READY |
| T-237 | Component: DataTable on `T-279` (extend, not recreate) | M | T-235, T-279 | standard | TODO |
| T-238 | Component: ReviewPanel / ApprovalPanel | M | T-235 | standard | TODO |
| T-239 | Component: Dialog / Confirm | S | T-235 | standard | TODO |
| T-240 | Component: Empty / Error / Loading states | S | T-235 | standard | TODO |
| T-284 | Design tokens v2 + full contrast matrix (D-202) | S | none | standard | DONE |
| T-285 | App shell: AppShell/Sidebar/Topbar/PageHeader/Toolbar (D-202) | M | T-284 | standard | DONE |
| T-286 | Form controls v2: Input / Select / Checkbox (Field folded in) | M | T-284 | standard | DONE |
| T-287 | Button v2: sizes, quiet variant, hover/active rules | S | T-284 | standard | DONE |
| T-288 | DataTable v2: density, sticky header, totals, selection | M | T-284 | standard | DONE |
| T-289 | Money inside DataTable: one symbol per column, stable width | S | T-288 | full | DONE |
| T-290 | Drawer 520 with an honest focus trap | M | T-285, T-288 | standard | DONE |
| T-291 | Report and print: no chrome, token colours, number rules | S | T-288, T-289 | standard | DONE |
| T-292 | State sweep: three empties, loading/error components, terminology | M | T-284, T-285 | standard | DONE |
| T-293 | Loans list density: one-line dates, member name over ID, 40px rows | M | T-284, T-288 | standard | DONE |
| T-294 | Shell reflow at 360 and 200%, one ledger tab stop | M | T-284, T-285, T-288 | standard | READY |
| T-295 | Loans money columns state their unit in the header | S | T-289, T-293 | standard | DONE |
| T-296 | Visual baselines ignore the build version | S | T-289 | standard | DONE |
| T-234 | AppShell + navigation | M | T-232, T-233, T-279 | standard | SUPERSEDED by T-285 |
| T-237 | Component: DataTable on `T-279` (extend, not recreate) | M | T-235, T-279 | standard | SUPERSEDED by T-288 |
| T-240 | Component: Empty / Error / Loading states | S | T-235 | standard | SUPERSEDED by T-292 |
| T-241 | Repair screens: vault, ledger, params, password, login (5 subtasks) | M | T-234 | standard | TODO |
| T-242 | Rebuild: Kas + close (K-01, K-03) | L | T-197, T-231, T-268, T-273, T-274 | standard | TODO |
| T-243 | Rebuild: ledger admin, loans, loan detail, products, users, slip, statement | L | T-199, T-200, T-229, T-273 | standard | TODO |
| T-244 | Merge `accounts/open` into member detail | S | T-245 | standard | TODO |
| T-245 | New screens: members, onboarding, member file, exit, obligations, origination, approval queue, arrears, reports, audit | L | T-209, T-217, T-220, T-226, T-229, T-272, T-280 | standard | TODO |

## P7 - Operator admin and pilot hardening

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-248 | Retention decision per record class (signed periods) | S | T-192 | standard | TODO |
| T-282 | Retention purge tasks per class | M | T-248 | full | BLOCKED |
| T-246 | User admin UI + API (B13) | M | T-192 | full | TODO |
| T-283 | Operator seat matrix: admin, obligation, manager, read-only pengurus | S | T-246 | full | TODO |
| T-247 | Provision named operators from the seat matrix | S | T-283 | standard | TODO |
| T-249 | Manual daily head-hash copy + disclosure (named off-host destination) | S | T-248 | standard | TODO |
| T-250 | `/metrics` | M | T-192 | standard | TODO |
| T-252 | Backup restore drill from the local dump (R-39) | M | T-251 | standard | TODO |
| T-253 | Pilot readiness checklist (signatures, artefacts, procedures) | S | T-246, T-247, T-248, T-249, T-250, T-251, T-252, T-283 | standard | TODO |

## P8 - Synthetic-coop dry run

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-254 | Synthetic data generator (12 months to a fiscal-year boundary) | M | T-253 | standard | TODO |
| T-255 | 30-business-day dry-run script into EOY | M | T-254 | standard | TODO |
| T-256 | Performance measurement at pilot volume | M | T-255 | standard | TODO |
| T-257 | Audit evidence pack | S | T-249, T-252, T-255 | standard | TODO |
| T-258 | Dry-run report | S | T-255, T-256, T-257 | standard | TODO |
| T-259 | Final `task ci` + release readiness | S | T-258 | standard | TODO |

## Deferred

Items explicitly outside P0-P8 and their revisit triggers are in `ROADMAP.md` section 7. They are
not backlog rows and must not be pulled into a phase without a new decision.
