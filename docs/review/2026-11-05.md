# Planning review, 5 November 2026

Eight reviewers read the replanned programme and the living docs corpus at `main` @ `4f90731`
(v0.1.21). Each had a different lens: KSP operations, risk and credit, compliance, backend,
frontend, project management, backlog quality and mechanical document consistency. All were
read-only; no code, gate, threshold or accepted limit was changed by the review.

This page is the durable record of what they found and what was decided. The full memos were
written outside the repository during the review wave; the findings are reproduced here in the
form that the backlog and the task files consume.

Verdict: direction sound, plan not executable as written. 17 blockers, 74 major findings.

---

## 1. Blockers and their resolution

| Finding | Defect | Resolution |
|---|---|---|
| Gate proofs cannot go red | P0 exit names `ci-fast`, but no CI job ran it and the web arm skipped without `node_modules`; T-174 seeded an allowlisted literal and a non-existent parameter key; the extraction done-test grepped a path prefix that never appears in imports | R-33; T-173, T-174, T-176 and T-189/T-202 acceptance rewritten to prove red on the pre-fix commit |
| First sitting illegal | Six rows were `READY` with no task file, against the DoR | R-32; task files T-173 to T-178 written with DoR |
| EOM missing | Three tasks required a completed EOM run; only EOY was scheduled | T-268 added, P1 |
| Contracts without owners | `DepositAccount.holder`, `branchCode`, `expectedCash`, slip cashier and reprint counter, statement running balance, K-12 preview and eligibility | T-273 (deposit read models), T-280 (preview and admissibility) |
| Member exit | Task only set `EXITED`; no refund, offset, closure, checker or statement | R-43, T-272 |
| Cash instalment | The only payment contract requires and debits a savings account, so a counter instalment needed two non-atomic calls | R-34, T-274 |
| SHU distribution | One aggregate journal passed acceptance while no member was credited | R-35, T-275 |
| Write-off split | T-181, T-186 and T-187 defined two decompositions, and the reconciliation identity omitted `released` | R-36; one identity, one reconciliation test in T-186 |
| Backup claim | Restore drill required an encrypted off-host backup that no task produced, against L-04 | R-39, P-06; T-252 now restores the local dump |
| Schedule fiction | P2b called float while four later tasks waited on it; critical path 89 to 133, not 74 to 105; P6 not parallel | R-40; ROADMAP rewritten with point sizes, a 179-day total, a 130-day chain and no float claim |
| Namespace collision | `R-xx` meant owner rulings in `DECISIONS.md` and design or antislop rules in `docs/design/` | R-41; design rules renamed to `AS-xx` |

---

## 2. Major findings by theme

**Money and ledger.** `strandedAllowances` did not subtract `released`, so `DAY-384` still aborted
EOD. Deny-by-lookup left lending journals reversible when a link row was missing. Allocation FKs
proved only that some instalment existed, and nothing tied `installment.paid_*` to allocated sums.
Idempotency TTL allowed a swept payment retry to debit twice. EOY acceptance passed on an empty
idempotent task. Penalty had no writer and could be deleted from the contract. Resolved by T-181,
T-182, T-186, T-187, T-268, T-270, R-36 and the accepted-limit row for payment retry.

**Authorization and control.** Restructure stayed maker-only. Wajib waiver had no checker. Origin,
MFA throttle and grant bounds were queued as self-review. The pilot seeded teller and lending
seats but not member-admin or manager seats. Resolved by T-269, T-209 acceptance, R-31 on T-260 to
T-262, and T-283.

**Scope dropped silently.** Approval tiers, exposure cap, arrears-at-origination, privacy and
breach handling, PMPJ and complaints were outside every phase. Resolved by R-42 and T-271 for
credit controls; P-05 records the privacy, AML and complaint deferrals with triggers.

**Operating reality.** Variance blocked the close on any difference. The 30-day dry run was asked
to prove a year-end without a year of history. No rule covered an absent checker or cash custody.
Resolved by R-37, T-254 (12-month seed) and the T-253 procedure checklist.

**Evidence honesty.** Two handlers had no owning extraction task; the privilege test connected as a
role CI never created; parameter keys were registered after the code that needed them; the cache
task named the wrong NOTIFY channel; CHECK constraints skipped `NOT VALID`; the axe wording was
weaker than the existing 2 themes x 2 locales gate; phase exits could pass on skipped checks.
Resolved across T-176, T-200, T-251, T-265, T-264, P6 acceptance and R-33.

**Document consistency.** P2a rows sat under the P1 heading and P1b sat after P8; the totals
omitted P1b; K-16 was eight documents in one file and nine elsewhere; `OPEN_ITEMS` carried a false
item and missed seven cited ids; the prototype disagreed with the screen specs on two screens.
Resolved in `BACKLOG.md`, `ROADMAP.md`, `OPEN_ITEMS.md`, `DESIGN-INDEX.md` and the design corpus.

---

## 3. What the review confirmed

- All 95 backlog rows at the time were row-faithful to the plan: no lost row, no renamed title, no
  size drift.
- All 32 distinct `delivered` capability evidence paths existed.
- All 14 `REG-` ids in `compliance/register.yaml` resolved with unchanged meaning, and no "MFA
  required" claim remained.
- `docsgen --check` was in sync: 134 migrations, 66 parameters, 63 tables.
- The legacy anchor table had 27 unique rows covering old sections 1 to 27.
- No owner ruling `D-xxx` was orphaned.

---

## 4. Decisions taken

R-31 to R-44 in `DECISIONS.md` section 1. Where a finding needed a product choice rather than a
fix, the choice is a ruling, not a silent edit: cash instalment in scope, per-member SHU
distribution, principal-only write-off allowance, variance tolerance with approval, local restore,
restructure checker, credit controls in P1, exit refund in P3, cash-flow statement and notes in the
RAT pack, `AS-` prefix for design rules, and no float in the schedule.

P-05 and P-06 record the two deferrals that need the owner to accept a limit rather than a task:
privacy, AML and complaint obligations, and the encrypted off-host backup.

---

## 5. What remains open

- The retention periods per record class must be signed before T-282 leaves `BLOCKED`.
- The cash-flow statement and notes stay `NEEDS-COMPLIANCE-REVIEW` until accounting sign-off.
- Approval tiers and the exposure cap need concrete parameter values, which are policy, not code.
- The 179-day estimate is a point estimate. A date requires the 20 percent contingency and an
  owner decision on staffing, because the plan assumes one worker for the critical path (R-40).
