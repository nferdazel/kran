# KRAN

Core banking for Indonesian cooperatives. The first vertical slice is a KSP (koperasi simpan
pinjam): members, simpanan pokok/wajib/sukarela, loans with maker/checker, SHU at year end, and
RAT-grade reporting. BPR/BPRS and syariah packs are planned, not built; they are out of scope for
this slice (R-10).

## What this is

KRAN serves the cooperative families KSP/USP/KSPPS, BPR/BPRS and BMT from one codebase, with
differences carried in data and regulatory packs instead of branches of code. The repository is
public so the source can be read and audited; it is not open source, and `LICENSE` grants no right
to use, copy, modify or redistribute without written permission (D-044).

What exists today: the platform (DB pool, migrations, outbox, hash-chain audit), effective-dated
parameters with maker-checker, auth + RBAC + branch scoping, the working calendar, the realtime hub,
an immutable double-entry ledger with reversals and trial balance, deposits (accounts, cash
deposit/withdrawal, transfer), teller cash sessions, the day-close framework (idempotent EOD/EOM
tasks with pre/post gates and an operator monitor), the lending cycle (application, approval,
disbursement, instalments, collectibility, PPAP, restructure/write-off) with arrears and allowance
reports, and the SvelteKit back-office (dark/light themes, i18n id/en, WCAG 2.2 AA gate).

What does not exist yet, despite older claims: a membership aggregate, annual close and SHU,
member onboarding screens, arrears screens, user administration in the UI, and time deposits (the
stack is unreachable and is being removed, not repaired). The capability ledger states this row by
row: [`docs/CAPABILITIES.md`](docs/CAPABILITIES.md).

