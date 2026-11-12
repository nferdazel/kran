# KRAN - Operations manual

This is the operational reference for a KRAN deployment: how to deploy, migrate, back up,
restore, close the books, run the CLI, rotate keys, provision a pilot, and work on the dev
database and web client. It replaces the 15 separate runbooks. Where a command is
safety-critical it is reproduced exactly, not paraphrased.

Nothing here is a product claim. The product rules live in `spec/kran-prd-techspec.md`;
accepted weaknesses live in `ACCEPTED-LIMITS.md`; the engineering security baseline lives in
`SECURITY.md`.

---

## 0. Conventions

### 0.1 Evidence classes

Operators need to know whether a procedure has actually been run on the server. Every
section states one of:

| Marker | Meaning |
|---|---|
| **EXERCISED** | A recorded production run exists, with a date. |
| **PARTIALLY EXERCISED** | One part of the procedure has a recorded production run; the remainder does not, and the section names which is which. |
| **UNVERIFIED ON SERVER** | The procedure exists in the repo and has been reviewed, but no recorded production execution exists. Treat the first run as a drill with a backup in hand. |
| **BLOCKED** | The procedure must not be run in the current state; the reason is given. |

Two stale claims exist in the old material and are not repeated here. Several `ops/scripts/*`
headers still say `BELUM PERNAH DIJALANKAN DI SERVER` although production deploys have been
recorded since 19 Oct 2026 (audit `BE-ISO-16`). Conversely, some runbook text describes a
drill whose log does not exist. This document states the evidence class per procedure and does
not infer one from a header comment.

### 0.2 Variables

Paths and identifiers used throughout. Values marked "server" come from the host environment
file, never from the repository.

| Variable | Default or source | Meaning |
|---|---|---|
| `APP_DIR` | `/srv/qouver/apps/kran` | Application root on the host (server). |
| `MONO_DIR` | `$APP_DIR/monorepo` | Checked-out repository; migration files are read relative to it. |
| `BIN` | `$APP_DIR/bin/kran-api` | Host binary used by `ctl` and by deploy gates. |
| `ENV_FILE` | `$APP_DIR/env/kran-prod.env` | Runtime environment, mode 600 (server). |
| `MIGRATE_ENV` | `$APP_DIR/env/kran-migrate.env` | Owner-role URL used only by migrate/seed (server). |
| `HOST_ENV` | `$APP_DIR/env/kran-host.env` | Loopback DB URL for host-run `ctl` units (server). |
| `KEK_FILE` | `/srv/qouver/apps/kran/env/kran-kek.key` | Field-encryption key file, mode 600 (server). |
| `HEALTH_URL` | `http://127.0.0.1:8095/readyz` | Readiness endpoint used by the deploy gate. |
| `UNIT_DIR` | `$HOME/.config/containers/systemd` | Quadlet unit directory (user systemd). |
| `PG_CONTAINER` | `qouver-postgres` | Postgres container on the host. |
| `PG_SUPERUSER` | `qouver` | Postgres superuser role on the host. |
| `KRAN_DATABASE_URL` | `$ENV_FILE` | Runtime DB URL; consumed by API, worker and `ctl`. |
| `<run-id>` | `daycloser-status` output | UUID of a day-close run. |
| `<uuid>` | same as `<run-id>` | Shorthand used in the verbatim `daycloser-*` commands. |
| `<tgl>` | `daycloser-status` output | Shorthand for `<business-date>` in the verbatim close commands. |
| `<name>`, `<role>`, `<person>` | operator roster and role catalogue | Account name, role code, and the person being offboarded. |
| `<amount>` | owner-approved pilot figure | Money amount for `post-opening-balance` or the vault row. |
| `<business-date>` | `daycloser-status` output | `YYYY-MM-DD` of the current book date. |
| `<branch-uuid>` | `GET /api/v1/branches` or the pilot record | Branch identifier. |
| `<username>` | operator roster | Account name, one per person. |

No secret value is printed by any procedure below. Where a password is generated, it is
written to a mode-600 file or read from stdin; it is never passed as a command argument.

### 0.3 Exit codes

The binary and the ops wrappers share one vocabulary. Scripts branch on these codes, so do not
"tidy" them without updating the callers.

| Code | Meaning |
|---|---|
| 0 | Success. |
| 1 | Ran, but the result is bad (data error, unhealthy chain, failed close). |
| 2 | Misuse or configuration (bad argument, missing `KRAN_DATABASE_URL`). |
| 3 | Recognised but refused in this state (not a business day, expand migrations pending, no rollback pair). |

### 0.4 Scripts

| Path | Role |
|---|---|
| `ops/scripts/deploy-vps.sh` | Webhook-driven deploy: ref guard, lock, CI gate, freeze gate, dump, build, migrate, swap, health gate, rollback. |
| `ops/scripts/rollback.sh` | Manual rollback to the previous image, web build and units. |
| `ops/scripts/backup-postgres.sh` | Daily/weekly/monthly dumps, globals, audit anchor copy, retention. |
| `ops/scripts/backup-pre-deploy.sh` | Pre-migration and pre-contract dump, verified with `pg_restore --list`. |
| `ops/scripts/migrate.sh` | Thin wrapper over `--role=migrate`; enforces `--yes` on destructive modes. |
| `ops/scripts/smoke.sh` | `/healthz`, `/readyz`, version against `.deployed_rev`. |
| `ops/scripts/kran-alert.sh` | Readiness and dead-outbox alert, run by `kran-alert.timer`. |
| `ops/scripts/audit-consistency.sh` | Compares script checksums on the host with the repo. |
| `ops/systemd/*.container` | Quadlet units for API and worker. |
| `ops/systemd/kran-dayclose.{service,timer}` | Day-close scheduler (host binary). |
| `ops/systemd/kran-audit-anchor.{service,timer}` | Daily audit head anchor. |
| `ops/systemd/kran-alert.{service,timer}` | Alert probe every two minutes. |
| `ops/migrations/contract-auto.txt` | Contract migration ids the deploy may apply automatically. |

---

## 1. Deploy and rollback

### 1.1 What a push to `main` does

A push to `main` is a production deploy. The webhook calls `ops/scripts/deploy-vps.sh` with
`repository.name` and `ref` from the HMAC-verified payload. The script runs, in order:

1. **Ref guard**: anything other than `refs/heads/main` exits 0 without side effects. An empty
   `ref` is rejected, not treated as "no guard".
2. **Lock**: `flock` on a lock file. A second deploy waits (default 900 s) instead of
   interleaving.
3. **Sync**: `git fetch origin main` and `git reset --hard origin/main`.
4. **CI gate**: waits for the four required check-runs on that SHA (see 1.2). A missing,
   neutral, skipped or timed-out check counts as failure.
5. **Freeze gate**: `kran-api --role=ctl daycloser-status` against the host DB. Any non-zero
   exit holds the deploy (see section 4).
6. **Change detection**: a deploy whose diff does not touch code skips the rebuild; a docs-only
   push does not rebuild the image.
7. **Pre-migration dump**: `backup-pre-deploy.sh` runs and must pass. Without a usable dump the
   deploy stops; there is no "continue without backup".
8. **Build**: image `localhost/kran-api:local` is built; the old tag is moved to `:prev` first,
   so exactly one rollback image exists.
9. **Migration gate**: `--role=migrate --check`, then `--up`, then the contract step described
   in section 2.
10. **Swap and restart**: web directory swap, `sync_units` copies `ops/systemd/*.container` and
    keeps `.prev` copies, then `systemctl --user restart kran-api` and `kran-worker`.
11. **Health gate**: polls `/readyz` for 60 s. On failure the script restores the previous
    image, web directory and units (`restore_units`), restarts, and exits non-zero.
12. **Record**: `.deployed_rev`, `releases.txt`, `deploy.log`.

The web and API are served from one origin: Caddy serves the SPA from `$APP_DIR/web` and
proxies `/api/*` to `127.0.0.1:8095`. There is no `/metrics` endpoint today; the example
separate-API Caddy block refuses `/metrics` (403).

### 1.2 CI gate contract

`deploy-vps.sh` matches check-run names against `CI_EXPECTED`. These names are a contract; a
rename in `.github/workflows/ci.yml` must land in the same commit as the `CI_EXPECTED` change,
otherwise the gate waits 30 minutes and then fails closed:

```
Nim (check + unit/property test)
DB (integrasi, Postgres 18)
Web (svelte-check + axe + Playwright)
Security (gitleaks)
```

Rules that the workflows themselves enforce:

- Runner is pinned to `ubuntu-24.04`; `timeout-minutes: 15` is a contract, not a budget. A job
  that needs more is split, not extended.
- `db-tests` runs integration scope only against `postgres:18`; the database name must end in
  `_test` or `_dev` because dev seeding is fail-closed elsewhere. Unit and property tests run
  in the Nim job.
- `traceability` reads `compliance/register.yaml` and fails when an `active` requirement has no
  control, no test file, or no matching `test "<name>"` in that file.
- `secret-scan` (weekly, full history) is separate from the per-push gitleaks job and is not a
  deploy gate.
- `ci.yml` also has `workflow_dispatch`. It exists because a rewritten and force-pushed
  repository produced no run at all, which blocked every deploy for 30 minutes; the manual run
  creates the same check names.

Gate variables on the server:

| Variable | Default | Meaning |
|---|---|---|
| `KRAN_GITHUB_REPO` | `nferdazel/kran` | Repository whose check-runs are read. |
| `KRAN_GITHUB_TOKEN` | unset | Optional read-only token; raises the API rate limit. |
| `KRAN_CI_WAIT_SECONDS` | `1800` | Maximum wait for CI. |
| `KRAN_SKIP_CI_GATE` | `0` | Emergency only; logged as `WARN`. |
| `KRAN_DEPLOY_LOCK_WAIT` | `900` | Wait for a concurrent deploy before failing. |
| `KRAN_HEALTH_GATE_SECONDS` | `60` | Total health-gate budget. |
| `KRAN_FORCE_DEPLOY` | `0` | Deploy the same revision again; deliberate use only. |

### 1.3 Manual deploy drill

**UNVERIFIED ON SERVER.** Production deploys arrive through the webhook and are recorded, but
the manual drill (old T-013) was never completed. Run this only with a verified backup and a
known-good `:prev` image.

1. Confirm the environment file exists and is mode 600:
   `stat -c '%a %n' "$APP_DIR/env/kran-prod.env"`.
2. Confirm the previous image exists: `podman image exists localhost/kran-api:prev`.
3. Confirm no deploy is running: `flock -n "$APP_DIR/.deploy.lock" true` (the script uses this
   lock; the probe does not hold it).
4. Confirm the freeze gate is clear: `"$BIN" --role=ctl daycloser-status; echo $?` returns 0.
5. Run `ops/scripts/deploy-vps.sh kran refs/heads/main` from the host and read
   `$APP_DIR/logs/deploy.log`.
6. Confirm the result: `ops/scripts/smoke.sh` exits 0 and `.deployed_rev` matches the SHA you
   intended.

### 1.4 First installation and switchover (16 Oct 2026, executed)

**EXERCISED** as a one-time switchover. The order is deliberate: the domain is never down for
more than one Caddy block swap. Before this, KRAN ran on 8098 as a rehearsal.

