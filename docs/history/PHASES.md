# Historical phases, Fase 0-4

Fase 0-4 of the old plan are complete. This page is frozen history: it records dates, the
reachable tag or commit range, the gate result, what shipped, and where the full report lives.
It is not current status. Current work is in `ROADMAP.md` and `BACKLOG.md`.

Dates are the milestone report dates. Commit ranges are the ranges reachable in this repository;
archive tags mark work-branch heads and are not releases. Fase 0-3 reports say the branches
were not merged by the agent; the current tree carries the resulting code.

| Phase | Dates | Tag or commit range | Gate result | Delivered | Report |
|---|---|---|---|---|---|
| Fase 0: foundation | 13-14 Oct 2026 | `archive/2026-10-21-feat-fase0-fondasi` at `056350b`; `df245d9..056350b` | `./task ci` exit 0; `./task test` 421 OK, 0 failed; Playwright 18 passed | Monorepo and `./task`; Money/Rate kernel; archcheck, lint-nomagic, paramgen; migration runner, outbox/inbox, hash-chain audit; parameters; auth/RBAC; business calendar; HTTP contract and client; realtime; web shell; scaffold; Fase 0 end-to-end flow | old milestone report, git history |
| Fase 1: ledger and party | 15-20 Oct 2026 | `archive/2026-10-21-feat-fase1-party` at `a4aa6b0`; `e57bc7e..a4aa6b0` | `./task ci` on `b3f3f98` green: 816 OK, 24 Playwright passed, 671 s | Party, CIF, encrypted identity documents, KYC and risk rating; COA, periods, immutable journals, reversal, trial balance and snapshot; posting rules and outbox consumer; product factory with versions and bindings; Fase 1 end-to-end | old milestone report, git history |
| Fase 2: deposit and teller | 21-23 Oct 2026 | `archive/2026-10-21-feat-fase2` at `afdcd02`; `a4aa6b0..afdcd02` | `./task ci` green; independent review APPROVE (no test counts printed in the report) | Savings accounts; cash deposit and withdrawal; PB transfer; teller session, vault, and cash movement; teller UI with review and shortcuts; keyboard-only e2e and axe | old milestone report, git history |
| Fase 3: day-close | 24-28 Oct 2026 | `feat/fase3-dayclose`; `133d741..878df39` | `./task ci` green 28 Oct 2026: vitest 142, Playwright 59; 12-month synthetic simulation passed | `daycloser` framework with run/task/chunk state, resume, pause, cancel; business-date cycle; pre/post-close gates; ledger and deposit tasks; close UI monitor; 12-month simulation | old milestone report, git history |
| Fase 4: lending | 29 Oct-2 Nov 2026 | `v0.1.4..v0.1.7` (`v0.1.4` T-161 to T-164, `v0.1.5` T-165 to T-167, `v0.1.6` T-168, `v0.1.7` T-169 and T-170) | `./task ci` green 2 Nov 2026: Nim 1565 OK, 0 failed; Playwright 65; golden schedule and accounting reconciliation | Loan product versions, akad, schedule engine; submit, approve, disburse; instalment payment and allocation; collectibility and PPAP/CKPN; restructure, write-off, recovery; lending reports; loan UI; releases `v0.1.4` to `v0.1.7` | old milestone report, git history |

The combined EOD benchmark of 100,000 savings accounts and 50,000 loans completed in 245.0 s on
local hardware, recorded in the Fase 4 report. It is a local measurement, not a production
service-level guarantee.

Historical task ids (`T-xxx`) are not paths in the current tree. Resolve them through the
reports above or the old task files in git history.
