# KRAN: PRD and Technical Specification

Status: product truth after the replan (branch `chore/replan-docs`). This document replaces the
Fase 0 to 4 specification in full; old section numbers survive only as citations, resolved by
Appendix A. Owner rulings R-01 to R-44 and the decisions in `docs/DECISIONS.md` bind this text.
Where this document and the code disagree, the disagreement is a defect: record it in
`docs/DECISIONS.md` and stop.

Product target: a KSP (Koperasi Simpan Pinjam) pilot operated by 3 to 10 staff, with at least two
operators who have no server access. Membership is a first-class aggregate. Savings return is
SHU-based, not interest. There are no time deposits. Lending runs on least-privilege maker and
checker seats. The report pack is RAT grade.

**MUST**, **MUST NOT** and **SHOULD** are normative, and every normative statement names an
enforcement point: a test, a gate command, or a phase exit criterion in `docs/ROADMAP.md`. "Enforced
today" means a test or gate in the current tree fails when the statement is violated; "enforced at
Pn" means the statement is the phase exit criterion and has no gate yet. That distinction is
deliberate: the replan found 15 blocker-level defects behind green gates. Evidence identifiers (`B1`
to `B13`, `C01` to `C20`) refer to `plan/audit/00-synthesis.md` and are historical. No business value
is written here; values live in parameter seeds and `docs/PARAMETERS.md`.