```
# 1. Free 8095 from the old system. The old stack is managed by **quadlet systemd**, not bare
#    podman: `systemctl --user stop cbs-api` - a plain `podman stop` lets the unit restart it.
systemctl --user stop cbs-api
# 2. KRAN moves to its final port: KRAN_PORT=8095 in the environment, then restart the unit.
systemctl --user restart kran-api        # /readyz on 8095 must be 200 before continuing
# 3. Caddy block: replace `cbs.qouver.com` with block A of `ops/caddy/Caddyfile.kran.example`,
#    then (once only) set the SELinux label for the web root:
semanage fcontext -a -t httpd_sys_content_t "/srv/qouver/apps/kran/web(/.*)?"
restorecon -RF /srv/qouver/apps/kran/web
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
#    The CSP header deliberately carries only `frame-ancestors 'none'`: the full policy comes
#    from the hash-based `<meta>` (D-045). Do not add `script-src` to the header; two CSPs are
#    intersected.
# 4. Verify the domain, then stop the old web:
#    / and /login = 200, /api/v1/auth/session = 401 (KRAN-style error)
systemctl --user stop cbs-web
# 5. Do not let the old containers come back after reboot, but do not delete anything (D-043):
systemctl --user mask cbs-api cbs-web
systemctl --user enable kran-api kran-worker   # two roles, one image
#    The dayclose unit is installed separately and is not enabled on the server; see section 4.1.
```

Two corrections that apply to the block above, both learned on the server:

- `ops/caddy/Caddyfile.kran.example` states that this host runs Caddy with `admin off`, so
  `caddy reload` fails with "connection refused" to the admin socket. Use
  `systemctl restart caddy` (about one second of dropped connections). Validate first with
  `caddy validate --config /etc/caddy/Caddyfile`.
- `KRAN_PORT` is not read by the binary. The quadlet unit writes `--port=8095` explicitly. Do
  not add a `KRAN_PORT` variable and expect it to take effect.

Rollback of the switchover (all old files still exist):

```
systemctl --user unmask cbs-api cbs-web && systemctl --user start cbs-api cbs-web
# then restore the cbs.qouver.com block to `reverse_proxy 127.0.0.1:3005` + reload caddy
# the Caddyfile backup is at /etc/caddy/Caddyfile.bak.kran-<stamp>
```

Host facts that make this installation non-obvious (all found on the server, not in local
gates):

| Fact | Consequence |
|---|---|
| Rocky 9 host has no `libpq`; the binary is built on Debian | Deploy vendors `libpq.so.5`, `libldap-2.5.so.0`, `liblber-2.5.so.0`, `libsasl2.so.2` into `$APP_DIR/lib` (file name equals soname) and the unit uses `LD_LIBRARY_PATH`. Installing `libpq` on the host (root) would remove the need. |
| The binary does not read `KRAN_PORT` | The unit must pass `--port=8095 --address=0.0.0.0`; without it the app defaults to 8080, which is already used on this host. |
| `webhook.service` does not inherit the unit's `EnvironmentFile` | `deploy-vps.sh` loads `$APP_DIR/env/kran-prod.env` itself; otherwise push deploys fail on an empty `KRAN_DATABASE_URL`. |
| The web directory is replaced on every deploy (`mv web.new web`) | The new directory inherits the parent's SELinux label (`var_t`) and Caddy answers 403/404. `deploy-vps.sh` runs `restorecon -RF "$APP_DIR/web"`; the `semanage fcontext` rule above must exist once, or `restorecon` restores `var_t`. |
| The old stack is quadlet-managed | `podman stop` is not enough; use `systemctl --user stop cbs-*` and `mask` so it does not return after reboot. |
| A same-named native unit hides the quadlet unit | Deploy refuses to run while `~/.config/systemd/user/kran-api.service` exists. On 19 Oct 2026 the first post-cutover deploy restarted the old binary and the health gate read that same old binary: "success" with no change. After removing or renaming the native unit, run `systemctl --user daemon-reload` once. `is-enabled` = `generated` is normal for quadlet. |

From-scratch install (summary): create the owner role and database, copy the environment file,
install the units, run `login` as root once for `semanage fcontext`, then deploy. The
`pgcrypto` and `btree_gist` extensions are created by migration and the bootstrap runner; no
manual DB step is needed.

### 1.5 Rollback

**UNVERIFIED ON SERVER.** `ops/scripts/rollback.sh` exists and the automatic rollback path is
wired into the deploy, but no production rollback (manual or automatic) is recorded. Treat the
first rollback as a drill.

```
ops/scripts/rollback.sh
```

What it does, in order:

1. Refuses to run if `kran-api.container` is absent (not a quadlet host) or if a native
   `kran-api.service`/`kran-worker.service` still exists. Either condition would make
   `systemctl restart` run a different binary than the one being rolled back.
2. Retags `localhost/kran-api:prev` as `:local`.
3. Restores `bin/kran-api.prev` (the gate binary) if present; otherwise warns and leaves it.
4. Restores `web.prev` and the `.prev` unit files written by `sync_units`.
5. Reloads systemd, restarts API and worker, and polls `/readyz` for 30 s. A failed poll exits
   non-zero; it does not report success.

Limits, stated plainly:

- Rollback restores the **image and web build**, not the schema. Migrations are expand-only,
  so an older binary normally runs on the newer schema. A contract applied before the failure
  stays applied; the old binary then runs against a post-contract schema, and product versions
  written during that window may need manual approval after recovery.
- Rollback does **not** touch the database. If data is wrong, rollback is not the tool; use the
  documented correction path (reversing journal, cancel/re-run close).
- There is exactly one previous image. Two consecutive bad deploys consume it.

---

## 2. Migrations

**EXERCISED for the routine path.** `--check` and `--up` run on every deploy. `--contract` has
been applied automatically from the allowlist. `--down` has never been run against real data
and remains **UNVERIFIED ON SERVER**.

Implementation: `tools/dbtools/lib.nim`; the CLI role is `--role=migrate`; the wrapper is
`ops/scripts/migrate.sh`.

### 2.1 File shape

`modules/<module>/migrations/<NNNN>_<slug>.sql`, ordered by `(NNNN, module, name)`. Each file
runs once, is idempotent by recording, and must not change after it is applied.

| Marker or suffix | Meaning |
|---|---|
| (none) | Expand: additive, safe while the old binary is still serving. |
| `-- dbtools:destructive <reason>` | Contains destructive DDL. `--up` refuses it (exit 3); only `--contract` runs it. The reason is mandatory. |
| `-- dbtools:contract <reason>` | Two-phase file. `--up` skips it; `--contract` runs it only after all expand migrations are applied. If the file is also destructive, both markers are required. |
| `<NNNN>_<slug>.down.sql` | Rollback pair. It is not a migration and is not ordered. It must not contain `BEGIN`/`COMMIT`/`ROLLBACK` and must not be empty. |

### 2.2 Commands

| Command | Effect |
|---|---|
| `ops/scripts/migrate.sh --check` | Read-only. Exit 1 when a pending expand migration exists or an applied file's checksum changed. Pending contract files are **not** counted here. |
| `ops/scripts/migrate.sh --up` | Apply pending expand migrations. |
| `ops/scripts/migrate.sh --contract --yes` | Apply contract-marked files. Refuses while expand is pending. |
| `ops/scripts/migrate.sh --down --yes N` | Revert the last N applied migrations, newest first. Requires the reviewed `.down.sql` pair. |
| `ops/scripts/migrate.sh --seed` | Apply `packs/*/generated/*.sql` (definitions and base values), idempotent, no dev/test seed. |

Exit codes are the binary's: 1 bad data, 2 misuse, 3 refused in this state.

### 2.3 Contract allowlist

Contract is manual and opt-in by principle. The one exception: ids listed in
`ops/migrations/contract-auto.txt` are applied by the deploy and re-checked on **every**
deploy, because the schema can lag after a restore or a manual `--down`. The allowlisted
automatic path is **EXERCISED**; a manual `migrate.sh --contract --yes` has no recorded
production run and is **UNVERIFIED ON SERVER**.

- A pending contract outside the allowlist stops the deploy (fail-closed); an operator runs it
  manually in a maintenance window.
- After the contract step the script re-runs `--check` and refuses to continue if any contract
  is still pending.
- If a deploy has no dump yet (for example a contract becomes pending on a deploy that changed
  no code), the script takes an extra pre-contract dump. If `backup-pre-deploy.sh` is
  unavailable, the deploy stops: a contract is never applied without a rollback net.
- If you cancel a contract with `--down` (for example the old binary is still live), the next
  push will reapply it while its id stays in the allowlist. Remove the id through a PR before
  pushing the fix, or revert that line.

Order of operations for a two-phase change:

1. Release the expand migration, deploy normally; old and new binaries coexist.
2. After the release is stable and no process uses the old shape, add the contract file through
   a reviewed PR. Either run `migrate.sh --contract --yes` in a maintenance window, or add the
   id to the allowlist so the next deploy applies it (make sure the new binary is live first).
3. If the contract was wrong: `migrate.sh --down --yes 1`, only when the reviewed pair exists.

### 2.4 Rollback limits

- Only the last N applied migrations, in order. There is no revert-by-name.
- The pair must exist and must have been reviewed before the incident. Writing a `.down.sql`
  on the server during an incident is not the procedure; without a pair the command is refused
  with exit 3 and no side effect.
- The `platform.schema_migration` row is deleted after a successful revert, so `--check` and
  `status` describe the database rather than an intention. The next `--up` reapplies it.
- `--down` knows nothing about data. Reverting a migration the application has used can drop a
  column that is still read. The pre-deploy dump remains the primary recovery path.
- There is no automatic revert when a deploy fails; deploy only calls `--check`/`--up`.
- There is no "applied then reverted" history in the database; the trail is the operator log and
  version control of the pair.

### 2.5 Refusals you will see

| Message | Meaning |
|---|---|
| `migrasi expand masih tertunda (...)` | Run `--up` first; contract always follows expand. |
| `tidak ada berkas pasangan ...` | The rollback pair was never written or merged. |
| `diminta membatalkan N migrasi, tetapi hanya M yang diterapkan` | N is wrong. Count the applied migrations first. |
| `DDL merusak ditolak oleh mode expand-only` | The file lacks the destructive marker. That is the guard working. |
| `berkas pasangan rollback tidak boleh memuat 'COMMIT'` | The pair manages no transaction; the runner does. |

### 2.6 Seed and parameter values

`deploy-vps.sh` runs `kran-api --role=migrate --seed` **after** swapping the binary and
**before** restarting the unit. Manual equivalent on the host:

```bash
# on the server, from the repo root (packs/ is here); the host binary needs the vendored libpq
cd /srv/qouver/apps/kran/monorepo
# the prod env uses the podman service name (`@qouver-postgres:`); the host cannot resolve it
KRAN_DATABASE_URL="$(grep '^KRAN_DATABASE_URL=' /srv/qouver/apps/kran/env/kran-prod.env | cut -d= -f2-)"
KRAN_DATABASE_URL="${KRAN_DATABASE_URL//@qouver-postgres:/@127.0.0.1:}"
KRAN_DATABASE_URL="$KRAN_DATABASE_URL" \
LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=migrate --root=. --seed

# or, if LD_LIBRARY_PATH is already set in the shell: `ops/scripts/migrate.sh --seed` from the repo root
```

`--seed` exit 1 means the database rejected the SQL (for example an EXCLUDE conflict with a
non-seed ACTIVE value); exit 3 means no seed files were found (wrong root or missing `packs/`).
Either cancels the deploy. Do not restart the worker with incomplete parameters; it exits 2.
Base values tagged `NEEDS-COMPLIANCE-REVIEW` are not compliance evidence, and values already
changed by an operator are not overwritten (`DO NOTHING`).

---

## 3. Backup and restore

### 3.1 Backups

`ops/scripts/backup-postgres.sh` runs daily at 02:00 host time (timer lives outside the repo;
the script is self-contained). It:

- dumps every database except `*_verify*`, `*_test*`, `*_dev*` and `postgres`, using
  `pg_dump -Fc`;
- rejects a dump under 1000 bytes and rejects a dump that `pg_restore --list` cannot read;
- copies the dump to `weekly/` on Sunday and `monthly/` on the first of the month;
- dumps globals (`pg_dumpall --globals-only`);
- copies `/srv/qouver/apps/kran/logs/audit-anchor.log` to `$KRAN_BACKUP_ROOT/anchor/`;
- applies retention: daily 7 days, weekly 28 days, monthly 84 days.