Values and regulatory clauses that are not verified stay tagged `NEEDS-COMPLIANCE-REVIEW` in code
and seed, and critical areas (interest, accrual, PPAP, tax, reconciliation, encryption, authz) stay
tagged `HUMAN-REVIEW-REQUIRED`. This repo does not claim compliance; the regulatory register awaits
verification by a compliance officer. Pilot data is synthetic and deliberately kept (owner decision,
23 Oct 2026); operations are in [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

The product name is KRAN; technical identifiers follow it: binary `kran-api`, env `KRAN_*`, systemd
unit `kran-*`, contract `kran-api.yaml`, npm scope `@kran/*` (D-039).

## Status

Version `VERSION` at the root is the single source for API, web, `kran.nimble` and `package.json`.

The old Fase 0-4 (foundation, ledger and party, deposit and teller, day-close, lending) are
historical; what they delivered and their gate evidence are in
[`docs/history/PHASES.md`](docs/history/PHASES.md). A replanning in November 2026 audited the whole
codebase, found correctness and product gaps that the old phase reports did not surface, and replaced
the phase plan. Current direction is [`docs/ROADMAP.md`](docs/ROADMAP.md) (P0-P8), with the queue in
[`docs/BACKLOG.md`](docs/BACKLOG.md). The product is not pilot-ready until P8 passes.

The command is the evidence. A task ends with `./task check-fast` green, and with `./task ci-fast`
(plus `./task ci` where the phase touches UI or e2e) green before anything is called done (D-194);
the output is pasted into the task file. Live status is in [`docs/BACKLOG.md`](docs/BACKLOG.md) and
[`docs/CAPABILITIES.md`](docs/CAPABILITIES.md). What the audit found still broken, and what is
accepted rather than fixed, is in [`docs/OPEN_ITEMS.md`](docs/OPEN_ITEMS.md) and
[`docs/ACCEPTED-LIMITS.md`](docs/ACCEPTED-LIMITS.md).

## Architecture

Clean architecture per module: `domain` → `application` → `infrastructure`/`interface`. Modules talk
only through `api.nim` and events, and that boundary is enforced with [`tools/archcheck`](tools/archcheck)
over `modules/*`. `apps/api/src` (the HTTP handlers) is not yet in scope; P0 adds it and the baseline
may only shrink from there. Three rules shape most decisions in this repo:

- Money and rates have their own types (`Money`, `Rate` in `shared/kernel`), with no float. Float
  rounds money unpredictably and the error accumulates in the ledger; fixed-point types make that
  fail at compile time, not at reconciliation.
- Business values do not live in code. Rates, limits, fees, calendar and thresholds come from DB
  parameters, and parameter keys may only be produced by [`tools/paramgen`](tools/paramgen).
  Business constants in code fail `lint-nomagic`. The reason: changing a value must go through
  maker-checker at runtime, not through a deploy.
- The ledger is immutable; corrections go through reversal journals. Book entries are never edited
  or deleted; a fix is written as a new journal (ADR-006). This is implemented in `modules/ledger`
  and covered by property/integration tests.

Stack: PostgreSQL 18, Nim 2.4 (API; pinned in [`kran.nimble`](kran.nimble)), SvelteKit + TypeScript
(back-office), WCAG 2.2 AA in two themes with i18n id/en.

Business events leave through an outbox table (transactional, with de-dup and dead-letter), then are
pushed to realtime clients over WebSocket with per-topic authorization. Things that cannot be guessed
from the code are explained in each module's `MODULE.md` and in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

Single source of truth: [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md).
Working rules for humans and agents: [`AGENTS.md`](AGENTS.md).

A rule that only lives in a document will be broken, so most rules above have an enforcer, and the
enforcers are themselves tested: [`tools/archcheck`](tools/archcheck) (module boundaries),
[`tools/lint-nomagic`](tools/lint-nomagic) + [`tools/paramgen`](tools/paramgen) `--check` (business
values), [`tools/i18ncheck`](tools/i18ncheck) (UI text), `eslint` (TS/Svelte, non-a11y, D-139),
[`tools/openapi`](tools/openapi) with a contract test (contract and TS client), and
[`tools/dbtools`](tools/dbtools) (expand-only migrations). Money and rate are enforced by kernel
types and their tests. Day-close is itself a module (`modules/daycloser`): a batch that runs outside
its registered, idempotent tasks and pre/post gates fails review (AGENTS §1.7), so "close the books"
is one code path, not one per module.

## Repository layout

```
apps/api        Nim entrypoint; one binary, four roles (api | migrate | ctl | worker)
apps/web        SvelteKit (back-office)
modules/<m>     bounded context: domain/ application/ infrastructure/ interface/ migrations/ seeds/ tests/ api.nim MODULE.md
shared/kernel   Money, Rate, BusinessDate, Result, Clock, Id (small and stable)
shared/platform-lib  http, Postgres pool, logging, bootstrap config
packages/       TS side: contracts (OpenAPI), api-client (generated), ui, i18n, config
packs/          segment and regulatory packs (versioned seed)
tools/          archcheck, lint-nomagic, paramgen, i18ncheck, openapi, dbtools, scaffold
docs/           spec, roadmap, backlog, decisions, operations, design, history
ops/            deploy artifacts (written in-repo, run on the server by humans)
```

## Local development

### Prerequisites

- Nim 2.4 (`nimble install -d -y` for dependencies). CI pins 2.4.0; `kran.nimble` requires
  `>= 2.4.0 & < 2.5.0`.
- PostgreSQL 18 for integration tests, not local: use `./task devdb up` (D-004). Without
  `KRAN_DATABASE_URL`, integration tests (and part of e2e) skip themselves, so the result is not
  evidence.
- Node 24 + pnpm for `apps/web` (registry notes: [`docs/OPERATIONS.md`](docs/OPERATIONS.md)).

### Quickstart

From the repo root (`./task devdb up` opens the tunnel to the dev DB; runbook in
[`docs/OPERATIONS.md`](docs/OPERATIONS.md)):

```sh
./task devdb up                  # dev DB tunnel
./task dbtools migrate           # apply migrations (idempotent)
./task dbtools seed --dev        # sample users + parameters
./task build                     # binary to .build/bin/kran-api
.build/bin/kran-api --role=api --port=8080 --address=127.0.0.1   # needs KRAN_DATABASE_URL
pnpm install && pnpm --filter @kran/web dev   # back-office at http://127.0.0.1:5173
```

Dev seed users: `dev.maker` (proposes parameter changes) and `dev.checker` (approves them), plus
`dev.cashmaker`/`dev.cashchecker` (cash maker-checker), `dev.console` (`platform_admin`),
`dev.loans` (`lending_maker`, added for the lending e2e fixture), and `dev.firstlogin` (forced
password change). Passwords are in [`packs/base/seed/0001_dev_users.sql`](packs/base/seed/0001_dev_users.sql).

## Configuration

The API reads `KRAN_DATABASE_URL` plus a small set of runtime variables (`KRAN_DB_POOL_SIZE`,
`KRAN_BIND_HOST`, timeouts, `KRAN_ALLOW_NO_DB`); the deploy path reads its own set
(`KRAN_GITHUB_REPO`, `KRAN_CI_WAIT_SECONDS`, `KRAN_HEALTH_GATE_SECONDS`, `KRAN_DEPLOY_LOCK_WAIT`,
`KRAN_FORCE_DEPLOY`). The table with defaults and consumers is in
[`docs/OPERATIONS.md`](docs/OPERATIONS.md); the deploy-side example is
[`ops/env/kran-prod.env.example`](ops/env/kran-prod.env.example). No real value belongs in this
repository. `KRAN_PORT` is not read by the binary: the quadlet unit passes `--port=8095`.

## Quality gates

One command entry point: `./task` (POSIX script, no extra tooling dependencies; D-001).

| Command | Contents |
|---|---|
| `./task check` | format + `nim check` + archcheck + lint-nomagic + paramgen `--check` + i18n check |
| `./task check-fast` | like `check` without the full `nim check` (daily iteration loop, D-077) |
| `./task verify [filter]` | `check-fast` + openapi + build + tests for the selected modules (D-077) |
| `./task test` | unit + property + integration (Postgres) + contract |
| `./task e2e` | token contrast + svelte-check + Playwright (e2e, axe 2 themes, keyboard) |
| `./task lint-web` | eslint (typescript-eslint + `svelte/*`, non-a11y) over `apps/web` and `packages/ui` |
| `./task openapi` | lint the OpenAPI contract + check the TS client is in sync |
| `./task ci-fast` | `check` + openapi + lint-web + tests, no e2e - daily loop gate (D-194) |
| `./task ci` | every gate above including e2e; must be green before a task is called done |
| `./task ci-repeat [N]` | repeat the full gate N times (default 3), to catch flake |
| `./task build` | build the `kran-api` binary into `.build/bin/` |
| `./task version` | print `VERSION` (single source for API, web, `kran.nimble`, `package.json`) |
| `./task release [major\|minor\|patch]` | bump `VERSION` + CHANGELOG, run the gate (incl. tests + e2e), commit + annotated tag `vX.Y.Z` |
| `./task fmt` | format code (rewrites files in place) |
| `./task dbtools migrate\|status\|validate\|seed` | SQL migrations and seed (needs `KRAN_DATABASE_URL`) |
| `./task scaffold <name> [--dry-run]` | scaffold a new module |
| `./task bench-password [--iterations N]` | benchmark password hashing cost |
| `./task bench-eod --accounts N [--loans M]` | seed synthetic accounts/loans, then time one full EOD |
| `./task devdb up\|down\|status\|psql` | manage the tunnel to the dev DB |

CI runs `./task check` and `./task test` on every push and pull request, plus a contract job over the
golden CI/CD rules and a traceability job.

## Deployment

Pushing to `main` deploys through the webhook with a health gate and auto-rollback, so a push is only
made through `./task release`; other branches are rejected by the ref-guard. Provisioning runs from
[`docs/OPERATIONS.md`](docs/OPERATIONS.md). Any multi-operator flow needs two real accounts: maker
and checker must be different people for product approval, parameter changes, and SHU distribution.

## Documentation

One page, one entry point, no status table: [`docs/README.md`](docs/README.md) maps the rest and says
which documents are current state and which are dated history.

- [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md): product and technical contract (§23 = phase list).
- [`docs/ROADMAP.md`](docs/ROADMAP.md): the P0-P8 direction that replaced the phase plan.
- [`docs/BACKLOG.md`](docs/BACKLOG.md): plan and task status.
- [`docs/DECISIONS.md`](docs/DECISIONS.md): engineering decisions with their rationale.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md): dev DB, web, migrations, CLI ops, deploy, pilot provisioning.
- [`docs/OPEN_ITEMS.md`](docs/OPEN_ITEMS.md) and [`docs/ACCEPTED-LIMITS.md`](docs/ACCEPTED-LIMITS.md): what is unfinished, and what is accepted rather than fixed.
- [`AGENTS.md`](AGENTS.md): working rules for agents and humans, including the per-task protocol.

## Security

Do not open a public issue for a vulnerability. The supported versions, the reporting channel and
what to include are in [`SECURITY.md`](SECURITY.md); GitHub private vulnerability reporting is
enabled on this repository.

## Contributing

This repo is public so it can be read and audited, not for reuse: `LICENSE` grants no right to use,
copy, modify or redistribute without written permission, and opening an issue or a PR does not change
that. Build, test and commit conventions are in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

This repo is public so it can be read and audited, not for reuse: copyright is retained, and any
license is valid only when granted in writing ([`LICENSE`](LICENSE), D-044). The `kran.nimble`
metadata is not a license grant.
