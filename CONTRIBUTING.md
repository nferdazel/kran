# Contributing to KRAN

KRAN is core banking for Indonesian cooperatives (koperasi KSP/USP/KSPPS, BPR/BPRS, BMT). One
codebase serves all three families through parameters and product/regulatory packs; differences
belong in data, not in branches of code.

The repository is public so the source can be read and audited. It is **not** open source:
`LICENSE` grants no right to use, copy, modify, or redistribute the code without written permission.
Opening an issue or a PR does not change that.

The project currently has a single maintainer (spec §23). Issues and PRs are read as time allows;
there is no triage SLA.

## Read this first

- [`AGENTS.md`](AGENTS.md) §1 (golden rules), §3 (git and release), §5 (no invented facts), §6
  (definition of done).
- [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md) is the product/technical
  source of truth. If code and spec disagree, do not silently pick one: record it in
  [`docs/DECISIONS.md`](docs/DECISIONS.md) and escalate.
- [`docs/README.md`](docs/README.md) maps the rest of `docs/` and says which documents are current
  state and which are dated history.

Identifiers and commit messages are English. Documentation and domain comments may be Indonesian
(AGENTS §9).

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Nim | 2.4.0 | `kran.nimble` requires `>= 2.4.0 & < 2.5.0`; CI pins 2.4.0 |
| PostgreSQL | 18 | not a local install: use the tunnel, `./task devdb up` (D-004) |
| Node + pnpm | Node 24 | for `apps/web`; pnpm version comes from `packageManager` |
| shellcheck | any current | `./task check` fails closed when it is missing |

```sh
nimble install -d -y
pnpm install
./task devdb up
./task dbtools migrate
./task dbtools seed --dev
./task build
```

`KRAN_DATABASE_URL` is read from `.local/dev.env` (mode 600, gitignored) and points at the dev
database through the SSH tunnel. Setup and limits are in
[`docs/runbooks/dev-db.md`](docs/runbooks/dev-db.md); never copy the URL or a password into a
commit, issue, or PR.

Without `KRAN_DATABASE_URL`, integration tests and database-backed e2e specs **skip themselves**.
A green run with skipped tests is not evidence (AGENTS §5).

Dev seed users (`dev.maker`, `dev.checker`, `dev.cashmaker`, `dev.console`, `dev.loans`, ...) exist
only for development and tests. Their passwords are intentionally public in
[`packs/base/seed/0001_dev_users.sql`](packs/base/seed/0001_dev_users.sql); see
[`SECURITY.md`](SECURITY.md).

## One entry point: `./task`

All work goes through the POSIX script at the repository root (D-001). `./task help` lists every
target.

| When | Command | What it runs |
|---|---|---|
| while iterating | `./task check-fast` | format check + archcheck + lint-nomagic + `paramgen --check` + i18n + version + shellcheck, without the full `nim check` (D-077) |
| one module changed | `./task verify <module>` | `check-fast` + openapi + build + tests for the selected modules |
| before a PR | `./task ci` | `check` (including the full `nim check`), openapi, lint-web, unit/property + integration + contract tests, and e2e (which builds the binary) |
| front-end only | `./task lint-web`, `./task e2e` | eslint over `apps/web`/`packages/ui`; token contrast, `svelte-check`, Playwright (axe, keyboard) |
| formatting | `./task fmt` | rewrites files in place |

`./task ci` needs a database and refuses to run without `KRAN_DATABASE_URL` rather than reporting
green with fewer tests (D-179). `KRAN_ALLOW_NO_DB=1` exists for a deliberate skip; if you use it,
say so in the PR and do not present the result as gate evidence.

Rules that are not negotiable:

- Do not weaken a test, lint rule, threshold, or gate to get green. That requires an entry in
  `docs/DECISIONS.md` and is escalated (AGENTS §5).
- Write the test first where the behaviour is testable: domain rules, `Money`/`Rate` arithmetic,
  and every calculation get property and/or golden tests. A fix should have a test that fails when
  the fix is reverted.
- New business values are database parameters, never constants: register the key with
  [`tools/paramgen`](tools/paramgen), add the migration and seed, and keep `./task paramgen --check`
  green. `tools/lint-nomagic` blocks business numbers in domain/application code.
- Money and rates use `Money`/`Rate` from `shared/kernel`; never float.
- Migrations are expand-only. Destructive changes go in a separate contract migration.
- Every new UI string goes through `packages/i18n` in both `id` and `en`.

## Branch, commit, pull request

- Branch from `main`: `feat/<id>-<slug>`. Keep commits small and conventional
  (`feat:`, `fix:`, `docs:`, `chore:`, ...); one commit is one logical change.
- **Never push or merge to `main`.** A push to `main` deploys production through the webhook
  (`deploy-vps.sh`), which accepts only `refs/heads/main`, waits for green CI, and auto-rolls back
  on a failed health check (D-043, [`docs/RELEASE.md`](docs/RELEASE.md)). Merging is a human
  decision by the maintainer.
- Do not commit real data or secrets. Test data is always synthetic. `ops/env/*.example` files are
  templates and must contain no real value.
- Open a PR and fill in the template (`.github/pull_request_template.md`). A PR that changes only
  Markdown or `docs/` does not trigger CI at all (`paths-ignore` in
  [`.github/workflows/ci.yml`](.github/workflows/ci.yml)); state that explicitly instead of
  claiming a gate result.
- Changes touching interest, accrual, PPAP, tax, reconciliation, encryption/key management,
  authorization, or the audit hash chain must be marked `HUMAN-REVIEW-REQUIRED` in the PR
  (AGENTS §8).

## What review looks for

The review is independent: the reviewer reads the diff, the tests, and the spec, not the author's
reasoning. A PR is approvable when it satisfies AGENTS §6:

- tests exist and pass; the PR states the command and the actual result;
- module boundaries hold (`./task archcheck`); modules talk only through `api.nim` and events;
- no business magic numbers; new parameters are registered, migrated, and seeded;
- money and rates go through `Money`/`Rate`, with no float anywhere;
- use cases are atomic, events leave through the outbox, financial operations are idempotent;
- the OpenAPI contract is updated and its contract test passes;
- UI text is in both locales and accessibility holds (axe in two themes × two locales, critical
  flow usable keyboard-only);
- audit events and permissions are correct; sensitive data is masked or encrypted;
- migrations are expand-only, with contract changes separated;
- `MODULE.md` and the relevant docs are updated, and regulatory requirements carry their `@REG-xxx`
  tag;
- no secrets, no real personal data.

Expect review comments about scope: unrelated refactors are asked to become their own task.

## Security and conduct

- Security problems: follow [`SECURITY.md`](SECURITY.md). Do not open a public issue.
- Participation is covered by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
- Accessibility barriers: [`ACCESSIBILITY.md`](ACCESSIBILITY.md) explains how to report one.