`ops/scripts/backup-pre-deploy.sh` writes one dump per deploy that changes migrations, plus one
per contract, into `$KRAN_BACKUP_ROOT/pre-deploy/`, verifies it by listing its contents and
checking that a non-empty database's dump contains at least one table definition, and keeps the
newest 10 (`KRAN_PREDEPLOY_KEEP`). The new dump is verified before older ones are deleted, so a
failure never shrinks the available backups.

Paths are under `$KRAN_BACKUP_ROOT` (default `/srv/qouver/backups`). A backup file is written on
the host; it is not encrypted and it is not copied off the host. That is the accepted
single-host limit, recorded in `ACCEPTED-LIMITS.md`; do not describe these backups as
"encrypted" or "off-site".

### 3.2 Restore drill (monthly)

**EXERCISED once, 21 Oct 2026.** The drill restores a daily dump into a separate database
without touching production. Schedule it monthly after the 02:00 backup. For the current
database size the drill takes under two minutes.

Safety rules:

- The drill database name **must** contain `_verify`, because the backup script excludes that
  pattern. The drill is therefore not itself backed up.
- Never restore into `kran`. Never edit or delete a dump.
- Restore **without** `--no-owner` on the same cluster: the roles (`kran_app`, `qouver`) already
  exist and the dump carries `ALTER ... OWNER TO`. The 21 Oct 2026 drill proved that
  `--no-owner` makes the schema owned by `qouver`, after which `kran_app` gets
  `permission denied for schema platform` during `ctl verify-audit`. That is a misleading drill
  result, not a bad dump.
- Never print `KRAN_DATABASE_URL`; it contains a password.

```bash
# 1. Pick the newest dump
ls -1t /srv/qouver/backups/postgres/daily/kran_*.dump | head -1

# 2. Create the drill database (the _verify pattern is excluded from backups)
DRILL=kran_verify_restore_$(date +%Y%m%d)
podman exec qouver-postgres psql -U qouver -d postgres -tAc "DROP DATABASE IF EXISTS $DRILL"
podman exec qouver-postgres psql -U qouver -d postgres -tAc "CREATE DATABASE $DRILL"

# 3. Restore
DUMP=/srv/qouver/backups/postgres/daily/kran_YYYY-MM-DD_02-00-01.dump
time podman exec -i qouver-postgres pg_restore -U qouver -d "$DRILL" < "$DUMP"
# expected: exit 0, no stderr lines

# 4. Compare counts with production
for t in platform.schema_migration ledger.journal platform.audit_log party.party platform.outbox; do
  echo -n "$t: restore="
  podman exec qouver-postgres psql -U qouver -d "$DRILL" -tAc "select count(*) from $t" | tr -d '\n'
  echo -n " produksi="
  podman exec qouver-postgres psql -U qouver -d kran -tAc "select count(*) from $t"
done

# 5. Verify the audit chain in the restored DB (without printing the URL)
URL=$(grep '^KRAN_DATABASE_URL=' /srv/qouver/apps/kran/env/kran-prod.env | cut -d= -f2-)
URL=${URL/@qouver-postgres:/@127.0.0.1:}; URL=${URL%/*}/$DRILL
KRAN_DATABASE_URL="$URL" LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=ctl verify-audit
# expected: "rantai audit utuh (N entri)", exit 0

# 6. Clean up
podman exec qouver-postgres psql -U qouver -d postgres -tAc "DROP DATABASE $DRILL"
podman exec qouver-postgres psql -U qouver -d postgres -tAc \
  "select count(*) from pg_database where datname='$DRILL'"   # harapan: 0
```

Set `DUMP` to the file printed by step 1; the `YYYY-MM-DD` placeholder is not a literal.

Evidence from the 21 Oct 2026 drill: dump `kran_2026-10-21_02-00-01.dump` (113 KB), drill DB
`kran_verify_restore_20261021`, `pg_restore` exit 0 with zero stderr lines and one second of
runtime, schema owned by `kran_app`, row counts equal to production (`schema_migration` 35,
`journal` 0, `audit_log` 5, `party` 0, `outbox` 0), 32 tables and 3 audit triggers, `verify-audit`
reported an intact chain of 5 entries, and the drill DB was dropped.

If a step fails:

- `pg_restore` non-zero: keep stderr, do not drop the drill DB before recording the failure,
  check `df -h /srv`, the Postgres image version, and whether the dump is truncated
  (`pg_restore -l`).
- `verify-audit` fails: record the message and do not call the dump good. Escalate to the owner.
- Record date, dump, duration, counts and exit codes as the drill evidence. The retained limits
  remain: no PITR, no off-host copy, no encryption at rest. The P7 restore-drill task
  (`ops/scripts/restore-drill.sh`) does not exist yet; until it does, this section is the
  procedure.

---

## 4. Day-close operations

The `daycloser` framework runs every scheduled institution task. There is no other batch or
cron in any module. Levels are EOD (daily), EOM (last working day of the month) and EOY (year
end). Closing can be triggered three ways, all through the same code path:

| Trigger | When it is used |
|---|---|
| `ctl daycloser-run` | Operator prepares or repeats a close; the only path for `--bootstrap`. |
| `POST /api/v1/dayclose/run` (plus resume/pause/cancel) | Button on `/app/dayclose`. |
| `ctl daycloser-auto` by systemd timer | Automatic daily close at the parameterised time. |

Run every command from the repository root (or with `--root=<dir>`), with a
`KRAN_DATABASE_URL` that points at the right database. On the server, wrap it in the API
container:

```bash
podman exec kran-api /usr/local/bin/kran-api --role=ctl daycloser-status
```

### 4.1 Daily scheduler

The scheduler reads `daycloser.auto.enabled` (default **false**),
`daycloser.auto.run_at` (local `HH:MM`), and `daycloser.auto.utc_offset_minutes` (WIB = `420`).
The unit and timer are mirrored in the repo. `deploy-vps.sh` does **not** install them.

```bash
# Try one manual run (safe: it does nothing when the time has not arrived).
podman exec kran-api /usr/local/bin/kran-api --role=ctl daycloser-auto; echo $?

# Install on the server (once):
scp ops/systemd/kran-dayclose.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now kran-dayclose.timer
systemctl --user list-timers kran-dayclose.timer
```

The unit uses the **host binary** (`/srv/qouver/apps/kran/bin/kran-api`), not `podman exec`, so
it does not depend on podman at close time. Because the host binary cannot resolve the podman
service name, the unit loads two files: `kran-prod.env` then `kran-host.env` (same credentials,
loopback URL, mode 600, outside the repo).

**Status:** installed on the server since 2 Nov 2026, with `daycloser.auto.enabled` still
`false`. Running with the switch on is **UNVERIFIED ON SERVER**; enable it through the
maker-checker parameter path, not by editing the unit.

Exit codes of `daycloser-auto`: `0` nothing due or close completed, `1` close ran but ended
`BLOCKED`/`FAILED`/`PAUSED` (inspect `daycloser-status`, then resume or cancel), `2` invalid
parameter, `3` refused in this state (no business date yet, or not a working day). The log is
`$APP_DIR/logs/dayclose-auto.log`.

If the time is wrong, check `daycloser.auto.utc_offset_minutes`. The repo has no timezone
table; the offset in minutes is what is used, and an institution with DST must adjust it.

The scheduler never closes a date that has not started. A successful close advances the book
date to the next working day (`rollOverBusinessDate`), and the timer fires every few minutes,
so without the guard every tick would close another date until midnight. `daycloser-auto`
therefore computes the **local** date (`UTC + utc_offset_minutes`) and exits 0 when the book
date is already past the local date:

```
tanggal buku 2026-11-03 sudah melewati tanggal lokal 2026-11-02; penjadwal tidak menutup tanggal yang belum berjalan
```

Consequence: one date per local day. If the book falls several days behind (for example after
a host outage), the scheduler closes one date per tick while the local clock is still past
`run_at`. That is intentional; `daycloser-status` shows progress.

### 4.2 States

| `daycloser-status` | Meaning | Action |
|---|---|---|
| `0`, `tanggal buku: <date> OPEN`, no active run | Ready | Deploy allowed; close may start |
| `1`, book date `CLOSING` | Close not finished | Deploy is held; `daycloser-resume` or `daycloser-cancel` |
| `1`, active run `PAUSED`/`RUNNING` | Running or stopped mid-way | Note the run id; resume or cancel |
| `2` | DB or configuration unreadable | Fix connectivity; the deploy gate also holds |

`deploy-vps.sh` calls `daycloser-status`. A non-zero exit holds the deploy. Do not change the
exit codes without updating the script.

### 4.3 First close (bootstrap)

Once only, when `platform.business_date` has no row:

```bash
kran-api --role=ctl daycloser-run --business-date=2026-10-26 --bootstrap
```

`--bootstrap` means "this is the first book date". Without it the command is refused (exit 3).
After that day closes, the book date becomes the next working day (`OPEN`) and `--bootstrap` is
not used again.

### 4.4 Daily close

```bash
kran-api --role=ctl daycloser-status                       # confirm OPEN and no active run
kran-api --role=ctl daycloser-run --business-date=<tgl>    # tgl = current book date
```

The flow (all except the tasks runs in one transaction at the seal step): `PRECHECK` -> freeze
(`CLOSING`) -> process/report tasks -> `POSTCHECK` -> seal (run `COMPLETED`, date `CLOSED`,
rollover to the next working day, event `BusinessDateOpened`).

Registered process tasks: idempotency sweep, time-deposit interest accrual, maturity/ARO,
dormant detection, and the daily balance snapshot (which writes and proves the balance cache).
On the last working day of a month (EOM level) the GL period close runs in the post-close
phase, after the snapshot and gates, because a period close cannot be undone.

The period closed is the one that contains the book date and ends in the same month. Example:
period 1 to 31 Oct 2026 is closed on the 30 Oct 2026 close (last working day). If the
institution uses annual periods, the monthly close reports `NOT_DUE`. If no period contains
that date at all, the run stops with `DAY-324` and the period must be created through the API
first.

**EOY is not implemented.** There is no registered year-end close task and no SHU calculation;
the calendar has an EOY level but no task runs it (audit blocker B8). Do not treat a normal EOM
close, or a manually created annual period, as a year-end close: the RAT statements, SHU
allocation and the archive of the RAT decision do not exist yet. They belong to the coop
product phase (P4) and the reporting phase (P5). Attempting a year end through the monthly path
is **BLOCKED** until both land.

While `CLOSING`, every HTTP write is rejected with `409` (`reason: business_date_closing`)
except login, logout and password change. That is deliberate: a transaction slipping in during
the close makes the post-close gate stale.

If the institution serves 24 hours, `daycloser.txn_policy_during_close = ALLOW` must be set
**before** the close starts: the maker-checker flow also goes through HTTP and is blocked
during `CLOSING`. The race risk is the institution's; it has not been tested against real
closing tasks (see `ACCEPTED-LIMITS.md`).

### 4.5 Preview before closing (dry-run `SIMULATION`)

```bash
kran-api --role=ctl daycloser-run --business-date=<tgl> --mode=SIMULATION; echo $?
```

It prints the plan (level, tasks, chunks, `"writes": false`) without writing anything: no run
row, journal, balance, event, or book-date change. State refusals are still checked (working
day, book date, duplicate run) so the preview does not promise a run that would be refused.

What it does not prove: whether tasks will succeed when they write. `DAY-331` (missing accrual
binding), `DAY-343` (deposit without a destination account) and `DAY-344` (ambiguous rule) only
appear on a real run. This is a plan-level dry run, not execution in a rolled-back
transaction. **UNVERIFIED ON SERVER** for the preview path specifically.

### 4.6 Blocking gates (run `BLOCKED`)

