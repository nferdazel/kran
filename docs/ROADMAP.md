# KRAN - Roadmap

Single source of direction for all work after the replan. It replaces the old phase table. Task rows
live in `BACKLOG.md`; product truth lives in `spec/kran-prd-techspec.md`.

Baseline at replan: VERSION 0.1.21, old Fase 0 to 4 complete and historical. **P0 to P8 are new**;
they are not the old Fase numbers.

Product target: KSP (savings-and-loan cooperative) pilot, 2+ operators without server access,
membership as a first-class aggregate, SHU-based savings, no time deposits, maker/checker lending,
RAT-grade reporting.

Size rule: one point per task, S = 0.5 day, M = 2 days, L = 4 days. The sum is arithmetic over the
rows in `BACKLOG.md`; it is not a range. Contingency is added once, at the programme level.

---

## 1. Phases

| Phase | Name | Days | Depends on | Exit criterion (verifiable) |
|---|---|---|---|---|
| **P0a** | Gates see the money code | 7.5 | - | `ci-fast` fails on a seeded violation in `apps/api/src` **and** `apps/web`; every baseline recorded and shrink-only; a skipped check fails the gate (R-33) |
| **P0b** | Web primitives (worker B) | 4.5 | P0a start | Money, idempotency, session lock and `DataTable<T>` exist once, with component tests; no screen rebuilt yet |
| **P1** | Financial correctness | 20.5 | P0a | Reversal denied for every lending or accrual journal, including a missing link row; write-off then EOD passes with the `released` identity; allocation FK binds the payment's own loan and rejects superseded rows; one business date proven on DPD, report and reversal; EOM registered; restructure needs a checker; penalty assessed and waivable; origination tiers, exposure cap and arrears block live |
| **P1b** | Security and data integrity | 11.5 | P1 | Bodyless POST rejected without same-site Origin; MFA challenge throttled; grant/revoke bounded; append-only tables privilege-protected; schema-integrity batch applied with `NOT VALID` then `VALIDATE` |
| **P2a** | Coop-facing extraction | 15.5 | P1 | `deposit`, `ledger`, `party` and the platform slice expose use cases via `modules/*/application`; the import predicate is red before and green after; archcheck baseline shrank |
| **P2b** | Remaining extraction | 23 | P2a | `product`, `teller`, `daycloser`, `lending` and platform completion extracted; `hello` deleted; handlers and `daycloser_*` hold no business rules; read models and K-12 contracts exist |
| **P3** | Membership aggregate (`coop`) | 16.5 | P2a | Member lifecycle and obligations derived from postings; exit computes and posts a refund with a checker; SHU basis signed before phase exit; no second ledger |
| **P4** | Coop product model: savings + EOY/SHU | 19 | P3 | Time deposits removed from code, catalogue and claims; EOY closes income and expense, requires closed periods and a zero trial balance; SHU reproducible; distribution posts per member with a checker and a RAT record; cash instalment is one atomic contract |
| **P5** | Reporting and list contracts | 21 | P2a (monthly), P4 (annual) | Eleven RAT documents reconcile to the ledger; every capped list has totals and pagination |
| **P6** | UI rebuild | 22 | P0b, P2a to P5 | 24 screens on the shared system; component tests exist; axe green in 2 themes x 2 locales; bundle budget enforced |
| **P7** | Operator admin and pilot hardening | 10.5 | P2a | User create/reset/MFA in UI; seat matrix with 3 named operators; retention decision and purge tasks; metrics; privilege test; restore drill from the local dump |
| **P8** | Synthetic-coop dry run | 7.5 | P6, P7 | 30 business days on a 12-month seed ending at a fiscal-year boundary, about 200 members, 50 loans, EOY/SHU, zero manual SQL, evidence pack |

Total: **179 dev-days** point estimate, all phases including P1b. Add 20 percent contingency before
committing a date: 215 dev-days. P1b is not on the critical path for dates (it follows P1 in the
queue), but it is counted in the total.

## 2. Order and reason

1. **Gates first.** Every later phase claims "done". If `ci-fast` cannot see `apps/api/src` or
   `apps/web`, the claim cannot be verified. A gate that passes when its tool is missing is not a
   gate (R-33).
2. **Correctness second.** Two defects can corrupt or freeze the books; one blocks every later EOD.
3. **Extraction third.** New modules start in `application/` (R-24); legacy modules move when
   touched. Coop needs `deposit`, `ledger`, `party` and a platform slice first.
4. **Membership before products.** SHU depends on member identity and on obligations derived from
   postings. Building SHU first freezes the schema without a basis.
