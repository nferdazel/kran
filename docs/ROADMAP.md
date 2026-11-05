# KRAN - Roadmap

Single source of direction for all work after the replan. It replaces the old phase table. Task
rows live in `BACKLOG.md`; product truth lives in `spec/kran-prd-techspec.md`.

Baseline at replan: VERSION 0.1.19, old Fase 0-4 complete. **P0-P8 are new**; they are not the old
Fase numbers.

Product target: KSP (savings-and-loan cooperative) pilot, 2+ operators without server access,
membership as a first-class aggregate, SHU-based savings, no time deposits, maker/checker lending,
RAT-grade reporting.

---

## 1. Phases

| Phase | Name | Size (dev-days, 1 dev) | Depends on | Exit criterion (verifiable) |
|---|---|---|---|---|
| **P0** | Gates see the money code | 5-8 | - | `ci-fast` fails on a seeded violation in `apps/api/src` **and** `apps/web`; baselines recorded and only shrink |
| **P1** | Financial correctness | 10-15 | P0 | Reversal of lending/accrual journals denied; write-off-then-EOD passes; allocation FK + sum trigger live; one business date; stable `params.reason` on every 409 |
| **P1b** | Security and data integrity | 5-8 | P1 | Bodyless POSTs rejected without same-site Origin; MFA challenge throttled; grant/revoke bounded; append-only tables privilege-protected; schema-integrity batch applied |
| **P2a** | Coop-facing extraction | 12-18 | P1 | `deposit`, `ledger`, `party` and the platform param/user/audit slice expose use cases via `modules/*/application`; archcheck baseline shrank |
| **P2b** | Remaining extraction | 15-22 | P2a | `product`, `teller`, `daycloser`, `lending`, platform completion extracted; `hello` deleted; handlers hold no business rules |
| **P3** | Membership aggregate (`coop`) | 12-18 | P2a | Member lifecycle + obligations derived from postings; no second ledger; SHU basis signed |
| **P4** | Coop product model: savings + EOY/SHU | 12-18 | P3 | Time deposits removed from code, catalogue and claims; EOY task registered; SHU reproducible; distribution requires checker + RAT record |
| **P5** | Reporting and list contracts | 15-22 | P2a (monthly), P4 (annual) | Nine RAT documents reconcile to the ledger; every capped list has totals + pagination |
| **P6** | UI rebuild | 25-40 | P0 (primitives), P2a-P5 (contracts) | 24 screens on the shared system; component tests exist; axe green in 2 themes; bundle budget enforced |
| **P7** | Operator admin and pilot hardening | 10-15 | P2a | User create/reset/MFA enrol in UI; retention tasks; metrics; privilege test; restore drill; 2 named operators |
| **P8** | Synthetic-coop dry run | 8-12 | P6, P7 | 30 business days, about 200 members, 50 loans, EOY/SHU, zero manual SQL, evidence pack |

Derived total: **124-188 dev-days**. Add 20% contingency before committing a date. The second web
worker (R-30) overlaps P6 with P2b-P5.

## 2. Order and reason

1. **Gates first.** Every later phase claims "done". If `ci-fast` cannot see `apps/api/src` or
   `apps/web`, the claim cannot be verified.
2. **Correctness second.** Two defects can corrupt or freeze the books; one blocks every later EOD.
3. **Extraction third.** New modules start in `application/` (R-24); legacy modules move when
   touched. Coop needs `deposit`, `ledger`, `party` and a platform slice first.
4. **Membership before products.** SHU depends on member identity and on obligations derived from
   postings. Building SHU first freezes the schema without a basis.
5. **Reporting after the ledger and the year-end.** Monthly documents can start after P2a; annual
   documents cannot exist before P4.
6. **UI alongside, not after everything.** Primitives need no new contract and start in P0/P1.
7. **Hardening and dry run last.** They prove the product can be operated by the people who will
   operate it.

## 3. Critical path

```
P0 → P1 → P2a → P3 → P4 → P5(annual) → P8
                   ↘ P2b ↗
P6 (web worker) runs alongside P2a…P5, blocked only by the contracts it consumes
P7 runs after P2a, independent of P4/P5
```

Longest chain: **P0 → P1 → P2a → P3 → P4 → P5 → P8**, roughly 74-105 dev-days. Float: P2b (5-7
days) and P7 (3-5 days). No float in **P0, P1, P3**: a slip there moves the dry run one-for-one.

## 4. Serial by rule

| Constraint | Why |
|---|---|
| Two migrations in the same module | Ordering and expand/contract sequencing |
| Anything running `task test|ci|verify|e2e|bench-*` | One shared `kran_test` database |
| Changes to `task`, gate scripts or baselines | Every other check reads them |
| `platform.param_*` seed changes and any task reading those keys | Cache and seed coherence |
| Money-path changes in the same module | One reviewer, one revertible change |

Genuinely parallel with two workers: web screens against shipped contracts, docs, design, read-only
investigation, and independent modules with no shared migration directory.

## 5. Phase gates

| Gate | Command | Applies to |
|---|---|---|
| Static and types | `./task check-fast` | every phase |
| Backend tests | `./task verify <modules>`, then `./task ci-fast` | P0-P5, P7 |
| Web types and unit | `svelte-check --fail-on-warnings`, `vitest run` (inside `ci-fast` after P0) | P0, P6 |
| End-to-end and axe | `./task e2e` once per phase, `./task ci` at phase exit | P6, P7, P8 |
| Contract | `./task openapi` and contract test | any API change |
| Migration | expand-only check, `migrate --check`, contract allowlist | any schema change |
| Docs inventories | `python3 tools/docsgen/docsgen.py --check` | any parameter or migration change |

A phase is not done because its tasks are marked done. It is done when its exit criterion is
demonstrated by a command whose output is attached to the task file.

## 6. History: old Fase 0-4

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
- Automated SHU distribution (calculation automated, posting manual and checked).
- Automated off-host audit anchoring (manual daily head-hash copy and disclosure).
- Mandatory MFA (optional, throttled, false claims removed, compensating controls named).
- Health ratios, DPK, branch P&L, non-member savings, promise-to-pay, collateral register.

Each item has a revisit trigger in `DECISIONS.md` §4. New scope enters by an owner decision, never by
silent addition.