**Contents:** [1 Product and scope](#1-product-and-scope) · [2 Domain model](#2-domain-model) ·
[3 Invariants](#3-invariants) · [4 Parameters](#4-parameters) · [5 Security and data](#5-security-and-data) ·
[6 UX](#6-ux) · [7 Operations](#7-operations) · [8 Compliance](#8-compliance) ·
[9 Roadmap and references](#9-roadmap-and-references) · [Appendix A](#appendix-a-legacy-anchor-table).

---

## 1. Product and scope

### 1.1 Product statement

KRAN is a back-office core banking system for an Indonesian savings-and-loan cooperative. It runs
the counter, the loan book, the ledger, the member register and the annual close from one system,
on one server, with one database, for one institution per deployment. It is not a consumer app, not
a payment switch and not a multi-tenant SaaS. The unit of work is a member at a counter, a loan
officer in the field, and a manager closing the books.

### 1.2 Problem

A 3 to 10 person KSP typically runs on a mix of paper, spreadsheets and an ad-hoc application: cash
is accepted against a handwritten slip and posted "later" or never; simpanan wajib goes uncollected
for months while the member still counts for SHU; a wrong posting is deleted instead of reversed,
so passbook and audit trail diverge; a loan is disbursed to the wrong account because the screen
asks for a UUID; and the member register, obligations and annual reports live outside the system.
Each failure becomes a requirement below. The software cannot fix a dishonest operator, but it can
make the honest path the shortest one (KSP operations memo, section 1).

### 1.3 Personas and seats

Seats, not job titles. In a three-person KSP one login holds several seats, so separation of duty is
enforced per action by the server (R-17), never by hiding a menu.

| Seat | Daily work | MUST NOT | Screens |
|---|---|---|---|
| Kasir (teller) | open cash, setor, tarik, transfer, cash loan instalment (T-274), reprint, count and close cash | post without an open session; approve a vault top-up; see another branch's cash | K-01, K-08 read, K-14 pay, K-23, K-24 |
| Petugas pinjaman | survey, application, schedule preview, disbursement, collections | approve an own application; disburse to cash; edit a posted payment | K-06 to K-08, K-11 to K-15, K-24 |
| Manajer | approvals (loan, parameter, product, vault), arrears, EOD, EOM, EOY, reports | approve an own submission; close without counting cash; run EOY without a signed SHU basis | K-02 to K-04, K-11, K-13 to K-17, K-19, K-20 |
| Admin / pembukuan | member data, obligations, corrections, user administration, daily recap | delete a posting; create an operator without role and branch; edit a closed period | K-04 to K-10, K-17 to K-21, K-23 |
| Pengurus | read the RAT pack, member register, close certificates, SHU | post, approve or change any record | K-04, K-06, K-08, K-16 |

A screen becomes reachable only through the permission code the server checks; role names are
labels and may drift. Navigation is built from the principal's permissions and does not render a
group with zero permitted links (`apps/web/src/lib/app/nav.ts`).

### 1.4 MVP scope (KSP vertical slice)

The product scope, in one list: a `coop` membership register with immutable member number, status
machine, join and exit dates, branch and link to `party`; pokok and wajib obligations per member with
payment, arrears, approved waiver and refund at exit computed from postings with a checker (R-43,
T-272), realised amounts read from deposit postings; sukarela accounts with deposit, withdrawal,
dormancy, minimum balance and statement; teller sessions with float, setor, tarik, transfer by
account or member number, cash count and variance, and a cash loan instalment that posts the loan
payment, the cash movement and the teller session effect in one transaction (R-34, T-274); lending
with application, maker and checker approval, disbursement to a member account, schedule, allocation,
penalty assessment from parameters with a checker-approved waiver (T-270), arrears, restructure,
write-off and recovery; an immutable ledger with reversal ownership, COA, periods, trial balance,
statements and EOD, EOM, EOY; ten RAT reports including a cash-flow statement and notes (R-44); and
governance for parameters, users, MFA and the audit viewer. Phases are owned by `docs/ROADMAP.md`; the MVP is
complete when the twelve scenarios in section 1.7 pass against a synthetic cooperative of 30 business
days, about 200 members, 50 loans, one EOY and SHU cycle, and zero manual SQL (P8 exit criterion).

### 1.5 Explicit non-goals

Out of MVP, each for a stated reason: time deposits and their ARO, early-withdrawal and accrual
stack, because R-16 removes them and no path can create one today, so removal at P4 is deletion, not
hiding; interest-bearing savings, because savings return is SHU under R-16; BPR, BPRS and syariah
packs, because R-10 defers them while the register keeps their ids; mobile, offline and
field-collection apps, because the pilot works from one branch on desktop; multi-institution
tenancy, because one institution owns one deployment and branches are not tenants; payment switch,
BI-FAST, QRIS, ATM and EDC, which are adapters after the pilot; the tax module and PPh withholding,
because REG-008 is deferred with no consumer; iuran anggota, dunning and promise-to-pay, which R-10
does not require and the plan does not cost; automated SHU distribution, because R-27 keeps
distribution a checked journal; automated off-host audit anchoring, because R-26 keeps a manual
daily head-hash copy; mandatory MFA, because R-19 and R-29 keep it optional and throttled; and
health ratios, DPK and branch P&L, which R-28 defers with tags.

### 1.6 Success criteria

The product succeeds when a phase exit demonstrates, with output: the books cannot be corrupted
silently (owned-journal reversal denied, write-off then EOD completes, allocations sum and reference
a real instalment); one business date governs posting, parameters, DPD and reports; every account,
slip, statement and report names a member; two named operators without server access complete
onboarding, lending, close and reports; ten RAT documents reconcile to `journal_line`; `ci-fast`
fails on a seeded violation in `apps/api/src` and `apps/web`; every 409 carries a stable
`params.reason`; every capped list reports a total; and axe is green in two themes, keyboard-only.

### 1.7 MVP acceptance scenarios

Each scenario is a product requirement and an end-to-end acceptance test. `P.*` denotes a parameter
value, never a literal.

| ID | Scenario | Expected | Evidence |
|---|---|---|---|
| S1 | Admit a member and collect pokok | `ACTIVE` with immutable number; equity increases by exactly the parameter; two audit rows; duplicate identity returns 409 with a stable reason | onboarding e2e, `coop` integration |
| S2 | Monthly wajib with arrears | Two `PAID`, one `ARREARS`; arrears equal unpaid obligations; obligations derived, no second billing ledger | obligations integration |
| S3 | Sukarela deposit and withdrawal | balance and GL move together; slip carries identity, cashier, time and zone; withdrawal below minimum rejected with a reason | teller e2e, `itapi_teller` |
| S4 | Loan application with eligibility | blocked on wajib arrears with a specific reason; approver is not the submitter; full trail | lending e2e, `itapi_lending` |
| S5 | Disburse to a member account | destination by account or member number with holder on review; `lending_maker` completes without `platform_admin`; second disbursement refused | lending e2e as seeded maker |
| S6 | Instalment with penalty and partial payment | allocations follow product order and sum exactly; penalty is assessed from parameters and a waiver needs a checker; schedule and arrears update; receipt shows the split | `itapi_lending` |
| S7 | Month-end arrears review | DPD, outstanding (principal, interest and penalty), last payment, officer and a total row; EOM refuses while unbalanced; no backdated posting after close | arrears e2e, `itdaycloser_gates` |
| S8 | Cash count and variance | variance equals actual minus expected, posted to the configured account; the reason is mandatory and an approval is required above the parameterised tolerance (R-37); session closes; EOD proceeds | `itapi_teller_sessions` |
| S9 | Member exit with an outstanding loan | refused with a specific reason; after settlement the refund is computed from postings, equals pokok, wajib and sukarela minus arrears, closes savings accounts, posts with a checker and sets `EXITED` with `ended_on` (T-272) | `coop` integration |
| S10 | Year-end close and SHU proposal | trial balance balanced; second run is a no-op; proposal totals equal the distributable amount; every row shows its basis | `itdaycloser_*`, SHU golden |
| S11 | RAT approval and distribution | refused without a recorded decision; GL delta equals the allocation sum; replay does not pay twice | distribution integration |
| S12 | Correct a wrong posting | original row remains; reversal is a new entry with actor and reason; passbook shows both and nets correctly | `itjournal`, `itapi_journal` |

### 1.8 Corrected premises

The replan corrected six premises that old reports repeated. They are restated so later work does
not re-inherit them.

| Premise | Correction | Evidence |
|---|---|---|
| The web app is server-rendered | It is a SPA: `ssr=false`, `prerender=false`, static adapter fallback; no server load or hooks | `apps/web/src/routes/+layout.ts` |
| Clean Architecture is enforced project-wide | Enforced for `modules/*` only; `apps/api/src` joins `archcheck` at P0 with a shrink-only baseline | `tools/archcheck/lib.nim` |
| Handlers are the application layer | Not ratified. Use cases move into `modules/*/application` per module (R-18, R-24) | P2a, P2b |
| The error format is custom | It is an RFC 9457 problem document, `application/problem+json`, `type` as a relative `/problems/<kind>` URI, plus `code`, `i18nKey`, `params`, `traceId` | `apps/api/src/problem.nim` |
| Time deposits are delivered | No request path can create one; the stack is unreachable | `modules/deposit/domain/account.nim`, `handlers_deposit.nim` |
| Fase 3 delivered EOD, EOM and EOY | EOY is a calendar level with no registered task; it is delivered at P4 | `daycloser_ledger.nim`, `calendar.nim` |

---

## 2. Domain model

### 2.1 Shape

A modular monolith: one Nim binary with roles (`api`, `worker`, `ctl`), one PostgreSQL database with
one schema per module, and a SvelteKit SPA that talks JSON over HTTPS and WebSocket. `kran-api`
serves HTTP and the realtime hub and is stateless; `kran-worker` runs the outbox dispatcher, close
executor and scheduled work, with one active worker per deployment; `kran-ctl` performs migrations,
first-user bootstrap, anchor export and one-shot repair, never a daily operation the UI must provide.

Rules that are architectural, not stylistic: a module owns its schema and tables and never reads
another module's tables; cross-module calls go through `<module>/api.nim`, asynchronous reactions
through events; a module never imports another module's `domain/`, `infrastructure/` or handlers.
The composition root (`apps/api`) wires modules and may see many `api.nim` surfaces, but it may not
hold business rules; that is the subject of the P2 extraction. Enforcement is `tools/archcheck` in
`task check`. It covers `modules/*` today and skips `apps/api/src`; P0 adds a `handlers` category
with a baseline that may only shrink.

### 2.2 Modules

Modules and their ownership: `platform` owns the audit chain, outbox and inbox, idempotency,
parameters, calendar and business date, users, roles, permissions, sessions, branches and MFA
factors, and exposes an `api.nim` slice at P2a. `party` owns the party record, encrypted identity
documents, KYC profile and re-KYC schedule (P2a). `coop` is the target membership module at P3.
`product` owns the savings and loan catalogue (P2b). `deposit` owns savings accounts and their
transactions (P2a). `teller` owns session, float, vault and cash count (P2b). `lending` owns
application, schedule, disbursement, payments and allocations, penalty, DPD, PPAP, write-off and
recovery (P2b). `ledger` owns COA, journals, periods, posting rules and statements (P2a). `daycloser`
owns the task registry, dependency graph, run and chunk state and the seal (P2b). `hello` is a
template and is deleted at P2b.

A cash loan instalment is one atomic use case: the lending payment, the cash movement and the teller
session effect commit or fail together (R-34, T-274). A success that posts the payment without the
cash movement is a defect, not a retry to schedule.

No `reporting` module exists by design. Reports read ledger and subledger data through the owning
module's read API; a report module that owns a second copy of the numbers is forbidden (C18).

### 2.3 Aggregate ownership

Ownership is fixed: `party` owns the party record, identity documents, KYC profile, risk level and
re-KYC schedule, with a UUID never shown, one document set, parameterised risk and every change
audited. `coop` owns the member: UUID plus immutable member number, one non-exited membership per
party, a declared status graph, `joined_on <= ended_on`, and a terminal exit. `deposit` owns savings
accounts (UUID plus account number) with balances derived from postings, no negative balance unless
the product allows it, and one journal per cash movement. `lending` owns loans (UUID plus loan
number) whose schedule comes from the product version, allocations sum to the payment and transitions
are audited. `ledger` owns journals: balanced, at least two lines, immutable, reversible only with
known ownership. `daycloser` owns runs: one active run per scope and date, chunk as checkpoint, seal
over snapshot and task state. `platform` owns users and sessions: permission per request, idle and
absolute bounds, and no grant exceeding the actor's own.

`coop` owns no money. If it ever holds a balance "for speed", the subledger-to-GL divergence that
the audit calls the only silent books-corruption path becomes unfixable.

### 2.4 The `coop` aggregate (target)

Minimal member record: identifier, immutable member number, party reference, branch, joined and
ended business dates, status, status reason, creating and updating actor with timestamps. Lifecycle:
`PENDING` (candidate, rejectable) to `ACTIVE` (obligations start) to `SUSPENDED` (temporary, no new
credit) to `EXITED` (terminal, refunds settled), with `REJECTED` from `PENDING`. Status values are a
closed set in code, not a parameter: a runtime-parameterised state machine cannot validate
transitions.

Rules: the member number never changes and is never reissued, because it is what a teller types and
a slip prints; at most one non-exited membership exists per party; every transition records actor,
reason, timestamp and effective date, and backdated admission requires a reason; pokok and wajib
obligations reference product and period `YYYY-MM` and realise amounts from deposit postings, so
`coop` never duplicates money; exit is refused while a loan is outstanding, computes the refund from
postings, offsets arrears, closes savings accounts and posts the refund with a checker (R-43,
T-272); `coop` posts no journal and calls `deposit` and `ledger` through their
`api.nim`. Events `MembershipActivated`, `MembershipChanged` and `MembershipExited` go through the
outbox in the state-change transaction. Not in `coop`: balances, cash, loan schedules, DPD, PPAP, SHU
amounts, product rates, GL accounts, KYC documents, teller sessions, report SQL, users and roles.

### 2.5 Ledger ownership and subledger links

A subledger journal MUST carry an explicit link from its subledger row to `ledger.journal` when the
owning table stores a link column; ownership is then a stored reference, not a guess from
`source_event`. The teller and vault paths store no link and derive ownership from `source_ref`, and
they are corrected through the teller correction rather than a generic reversal. Until P1, ownership
is inferred from five tables and lending, accrual and write-off journals carry no link, so their
reversal is possible and corrupts the books (B3). T-180 adds the link rows for the lending paths and
keeps the teller derivation rule.

| Journal source | Generic reversal | Correct path |
|---|---|---|
| Pure ledger journal | yes | reversal with reason |
| Deposit transaction or transfer | no | deposit correction, reversing subledger and GL |
| Teller session, overage, shortage, vault | no | teller correction |
| Lending disbursement, accrual, payment, write-off, recovery | no | lending correction or compensating entry |
| Parameter or product change | not a journal | new version with maker-checker |

### 2.6 Data foundation

PostgreSQL, one schema per module, migrations as plain SQL files numbered within a module. The
runner records each file in `platform.schema_migration` with a checksum and rejects a changed file.
The full table and trigger inventory is generated into `docs/SCHEMA.md`; this document never
duplicates it.

| Known gap | Consequence | Owner |
|---|---|---|
| no foreign key from allocation to instalment, no sum check | money can be allocated to a non-existent schedule row | P1 |
| no foreign keys to `platform.branch` | branch isolation is application-only | P1b |
| append-only depends on runbook grants | a fresh deploy may be trigger-only | P1b |
| no row-level security | branch scoping is an application rule | accepted limit, revisit with measurement |

Every query that reads or writes branch-owned data MUST apply the principal's branch filter in SQL,
not after `LIMIT`. The first three gaps above are exit criteria, not backlog wishes.

### 2.7 Module documentation contract

Every module keeps `MODULE.md` with eleven headings that form the contract: purpose and bounded
context; aggregates and business rules; public API (`api.nim`); published and consumed events with
versions; parameter keys with sensitivity and regulatory references; tables and schema; registered
day-close tasks; permissions; i18n namespace; related `REG-xxx` requirements and tests; decisions
with ADR links. A missing heading means an incomplete module. The file states current behaviour,
never a plan; plans live in `docs/BACKLOG.md`.

---

## 3. Invariants

These are product invariants. A change that breaks one requires an owner decision, not a review
comment.

### 3.1 Money

1. Money is a fixed-point integer of minor units (sen) in `int64`, scale 2. There is no `float`,
   `double` or `Number` on a money path in Nim, SQL or TypeScript. Storage is `numeric(24,2)`; the
   API transports a decimal string with exactly two decimals; the UI formats with
   `Intl.NumberFormat` and never parses through `Number`.
2. Input below one sen is rejected, not rounded. Arithmetic is checked and overflow raises; it is
   never allowed to wrap.
3. Rounding is half-to-even, applied once at the point a value becomes money. Intermediate
   calculations keep full precision.
4. A money value carries its currency at the boundary; the pilot currency is IDR and the column is
   explicit, not implied by locale.
5. Debit and credit are separate columns plus a label. Colour never carries the meaning alone.

Enforced today by `shared/kernel/money.nim`, property tests for sum and rounding, and the frontend
parser. Every new money use case MUST have a property test and a golden test against a hand-computed
reference.
### 3.2 Rates and percentages

Rates are fixed-point integers with six decimal places (micro-units). A percentage is stored as a
rate, never as a float. Multiplication of money by a rate goes through one kernel operation that
rounds half-to-even exactly once. Penalty, interest, PPAP and SHU percentages MUST come from
parameters. A literal percentage in code fails review and, where `lint-nomagic` sees it, the build.

### 3.3 Ledger immutability

1. A posted journal is immutable. `UPDATE` and `DELETE` are denied by trigger and by database
   privilege for the runtime role.
2. A journal has at least two lines and sums to zero; the check is deferred to commit. A period
   accepts no posting after it is closed, and closing or reopening is an explicit audited operation.
3. Corrections are reversing entries with a reason. There is no edit path and no delete path in any
   UI or API.
4. A journal has exactly one reversal. The same idempotency key returns the original result; a
   different key against an already reversed journal returns 409.
5. A journal is sealed with the business date and the actor, and the audit chain records who
   reversed what and why.

Enforced today by `itjournal` (balance triggers, immutability, single reversal) and `itapi_journal`
(idempotent and race-safe reversal).

### 3.4 Reversal ownership

The generic reversal endpoint MUST refuse a journal whose owning subledger keeps state outside the
ledger, unless that module exposes a correction that reverses both. Where the owning table stores a
link, ownership is that stored reference; teller and vault journals derive it from `source_ref`;
neither is a guess from `source_event`. A refusal carries a stable reason and names the correct
path; "not reversible" without a next step is a defect. Enforced at P1: reversal of a lending,
accrual or write-off journal is denied, and the test fails if denial is removed.

### 3.5 Idempotency

Every financially effective request accepts an `Idempotency-Key` header, scoped per principal; the
same key with a different payload is a conflict. The key row is written inside the business
transaction, and a non-2xx response never stores a key. A replay of a completed key returns the
stored result, not a second posting. The key survives a network failure, a 5xx and a session
re-authentication, and time to live is a parameter. A lending payment key MUST be permanent or
natural, derived from the loan, instalment and amount, so that no time-to-live sweep can turn a
retry into a second debit; enforced at P1 by a retry test that sweeps the key between attempts and
asserts one debit. For the other financially effective paths the time-to-live key is a named
accepted limit in `docs/ACCEPTED-LIMITS.md`, and that limit does not extend to lending payments.
The UI shows the reference before completion and
disables the form while the outcome is unknown; "unknown state" never says success.

Enforced today by `itapi_idempotency` on the backend and by one shared client helper after P6. Four
divergent client implementations are the current state and are a defect (C15).

### 3.6 Outbox, inbox and realtime

1. A state change and its event are written in one transaction. There is no event without a state
   change and no state change that silently lacks its event.
2. A writer that emits an outbox event writes the audit row first in the same transaction. This
   preserves commit order versus `seq` order, and the realtime cursor depends on it.
3. The dispatcher claims batches with `FOR UPDATE SKIP LOCKED`, never select-then-update. Delivery
   is at least once; consumers deduplicate through the inbox keyed by event and consumer.
4. Failed events remain visible with attempts and last error; redrive is an operator action.
5. Realtime carries a resume token and a reconnect replays from the outbox. A missed event is a
   defect, not a refresh hint. Topics are authorised; a denied topic surfaces as a warning.

Enforced today by `itposting`, `itoutboxcursor` and `itapi_ws`.

### 3.7 Day-close framework

1. All scheduled institutional work runs through `daycloser`. A module-local cron, batch or
   one-off loop is forbidden. A task is registered with code, level, criticality and dependencies;
   the graph is deterministic and validated against the run snapshot.
2. A run has one active instance per scope and business date; catch-up runs day by day. States are
   planned, precheck, running, postcheck, completed, with failed and blocked resumable and
   completed or cancelled terminal.
3. A succeeded chunk is never re-run on resume; a failed chunk is retried. Parameters are frozen
   per run, so a change mid-run does not alter that run.
4. A critical task failure fails the run. A non-critical failure is recorded and does not hold the
   close. Skip is allowed only for a non-critical, single-chunk task, with a reason stored where
   the monitor can read it.
5. The run seals a hash over the parameter snapshot and the task and chunk states. A completed run
   cannot be deleted.
6. Closing advances the business date in the same transaction as the seal. A cancelled run returns
   the date to open; a closed date is never reopened without a policy that does not exist yet.
   During closing, ordinary writes are rejected with 409 unless the close-policy parameter allows
   them.

Enforced today by `itapi_dayclose`, `itdaycloser_lifecycle` and `itdaycloser_gates`. EOY is not
registered today; P4 adds it with the same contract.

### 3.8 Business date

There is one business date per institution, from `platform.business_date`. It is not derived from
the server clock, the browser clock or UTC. Every dated read passes the resolved date: parameter
`asOf`, allocation, DPD, report period, schedule due check. A function that defaults to "today" from
the OS clock is a defect. The institution time zone is a parameter, and a deployment outside the
seed zone must set it before the first posting. Screens display the business date wherever a dated
decision is made. A backdated correction is a reversal plus a new entry on the current business
date, unless an explicit backdating policy exists.

Enforced at P1 by a test that posts at a wall-clock time where UTC and local date differ and asserts
one date everywhere. Today at least five paths disagree (C04).

### 3.9 Concurrency

Balance changes use atomic conditional updates, never read-modify-write. Lock order is documented
and stable; a new path that can hold two locks states the order in the module document.
Transactions that can receive `40001` or `40P01` retry with a bounded, parameterised policy, and a
silent loop is forbidden. A worker honours termination: finish the current chunk or release the
lease, never abandon a lease that blocks catch-up. One run per scope and date is enforced by a
partial unique index plus an advisory lock, not by application hope.

Enforced today by `transaction_repo` and `transfer_repo`; retry is added at P1b with a test that
injects a serialization failure.

### 3.10 Test strategy

| Level | Scope | Gate |
|---|---|---|
| Unit and property | domain rules, Money, Rate, sums, rounding, balance and schedule invariants | `task test` |
| Golden | interest, penalty, PPAP, SHU and schedule methods against hand-computed fixtures | `task test` |
| Integration | use case plus real PostgreSQL plus migrations | `task test`, shared test database |
| Contract | every operation implemented and schema-checked | `task openapi`, `tcontract` |
| Simulation | months of catch-up, holidays, EOM, EOY, chunk failure | `itdaycloser_sim` |
| Web, end-to-end, a11y | state machines, money parsing, forms, role-authentic flows, axe in two themes | `vitest` in `ci-fast` after P0, `task e2e`, `task ci` |

A test that cannot fail when the behaviour is removed is not evidence; capability claims point at a
test that fails when the capability breaks. Tests are never edited to accommodate an extraction:
characterization tests pin current behaviour first. The shared `kran_test` database makes
database-touching suites serial by rule. No new test framework, assertion library or DOM
environment without an ADR. Parameter mutation is covered per key: a seeded change must change
behaviour, which is how the no-hardcode rule is proved for that key.

### 3.11 Write-off allowance

The write-off allowance base is principal only (R-36). Interest and penalty are not in the base; they
leave the book by one explicit release rule, never by a second decomposition of the same loan. The
reconciliation identity is `allowance - applied - released`, and a balance that fails it aborts the
close visibly rather than passing a lower gate. One reconciliation test proves the identity (T-186),
and no report may present a second definition.

---

## 4. Parameters

### 4.1 Policy

No business value lives in code. Rates, limits, fees, thresholds, calendar shape, retention, review
cadence, penalty basis and close policy are parameter rows with an effective date, a scope, a reason
and an approver. A parameter is business data, not configuration: versioned, approved and audited.

### 4.2 Definition, seed, generation

Definitions live in `modules/<module>/seeds/params.yaml` with key, module, value type, allowed
scopes, sensitivity, approval requirement, regulatory references and description key. `paramgen`
validates the definition, generates typed Nim keys and TypeScript types, and emits the provenance
report; a key not generated does not exist for code. `paramgen --check` fails when generated
artifacts differ from seeds. Value types are explicit (integer, decimal, money, rate, date, boolean,
string, enum, JSON), and coercion happens once in generated code. A deprecated key is removed from
code first and then marked deprecated; reads fail closed.

### 4.3 Keys in code

Code uses the generated typed constant, for example a generated key for the DPD lower bound, passed
with an explicit business date and scope. Raw string keys in business code are a defect and are
caught by `lint-nomagic` where it has coverage. `P_*` naming is a convention inside generated
artifacts, not a security boundary; the boundary is that unknown keys do not compile.

### 4.4 Scope and resolution order

Scopes are global, institution, branch, product, segment and role, resolved from most specific to
least specific in that order. Only the scope type the caller explicitly requests participates. An
empty id is a legitimate root-institution request, not a wildcard. A more general scope never
silently replaces a requested specific scope. A parameter read states its scope; there is no ambient
"current scope" that changes meaning between a teller and a manager. A caller outside its branch may
read a value only with a permission that allows cross-branch read, and the read is audited. An
author may propose a value only for a scope it may read.

### 4.5 Lifecycle and maker-checker

States are draft, pending, active, superseded and rejected. Exactly one value is active per key,
scope and date; a new value closes the previous one by setting its end date, never by deleting it.
Submission requires a reason. Approval requires a different person and the database enforces
`checker <> maker`. Activation writes an audit row, an outbox event and a notification. A value with
an end date must have a successor covering the next day; otherwise the gap is refused at submission
and again at approval. Critical values require an approval role distinct from the authoring role.

### 4.6 No fallback

A missing active value is an error, not a default. The caller raises, the API names the missing key,
and startup refuses to serve traffic when a required key has no visible value. A default in code
defeats the framework and is forbidden. Where a fallback is genuinely required for availability, it
is a parameter of its own with an explicit owner.

### 4.7 Provenance and unverified values

Every value that encodes a regulatory choice carries `NEEDS-COMPLIANCE-REVIEW` until a compliance
owner signs it, and its submission reason names the source and access date. A value is never
presented as compliant because it is seeded. `docs/PARAMETERS.md` lists marker and provenance for
every key; `docs/COMPLIANCE.md` lists the sign-off state.

### 4.8 Enforcement and catalogue

Schema validation at build proves every definition uses a supported type and scope; generated keys
prove business code cannot use an unregistered key; `lint-nomagic` proves no business literal in
scanned layers; the startup check proves every required key resolves for the intended scope;
`itparam` proves no self-approved activation; and `docs/PARAMETERS.md` gives operators and auditors
the value set. The commands are `task check`, `task paramgen` and `task test`; the generated catalogue
is compared byte for byte by the docs gate (`docs-check`, DOC-05). Hand-editing a generated catalogue
is a defect.

`docs/PARAMETERS.md` is generated. `docs/SCHEMA.md` and `docs/CAPABILITIES.md` follow the same rule.

---

## 5. Security and data

### 5.1 Posture and assets

Assets, in order of harm if lost: ledger integrity, member identity and savings balances, audit
evidence, credentials, operational availability. The posture is defense in depth, least privilege,
secure by default and auditable by construction; the pilot is single-tenant on a private server, but
"the network is trusted" is not an assumption the product relies on.

### 5.2 Authentication and session

1. Login is username and password over TLS. The password is verified with a memory-hard KDF, and
   throttling is applied before the KDF so a failed attempt cannot be a CPU amplifier.
2. The session token is opaque, generated from a cryptographic source, stored server-side as a
   SHA-256 digest, and delivered only in a `HttpOnly`, `Secure`, `SameSite=Strict` cookie. No token
   appears in a response body or a URL.
3. Session lifetime has two parameterised bounds, idle and absolute. Idle is refreshed on use;
   absolute is not. Logout revokes server-side; password change and reset revoke other sessions;
   login failure does not reveal whether the username exists.
4. A teller terminal locks on the client after 15 minutes of inactivity, warns before the lock, and
   preserves the draft and its idempotency key across re-authentication (R-21, DD-04). The server
   idle bound is separate and longer; it does not replace the client lock.
5. A request in flight completes and reports its result after unlock, and re-authentication returns
   the user to the same screen and step.

Enforced today by `itapi_auth`, `tlogin_guard`, cookie assertions and session policy tests; the
client lock is P6, with desktop behaviour tested in e2e.

### 5.3 MFA

MFA is optional (R-19, R-29), a recorded accepted limit, not an accident. The service switch defaults
to off; when off, MFA routes answer with a stable reason and login is unchanged. When on, enrolment is
self-service TOTP with the secret encrypted and returned once. When a login requires a factor, the
session is half-authenticated until the challenge succeeds; only the challenge route and logout
accept that session. The challenge is throttled per account and per source, and a replayed code is
refused. The product MUST NOT claim that MFA is required; compensating controls are named in
`docs/SECURITY.md`: named accounts, least privilege, daily audit review, no shared logins, and no
operator access to the server. Enrolment, reset and recovery become UI tasks at P7.

### 5.4 Authorization

1. A permission code has the form `module.resource.action` and is checked server-side on every
   route; hidden navigation is a convenience, never a control. A grant is a role, a permission and
   a branch scope, where an empty branch means all branches.
2. Separation of duty is per action: the approver of a submission is never its submitter. The
   conflict matrix is data, and conflicting role pairs are refused at assignment.
3. A grant or revocation cannot exceed the actor's own grant; revocation and disable are bounded
   the same way.
4. Maker-checker is a platform capability used by parameters, products, vault, lending approvals
   and SHU distribution. It is not reimplemented per module.
5. A denied action returns 403 with the missing permission; a denied scope returns a distinct
   reason. Neither returns 404 to hide existence, because the operator must be able to ask for the
   right access.
6. Lending runs with `lending_maker` and `lending_checker` seats that can read what they need to
   complete the task (R-17). Disbursement must not require `platform_admin`.

Enforced today by `itapi_roles`, `taccess_log` and the authz unit tests; the grant bound and the
lending read grant are P1b exit criteria.

### 5.5 API surface and error contract

1. The contract is `packages/contracts/openapi/kran-api.yaml`, OpenAPI 3.1. The generated
   TypeScript client is the only client. An implementation that differs from the contract fails the
   contract test.
2. Paths are versioned under `/api/v1`. A breaking change creates a version; a deprecation carries
   a header and a removal date.
3. Money is a two-decimal string; dates are `YYYY-MM-DD` business dates; timestamps are ISO 8601
   with an offset; identifiers are UUID strings.
4. Errors are RFC 9457 problem documents with `type`, `title`, `status`, `code`, `i18nKey`,
   `traceId` and optional `detail` and `params`. `type` is a relative `/problems/<kind>` reference.
   The server never sends a user-facing sentence; the client translates `i18nKey` plus `params`.
5. Every 409 carries `params.reason` with a stable machine code. Free text in `detail` is for
   operators and logs, never for branching logic.
6. Pagination is cursor-based. A capped list returns a total and a next cursor, or states that it
   is truncated and why.
7. `Idempotency-Key` is honoured on financially effective POSTs; `ETag` and `If-Match` are used
   where a lost update is possible. Realtime is a WebSocket at `/api/v1/events/stream` with an
   authorised topic subscription and a resume token.
8. Request scope carries actor, branch, trace id and reason into the use case and the audit row.

### 5.6 Audit trail

1. Every state change that matters to money, access or configuration writes an audit row with
   actor, action, entity, before and after (or a reference), branch, trace id, timestamp, and a
   reason where the action requires one.
2. The audit log is append-only. `UPDATE`, `DELETE` and `TRUNCATE` are denied by trigger, and the
   runtime role lacks the privileges.
3. Rows form a hash chain computed by the database trigger, not the application. Verification
   follows `prev_hash` and rejects a fork.
4. A daily anchor records the head sequence and hash. The copy is made manually once per day and
   stored off the application host, with a written disclosure that a database administrator can
   rewrite the tail and that the anchor is the only external witness (R-26).
5. The audit viewer supports filter by actor, action, entity, date and trace id, with pagination
   (P5). The current 20-row unfiltered view is not acceptable evidence.
6. The anchor command exists today and is scheduled in `ops/`; the operator step and the disclosure
   live in `docs/OPERATIONS.md`.

Retention is defined per record class (R-26): audit, outbox and inbox have parameters and purge
tasks; financial records and consent evidence keep the period set by the institution, marked
`NEEDS-COMPLIANCE-REVIEW` until signed. A purge task never runs against a class whose retention is
not set; it fails closed.

### 5.7 Encryption and keys

TLS terminates at the reverse proxy, and the application trusts a forwarded scheme only from the
configured proxy. Sensitive fields (identity number, tax number, phone, address) use envelope
encryption: a key-encryption key from a host file with mode 600 derives per-record data keys;
AES-256-GCM provides confidentiality and integrity; a blind index supports exact-match search.
Unmasking requires a permission and a reason and produces an audit row. Logs never contain PII,
secrets, tokens or unmasked identity data. Key rotation is a tested operational procedure and a key
is never committed. Backups are local, single-host and unencrypted for the pilot (R-39, L-04); an
encrypted off-host copy is deferred with a trigger and is not an existing capability. Detail lives in
`docs/adr/017-field-level-encryption.md` and `docs/SECURITY.md`.

### 5.8 Privacy controls

The product records a lawful basis for member data, shows the notice version, answers subject access
and correction requests, and states retention per class. Today consent, subject-request handling and
a breach runbook do not exist and are not claimed (REG-002 is deferred). Any future implementation
follows four rules: consent is a record with version, timestamp, channel and evidence, not a
boolean; a subject request is a case with a due date and outcome, and deletion is bounded by
financial retention and ledger immutability; a breach has a runbook with a drilled timeline and a
legal notification window that stays `NEEDS-COMPLIANCE-REVIEW` until verified; analytics and logs
follow the same retention and access rules as the data they describe.

### 5.9 Threat notes and accepted limits

| Threat | Control | Residual |
|---|---|---|
| stolen operator cookie | short idle bound, client lock, revocation, audit | a live session on an unattended terminal is detectable, not prevented, until the client lock ships |
| insider with database access rewrites the audit tail | trigger chain plus daily off-host anchor | the anchor is manual; disclosure names the gap |
| self-approval through a second login | SoD per action, distinct approver | shared credentials are a policy violation the system cannot detect |
| cross-branch read or malicious upload | branch-scoped queries; no upload in MVP | no row-level security; KYC images out of scope |
| dependency or credential compromise | pinned versions, lockfile, audit at P0, no secrets in repo | no SBOM yet; brute force mitigated, not eliminated |
| reversal abuse | ownership gate, reason, permission, audit | an authorised user can still reverse a pure ledger journal; intended |

Accepted limits are listed with owner and detection in `docs/ACCEPTED-LIMITS.md`. A limit is not a
plan; it is a risk the owner accepted.

---

## 6. UX

### 6.1 Design direction

The visual identity is the one decided in D-160 and kept by DD-01: IBM Plex Sans, cool neutral
surface, one plum accent, tabular numerals, hairline rules, flat cards, elevation only for overlay.
The replan redesigns structure, flows and component coverage, not identity.

Binding rules: one focus per screen, with the table on a list screen and the form plus amount on a
transaction screen; tables and numbers are the primary content, with no metric-card strip, decorative
chart or hero; status is text plus shape plus colour; one modal layer maximum, with inline review for
routine confirmation; motion is 150 to 200 ms for non-numeric elements and 0 ms for numbers; print
uses the light theme, repeats table headers, and never splits a total or signature block; and all
seven interaction states are designed for every screen, because silent emptiness is a false statement
about the cooperative.

The full token, component and screen specification lives in `DESIGN.md`, `docs/DESIGN-INDEX.md` and
`docs/design/`.

### 6.2 Operator vocabulary

The UI speaks the operator's language, in Indonesian, with an English locale that is a real
operating mode (DD-02, DD-03). Kasir, not teller; Kas besar, not vault; Tutup kas, not finalize
session; Setor (masuk) and Tarik (keluar), not debit and credit; Anggota and nomor anggota, not party
or UUID; Tunggakan and DPD, not an arrears view or an aging bucket code; Tutup buku, not run, task or
chunk. `SHU` and `RAT` stay acronyms in both locales with a one-line gloss on first use, never
"profit sharing" or "annual members meeting". Internal words (`uuid`, task codes, table names, `run`,
`vault`) never reach the UI. An error names the consequence and the next step: "Kas belum dibuka",
"Selisih kas 12.000,00", not a stack code.

### 6.3 Interaction rules

Identity before amount: member name and number accompany every amount, and a UUID is never typed or
shown as the identifier (B1, C14). Review before post happens inline on the same screen, showing
identity, amount, before and after, cashier and time. One idempotency helper serves every money
screen and keeps its key on an unknown outcome, which disables the form and offers a status check,
never a success claim. Every read stamps its load time and every mutation re-reads the mutated
entity. There is no delete path. The three empty states are distinct, a denied permission renders an
in-place panel without a redirect loop, keyboard shortcuts cover the counter, and the 15-minute
client lock warns at 14:00 while preserving draft and key (R-21, DD-04). Screen-level tests prove
each rule after P6.

### 6.4 Internationalization

Locales are `id` (default) and `en`, both complete; a missing English key is a defect. All UI text
comes from the catalogue, a hardcoded string fails review, and the server sends `i18nKey` plus
`params` rather than a user sentence. Numbers, dates and money use `Intl` per locale, with money at
two decimals and tabular digits. `SHU` and `RAT` remain acronyms with a one-line gloss on first use.
Plural keys without both forms fail the check.

### 6.5 Accessibility

WCAG 2.2 AA is a release condition. Contrast is verified for every token pair in both themes,
including text over status tint, and focus is a visible 2 px ring. DOM order equals visual order,
with no positive `tabindex` and one tab stop per composite widget, one `h1`, complete landmarks and
a skip link. Tables are semantic with caption and `aria-sort`, and horizontal scroll is a labelled
keyboard region. Zoom at 200 percent reflows to one column, and ledger, arrears, schedule and report
tables are never card-ified and never hide a column. Critical flows work keyboard-only. axe runs at
moderate and above in both themes, and a screen with a spec but no axe assertion is not covered.
Reduced motion removes transitions while preserving state.

### 6.6 Screens and states

There are 24 target screens, listed with route, actor, permissions and status in
`docs/DESIGN-INDEX.md` and specified in `docs/design/01-ia-flows.md`; this specification states the
contract. A screen is reachable only if its route, permission and data contract exist, and a nav
entry whose screen is missing is not rendered. Every screen implements the seven states and names
its empty state. The teller screen, not the ledger, is the teller's landing page. Transfer is a mode
inside Kas, account opening is a section of the member file, close is one console with EOD, EOM and
EOY tabs, and reports are one family route with ten documents, including a cash-flow statement and
notes to the financial statements (R-44). A screen that depends on a missing
backend capability ships only when the capability exists.

### 6.7 Print documents

| Document | Must carry | Never |
|---|---|---|
| Slip | institution header, member name and number, account number, amount, cashier, reference, timestamp with zone, reprint marker (R-22) | a reprint indistinguishable from the original |
| Statement | running balance, period, generated time, page x of y | totals presented as a GL reconciliation |
| Close certificate | business date, totals, variance, actor, signature block | printing while the period is open |
| Report pack | period, branch, control lines, repeated headers, open-period watermark | an orphaned total row |
Exact mandatory slip fields are `NEEDS-COMPLIANCE-REVIEW` (R-22); the listed fields are the minimum
the product prints, and removing one requires an owner decision. No mobile, offline, branch-creation,
KYC-upload, promise-to-pay or health-ratio surface is in MVP; each either lacks an endpoint or is
deferred by ruling.

---

## 7. Operations

### 7.1 Deployment topology

One VPS, rootless Podman, Caddy as reverse proxy, GitHub Actions as the verification gate, a webhook
that runs `ops/scripts/deploy-vps.sh` on push to `main`, and systemd user units for the API, worker
and scheduled jobs.

Deployment rules (D-178, D-194): push to `main` deploys production, and a manual push to `main` is
forbidden because release goes through `./task release`; the deploy script accepts only
`refs/heads/main` and fails closed on an empty or other ref; one deploy runs at a time under a lock;
the tree is synchronised with fetch and hard reset to `origin/main`; the deploy waits for a green CI
check run for that commit before building; only current and previous image tags are kept; health is
polled after restart and a failure restores the previous image; and secrets live only on the server
in files with mode 600.

### 7.2 Release flow

`./task release` bumps the single version source, updates the changelog, runs the gate, commits,
tags an annotated version and pushes once. The tag marks the release; it does not trigger a deploy.
Procedure and rollback are in `docs/RELEASE.md`. `ci-fast` is the daily gate and does not run e2e;
`ci` adds e2e and must be green before release or merge. A docs-only change does not rebuild the
image.

### 7.3 Migrations

Migrations are plain SQL, one transaction per file, numbered within a module, recorded with a
checksum. Expand first: add columns, tables, indexes and grants in a migration that works with the
previous application version. Contract last: remove or rename only in a file marked
`-- dbtools:contract <reason>`, applied by an explicit contract run after all expand migrations.
Destructive DDL requires `-- dbtools:destructive <reason>` even inside a contract file. Indexes on a
populated table are built concurrently. A migration without a reverse has a written recovery step.
Grants that enforce append-only are part of the migration (P1b), and a pre-migration backup is
automatic in production.

### 7.4 Backup and restore

A daily logical backup runs from the database container with a daily, weekly and monthly rotation;
the audit anchor is exported with it so the chain head travels with the dump; a pre-deploy backup is
taken before any release with a migration. Backups stay local, single-host and unencrypted for the
pilot (R-39, L-04); an encrypted off-host copy is deferred with a trigger and is not an existing
capability. The restore drill restores the local dump and produces a record with date, operator,
source, duration and verification results, which is evidence an auditor can read (T-252). Recovery
targets are institution values documented in `docs/OPERATIONS.md`, not invented here.

### 7.5 Monitoring and health

`/healthz` reports liveness; `/readyz` reports database reachability, migration state, worker
heartbeat age and dead outbox events. Metrics cover request rate and latency, error rate by code,
outbox lag, close state and duration, login failures and anchor age. An alert fires on readiness
failure, stale heartbeat, dead events, failed close, anchor older than a day and disk pressure. Logs
are structured, carry trace id and actor, and contain no PII or secret. A close failure is visible
to the manager in the close console, not only in a log.

### 7.6 Day-close operations

The manager opens the close console, reads pre-checks, and runs the level; the console shows
blockers with links, task progress and the resulting certificate. A failed critical task shows a
code, a hint and a resume action, and retrying is safe because each task is idempotent per business
date. During closing, ordinary writes are blocked; the manager can cancel a run, which returns the
date to open in one transaction. EOD requires teller sessions closed and cash counted; a variance
does not block the close, but its reason is mandatory, an approval is required above the
parameterised tolerance, and the day proceeds once the variance is posted (R-37). EOM requires
a balanced trial balance and no pending approvals; EOY requires a signed SHU basis and the parameter
set. The next business date is opened by the seal, not by a separate command. If the close cannot
complete, lending stops: that is a business rule, not an operational preference.

### 7.7 Administration, CLI and break-glass

`kran-ctl` exists for bootstrap and repair: create the first user, apply a migration, verify the
audit chain, export the anchor, recover a stuck lease. Anything an operator does daily must exist in
the UI (user create, reset, MFA enrolment, arrears, close). A CLI-only daily task is a product gap.
Break-glass access is documented, time-bound and audited; server access is not part of an operator's
job. `docs/OPERATIONS.md` is the runbook for deploy, migration, backup and restore, day-close, ops
CLI, break-glass, key rotation, pilot provisioning, and the development database and web.
Safety-critical tables are copied verbatim; this specification does not restate procedures.

---

## 8. Compliance

### 8.1 Stance

This section maps obligations to controls. It is not legal advice, and no statement here is a claim
of compliance.

Two rules are absolute. First, no invented regulation: an article, threshold, deadline or percentage
not read from a primary source and signed off is marked `NEEDS-COMPLIANCE-REVIEW` everywhere it
appears. Second, no compliance claim from a green gate: the traceability gate proves a register row
points at an existing control and test, not that the control is correct or the institution complies.

Marker convention, carried from the old register: `V?` means the number, article or version must be
verified against a current primary source; `V!` means the item is sensitive to regulatory change and
MUST be checked before any value is used. Both remain unresolved by definition.

### 8.2 Obligation map

| ID | Obligation | System artefacts | Current state |
|---|---|---|---|
| O1 | identify the member before the first transaction: document, risk level, re-KYC schedule, verifier and date | party record, encrypted identity, KYC profile, audit row | backend exists; screen and document storage absent (B7) |
| O2 | balanced journal per money movement, reversals, attributable change log | immutable journal, triggers, hash chain, daily anchor | strong core; viewer and filters absent |
| O3 | statements the pengurus signs and the RAT ratifies | balance sheet, income statement, equity, member register, SHU | absent until P4 and P5 |
| O4 | lawful basis, notice, retention disclosure, subject access, breach handling | consent, notice version, retention per class, export and erase | absent; REG-002 deferred |
| O5 | cash aggregation per member per day, threshold and suspicion flags, report register | aggregation, threshold parameter, case register | absent |
| O6 | written retention schedule per record class, enforced by tasks | retention parameters, purge tasks, archive path | undecided; only idempotency keys have a TTL |
| O7 | least privilege, unique accounts, approved privileged change, restore proof, patched dependencies | grant history, SoD, login and deploy records, restore drill | partial; no dependency scan, grants by runbook |
| O8 | a member can contest a posting and the cooperative can reconstruct it | complaint case linked to journal and slip | absent; slip identity at P6 |

Full evidence expectations and gap ownership live in `docs/COMPLIANCE.md`.

### 8.3 Regulatory register

All 28 identifiers are preserved, grouped as before. The stance after each entry is the MVP
position, not the legal status.

#### Cross-segment

REG-001 (V!) financial sector development and strengthening umbrella, including the KSP supervision
transition: reference only. REG-002 (V?) personal data protection, covering consent, subject rights,
retention and breach notice: deferred, no feature and no claim. REG-003 (V?) anti-money-laundering
and terrorism financing duties and record retention: deferred. REG-004 (V!) AML for financial
service providers, covering CDD, EDD, PEP, screening and risk rating: partial, risk level and re-KYC
only. REG-005 (V?) electronic information and transactions, electronic documents and system
security: reference only. REG-006 (V?) consumer and public protection, covering transparency and
complaints: deferred, no complaint register. REG-007 (V?) corporate documents and financial record
retention: deferred, retention undecided. REG-008 (V!) taxation of savings return and fees:
deferred, no tax module. REG-009 (V!) deposit insurance, where KSP is not a participant: a
prohibition, never claim insured savings. REG-010 (V?) identity verification against the civil
registry: adapter absent, document type and length are parameters. REG-011 (V!) accounting standards
for COA, posting rules and statements: partial, COA and posting rules, statements absent.

#### Koperasi

REG-101 (V?) cooperative law, covering membership, pokok and wajib, SHU, RAT and reserves: partial,
equity classification only, membership at P3. REG-102 (V?) cooperative and SME enabling regulation:
reference only. REG-103 (V!) savings and loan cooperative business regulation, covering licensing,
ratios, reporting and lending limits: no enforcement, limits not implemented. REG-104 (V!)
cooperative health assessment framework: deferred, no health report. REG-105 (V!) KSP supervision by
the financial services authority during transition: reference only.

#### BPR

REG-201 (V?) banking law and its amendments: out of scope. REG-202 (V!) BPR and BPRS business and
institutional regulation: out of scope. REG-203 (V!) capital adequacy, lending limit and
risk-weighted assets: out of scope, no ratio engine. REG-204 (V!) asset quality and loan loss
provision, covering grades and allowance rates: parameters exist in `lending`, values unverified.
REG-205 (V!) IT operation for BPR and BPRS: out of scope and must not be claimed for KSP. REG-206
(V!) BPR health assessment: out of scope. REG-207 (V!) BPR reporting and credit information
reporting: out of scope.

#### Syariah and BMT

REG-301 (V?) Islamic banking law: out of scope. REG-302 (V!) sharia council fatwas for contracts,
penalties and charity funds: out of scope. REG-303 (V!) sharia financing by cooperatives: out of
scope. REG-304 (V?) sharia supervisory board composition and reports: out of scope. REG-305 (V!)
profit sharing, non-halal funds and zakat: out of scope.

### 8.4 Obligation to control mapping

| Control | Mechanism | Module | Evidence |
|---|---|---|---|
| member identity | onboarding captures document, verifier and date; risk level parameterised; re-KYC scheduled | `party`, `coop` | member file, audit rows |
| segregation of duties | permission per action, conflicting role pairs, distinct approver | `platform` | grant history, approval trail |
| immutable bookkeeping | journal triggers, immutability privileges, reversal with reason | `ledger` | trial balance, reversal audit |
| asset quality and limits | DPD from business date, grade from parameters, allowance journal, exposure check | `lending`, `daycloser` | PPAP run, blocked application |
| reporting and retention | server-computed documents for closed periods; per-class retention and purge | `ledger`, `coop`, `lending`, `platform` | printed pack, purge log |
| privacy and audit evidence | field encryption, masking, unmask audit, hash chain, daily anchor, filtered viewer | `party`, `platform` | audit extract, verification output |

Values for REG-204 are seeded for the pilot but are not a compliance claim; the research log records
that the calculation basis differs from the BPR rule in at least one respect. No threshold in this
table is normative.

### 8.5 Claims the product must not make

The product must never say that savings are insured by the deposit insurance agency (KSP is not a
participant, REG-009); that MFA is required (R-19, R-29); that it is "compliant with" a named
regulation, because the product supports controls while the institution and its advisor make the
claim; that time deposits are supported (removed at P4); or that the audit trail is tamper-proof,
because it is tamper-evident against application users, with a manual off-host anchor and a
disclosed residual risk. These apply to screens, print, marketing and help text.

### 8.6 Traceability and sign-off

The register is machine-read from `docs/compliance/register.yaml`, which maps each requirement to a
parameter, a module and a test, and `./task traceability` fails when an active row has no control or
no existing test. The gate checks links, not coverage; a row is active only when a consumer exists
in code. `register-validation.md` is the research log with source, passage, access date and `VERIFY`
tag, and it is the only place a quoted passage may live. `NEEDS-COMPLIANCE-REVIEW` is removed per
institution after the client's compliance owner signs, never globally because one pilot accepted a
value. A parameter submission that encodes a regulatory value names the source and access date in
its reason; a value without provenance is treated as unverified. `docs/COMPLIANCE.md` owns the
obligation narrative, evidence and gap list; this specification owns the identifiers and rules.

---

## 9. Roadmap and references

### 9.1 Roadmap

The phase sequence, exit criteria, dependencies and serial rules live in `docs/ROADMAP.md`. The
queue lives in `docs/BACKLOG.md`. This specification deliberately contains no phase table, because a
second copy would drift.

The product requires the sequence to respect seven constraints: gates must see the money code and
the web app before any phase claims completion; financial correctness precedes product features,
because a ledger that can be stranded cannot carry a cooperative; use cases move into
`modules/*/application` per module before new MVP features (R-18, R-24); membership precedes SHU,
which depends on member identity and obligations derived from postings; reporting follows the ledger
and the year-end, since annual documents need EOY; the UI rebuild consumes shipped contracts, with
primitives starting earlier; and operator administration plus the synthetic dry run are release
conditions, not polish.

### 9.2 Architecture decision records

The ADR register is `docs/DECISIONS.md`; only ADR-017 has a file today, and the rest are recorded
there as decisions. Adopted: modular monolith with one schema per module (ADR-001); contract-first
OpenAPI with a generated client (ADR-003); PostgreSQL as queue, event log and scheduler (ADR-004);
single tenant per deployment with multiple branches (ADR-005); immutable ledger with derived balances
and reversal (ADR-006); database-driven parameters with layered enforcement (ADR-008); type-safe i18n
(ADR-009); day-close as an idempotent dependency graph with checkpoints (ADR-010); fixed-point Money
in code and numeric in storage (ADR-011); SPA with static adapter (ADR-012); CI verifies, VPS builds,
webhook deploys with health gate and rollback (ADR-014); KRAN replaces the legacy core after pilot
acceptance (ADR-015); and `paramgen` as a critical build tool (ADR-016). Decided: Mummy with
WebSocket (ADR-002, D-019); browser print, with a server-side PDF engine left open and not needed for
MVP (ADR-013, D-127); and field-level envelope encryption with AES-256-GCM and a blind index
(ADR-017, human review before real data). Not adopted: row-level security for branch scoping
(ADR-007); branch scoping is an application filter, revisited only with measurement.

### 9.3 Open questions

These remain open and are tracked with owners in `docs/OPEN_ITEMS.md`. They affect product
behaviour, not the reading of this document: whether a pengurus needs a separate read-only login or
oversight is a permission on a normal account (O-1, role model and audit attribution); whether the
close certificate is printable on its own route like a slip (O-2, print surface and evidence
handling); and the exact retention period per record class (O-3, purge tasks cannot be enabled
because R-26 decides mechanism only).

Resolved questions are not repeated. The audit's Q1 to Q8 became rulings: membership is first-class
(R-15), time deposits are out and savings return is SHU (R-16), lending is maker and checker (R-17),
use cases move to the application layer (R-18, R-24), MFA stays optional (R-19, R-29), retention is
per class with a manual anchor (R-20, R-26), the teller terminal locks (R-21), and slips carry
identity (R-22).

### 9.4 References

`docs/ROADMAP.md` (phases and exit criteria), `docs/BACKLOG.md` (queue), `docs/DECISIONS.md`
(rulings and active decisions), `docs/OPEN_ITEMS.md` (open and closed-but-cited items),
`docs/ACCEPTED-LIMITS.md` (accepted risks), `docs/DOMAIN.md` (glossary and ownership),
`docs/PARAMETERS.md`, `docs/SCHEMA.md` and `docs/CAPABILITIES.md` (generated inventories),
`docs/SECURITY.md` and `docs/COMPLIANCE.md` (controls and obligation evidence), `docs/OPERATIONS.md`
and `docs/RELEASE.md` (runbooks and release), `docs/DESIGN-INDEX.md` and `DESIGN.md` (design),
`docs/compliance/register.yaml` and `register-validation.md` (traceability and research log),
`docs/adr/017-field-level-encryption.md` (field encryption), and
`packages/contracts/openapi/kran-api.yaml` (the wire contract).

The old specification is recoverable from git history. Fase 0 to 4
history is condensed in `docs/history/PHASES.md`; their task files and milestone reports are archived
outside the repository and remain in git history. Nothing in those documents overrides this one.

---

## Appendix A. Legacy anchor table

The old specification used sections 1 to 27. Code, tests and comments cite `spec §N` in 692 places.
Each citation resolves through this table. Every old section appears exactly once.

| Old section | Title (old) | New part | Where it is covered |
|---|---|---|---|
| 1 | Summary and goals | 1 | 1.1, 1.2, 1.6 |
| 2 | Scope | 1 | 1.4, 1.5 |
| 3 | Personas and segment needs | 1 | 1.3 |
| 4 | Regulatory compliance analysis | 8 | 8.1 to 8.6 |
| 5 | Architecture principles | 3 | 3.1 to 3.9, 2.1, 2.7 |
| 6 | System architecture | 2 | 2.1 |
| 7 | Monorepo structure | 2 | 2.1, 2.2 |
| 8 | Modules and bounded contexts | 2 | 2.2, 2.3 |
| 9 | Data foundation (PostgreSQL) | 2 | 3.1 (money), 2.6 (schema), 7.3 (migration rules) |
| 10 | Parameter framework | 4 | 4.1 to 4.8 |
| 11 | Day-close framework | 3 | 3.7, 7.6 |
| 12 | Backend specification (Nim) | 3 | 3.1 to 3.9 |
| 13 | API design | 5 | 5.4, 5.5 |
| 14 | Frontend specification | 6 | 6.1 to 6.7 |
| 15 | Theming (dark and light) | 6 | 6.1, 6.5 |
| 16 | Internationalization | 6 | 6.4 |
| 17 | Accessibility | 6 | 6.5 |
| 18 | Security and data protection | 5 | 5.1 to 5.9 |
| 19 | Reactive architecture | 3 | 3.6 (backend), 6.3 (frontend) |
| 20 | Testing strategy | 3 | 3.10 |
| 21 | CI and CD | 7 | 7.1, 7.2, 7.3 |
| 22 | Observability and operations | 7 | 7.4, 7.5, 7.6, 7.7 |
| 23 | Roadmap and milestones | 9 | 9.1, pointer only; no phase table |
| 24 | Risks | 9 | 5.9, 8.2, `docs/ACCEPTED-LIMITS.md` |
| 25 | Initial ADRs | 9 | 9.2 |
| 26 | Open questions and assumptions | 9 | 9.3, 1.8 |
| 27 | Appendix: module document template | 9 | 2.7, 9.4 |

Resolution rule: a comment that cites `spec §N` means the new section shown here. A sub-number such
as `§9.1(2)` resolves to the subsection in the row that covers its subject, so `§9.1` money goes to
3.1 while `§9.1(11)` migrations goes to 7.3. Where a row names several subsections, the citation
subject decides: `§13` auth and error references go to 5.4 and 5.5, `§21` migration references to
7.3, `§22` silent-deployment references to 7.5. The docs gate (`docs-check`, DOC-05) requires every
old number 1 to 27 to appear exactly once and rejects a citation outside the range.