5. **Reporting after the ledger and the year-end.** Monthly documents can start after P2a; annual
   documents cannot exist before P4.
6. **UI primitives early, screens late.** P0b needs no new contract. The 19 screens that read
   annual or arrears data wait for P4 and P5.
7. **Hardening and dry run last.** They prove the product can be operated by the people who will
   operate it.

## 3. Critical path

```
P0a -> P1 -> P2a -> P3 -> P4 -> P5 -> P6 -> P8
```

Point estimate along that chain: 7.5 + 20.5 + 15.5 + 16.5 + 19 + 21 + 22 + 7.5 = **130 dev-days**.

With one worker the whole queue is sequential and the total is 179 days; the chain matters only when
a second worker takes `apps/web`. A second worker may overlap P0b and screen work against shipped
contracts, which shortens calendar time but does not change the point estimate.

**There is no float.** Earlier drafts claimed P2b and P7 were float. They are not: P4 and P5 read
extracted code, and P8 needs P7. P2b, P7 and P6 are on the chain for planning purposes (R-40).

## 4. Serial by rule

| Constraint | Why |
|---|---|
| Two migrations in the same module | Ordering and expand/contract sequencing |
| Anything running `task test`, `ci`, `verify`, `e2e` or `bench-*` | One shared `kran_test` database |
| Changes to `task`, gate scripts or baselines | Every other check reads them |
| `platform.param_*` seed changes and any task reading those keys | Cache and seed coherence |
| Money-path changes in the same module | One reviewer, one revertible change |
| Applied migrations, including their comments | `migrate --check` treats any content change as drift and stops the deploy |

Genuinely parallel with two workers: web screens against shipped contracts, docs, design, read-only
investigation, and independent modules with no shared migration directory. A second worker does not
touch `apps/api`, `modules`, `task`, migrations, `packages/contracts` or parameter seeds.

## 5. Phase gates

| Gate | Command | Applies to |
|---|---|---|
| Static and types | `./task check-fast` | every phase |
| Backend tests | `./task verify <modules>`, then `./task ci-fast` | P0a to P5, P7 |
| Web types and unit | `svelte-check --fail-on-warnings`, `vitest run`, `pnpm --filter @kran/ui test` (inside `ci-fast` after P0a) | P0a, P0b, P6 |
| End-to-end and axe | `./task e2e` once per phase, `./task ci` at phase exit | P6, P7, P8 |
| Contract | `./task openapi` and contract test | any API change |
| Migration | expand-only check, `migrate --check`, contract allowlist | any schema change |
| Docs inventories | `python3 tools/docsgen/docsgen.py --check` | any parameter or migration change |

A phase is not done because its tasks are marked done. It is done when its exit criterion is
demonstrated by a command whose output is attached to the task file, and when no named check was
skipped (R-33).

## 6. History: old Fase 0 to 4

| Phase | Status | What it delivered | Evidence |
|---|---|---|---|
| 0 Foundation | done | monorepo, kernel, gates, parameter framework, auth, calendar, contract, realtime, web shell, ops scripts | `history/PHASES.md` |
| 1 Ledger + party | done 20 Oct 2026 | ledger invariants, COA, journals, reversal, party/KYC | `history/PHASES.md` |
| 2 Deposit + teller | done 23 Oct 2026 | accounts, deposits, teller sessions, vault | `history/PHASES.md` |
| 3 Day-close | done 28 Oct 2026 | task framework, EOD/EOM levels, gates, automation | `history/PHASES.md` |
| 4 Lending | done 2 Nov 2026 | origination, schedules, payment, PPAP, write-off; PPAP/DPD values still need compliance review | `history/PHASES.md` |

The 166 old task files, milestone reports, spikes and proposals are in git history and in the local
planning archive. They are not part of the living docs.

## 7. Deliberately out of scope

- BPR/BPRS/syariah packs, time deposits, interest-bearing savings.
- Mobile app, offline mode, multi-institution tenancy.
- Automated SHU distribution (calculation automated; distribution posts per member but stays a
  checked, manual run).
- Automated off-host audit anchoring and encrypted off-host backup (manual daily copy; local dump
  restore, R-39).
- Mandatory MFA (optional, throttled, false claims removed, compensating controls named).
- Privacy, AML and complaint obligations beyond the recorded triggers (O4, O5, O8; P-05).
- Health ratios, DPK, branch P&L, non-member savings, promise-to-pay, collateral register.

Each item has a revisit trigger in `DECISIONS.md` section 4 and `OPEN_ITEMS.md`. New scope enters by
an owner decision, never by silent addition.