A run stops as `BLOCKED` (not `FAILED`) when a **gate** fails. The command output names the
task and code; the counts are in `daycloser.task.metrics`:

```sql
SELECT t.task_id, t.state, t.error->>'code' AS code, t.metrics
  FROM daycloser.task t JOIN daycloser.run r USING (run_id)
 WHERE r.business_date = DATE '2026-10-28'
 ORDER BY t.task_id;
```

| Code | Meaning | Action |
|---|---|---|
| `DAY-301` | A teller session is still OPEN | Close the session (with a cash count) in the application. |
| `DAY-302` | A session closed with unbalanced cash | Resolve the difference first. |
| `DAY-303` | A vault top-up request is undecided | Ask the checker to decide. |
| `DAY-304` | A suspense account has a balance | Post the correction journal **after** cancelling this run. |
| `DAY-305` | Trial balance is unbalanced | Stop. Investigate the journals; this indicates data damage. |
| `DAY-306/307` | Subledger balances unreadable / an account has no balance row | Run `ctl reconcile-deposits` and investigate. |
| `DAY-308` | Subledger total differs from GL | Investigate the difference; never "tidy" it with an unexplained journal. |
| `DAY-309` | Post-close ran while the date was not `CLOSING` (or the freeze time is unreadable) | Stop. Check `platform.business_date`; this indicates an inconsistent state. |
| `DAY-310` | A journal was posted after the freeze | Cancel the run, inspect that journal, close again. Journals created by the closing tasks themselves (accrual/maturity, `journal.daycloser_run_id` set) are excluded; if this code appears, a business path slipped through before the freeze. |
| `DAY-311` | An account in a gate parameter is unknown or inactive | Fix the parameter (`daycloser.precheck.suspense_accounts`, `daycloser.postcheck.subledger_gl_accounts`) through maker-checker. |
| `DAY-312` | A gate parameter list is empty | Fill it; an empty list silently disables the gate. |
| `DAY-320` | Balance snapshot failed to write (database error) | Read the error; the task retries automatically and the run stops if it keeps failing. |
| `DAY-321` | Balance snapshot differs from the journals | Stop. Compare the `source=ledger` report with `balance_snapshot` for that date. The rebuild was rolled back, so the old cache is intact. `metrics.accountDiff` names the differing accounts. |
| `DAY-323` | GL period unreadable | Database error; retry `daycloser-resume` once the DB is healthy. |
| `DAY-325` | Period close failed (database error) | The period stays OPEN; read the log, then `daycloser-resume`. |
| `DAY-327` | Period status changed during the close | Inspect `ledger.period`; if another operator already closed it, resume reports `alreadyClosed`. |
| `DAY-322` | Trial balance unbalanced at snapshot time | Indicates data damage; do not close the books. |
| `DAY-324` | End of month but no GL period ends today | Create the GL period first, then run the close again. |
| `DAY-326` | A cash session is OPEN inside the period being closed | Cancel the run first (`daycloser-cancel`); while `CLOSING` all HTTP writes are refused, so the session cannot be closed in the app. Once the date is `OPEN` again, close the session and rerun. |
| `DAY-328` | A previous period is still OPEN | Close the previous period first (in order); closing a newer month leaves the older month without a basis. |
| `DAY-330` | The accrual account list could not be read | Database error; the task retries automatically and the run stops if it keeps failing. |
| `DAY-331` | The account's product version has no valid accrual attributes (rate/basis/scale) | Complete the product version binding through maker-checker, then `daycloser-resume`. Do not accrue an account without a clear interest agreement. |
| `DAY-332` | Account date or book date invalid | Data damage; inspect `deposit.account.opened_on` and `platform.business_date`. |
| `DAY-333` | The accrual journal could not be created | Check the `InterestAccrued` rule and the period status of the book date. |
| `DAY-334` | Duplicate accrual for account plus date | The task should be idempotent; investigate the second write (was the advisory lock bypassed?). |
| `DAY-335` | Cumulative interest decreased | Principal was reduced without an accrual correction; inspect that deposit's movements. |
| `DAY-336` | Interest value exceeds the numeric limit | Product principal/rate is implausible; inspect the binding. |
| `DAY-337` | Accrual row could not be saved | Database error; the task retries automatically. |
| `DAY-340` | The maturity account list could not be read | Database error; the task retries automatically. |
| `DAY-341` | A maturing time deposit has no `aro_instruction` | Data damage: the task does **not** guess ARO. Record the member's instruction (`NONE`/`PRINCIPAL`/`PRINCIPAL_AND_INTEREST`) through the official path, then `daycloser-resume`. |
| `DAY-342` | Account, maturity or book date invalid | Data damage; inspect `deposit.account.opened_on`, `maturity_date` and `platform.business_date`. |
| `DAY-343` | A maturing deposit has no valid savings account at the same branch | Operational prerequisite (same pattern as `DAY-301`): open a destination savings account for that member, then `daycloser-resume`. The error names the deposit account number. A `DORMANT` account **is** valid and is reactivated by the dormant task in the same close; POKOK/WAJIB savings are never used. |
| `DAY-344` | The maturity journal could not be created | Check the `DepositMatured`/`InterestPosted`/`InterestCapitalized` rules. A closed period is **not** this code: a period error from the ledger trigger appears as `DAY-345` (retryable). |
| `DAY-345` | Maturity transfer failed to save, or the balance changed mid-process | Database error or concurrent movement; the task retries. If it repeats, inspect transactions touching that account on that date. |
| `DAY-346` | Unknown `aro_instruction` | Data damage (the DB CHECK should reject it); fix the value, do not treat it as `NONE`. |
| `DAY-347` | *(no longer emitted)* invalid rollover tenor | Old code; the tenor now comes from product attributes (`DAY-354` if missing). |
| `DAY-348` | A maturing account has no `deposit.account_balance` row | Balance cache lost: do not close the account (principal could vanish without a trace). Reconstruct the balance with `reconcile-deposits`, then `daycloser-resume`. |
| `DAY-349` | The new maturity date is already past (process late by more than one tenor) | Complete the rollover/payment manually through the official path, fix `maturity_date`, then resume. |
| `DAY-350` | The dormant account list could not be read | Database error; the task retries automatically. |
| `DAY-351` | `deposit.dormant.after_months` unreadable or not a whole month >= 1 | Fill the institution parameter (or fix its type) through maker-checker. The task does **not** guess a threshold, and because the dormant task is non-critical the run still ends `COMPLETED` with the task `FAILED`. Do **not** rely on `daycloser-resume` (a `COMPLETED` run cannot be resumed) and do not close the date again (`run_exists`): the dormant scan runs on the **next** close after the parameter is fixed. Inspect task state in `daycloser-status` or `/app/dayclose`. |
| `DAY-352` | Unknown account status while reading the dormant list | Data damage; fix `deposit.account.status` (the CHECK should reject foreign values). |
| `DAY-353` | Dormant status could not be saved | Database error; the task retries. No money moves, and the task is **non-critical**, so the close can complete while recording the failure. |
| `DAY-354` | The account's product version does not bind `product.savings.rollover_tenor_days`, or the value is not a whole number > 0 | Complete the product attribute on the version in use, then `daycloser-resume`. The task does **not** infer the tenor from `maturity_date - opened_on`. |

Subledger gate (`DAY-308`): `ledger.subledger_vs_gl` compares the total savings subledger
balance with the GL accounts that hold it. Liability accounts (`201`/`202`) come from
`daycloser.postcheck.subledger_gl_accounts`; the **equity** accounts that hold savings postings
(`301.1` principal, `301.2` obligatory) are **derived** from the active `DepositPosted` rule,
not from that parameter. A difference exactly equal to principal plus obligatory means the
equity accounts were not counted (a fixed bug class) or a posting went to an account the rule
does not use. Do not patch this by adding equity accounts to the parameter: that parameter is
for liability accounts only, and a parameter change cannot be applied retroactively to the date
being closed.

Runtime role grants: a refusal shaped like
`rencana chunk <name> gagal: DAY-38x ... permission denied for table ...` is **not** a data
problem. The runtime role (`kran_runtime`) lacks rights on a table created **after** the
schema-wide grant migration, because `GRANT ... ON ALL TABLES` only covers tables that existed
when it ran. The fix is a grant migration in the owning module, a release, and a deploy (the
migration gate applies it); then rerun the close. Do **not** patch this with `psql` on
production: a grant that exists only on one server disappears on restore into another
environment and leaves no trace in the repo.

The pre-close gate runs before the freeze, so its failure does not freeze the date: the
institution can keep serving, but that date cannot be closed twice (a `BLOCKED` run must be
resumed or cancelled). The post-close gate runs while the date is `CLOSING`, so all writes are
held until the run finishes.

`daycloser-resume` reruns **all** gates, including those that passed before, because the state
certified by the pre-close gate can change while a run is stopped. A resumed run can therefore
return `BLOCKED` with a different code; that is correct behaviour, not a failed resume.

Business-path journals created **after** the freeze for that date are rejected by `DAY-310` on
resume; journals owned by the closing run itself are distinguished by `journal.daycloser_run_id`.
The correct path is: cancel the run, fix the books, then run the close again for the same date.

### 4.7 Failed or interrupted close

`daycloser-run` exits **1** when the run ends `FAILED`/`BLOCKED`. The book date stays `CLOSING`,
which is what holds the deploy and transactions until the problem is resolved. The resume and
cancel paths below are **UNVERIFIED ON SERVER**: no production use is recorded.

1. Read the cause: the command names the task and code; `daycloser-status` shows the last run
   including the seal if it completed.
2. Fix the cause (wrong parameter, unregistered holiday, missing account).
3. Continue **without repeating successful chunks**:

   ```bash
   kran-api --role=ctl daycloser-resume --run=<uuid>
   ```

4. If the close cannot be completed now, cancel it:

   ```bash
   kran-api --role=ctl daycloser-cancel --run=<uuid>
   ```

   If no process holds the lock, the cancellation takes effect immediately: remaining tasks
   become `CANCELED`, the run is `CANCELED`, and the book date reopens (`CLOSING -> OPEN`). If
   a process is alive, the request is read at the next chunk boundary.

`CLOSED` is never reopened. A correction after close is a reversing journal on the current
day, not a reopened date.

A `CANCELED` run may be repeated for the same date:

```bash
kran-api --role=ctl daycloser-run --business-date=<tgl>
```

That is the only way to advance the books after a cancellation. The new run relies on task
idempotency (`imPerBusinessDate`), so chunks that succeeded in the old run do not post twice.

If `daycloser-cancel` answers "tanggal buku ... dibuka kembali (pemulihan pembatalan)", that is
the recovery path for an old `CANCELED` plus `CLOSING` state; run it once, then check
`daycloser-status` (must be 0).

### 4.8 Stuck run (`RUNNING` too long)

1. Check whether the process exists (container or `ps`). If the process is dead but the state is
   `RUNNING`, `daycloser-resume` returns `RUNNING` tasks/chunks to `PENDING` and continues.
2. If the process is alive but hung, `daycloser-cancel` writes `control = CANCEL` and the
   orchestrator stops at a chunk boundary. There is no per-task timeout (a recorded limit).

### 4.9 Evidence

```sql
SELECT run_id, business_date, state, summary_hash, started_at, finished_at
  FROM daycloser.run ORDER BY business_date DESC LIMIT 5;

SELECT action, business_date, resource_id FROM platform.audit_log
 WHERE action LIKE 'daycloser.%' ORDER BY seq DESC LIMIT 20;

SELECT event_type, payload FROM platform.outbox
 WHERE event_type = 'BusinessDateOpened' ORDER BY seq DESC LIMIT 5;
```

`summary_hash` covers the parameter snapshot plus task/chunk state and attempts; a `COMPLETED`
run without a seal is impossible (one transaction).

### 4.10 Deploy during a close

