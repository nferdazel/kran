# KRAN

Core banking for the Indonesian standard: koperasi (KSP/USP/KSPPS), BPR/BPRS, and BMT. One
codebase serves all three families through *product & regulatory packs*: differences between them
live in parameters and packs, not in branches of code.

The product is early but past the foundation. **Fase 0 (foundation), Fase 1 (core ledger & party),
and Fase 2 (deposit + teller) are delivered**, and Fase 2 runs in a production pilot with synthetic
data. What exists today: the platform (DB pool, migrations, outbox, hash-chain audit), effective-dated
parameters with maker-checker, auth + RBAC + branch scoping, the working calendar, the realtime hub,
an immutable double-entry ledger with reversals and trial balance, deposits (accounts, cash deposit/
withdrawal, transfer), teller cash sessions, and the SvelteKit back-office (dark/light themes, i18n
id/en, WCAG 2.2 AA gate). Phase close-out reports: [`M0`](docs/milestones/M0-report.md),
[`M1`](docs/milestones/M1-report.md), [`M2`](docs/milestones/M2-report.md).

Values and regulatory clauses that are not yet verified are tagged `NEEDS-COMPLIANCE-REVIEW` in
code/seed, and critical areas (interest, accrual, PPAP, tax, reconciliation, encryption, authz) are
tagged `HUMAN-REVIEW-REQUIRED` (`AGENTS.md` §1.8 and §8). This repo does not claim any compliance;
the regulatory register awaits verification by a compliance officer. The pilot data is synthetic and
deliberately kept (approved by the owner, 23 Oct 2026) — see
[`docs/runbooks/pilot-provisioning.md`](docs/runbooks/pilot-provisioning.md).

The product name is **KRAN**; every technical identifier follows it: binary `kran-api`, env `KRAN_*`,
systemd unit `kran-*`, contract `kran-api.yaml`, npm scope `@kran/*` (D-039). Only `cbs-core`, the
legacy system that still runs and is awaiting cutover, keeps its own name.

Stack: PostgreSQL 18 · Nim 2.2 (API; the version range is pinned in [`kran.nimble`](kran.nimble)) ·
SvelteKit + TypeScript (back-office). The UI is built against WCAG 2.2 AA in two themes (dark/light)
with i18n id/en from the foundation on.

Single source of truth: [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md) (PRD +
technical spec). Working rules for humans and agents: [`AGENTS.md`](AGENTS.md).

## Where it stands now

Every task must end with `./task ci` green; that is the only evidence that counts. Recorded gate
evidence per phase lives in the milestone reports and in [`docs/PROGRESS.md`](docs/PROGRESS.md); the
counts move with every task, so they are kept there rather than duplicated here.

Fase 2 (deposit + teller) is deployed and exercised end-to-end in the pilot: book period, savings
products approved by a second account, member accounts, and a teller cash day, all through the public
API so maker-checker, audit, and posting rules run like a real operator. Provisioning is scripted in
[`docs/runbooks/pilot-provisioning.md`](docs/runbooks/pilot-provisioning.md). Product maker-checker
requires **a second operator account** (role `product_checker`) distinct from the maker — a single
account cannot approve the product it created. Planned work, progress, and what is still open are in
[`docs/BACKLOG.md`](docs/BACKLOG.md), [`docs/PROGRESS.md`](docs/PROGRESS.md), and
[`docs/OPEN_ITEMS.md`](docs/OPEN_ITEMS.md) (items there really are open, not assumed done).

## Architecture

Clean architecture per module: `domain` → `application` → `infrastructure`/`interface`. Modules talk
only through `api.nim` and events, and that boundary is enforced by
[`tools/archcheck`](tools/archcheck). Three rules shape most decisions in this repo:

- **Money and rates have their own types** (`Money`, `Rate` in `shared/kernel`), with no float.
  Float rounds money unpredictably and the error accumulates in the ledger; fixed-point types make
  that fail at compile time, not at reconciliation.
- **Business values do not live in code.** Rates, limits, fees, calendar, and thresholds come from
  DB parameters, and parameter keys may only be produced by [`tools/paramgen`](tools/paramgen).
  Business constants in code fail `lint-nomagic`. The reason: changing a value must go through
  maker-checker at runtime, not through a deploy.
- **The ledger is immutable; corrections go through reversal journals.** Book entries are never
  edited or deleted; a fix is written as a new journal (ADR-006). This is implemented in
  `modules/ledger` and covered by property/integration tests.

Directory map:

```
apps/api        Nim entrypoint; one binary, four roles (api | migrate | ctl | worker)
apps/web        SvelteKit (back-office)
modules/<m>     bounded context: domain/ application/ infrastructure/ interface/ migrations/ seeds/ tests/ api.nim MODULE.md
shared/kernel   Money, Rate, BusinessDate, Result, Clock, Id (small and stable)
shared/platform-lib  http, Postgres pool, logging, bootstrap config
packages/       TS side: contracts (OpenAPI), api-client (generated), ui, i18n, config
packs/          segment and regulatory packs (versioned seed)
tools/          archcheck, lint-nomagic, paramgen, i18ncheck, openapi, dbtools, scaffold
docs/           spec, adr, tasks, backlog, runbooks, spikes, milestones
ops/            deploy artifacts (written in-repo, run on the server by humans)
```

