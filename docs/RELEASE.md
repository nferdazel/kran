# KRAN - Release and versioning

Decision: **D-178** (1 Nov 2026), amended by **D-194** (2 Nov 2026). The flow is adapted from a
sibling project, with one difference that matters: KRAN closes a hole left open there. The
release workflow verifies that the tag equals `VERSION`, and the deploy has a fail-closed CI
gate.

Status: active. `VERSION` is the only version source. `./task release` performs the bump, the
changelog, the gate, the commit and the tag. A tag is a **marker**, not a deploy trigger.

---

## 1. One version, five places

`VERSION` at the repository root (plain `X.Y.Z`) must equal:

| File | Role |
|---|---|
| `kran.nimble` | Nim package version |
| `package.json` | pnpm workspace version |
| `apps/api/src/version_gen.nim` | `AppVersion` and `AppCommit` for `/healthz` and startup logs |
| `apps/web/src/lib/version.ts` | `APP_VERSION` and `APP_COMMIT` for the UI footer |

The last two are **generated** by `tools/gen-version.sh`, called from `./task build`, and
**committed**. `./task check` and `./task check-fast` run `./task version-check`, which fails
when any of the five values drifts. A version cannot be silently forgotten.

`KRAN_VERSION` (environment or systemd) still wins over the stamped value, so a running process
does not depend on when the binary was built.

---

## 2. Release flow

Releases are **batched**, not made per commit: one tag runs the release workflow and marks a
deploy that waits for full CI (about 10 to 15 minutes on GitHub Actions). Tagging every commit
only burns runners and turns `CHANGELOG.md` into noise. The working rule: release when one
complete piece of work is done (one task, one fix batch, or just before a new phase opens).

```sh
./task release            # bump derived from Conventional Commits
./task release minor      # force minor (major|minor|patch)
./task release --no-push  # rehearsal: local commit + tag, no push/gh
```

1. The working tree must be clean; `VERSION` must be plain semver.
2. A bump without an argument is derived from the commits since the last `v*` tag: `!:` or
   `BREAKING CHANGE:` means major, `feat:` means minor, anything else means patch.
3. `VERSION`, `kran.nimble` and `package.json` are raised; `tools/gen-version.sh` restamps the
   generated files.
4. `tools/gen-changelog.sh` adds an entry to `CHANGELOG.md` (Keep a Changelog) from the
   commits: `feat` to Added, `fix` to Fixed, `perf` and `refactor` to Changed, `ops`, `ci` and
   `deploy` to Operations. Commits matching `chore: release*` are skipped. The same file is
   used as the GitHub Release note.
5. Gate: `./task check-fast` plus `./task build` plus `./task test` plus `./task e2e`, then
   `./task version-check` (D-194). This needs `KRAN_DATABASE_URL`, which is checked **before**
   the version bump so an environment failure does not leave a half-bumped tree. `--skip-check`
   exists for emergencies and is **recorded** in the release note.
6. Commit `chore: release vX.Y.Z` (no `-s`; this repository does not use DCO), create an
   annotated tag `vX.Y.Z`, then `git push origin <branch> --follow-tags` and
   `gh release create`.
7. `.github/workflows/release.yml` (trigger `tags: v*`) verifies that the tag equals `VERSION`
   (including the manifest and generated files) and then creates the GitHub Release
   idempotently. Only the latest tag carries the *Latest* badge.

**Pushing a tag does not deploy.** Deploy still happens on a push to `main` through the webhook
and `ops/scripts/deploy-vps.sh`. The release commit is deployed because it is on `main`.

`CHANGELOG.md` is never written by hand. Entries come from `tools/gen-changelog.sh`, and the
file does not cover releases that predate the generator.

---

## 3. CI gate in front of the deploy

`deploy-vps.sh` waits for the GitHub check-runs of the SHA being deployed before it touches
anything:

```
Nim (check + unit/property test)
DB (integrasi, Postgres 18)
Web (svelte-check + axe + Playwright)
Security (gitleaks)
```

Rule: only `success` is green. `skipped` and `neutral` mean the check did not run. One name is
judged from the most recent run. A missing check or a timeout is a **failure** (fail-closed).
A change that touches only documentation passes the gate because CI does not run for those
paths. API requests are conditional (`If-None-Match`), so a poll with no change gets `304` and
does not consume quota; without a token the limit is 60 requests per hour per IP. If the quota
is exhausted (`HTTP 403` or `429`), the gate reads `X-RateLimit-Reset` and waits until the reset
**once**, inside the wait budget, before failing. The failure message names `KRAN_GITHUB_TOKEN`,
because a read-only token is the remedy (O-120).

| Variable | Default | Meaning |
|---|---|---|
| `KRAN_GITHUB_REPO` | `nferdazel/kran` | Repository whose check-runs are read |
| `KRAN_GITHUB_TOKEN` | unset (optional) | Public repository; a token only raises the API limit |
| `KRAN_CI_WAIT_SECONDS` | `1800` | Maximum wait for CI (the first deploy using this gate waited 14m04s) |
| `KRAN_SKIP_CI_GATE` | `0` | **Emergency only**; logged as `WARN` in `deploy.log` |
| `KRAN_DEPLOY_LOCK_WAIT` | `900` | Maximum wait for another deploy to finish, instead of failing immediately |

Why this gate exists: on 1 Nov 2026 production served a web build from 25 Oct for about six
days. CI was green and the API was deployed, but the web build on the host died at
`corepack: command not found` and nobody checked the deploy result. The CI gate is not a
substitute for checking the deploy; it only ensures a deploy does not start for a commit already
proven red.

Job names are a contract with the gate. Renaming a job in `ci.yml` without updating
`CI_EXPECTED` in `deploy-vps.sh` in the same commit makes the gate time out and fail closed. A
new job is not a gate unless it is added to `CI_EXPECTED`.

---

## 4. Rollback

A bad release is rolled back with `ops/scripts/rollback.sh`, which restores the previous image,
web build and units, then polls `/readyz`. It does not restore the schema. The procedure, its
preconditions and its limits are in `OPERATIONS.md` section 1.5.

Rollback is not triggered by a tag. There is no per-commit image tag: exactly one previous image
(`:prev`) is kept for this purpose.

---

## 5. Known limits

- Job names are matched as strings. Renaming one without updating `CI_EXPECTED` makes the deploy
  gate time out (fail-closed); the coupling is stated in the D-178 decision text.
- The local release gate covers test and e2e but is still not a full `./task ci`: `check-fast`
  skips the full `nim check` pass (D-077). The complete guarantee comes from CI on the same
  commit, and the deploy waits for it.
- The release gate requires a database URL; without it the command stops before changing
  `VERSION`.
- `release.yml` trusts the tag name only after comparing it with all five version locations. A
  moved tag on an existing release cannot be used to publish different content; enabling
  immutable releases is a repository setting, not a workflow change.

---

## 6. Related documents

- `OPERATIONS.md`: deploy sequence, CI gate variables, rollback, migrations, backup and restore.
- `SECURITY.md`: security gates, dependency policy, vulnerability reporting.
- `ROADMAP.md` and `BACKLOG.md`: what is being released and in which phase.
- `DECISIONS.md`: D-178 and D-194, plus any later ruling that changes this flow.
- `OPEN_ITEMS.md`: current open items that affect release or deploy.
- `ACCEPTED-LIMITS.md`: build reproducibility and image-tag retention limits.