A deploy while `CLOSING` is refused by the gate (webhook exits 0, log shows `FREEZE`). Wait for
the close to finish, or cancel the run first. Never force it by editing DB state: the seal and
the audit no longer describe what happened.

---

## 5. Ops CLI and break-glass

### 5.1 CLI contract

One binary, four roles. Run from the repository root (or pass `--root=<dir>`), because
migrations are read relative to the root.

| Role | Command | Exit |
|---|---|---|
| `api` | `kran-api --role=api [--port=8080] [--address=127.0.0.1] [--version=<str>]` | Runs until SIGINT/SIGTERM, then 0 |
| `migrate` | `kran-api --role=migrate` or `--role=migrate --up` | 0 when finished (idempotent) |
| `migrate` | `kran-api --role=migrate --check` | 0 clean, 1 pending or drift |
| `ctl` | `kran-api --role=ctl verify-audit` | 0 chain intact, 1 broken entry |
| `ctl` | `kran-api --role=ctl outbox-status` | 0 (prints counts per status) |
| `ctl` | `kran-api --role=ctl daycloser-status` | 0 idle, 1 active run or `CLOSING`, 2 DB/config unreadable |
| `ctl` | `kran-api --role=ctl daycloser-run --business-date=<YYYY-MM-DD> [--bootstrap] [--mode=SIMULATION]` | 0 completed, 1 failed/blocked, 3 refused, 2 bad argument |
| `ctl` | `kran-api --role=ctl daycloser-resume --run=<uuid>` | 0 completed, 1 still failing, 3 ended or locked, 2 missing argument |
| `ctl` | `kran-api --role=ctl daycloser-pause --run=<uuid>` | 0 recorded (read at chunk boundary), 3 ended, 2 missing |
| `ctl` | `kran-api --role=ctl daycloser-cancel --run=<uuid>` | 0 cancelled (immediate when no live process; reopens a frozen book date), 3 ended, 2 missing |
| `ctl` | `kran-api --role=ctl bootstrap-admin --username=<name>` | 0 created, 3 an admin already exists, 2 missing `--username` |
| `ctl` | `kran-api --role=ctl reset-password --username=<name>` | 0 new password printed once, 1 write/CSPRNG failure, 2 missing, 3 no such user |
| `ctl` | `kran-api --role=ctl audit-anchor [--out=<file>]` | 0 anchor line printed (and appended), 1 write failure, 2 no DB |
| `ctl` | `kran-api --role=ctl reconcile-deposits [--branch=<uuid>]` | 0 all balance caches match, 1 difference found, 2 bad argument |
| `ctl` | `kran-api --role=ctl create-user --username=<name> --user-role=<role> [--branch=<uuid>] [--full-name=<name>]` | 0 created (password printed once), 3 refused, 2 missing, 1 write/CSPRNG failure |
| `ctl` | `kran-api --role=ctl assign-role --username=<name> --user-role=<role> [--branch=<uuid>]` | 0 granted, 3 refused/not found (role/scope/SoD), 2 missing, 1 write failure |
| `ctl` | `kran-api --role=ctl revoke-role --username=<name> --user-role=<role> [--branch=<uuid>]` | 0 revoked, 3 refused/not found (including last manager), 2 missing, 1 write failure |
| `ctl` | `kran-api --role=ctl disable-user --username=<name>` | 0 inactive plus sessions revoked, 3 not found/last manager, 2 missing, 1 write failure |
| `ctl` | `kran-api --role=ctl enable-user --username=<name>` | 0 inactive to active, 3 not found or not inactive, 2 missing, 1 write failure |
| `ctl` | `kran-api --role=ctl unlock-user --username=<name>` | 0 locked to active, 3 not found or not locked, 2 missing, 1 write failure |
| `ctl` | `kran-api --role=ctl create-branch --branch-code=<3 digits> --branch-name=<name>` | 0 registered, 3 invalid/used code, 2 missing |
| `ctl` | `kran-api --role=ctl post-opening-balance --username=<name> --branch=<uuid> --amount=<amount> --business-date=<YYYY-MM-DD>` | 0 posted (idempotent per branch), 3 refused, 2 bad argument, 1 DB rejected the journal |
| `ctl` | `kran-api --role=ctl help` | 0 |
| `worker` | `kran-api --role=worker` | Runs until stopped; 2 parameter/DB not ready (no restart), 1 transient DB error |
| none | Unknown command or bad argument | 2 (usage on stderr) |

`ctl` is mostly read-only. Commands that write: `bootstrap-admin`, `reset-password`,
`create-user`, `assign-role`, `revoke-role`, `disable-user`, `enable-user`, `unlock-user`,
`create-branch`, `post-opening-balance`, and `daycloser-run|resume|pause|cancel`
(`audit-anchor` only appends to a file). All of them write audit. None takes `--yes`, because
access and lifecycle recovery must work during an incident. Automated scripts call only the
read-only commands in this role; do not add write commands outside that list without a design
discussion.

`--role=migrate` uses the same implementation as `./task dbtools migrate`/`validate`
(`tools/dbtools/lib.nim`), so there is no second migration path with different results.

`ctl verify-audit` on the dev database can return **1** while the code is correct: the platform
integration test deliberately breaks the chain (disables the checking trigger, edits one row,
reenables it) to prove detection. Exit 1 on a dev DB is therefore not a signal of real damage.

### 5.2 Bootstrap the first admin

```
kran-api --role=ctl bootstrap-admin --username=admin.pertama
```

The user is created with `must_change_password = true` and the `platform_admin` role (the
permission catalogue is a migration, so that role holds every known permission). A random
initial password (CSPRNG, length = `password_min_length` plus a margin, alphabet without
easily confused characters) is printed **once** to stdout. Only its hash is stored. If the
output is lost before use, use `reset-password`, below; never update
`platform.app_user.password_hash` with SQL.

Until the password is changed, the account can use only `/auth/session`, `/auth/password` and
`/auth/logout`. Permissioned routes answer 403 `password_change_required` (including the
realtime path), and the UI redirects to `/app/password`. After the change, the current session
stays valid and the user's other sessions are revoked.

Exit codes: 0 created, 3 refused because an admin already exists (or the user name is taken),
2 misuse, 1 DB failure or invalid security policy.

### 5.3 Reset a password

**EXERCISED ON SERVER** (12 Nov 2026, user `admin`, release `d0404e0`). The path below was run
against production and the resulting login was proven end-to-end. Two corrections from that run:

- Run the command **inside the API container** on `d0404e0`. The host binary at
  `/srv/qouver/apps/kran/bin/kran-api` is the gate build and links against the vendored
  `libpq`; it works, but the container is the same binary the service uses and needs no
  `LD_LIBRARY_PATH` juggling.
- Do **not** rewrite `@qouver-postgres:` to `@127.0.0.1:`. `qouver-postgres` is a podman
  network alias, and it resolves from inside the container; on the host that replacement
  points at a port with no listener.

```bash
# Inside the API container (production iteration parameters, random password printed once).
umask 077
podman exec kran-api /usr/local/bin/kran-api --role=ctl reset-password --username=admin \
  > /srv/qouver/apps/kran/private/admin-reset-$(date +%Y%m%d).txt 2>&1
```

Verify with the same call the browser makes, using the printed password straight from the file,
so the secret never lands in shell history or chat:

```bash
pw=$(sed -n '2p' /srv/qouver/apps/kran/private/admin-reset-$(date +%Y%m%d).txt)
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://cbs.qouver.com/api/v1/auth/login \
  -H 'content-type: application/json' --data-raw "{\"username\":\"admin\",\"password\":\"$pw\"}"
# 200 = the new password works through the public entry point.
```

Recorded run (12 Nov 2026): reset 01:57:19Z, `auth.login.success` 01:58:50Z (container) and
02:00:06Z (public), `failed_attempts` back to 0, `must_change_password = true`,
`user.password_reset` in the audit chain with `sessions_revoked: 1`.

The random password is printed **once**; the hash uses production iteration parameters;
`must_change_password = true`; a `LOCKED` account returns to `ACTIVE` (an `INACTIVE` or
`SUSPENDED` account is **not** activated); the old hash goes into `user_password_history` so it
cannot be reused; all sessions are revoked; audit `user.password_reset` is written in the same
transaction. The next login is forced to change the password.

### 5.4 Audit anchor

The daily timer below is **EXERCISED** (installed 2 Nov 2026). The `podman run` form is
**UNVERIFIED ON SERVER**: it is the container-shaped alternative, while the timer uses the host
binary.

```bash
podman run --rm --network qouver \
  --env-file /srv/qouver/apps/kran/env/kran-prod.env \
  -v /srv/qouver/audit-anchor:/anchor:Z \
  localhost/kran-api:local --role=ctl audit-anchor --out=/anchor/audit-anchor.log
```

One line is `UTC-time seq=<n> hash=<hash>`, appended to the file. Keep that file **outside** the
database and outside database backups (for example on the daily copy to another host).
Verification: `ctl verify-audit` must report an intact chain, and the last anchor line's
`seq`/`hash` must equal the `platform.audit_log` row at that `seq`.

Daily timer (installed on the server since 2 Nov 2026, `kran-audit-anchor.timer`, 23:50 host
time, `Persistent=true`):

```bash
scp ops/systemd/kran-audit-anchor.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now kran-audit-anchor.timer
systemctl --user list-timers kran-audit-anchor.timer
tail -1 /srv/qouver/apps/kran/logs/audit-anchor.log
```

Like `kran-dayclose.service`, the unit uses the host binary plus `kran-host.env`. The anchor
file still **must** be copied off the server; the timer only removes the manual step, it does
not create the off-host copy. See `SECURITY.md` for what the chain does and does not prove.

### 5.5 Alerts

`kran-alert.timer` (user systemd, every two minutes) runs `ops/scripts/kran-alert.sh`:

- `/readyz` non-200: the message names the failing check and detail;
- `platform.outbox` rows in `DEAD` > 0: the message states the count;
- delivery via `tg-notify.sh` (same Telegram channel as backups), only when the state changes,
  repeated every 6 hours while the problem persists;
- last state in `~/.local/state/kran-alert/last`, log in `~/kran-alert.log`;
- it does **not** probe during a deploy (the deploy lock file is held): while the repo is
  synced before `migrate --up`, the old API can briefly report a pending expand migration. That
  is normal and is not sent as an alert. The stored state is not changed, so a failed deploy
  still alerts on the next probe;
- the script the timer runs is a manual copy at `/srv/qouver/scripts/kran-alert.sh`, not a
  deploy output. After changing `ops/scripts/kran-alert.sh`, copy it again to that path;
- test without sending: `/srv/qouver/scripts/kran-alert.sh --dry-run`.

Readiness checks behind `/readyz`: database, migration root and pending state, realtime pump,
outbox lag, worker heartbeat, and drain state. The `outbox-dead` count appears in `detail` but
does not fail readiness. A worker that has never reported is failed after a 180 s startup
grace; a stale heartbeat fails immediately.

### 5.6 Break-glass `platform_admin`

`platform_admin` is an **emergency** account, not a daily one. This procedure is mandatory
every time it is used. The numbers and format below are owner decisions, not quotations from
regulation; items that touch legal duties are marked `NEEDS-COMPLIANCE-REVIEW`. Use is recorded
in the physical Break-glass book, not in this repository, so a repo reader cannot tell whether
the procedure has ever been exercised. Treat the first use as a drill and record it.

Minimum daily structure:

| Account | Role | Must not also hold |
|---|---|---|
| O1 | `ops_admin` (top-up requester, user/member administration) | `ledger_admin` |
| O2 | `cash_admin` (top-up approver, cash provision) | `ledger_admin`, `teller` |
| O3 | `teller` (drawer cash) | `cash_admin`, `ledger_admin` |
| O4 (target) | `ledger_admin` (bookkeeping, periods, COA, reversals) | `cash_admin`, `ops_admin`, `teller` |
| BG | `platform_admin`, sealed, held by the pengurus | none |