Business events leave through an outbox table (transactional, with de-dup and dead-letter), then are
pushed to realtime clients over WebSocket with per-topic authorization. Things that cannot be guessed
from the code are explained in each module's `MODULE.md` and in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

## Mechanical enforcement

A rule that only lives in a document will be broken, so most rules above have an enforcer, and the
enforcers are themselves tested: [`tools/archcheck`](tools/archcheck) (module boundaries),
[`tools/lint-nomagic`](tools/lint-nomagic) + [`tools/paramgen`](tools/paramgen) `--check` (business
values), [`tools/i18ncheck`](tools/i18ncheck) (UI text), `eslint` (TS/Svelte, non-a11y, D-139),
[`tools/openapi`](tools/openapi) with a contract test (contract and TS client), and
[`tools/dbtools`](tools/dbtools) (expand-only migrations).
Money/rate are enforced by kernel types and their tests. The rules that do not yet have an enforcer
(day-close via `daycloser`) are tracked as open items and arrive together with their modules.

## Running and testing

Quick start from the repo root (`./task devdb up` opens the tunnel to the dev DB; runbook in
[`docs/runbooks/dev-db.md`](docs/runbooks/dev-db.md)):

```sh
./task devdb up                  # dev DB tunnel
./task dbtools migrate           # apply migrations (idempotent)
./task dbtools seed --dev        # sample users + parameters
./task build                     # binary to .build/bin/kran-api
.build/bin/kran-api --role=api --port=8080 --address=127.0.0.1   # needs KRAN_DATABASE_URL
pnpm install && pnpm --filter @kran/web dev   # back-office at http://127.0.0.1:5173 (registry: docs/runbooks/dev-web.md)
```

Dev seed users: `dev.maker` (proposes parameter changes) and `dev.checker` (approves them), plus
`dev.cashmaker`/`dev.cashchecker` (cash maker-checker) and `dev.firstlogin` (forced password change).
Passwords are in [`packs/base/seed/0001_dev_users.sql`](packs/base/seed/0001_dev_users.sql).

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
| `./task ci` | every gate above; must be green before a task is called done |
| `./task ci-repeat [N]` | repeat the full gate N times (default 3), to catch flake |
| `./task build` | build the `kran-api` binary into `.build/bin/` |
| `./task fmt` | format code (rewrites files in place) |
| `./task dbtools migrate\|status\|validate\|seed` | SQL migrations and seed (needs `KRAN_DATABASE_URL`) |
| `./task scaffold <name> [--dry-run]` | scaffold a new module |
| `./task bench-password [--iterations N]` | benchmark password hashing cost |
| `./task devdb up\|down\|status\|psql` | manage the tunnel to the dev DB |

Prerequisites:

- Nim 2.2 (`nimble install -d -y` for dependencies). CI pins 2.2.12; `kran.nimble` requires
  `>= 2.2.0 & < 2.3.0`.
- PostgreSQL 18 for integration tests, **not local**: use `./task devdb up` (D-004). Without
  `KRAN_DATABASE_URL`, integration tests (and part of e2e) skip themselves, so the result is not
  evidence.
- Node 24 + pnpm for `apps/web` (registry notes:
  [`docs/runbooks/dev-web.md`](docs/runbooks/dev-web.md)).

## Git workflow and release

Work on a branch `feat/<id>-<slug>`, keep commits small (conventional commits), then open a PR or
leave the branch ready for review; merging to `main` is always a human decision. Since the repo has
a deploy hook (D-043), pushing to `main` **deploys** through the webhook with a health gate and
auto-rollback; other branches are rejected by the ref-guard. Do not push secrets or real data (test
data is always synthetic), and do not touch the server, webhook, Caddy, or production `ops/` unless a
task explicitly asks for it.

## License

This repo is **public so it can be read and audited**, not for reuse: copyright is retained, and any
license is valid only when granted in writing ([`LICENSE`](LICENSE), D-044). The `kran.nimble`
metadata is not a license grant.

## Where to read next

- [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md): product and technical contract (§23 = phase list).
- [`docs/DECISIONS.md`](docs/DECISIONS.md): engineering decisions with their rationale.
- [`docs/BACKLOG.md`](docs/BACKLOG.md): plan and task status.
- [`docs/OPEN_ITEMS.md`](docs/OPEN_ITEMS.md): what is unfinished and needs a decision.
- [`docs/runbooks/`](docs/runbooks): operational procedures (dev DB, web, migrations, CLI ops, deploy, pilot provisioning).
- [`AGENTS.md`](AGENTS.md): working rules for agents and humans, including the per-task protocol.
