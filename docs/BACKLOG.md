# BACKLOG - KRAN

Queue for the replanned product. Phase definitions, exit criteria and the critical path live in
`ROADMAP.md`. A task is taken only when its status is `READY`, in phase order, one at a time per
worker (see `ROADMAP.md` §4 and the parallel matrix in the planning archive).

Status: `TODO` · `READY` · `IN_PROGRESS` · `DONE` · `BLOCKED`.
Risk class: `full` = independent review required (money, schema, authz, audit); `schema` = migration;
`standard` = self-review plus gates. Review cap is 2 rounds (R-25).

Every task file follows `tasks/_TEMPLATE.md`. Acceptance criteria are written there from the
task anchor before the task becomes `READY`.

## P0 - Gates see the money code

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-173 | `archcheck` handlers category + shrink-only baseline | M | - | standard | READY |
| T-174 | `lint-nomagic` covers `apps/api/src` + baseline | M | T-173 | standard | READY |
| T-175 | `nim check` warnings fatal or shrink-only | S | - | standard | READY |
| T-176 | `ci-fast` gates for `apps/web` + `packages/ui` flag | S | - | standard | READY |
| T-177 | Dependency and lockfile audit | S | T-176 | standard | READY |
| T-178 | `fmt-check` dispatcher + typed OpenAPI timestamps | M | - | standard | READY |
| T-179 | Baseline documentation + frozen green record | S | T-173, T-174, T-175, T-176, T-177, T-178 | standard | TODO |
## P1 - Financial correctness

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-180 | Journal ownership + reversal denial (B3) | M | T-173, T-174 | full | TODO |
| T-181 | Write-off allowance release + `DAY-384` remediation (B4) | M | T-180 | full | TODO |
| T-182 | `payment_allocation` FK + deferred sum trigger (B5/DB-01) | M | T-181 | full | TODO |
| T-183 | HTTP period close preconditions (BE-LOGIC-04) | S | - | standard | TODO |
| T-184 | One business date + `utc_offset_minutes=420` (C04) | S | T-183 | full | TODO |
| T-185 | Stable `params.reason` + error mapping (C02) | S | T-183 | standard | TODO |
| T-186 | Verify the two risk-credit claims and act | M | T-181 | full | TODO |
| T-187 | Reconciliation gates for daily close (GL 110/111) | M | T-180, T-181, T-182 | full | TODO |
| T-188 | Characterization net + harness consolidation | M | T-173 | standard | TODO |
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
| T-199 | `lending` extraction | L | T-197 (needs T-180-T-182) | full | TODO |
| T-200 | Platform completion | L | T-199 | standard | TODO |
| T-201 | Delete `hello` | S | T-200 | standard | TODO |
| T-202 | Handler shrink verification | M | T-196, T-197, T-198, T-199, T-200 | standard | TODO |
| T-203 | Docs update for extraction | S | T-202 | standard | TODO |
## P3 - Membership aggregate (`coop`)

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-204 | `coop` schema + member aggregate | M | T-195 | schema | TODO |
| T-205 | Member number, status, join/exit | M | T-204 | standard | TODO |
| T-206 | Minimal KYC record | S | T-205 | standard | TODO |
| T-207 | Obligations derived from postings | M | T-206 | standard | TODO |
| T-208 | Obligation generation rules | M | T-207 | standard | TODO |
| T-209 | API surface + contract | M | T-208 | standard | TODO |
| T-210 | Backfill from `party` | M | T-209 | standard | TODO |
| T-211 | SHU basis decision + proof of derivation | M | T-207, T-208 | standard | TODO |
## P4 - Coop product model: savings + EOY/SHU

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-212 | Remove time deposits (code, catalogue, claims, params) | M | T-203 | standard | TODO |
| T-213 | Savings kinds + SHU-based return | M | T-212 | standard | TODO |
| T-214 | Pokok/wajib obligation posting + arrears | M | T-209, T-213 | full | TODO |
| T-215 | EOY `daycloser` task registered + idempotent | M | T-212 | standard | TODO |
| T-216 | SHU computation without seeded defaults | L | T-211, T-215 | full | TODO |
| T-217 | RAT decision record | S | T-216 | standard | TODO |
| T-218 | Manual distribution journal with checker | M | T-217 | full | TODO |
| T-219 | Parameter skeleton + `NEEDS-COMPLIANCE-REVIEW` tags | S | T-216 | standard | TODO |
## P5 - Reporting and list contracts

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-220 | List contract: pagination + totals | M | T-203 | standard | TODO |
| T-221 | Balance sheet | M | T-220 | standard | TODO |
| T-222 | Income statement | M | T-221 | full | TODO |
| T-223 | Equity statement | S | T-222 | standard | TODO |
| T-224 | Member register | M | T-209 | standard | TODO |
| T-225 | Savings arrears | M | T-214 | standard | TODO |
| T-226 | Loan exposure and arrears | M | T-187 | standard | TODO |
| T-227 | Cash recap | M | T-220 | standard | TODO |
| T-228 | Close certificate | M | T-215 | standard | TODO |
| T-229 | SHU per member + audit viewer filters/cursor | M | T-218, T-220 | standard | TODO |
## P6 - UI rebuild

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-230 | Primitive: idempotency | S | T-176 | standard | TODO |
| T-231 | Primitive: 15-minute session lock | S | T-230 | standard | TODO |
| T-232 | Primitive: identity/member reference | S | T-230 | standard | TODO |
| T-233 | Primitive: `Money` + `DataTable<T>` | S | T-230 | standard | TODO |
| T-234 | AppShell + navigation | M | T-232, T-233 | standard | TODO |
| T-235 | Component-test tooling ADR | S | T-176 | standard | TODO |
| T-236 | Component: Input / Select / MoneyInput | S | T-235 | standard | TODO |
| T-237 | Component: DataTable | M | T-235 | standard | TODO |
| T-238 | Component: ReviewPanel / ApprovalPanel | M | T-235 | standard | TODO |
| T-239 | Component: Dialog / Confirm | S | T-235 | standard | TODO |
| T-240 | Component: Empty / Error / Loading states | S | T-235 | standard | TODO |
| T-241 | Repair screens: vault, ledger, params, password, login | M | T-234 | standard | TODO |
| T-242 | Rebuild: Kas + close (K-01, K-03) | L | T-197, T-231, T-215 | standard | TODO |
| T-243 | Rebuild: ledger admin, loans, loan detail, products, users, slip, statement | L | T-199, T-200, T-229 | standard | TODO |
| T-244 | Merge `accounts/open` into member detail | S | T-245 (K-08) | standard | TODO |
| T-245 | New screens: members, onboarding, member file, exit, obligations, origination, approval queue, arrears, reports, audit | L | T-209, T-217, T-220, T-229 | standard | TODO |
## P7 - Operator admin and pilot hardening

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-246 | User admin UI + API (B13) | M | T-200 | standard | TODO |
| T-247 | Seed two named operators | S | T-246 | standard | TODO |
| T-248 | Retention tasks per record class | M | T-198 | schema | TODO |
| T-249 | Manual daily head-hash copy + disclosure | S | T-248 | standard | TODO |
| T-250 | `/metrics` | M | T-198 | standard | TODO |
| T-251 | Privilege test for the runtime DB role | M | T-182 | schema | TODO |
| T-252 | Backup restore drill | M | T-251 | standard | TODO |
| T-253 | Pilot readiness checklist | S | T-246, T-247, T-248, T-249, T-250, T-251, T-252 | standard | TODO |
## P8 - Synthetic-coop dry run

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-254 | Synthetic data generator | M | T-253 | standard | TODO |
| T-255 | 30-business-day dry-run script | M | T-254 | standard | TODO |
| T-256 | Performance measurement at pilot volume | M | T-255 | standard | TODO |
| T-257 | Audit evidence pack | S | T-249, T-252, T-255 | standard | TODO |
| T-258 | Dry-run report | S | T-255, T-256, T-257 | standard | TODO |
| T-259 | Final `task ci` + release readiness | S | T-258 | standard | TODO |
## P1b - Security and data-integrity follow-ups (added after backlog review)

| ID | Title | Size | Deps | Risk | Status |
|---|---|---|---|---|---|
| T-260 | Origin/CSRF enforcement for bodyless POSTs | S | T-173 | standard | TODO |
| T-261 | MFA challenge throttle + factorless policy | S | T-260 | standard | TODO |
| T-262 | Grant/revoke bounds for user administration | S | T-260 | standard | TODO |
| T-263 | Immutable-table DB grants | M | T-251 | schema | TODO |
| T-264 | Schema integrity batch | M | T-263 | schema | TODO |
| T-265 | Wire the parameter cache | M | T-184 | standard | TODO |
| T-266 | Snapshot-backed balances | M | T-187 | standard | TODO |
| T-267 | Audit lock and index review | M | T-263 | schema | TODO |

## Deferred

Items explicitly outside P0-P8 and their revisit triggers are in `ROADMAP.md` §7. They are not
backlog rows and must not be pulled into a phase without a new decision.