Minimum **3 daily operators**. If `cash_admin` is attached to O1, every routine top-up needs BG
as approver, which in practice destroys cash-path separation of duties; accept that only as a
temporary state.

BG may be used only for:

1. Being the **second account** on a dual operation (maker is not checker) when no human
   counterpart is available (leave, resignation, force majeure). Use the daily account as maker
   and BG as checker; two different `user_id` values satisfy the self-approval CHECK.
2. Configuration repair that has no other role path.

It is not valid to use BG to bypass a structural control (self-approving the same object,
revoking the last manager, editing historical journals).

Every use requires: the automatic `platform.audit_log` row; the Break-glass book (digital or
paper) recording time (WIB), daily account (maker), BG account (checker), operation,
`request_id`/`journal_id`, reason, signatory and the reviewing pengurus initials; a written
signed report to the pengurus on the next working day; and an approval in advance when usage
exceeds **3 times per month**.

Leave and resignation:

- Leave of 5 working days or fewer: no role change; if a dual operation is needed, use BG plus
  the book and report.
- Leave longer than 5 working days or resignation, within **1 working day**:
  1. Ensure the replacement already holds `platform.user.manage` (`assign-role` to
     `ops_admin`); otherwise `disable-user` is refused with `last_admin`.
  2. `kran-api --role=ctl disable-user --username=<person>` (revokes all sessions).
  3. Move essential roles to the replacement (`assign-role`). A separation-of-duties conflict
     created by that assignment is refused with `sod_conflict`; that is correct, not a bug.
  4. Do not hand over a password; create a new account with a new password.

Vault top-up evidence (`NEEDS-COMPLIANCE-REVIEW`): the request `note` format is
`[SOURCE TYPE] <evidence type> <reference number> | <purpose>`, for example
`[BANK] slip setoran 2026-10-24/BCA/123456 | setoran modal kas cabang` (bank deposit slip for
branch cash capital). The original physical
evidence stays in the branch cash-evidence file (monthly); the digital copy is in the
institution's evidence folder outside the database. The DB stores no file; `request_id` is the
document number. Physical retention of 10 years is a proposal awaiting compliance review, not
a verified rule. The checker rejects a request when the amount differs from the evidence, the
source account is wrong, the `note` has no reference number, the branch is wrong, the requester
is the same person, or the business date is not OPEN.

---

## 6. Key rotation and credentials

### 6.1 Field encryption model

Implementation: `shared/platform-lib/crypto/fieldcrypto.nim`; decision: `adr/017-field-level-encryption.md`.
**Cryptography area: HUMAN-REVIEW-REQUIRED before real member data.**

- **KEK** lives in a separate file (mode 600, env `KRAN_KEK_FILE`).
- A **DEK** is derived per table: `HMAC-SHA256(KEK, "kran:dek:v1:" || table)`.
- Ciphertext is AES-256-GCM in the form
  `kran:enc:v1:<kid>:<nonce_b64url>:<ciphertext||tag_b64url>`, with the table name as AAD.
- Equality search uses a **blind index**:
  `HMAC-SHA256(HMAC-SHA256(KEK,"kran:bidx:v1:"||table), value)`, hex encoded.
- Table names are part of the key domain and the AAD. Renaming a table without re-encrypting
  makes the data unreadable.
- Only equality is supported on encrypted columns. No `LIKE`, no ranges.
- Decryption errors are surfaced, never swallowed into an empty value.
- Columns may be NULL; do not encrypt an empty string as a substitute for NULL.

All commands in this subsection are examples to run in the repo or on a laptop. The production
KEK file is created manually by the owner on the server.
**UNVERIFIED ON SERVER** for creation by this document; the existing `v1` key was created during
the Fase 1 go-live and the API has been healthy with it mounted.

Create a key file:

```
umask 077
printf 'v1:%s\n' "$(openssl rand -base64 32)" > /srv/qouver/apps/kran/env/kran-kek.key
chmod 600 /srv/qouver/apps/kran/env/kran-kek.key
```

- File format: one or more versioned keys, one per line, `<kid>:<base64 32 bytes>`. Blank lines
  and lines starting with `#` are ignored.
- `kid` is the key version marker (`v1`, `v2`, ...), letters/digits/`_`/`-`/`.` only.
- The key must be exactly 32 bytes after base64 decoding.
- Mode **must** be 600. A file readable by group or others is refused at startup.

Storage rules:

- The KEK file is **not** part of the same database backup. Keep it separately, encrypted or
  offline. A lost file means the encrypted data cannot be read back; there is no recovery path.
- Never put the KEK file in the repo, the image, or a database dump.

Activation in the unit:

```
# kran-api.container / kran-worker.container
UserNS=keep-id:uid=10001,gid=10001
Volume=/srv/qouver/apps/kran/env/kran-kek.key:/run/secrets/kran-kek.key:ro,z

# env (kran-prod.env) - path **inside the container**
KRAN_KEK_FILE=/run/secrets/kran-kek.key
```

Without `UserNS=keep-id`, the container runs as uid 10001 mapped to a host subuid, cannot read
the mode-600 file, and the API refuses to start. This was proven during the Fase 1 go-live.

Behaviour, with no silent fallback:

| State | Behaviour |
|---|---|
| `KRAN_KEK_FILE` empty | The application starts. Every encrypt/decrypt call fails with `NotConfiguredError` ("field encryption is not configured"). |
| `KRAN_KEK_FILE` set and the file is valid | Read and validated at startup; ready to use. |
| File missing, unreadable, corrupt, invalid kid, or mode not 600 | Startup is refused (`KekError`). |

A deployment that is healthy without encrypted columns does not need `KRAN_KEK_FILE`.

### 6.2 KEK rotation

**BLOCKED while identity data exists**, until a blind-index reindex command exists. The
accepted limit is in `ACCEPTED-LIMITS.md`; do not describe rotation as supported.

- Adding a key: append a new line **below** (`v2:...`). The active key is the last entry, so new
  encryption uses `v2`; old ciphertext (`kid` `v1`) remains readable while `v1` exists. Do not
  remove the old key until every row with that `kid` has been re-encrypted.
- KEK rotation cannot be independent per table: the DEK is bound to the KEK. Replacing or
  deleting a KEK makes old ciphertext unreadable unless it is re-encrypted with the new key
  (while the old key still exists, reads keep working).
- Rotating the blind-index key invalidates the index: the index is an HMAC of a derived key, so
  old values no longer match and a reindex is required.
- Do **not** rotate the KEK while identity data (`party.identity_doc.number_bidx`) exists. Without
  a reindex, duplicate-NIK detection fails open: no error, but the unique constraint no longer
  catches duplicates. If an emergency rotation is unavoidable: (1) re-encrypt all ciphertext
  with the new key, (2) recompute `number_bidx` from the plaintext decrypted with the old key,
  (3) compare row counts and search for new duplicates, (4) only then remove the old key. Step 2
  has no `ctl` command; do it manually from a database snapshot and record it.
- Always test read (decrypt plus index search) before deleting an old key.

### 6.3 Database roles

**UNVERIFIED ON SERVER.** The separation of owner and runtime role is the intended state, but
the live grants have not been verified (`\dp` output from production is missing; audit finding
X3). A fresh deployment that skips this procedure runs as the schema owner, and the append-only
guarantee is then trigger-only. The P7 privilege test is the fix; until it exists, run the
verification below.

Goal: two layers for the append-only audit trail, trigger **and** privilege. The runtime role
must not `UPDATE`/`DELETE`/`TRUNCATE` `platform.audit_log`. The owner role is used only for
migrations and seed.

| Role | Used by | Rights |
|---|---|---|
| `kran_app` | `--role=migrate` (deploy), seed | Schema/object owner, DDL |
| `kran_runtime` | api, worker, ctl | CRUD on business tables; audit `SELECT`/`INSERT` only; no DDL; no audit `TRUNCATE` |

One-time steps, as superuser, in a maintenance window. Step 2 below passes the new password as
a command argument, which is visible in `ps` for the duration; if that matters in your
environment, export it and read `os.environ` in the Python block instead of using `sys.argv`
(the command lines themselves do not change).

```bash
cd /srv/qouver/apps/kran

# 1. New runtime password (not printed; stored in env, not in argv)
NEW_PW="$(openssl rand -hex 24)"
printf "\\set pw '%s'\nCREATE ROLE kran_runtime LOGIN PASSWORD :'pw';\n" "$NEW_PW" \
  | podman exec -i qouver-postgres psql -U qouver -d postgres

# 2. Move the owner URL to a separate file (not loaded by any unit), then set the runtime URL
python3 - "$NEW_PW" <<'PY'
import os, re, sys
pw = sys.argv[1]
base = "/srv/qouver/apps/kran/env"
prod = open(f"{base}/kran-prod.env").read().splitlines()
url = next(l.split("=", 1)[1] for l in prod if l.startswith("KRAN_DATABASE_URL="))
open(f"{base}/kran-migrate.env", "w").write("KRAN_DATABASE_URL=" + url + "\n")
os.chmod(f"{base}/kran-migrate.env", 0o600)
runtime = re.sub(r"(://[^:]+:)[^@]*(@)", r"\g<1>" + pw + r"\g<2>", url)
runtime = re.sub(r"(://)[^:]+(:)", r"\g<1>kran_runtime\g<2>", runtime, count=1)
out = []
for l in prod:
    if l.startswith("KRAN_DATABASE_URL="):
        l = "KRAN_DATABASE_URL=" + runtime
    out.append(l)
open(f"{base}/kran-prod.env", "w").write("\n".join(out) + "\n")
os.chmod(f"{base}/kran-prod.env", 0o600)
PY

# 3. Grant the runtime role (idempotent; run as superuser)
podman exec -i qouver-postgres psql -U qouver -d kran <<'SQL'
GRANT USAGE ON SCHEMA platform, ledger, party, product, deposit, teller, lending TO kran_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA platform, ledger, party, product, deposit, teller, lending
  TO kran_runtime;
GRANT SELECT, INSERT ON platform.audit_log TO kran_runtime;
REVOKE UPDATE, DELETE, TRUNCATE ON platform.audit_log FROM kran_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA platform, ledger, party, product, deposit, teller, lending TO kran_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA platform, ledger, party, product, deposit, teller, lending TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA platform
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA ledger
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA party
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA product
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA deposit
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA teller
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA lending
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA platform
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA ledger
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA deposit
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA teller
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE kran_app IN SCHEMA lending
  GRANT USAGE, SELECT ON SEQUENCES TO kran_runtime;
SQL

# 4. Revoke write rights on immutable tables
#    Migration `platform/0042` does this automatically on deploy. Run it here as well so the
#    procedure stays correct if step 3 is repeated (the GRANT above covers all tables).
podman exec -i qouver-postgres psql -U qouver -d kran <<'SQL'
REVOKE UPDATE, DELETE, TRUNCATE ON ledger.journal, ledger.journal_line FROM kran_runtime;
REVOKE UPDATE, DELETE, TRUNCATE ON platform.audit_log FROM kran_runtime;
REVOKE DELETE, TRUNCATE ON platform.param_value FROM kran_runtime;
SQL

# 5. Restart with the runtime URL, then verify
systemctl --user restart kran-api kran-worker
sleep 3
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8095/readyz          # 200
systemctl --user is-active kran-api kran-worker                                 # active active
```

`ALTER DEFAULT PRIVILEGES` caveat: default privileges cannot exclude specific tables, so a
**new** immutable table (for example a history or journal table in a later module) receives
`UPDATE`/`DELETE` when created. Every migration that creates such a table must add its own
`REVOKE` for `kran_runtime` (the pattern is `platform/0042`).

Mandatory verification:

```bash
# a. Runtime must NOT change audit or journals
podman exec qouver-postgres psql -U qouver -d kran -tAc "SELECT has_table_privilege('kran_runtime','ledger.journal','UPDATE') OR has_table_privilege('kran_runtime','ledger.journal','DELETE'), has_table_privilege('kran_runtime','ledger.journal_line','UPDATE') OR has_table_privilege('kran_runtime','ledger.journal_line','DELETE'), has_table_privilege('kran_runtime','platform.audit_log','UPDATE') OR has_table_privilege('kran_runtime','platform.audit_log','DELETE')"   # must be f f f
podman exec qouver-postgres psql -U qouver -d kran -tAc "SELECT has_table_privilege('kran_runtime','platform.param_value','DELETE')"   # must be f

# b. Direct write through the runtime role: the DB rejects the audit update
PW=$(sed -nE 's#^KRAN_DATABASE_URL=.*://[^:]+:([^@]+)@.*#\1#p' /srv/qouver/apps/kran/env/kran-prod.env)
podman exec -e PGPASSWORD="$PW" qouver-postgres psql -h 127.0.0.1 -U kran_runtime -d kran -c \
  "UPDATE platform.audit_log SET action = action WHERE seq = (SELECT max(seq) FROM platform.audit_log)"
# expected: ERROR: permission denied for table audit_log

# c. Runtime can still write business tables (worker heartbeat is fresh)
podman exec qouver-postgres psql -U qouver -d kran -tAc \
  "select worker_name, extract(epoch from now()-last_seen_at)::int from platform.worker_heartbeat"

# d. Migrations still run with the owner role
URL=$(sed -n 's/^KRAN_DATABASE_URL=//p' /srv/qouver/apps/kran/env/kran-migrate.env)
URL="${URL//@qouver-postgres:/@127.0.0.1:}"
KRAN_DATABASE_URL="$URL" LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=migrate --check; echo "check=$?"
```

Rollback: restore `KRAN_DATABASE_URL` from `kran-migrate.env` into `kran-prod.env`, restart,
confirm `/readyz` 200. `REVOKE ALL ... FROM kran_runtime; DROP ROLE kran_runtime;` is optional.
Do not delete `kran-migrate.env` while later deploys still need the owner role.

### 6.4 Rotate a database password

**UNVERIFIED ON SERVER** as a documented sequence. It replaces an ad hoc rotation on 17 Oct
2026 where `sed` duplicated the `KRAN_DATABASE_URL=` prefix and the API failed to start for
about a minute. **Never** put a password in a command argument; `ps` shows it.

Before starting: record the current revision and `/readyz`; confirm no deploy is running; open
two terminals (one for DB, one for the app); generate the new password without URL-breaking
characters (`@ : / ? #` are risky; `+ / =` are allowed) and without printing it; use `read -s`
to get it into `NEW_DB_PASSWORD`.

```bash
# 1. Change the application role password (password via stdin, not argv)
#    Replace NEW_PASSWORD with the value in NEW_DB_PASSWORD; do not paste a real value into history.
podman exec -i qouver-postgres psql -U qouver -d postgres -c \
  "ALTER ROLE kran_app PASSWORD :'pw'" <<< "\\set pw 'NEW_PASSWORD'"
# or interactively:
podman exec -it qouver-postgres psql -U qouver -d postgres -c "\\password kran_app"

# 2. Build the new env line WITHOUT sed on the whole line (avoid a doubled prefix)
cd /srv/qouver/apps/kran
cp env/kran-prod.env env/kran-prod.env.bak-$(date +%Y%m%d-%H%M)
python3 - <<'PY'
import re, os
p = "env/kran-prod.env"
pw = os.environ["NEW_DB_PASSWORD"]          # export via `read -s`, never a literal
lines = open(p).read().splitlines()
out = []
for line in lines:
    if line.startswith("KRAN_DATABASE_URL="):
        url = line.split("=", 1)[1]
        url = re.sub(r"(://[^:]+:)[^@]*(@)", r"\g<1>" + pw + r"\g<2>", url)
        line = "KRAN_DATABASE_URL=" + url
    out.append(line)
open(p, "w").write("\n".join(out) + "\n")
PY
chmod 600 env/kran-prod.env

# 3. Restart and verify (both are mandatory)
systemctl --user restart kran-api kran-worker
sleep 3
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8095/readyz   # expected 200
KRAN_DATABASE_URL="$(grep '^KRAN_DATABASE_URL=' env/kran-prod.env | cut -d= -f2-)" \
  LD_LIBRARY_PATH=/srv/qouver/apps/kran/lib \
  /srv/qouver/apps/kran/bin/kran-api --role=migrate --check             # expected exit 0

# 4. Delete the env backup only after step 3 is green
rm env/kran-prod.env.bak-*
```

If it fails: `/readyz` not 200 means restore the env backup, restart, verify, and do **not**
delete the backup. `--check` failing authentication means the DB password and the URL are out
of sync; repeat steps 1 and 2 rather than guessing the URL shape. Record time, role and result
in the task file; never record the password.

### 6.5 Credential locations

| Secret | Location | Mode |
|---|---|---|
| Runtime DB URL | `$APP_DIR/env/kran-prod.env` | 600 |
| Owner DB URL (migrate/seed) | `$APP_DIR/env/kran-migrate.env` | 600 |
| Host loopback DB URL | `$APP_DIR/env/kran-host.env` | 600 |
| Field-encryption KEK | `$APP_DIR/env/kran-kek.key` (mounted at `/run/secrets/kran-kek.key`) | 600 |
| Webhook HMAC secret | Hook configuration on the host, `webhook.json` | 600 |
| Deploy SSH key | `~/.ssh/kran_deploy` on the VPS (read-only deploy key) | 600 |
| CI read token (optional) | Server environment | host-defined |
| Dev DB URL | `.local/dev.env` on the developer machine (gitignored) | 600 |

---

## 7. Pilot provisioning

**PARTIALLY EXERCISED.** The vault insert is recorded on 23 Oct 2026. The branch alignment is
required for the pilot flows to work but is not separately recorded, and the account and role
commands are the documented path rather than individually evidenced. The pilot data is
intentionally retained (owner decision, 23 Oct 2026) and is synthetic; no real member data.

### 7.1 Prerequisites

- A deployed `kran-api` that includes `ctl create-user`.
- Migrations for pilot roles and role scope applied (branch-scoped `teller`; institution-scoped
  `product_checker`, `platform_admin`, parameter roles).
- Production DB access for one data adjustment: moving the demo party to the pilot branch.

### 7.2 Operator accounts

| Account | Role | Branch | Used for |
|---|---|---|---|
| `admin` | `platform_admin` | global | Open periods, create products (maker), open accounts |
| `checker.pilot` | `product_checker` | global | Approve products (checker is not maker) |
| `teller.pilot` | `teller` | `b0000000-0000-4000-8000-000000000001` | Cash session, cash deposit, transfer |

`kran-api` has `bootstrap-admin` only for the first admin. Additional accounts:

```sh
podman exec kran-api /usr/local/bin/kran-api --role=ctl create-user \
  --username=checker.pilot --user-role=product_checker --full-name="Checker Pilot"

podman exec kran-api /usr/local/bin/kran-api --role=ctl create-user \
  --username=teller.pilot --user-role=teller \
  --branch=b0000000-0000-4000-8000-000000000001 --full-name="Teller Pilot"
```

The initial password is printed **once** (`must_change_password = true`). Log in and change it
through `POST /api/v1/auth/password` before use; without that, every other route answers 403.

Role scope:

- A `BRANCH` role (`teller`) **must** get `--branch=<uuid>`; without it the command is refused
  (exit 3) rather than granted globally.
- An `INSTITUTION` role (`product_checker`, `platform_admin`, parameter roles) **must not** get
  `--branch`; supplying one is refused (exit 3). Previously this produced a dead account,
  because institution routes authorise against an empty branch.

Account lifecycle (same discipline as `create-user`/`reset-password`: one transaction, audit,
session revocation where relevant; exit 2 misuse, 3 refused/not found):

```sh
# Assign/revoke a role (a BRANCH role needs --branch; an INSTITUTION role must not have one)
podman exec kran-api /usr/local/bin/kran-api --role=ctl assign-role \
  --username=teller.pilot --user-role=teller --branch=b0000000-0000-4000-8000-000000000001
podman exec kran-api /usr/local/bin/kran-api --role=ctl revoke-role \
  --username=teller.pilot --user-role=teller --branch=b0000000-0000-4000-8000-000000000001

# Offboarding: disable and revoke all sessions. Re-enabling works only for an INACTIVE account.
podman exec kran-api /usr/local/bin/kran-api --role=ctl disable-user --username=teller.pilot
podman exec kran-api /usr/local/bin/kran-api --role=ctl enable-user --username=teller.pilot

# Unlock a lockout (LOCKED -> ACTIVE only; resets the failure counter).
podman exec kran-api /usr/local/bin/kran-api --role=ctl unlock-user --username=teller.pilot
```

`revoke-role` refuses to remove the last `platform_admin` (exit 3), so there is no state without
an admin. `enable-user` does not touch a `LOCKED` or `SUSPENDED` account; use `unlock-user` for
lockout.

### 7.3 Pilot branch

`b0000000-0000-4000-8000-000000000001` is the pilot branch and the cash vault lives there. The
seeded demo party still sits at a demo UUID, so align it once, before any account exists:

```sql
UPDATE party.party
   SET branch_id = 'b0000000-0000-4000-8000-000000000001', updated_at = now()
 WHERE branch_id = '00000000-0000-4000-8000-000000000001';
```

Without this, account opening is refused with `branch_mismatch` and a cash session at the
party's branch fails with `vault_not_configured`.

### 7.4 Period and products

1. `POST /api/v1/ledger/periods` with `{"startsOn":"2026-10-01","endsOn":"2026-10-31"}`. Cash
   transactions are refused with `period_closed` when no period is OPEN.
2. `POST /api/v1/products` as `admin` for each product, then
   `POST /api/v1/products/{code}/versions/{versionId}/approve` as `checker.pilot`.

Pilot products:

| Code | Name | savingsKind | min_balance |
|---|---|---|---|
| `SIMP-POKOK` | Simpanan Pokok | `POKOK` | 0 |
| `SIMP-WAJIB` | Simpanan Wajib | `WAJIB` | 0 |
| `SIMP-SUKARELA` | Simpanan Sukarela | `SUKARELA` | 10.000 |
| `TABUNGAN` | Tabungan Anggota | `TABUNGAN` | 25.000 |

All pilot products use `interest_posting = NONE` and `interest_rate = 0`. The accrual engine
exists, but pilot rates are not compliance-verified (`NEEDS-COMPLIANCE-REVIEW`); do not display
an interest figure that has not been approved. Under the replanned product scope, time deposits
leave the MVP and savings return is SHU-based.

### 7.5 Accounts and a cash day

1. Open accounts (`POST /api/v1/deposit/accounts`, `Idempotency-Key` required) for the pilot
   members: pokok plus wajib for one member, savings for the others.
2. Open a teller session (`POST /api/v1/teller/sessions`) with a float of Rp2.000.000.
3. Post a cash deposit (`POST /api/v1/teller/cash-transactions`) and one book transfer
   (`POST /api/v1/teller/transfers`).
4. Close the session (`POST /api/v1/teller/sessions/{id}/close`) with `countedCash` equal to the
   float plus all cash deposits.

Every POST requires `Idempotency-Key`; a deterministic key makes a retry safe for accounts and
transactions. Product creation is **not** idempotent per code; read the catalogue before
repeating it.

### 7.6 Verification

- `GET /api/v1/deposit/accounts?partyId=...` shows the balance produced by the transactions.
- `GET /api/v1/deposit/accounts/{id}/statement?from=...&to=...` shows the movements.
- `GET /api/v1/teller/vault?branchId=...` equals opening vault minus float plus counted cash.
- `GET /api/v1/ledger/journals` and the trial balance show double-entry journals.
- Audit: `user.create`, `product.*`, `deposit.account.open`, `teller.*` are present in
  `GET /api/v1/audit` or `platform.audit_log`.

### 7.7 Vault row (one-time)

When `teller.vault` has no row for the operating branch, a cash session refuses to open with
`vault_not_configured` and `POST /teller/vault/topups` returns 404. Run this as the owner role
(not the API runtime role) on the DB host:

```sql
INSERT INTO teller.vault (branch_id, balance)
VALUES ('<branch-uuid>', '<amount>')
ON CONFLICT (branch_id) DO NOTHING;

SELECT branch_id, balance FROM teller.vault ORDER BY branch_id;
```

Then verify through the API with a session holding `teller.vault.read`:
`GET /api/v1/teller/vault?branchId=<branch-uuid>` returns 200 with `{branchId, balance}`.
Record the branch UUID, amount and execution time in the task file; never record credentials.

Executed for the pilot on 23 Oct 2026: branch `b0000000-0000-4000-8000-000000000001`, opening
float `10000000.00` (Rp10.000.000, owner-approved), result `INSERT 0 1`. The vault balance is
now posted to GL (`101.1`/`203`) by the teller module; the earlier note that it was absent from
the balance sheet no longer applies.

To reduce the balance, use an explicit SQL adjustment with a written reason (there is no
API debit for the vault), then reconcile against physical cash and `platform.audit_log`.
Deleting the vault row disables cash sessions (fail-closed); never use that as a deploy rollback.

### 7.8 Standing limits

- Cash limits come from `teller.cash.limit_*` parameters. There is still no cumulative daily
  limit.
- Branch master data exists (`platform.branch`, `ctl create-branch`, `GET /api/v1/branches`);
  writes still go through `ctl`.
- Pilot passwords must be changed after handover and must never be stored in the repo.

---

## 8. Dev database and web

### 8.1 Dev database

Integration tests use the `kran_dev` database on the Postgres server, reached from the laptop
through an SSH tunnel. The reason and the original decision are historical; the constraint that
matters is that this is the only shared dev database.

```sh
./task devdb up        # open the tunnel 127.0.0.1:55432 -> server 127.0.0.1:5432
./task devdb status    # check the connection and database
./task test            # integration tests run too (KRAN_DATABASE_URL comes from .local/dev.env)
./task devdb down      # close the tunnel when finished
```

If `KRAN_DATABASE_URL` is empty or the tunnel is down, integration tests **skip themselves**
(printed as `SKIP`) instead of failing.

Files and credentials: `.local/dev.env` (gitignored, mode 600) holds `KRAN_DATABASE_URL`.
Recreate it with the provisioning steps below if lost. Never copy its value into a document or
a commit. The tunnel uses `ControlMaster` at `.local/devdb.sock` with `ControlPersist=600`, so
subsequent `ssh` commands do not handshake again.

Boundaries:

- Only the dev database and its dev role are touched. The old `cbs` database belongs to a
  different system and is not touched. The dev DB and role were renamed on the server on
  15 Oct 2026.
- No quadlet, container, config, backup or hook changes on the server.
- No real data; all test data is synthetic.

`./task e2e` **drops all module schemas** in the dev database before migrating and seeding
(`dbtools reset`, refused unless the database name ends in `_dev`/`_test`). Data you entered
manually through the dev UI is lost. The reason: leftover integration state (for example a
CLOSED accounting period) makes dev seeding fail and e2e blames the wrong feature; starting from
zero also proves empty-database migration on every gate run.

Initial provisioning (once, 13 Oct 2026, as the operator account on the server, using
`podman exec qouver-postgres`):

```sh
# role + database
psql -U qouver -c "CREATE ROLE kran_dev LOGIN"          # idempotent (check pg_roles first)
psql -U qouver -c "ALTER ROLE kran_dev PASSWORD '<password>'"
psql -U qouver -c "CREATE DATABASE kran_dev OWNER kran_dev"
# extensions
psql -U kran_dev -d kran_dev -c "CREATE EXTENSION pgcrypto; CREATE EXTENSION pg_trgm; CREATE EXTENSION btree_gist;"
```

The password is generated randomly (`openssl rand -hex 24`) and exists only in
`.local/dev.env`.

Local library and tunnel notes:

- `db_connector` loads `libpq.dylib` at runtime. On macOS/Homebrew it lives in
  `opt/libpq/lib`, which is not on the default search path. Add to `.local/dev.env`:
  `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/libpq/lib`. Without it the error is
  `could not load: libpq.dylib`.
- The SSH master closes an idle tunnel (`ControlPersist`, default 600 s), so a long integration
  run can fail with `Connection refused`. For a working session set
  `KRAN_DEVDB_PERSIST=7200` in `.local/dev.env`. `./task devdb up` is idempotent.
- The tunnel can also die when the SSH connection drops, even with keepalive. Run
  `./task devdb status` before a long gate; if a gate reports `Connection refused` or
  `server closed the connection unexpectedly`, check the tunnel before blaming the code and
  rerun the gate. Do not loosen a test to get past it.
- `./task devdb up` proves the tunnel with a real query (`select 1`), not a port check. A tunnel
  whose SSH is dead still accepts local connections, which used to surface mid-test as
  `server closed the connection unexpectedly`.

Migrations and status:

```sh
./task dbtools validate   # no DB: order + files + expand-only guard
./task dbtools migrate    # needs KRAN_DATABASE_URL; idempotent
./task dbtools status     # list migrations + detect files whose content changed
```

The platform integration test **drops the `platform` schema** (including `audit_log`) and
reapplies migrations. Never point `KRAN_DATABASE_URL` at a database whose data matters.

### 8.2 Web workspace

Applies to `apps/web` and `packages/{config,i18n,ui}`. Daily commands go through `./task`;
the notes here cover what `./task` does not.

The dev machine's `~/.npmrc` points at a private registry that does not resolve from ordinary
networks. `pnpm` ignores `npm_config_registry` (it reads `pnpm_config_registry`). To install or
upgrade dependencies:

```sh
pnpm_config_registry=https://registry.npmjs.org/ pnpm install --frozen-lockfile
```

Without the override the command tries the private registry and hangs until retries are
exhausted (over 10 minutes).

- `pnpm-lock.yaml` is committed and used by CI (`--frozen-lockfile`). Dependency versions are
  also pinned exactly in `package.json`, so lockfile and manifest reinforce each other.
- Adding or changing a dependency: install with the override, pin the version (for example
  `pnpm add -D -E <package>`), and inspect `git diff pnpm-lock.yaml`.
- Supply-chain policy verifies the lockfile during install; if it fails on incomplete metadata,
  run an online install (not `--offline`).

Gates:

```sh
./task e2e    # kontras token (vitest) + kompilasi Paraglide + svelte-check + Playwright
./task ci     # semua: Nim + web
```

`./task e2e` calls binaries in `node_modules/.bin` directly instead of `pnpm run`, because
`pnpm run` may reinstall dependencies first and that install can hang on this network. Local
binaries are deterministic and still correct in CI after `pnpm install`.

Playwright browser, once per machine and Playwright version:

```sh
cd apps/web && ./node_modules/.bin/playwright install chromium
```

`playwright.config.ts` uses `reuseExistingServer: false` on purpose: every run builds and serves
a fresh build, so a test cannot pass against a stale server.

i18n:

- Catalogue: `packages/i18n/messages/{id,en}.json` (flat, keys prefixed by namespace).
- Gate: `./task i18n` (`tools/i18ncheck`): every key exists in every locale, placeholders are
  consistent, no orphan keys, keys used by code exist in the catalogue.
- The Paraglide plugin is vendored as a devDependency in `packages/i18n` and referenced by
  `project.inlang/settings.json` with a local path, so the build needs no network.

---

## 9. Incident basics

There is no metrics endpoint yet and no formal incident runbook before this section. Detection
comes from `/readyz`, the alert timer, deploy failures, and operator reports. The sequence below
assumes the pilot shape: one host, one API, one worker, one Postgres container.

### 9.1 First 15 minutes

1. Confirm scope: open the site, `curl -fsS http://127.0.0.1:8095/healthz` and `/readyz`. A
   non-200 readiness body names the failing check and its detail.
2. Check the last deploy: `tail -50 $APP_DIR/logs/deploy.log`. If a deploy just failed, the
   script should already have rolled back; confirm with `cat $APP_DIR/.deployed_rev` and
   `systemctl --user status kran-api kran-worker`.
3. Check the alert state: `cat ~/.local/state/kran-alert/last`, `tail -50 ~/kran-alert.log`.
   Run `/srv/qouver/scripts/kran-alert.sh --dry-run` to probe without sending.
4. Check the worker and outbox: `kran-api --role=ctl outbox-status`. A growing `DEAD` count means
   events are not being delivered; readiness reports the count but does not fail on it.
5. Check the book date: `kran-api --role=ctl daycloser-status; echo $?`. A close stuck in
   `CLOSING` blocks writes and deploys; resolve with section 4.7, not by editing DB state.

### 9.2 Decide: roll back or fix forward

- A bad **release** with a healthy database: `ops/scripts/rollback.sh` (section 1.5). It
  restores the image, web build and units, not the schema.
- A bad **migration**: do not improvise a `--down` during the incident. Restore from the
  pre-deploy dump only if the data is unusable; otherwise apply the reviewed fix forward. The
  pre-deploy dump is the recovery path because `--down` knows nothing about data.
- A **data** error in the books: never edit journal rows. Post a reversing journal through the
  normal path, with maker-checker.
- A **security** incident: stop and follow `SECURITY.md`. Do not destroy logs or sessions before
  capturing evidence; revoke sessions through `disable-user`, which also audits.

### 9.3 Database unavailable

1. `podman ps` and `systemctl --user status` for the Postgres container and the API.
2. `podman exec qouver-postgres pg_isready -U qouver`.
3. Check disk: `df -h /srv`. A full disk stops writes and backups.
4. The API and worker will fail readiness; the deploy gate holds. Do not restart-loop the
   worker: exit 2 means configuration, not a transient fault.

### 9.4 Audit chain alarm

`ctl verify-audit` exit 1 means an entry does not verify. On the dev database this can be
expected (section 5.1); in production it is not.

1. Record the command output and the last anchor line (`tail -1
   $APP_DIR/logs/audit-anchor.log`).
2. Compare the anchor's `seq`/`hash` with the row at that `seq` in `platform.audit_log`.
3. Do not truncate, rebuild or "repair" the chain. Preserve the database and the anchor file
   and escalate to the owner; this is a `HUMAN-REVIEW-REQUIRED` area.

### 9.5 Reconciliation alarm

`ctl reconcile-deposits` exit 1 means the balance cache and the movement rows disagree.
`daycloser` gates `DAY-306/307/308` cover related conditions. Capture the output (it names the
accounts), then investigate the transactions on those accounts before closing the date. Do not
"tidy" the difference with an unexplained journal.

### 9.6 Evidence to keep

For any incident: timestamps in WIB and UTC, the revision from `.deployed_rev`, the relevant
`deploy.log` lines, readiness bodies, `daycloser-status` output, `outbox-status`, the audit
anchor line for the day, and the commands you ran. Put them in the task file that owns the
incident; do not paste secrets or member data into a ticket.

### 9.7 Known detection gaps

- No metrics, so latency, error rate, pool saturation and outbox depth are not measured
  continuously (audit `BE-ISO-04`, `C19`). The P7 `/metrics` task is the fix.
- Alerts cover readiness and dead outbox only; there is no alert on a stuck close, a failed
  backup, or a failed restore drill.
- Backup failure is visible only in the backup log and the Telegram channel used by the backup
  script; the alert timer does not check it.
- No PITR and no off-host backup copy (section 3.1). Recovery point is the last verified dump.
