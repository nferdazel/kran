# PROGRESS T-013 — artefak `ops/` (spec §21.4–21.6)

Log kerja T-013. Lingkup: **hanya berkas di repo**. Tidak ada perintah yang dijalankan di
server; tidak ada SSH/deploy/secret. Dikerjakan di branch `feat/fase0-fondasi`; perubahan
ditinggalkan di working tree (orkestrator yang commit).

---

## 1. Berkas dibuat + ringkasan

| Berkas | Isi ringkas |
|---|---|
| `ops/scripts/deploy-vps.sh` | Kontrak §21.4: ref-guard fail-closed → `flock` → `git fetch`+`reset --hard` → FREEZE GATE → rebuild selektif → pre-migration dump → `podman build` (tag `:local`+`:sha`) + ekstrak binary → MIGRATION GATE (`--role=migrate --check`/`--up`) → swap web atomik → restart `cbs-api`/`cbs-worker` → HEALTH GATE `/readyz` ×15 + auto-rollback → `.deployed_rev` → self-update skrip. Tanpa secret (URL repo dari `CBS_GIT_URL` env VPS). |
| `ops/scripts/migrate.sh` | `--up`/`--check`/`--contract --yes`/`--down --yes [N]`; membungkus `bin/cbs-api --role=migrate ...` (§21.6, §21.7). Manual/opt-in; `--contract`/`--down` wajib `--yes`. |
| `ops/scripts/backup-postgres.sh` | Backup harian semua DB prod (`pg_dump -Fc` + `pg_restore --list` + globals + retensi 7/28/84) **dengan filter non-prod O-002** (`*_verify*`, `*_test`, `*_dev`). |
| `ops/scripts/backup-pre-deploy.sh` | Dump pra-migrasi ke `/srv/qouver/backups/pre-deploy/<rev>-<ts>.dump`, divalidasi `pg_restore --list` (§21.4 #6). |
| `ops/scripts/rollback.sh` | Manual: `bin/cbs-api.prev` → `bin/cbs-api` & `web.prev` → `web`; restart; **tanpa menyentuh DB** (§21.6). |
| `ops/scripts/smoke.sh` | Cek `/healthz`, `/readyz`, dan versi `==` isi `.deployed_rev` (§21.6). |
| `ops/scripts/audit-consistency.sh` | Bandingkan md5 `ops/scripts/*.sh` (repo) ↔ `<server>/srv/qouver/apps/kran/scripts/*`. Pelapor (exit 0); alamat server lewat `CBS_VPS` (tidak di-hardcode). |
| `ops/systemd/cbs-api.service` | Systemd **user** unit, `ExecStart=…/bin/cbs-api --role=api`, `EnvironmentFile=/srv/qouver/apps/kran/env/cbs-prod.env`, `Restart=always`, `NoNewPrivileges=true`, `PrivateTmp=true` (§21.5). |
| `ops/systemd/cbs-worker.service` | Sama, `--role=worker` (§21.5). |
| `ops/caddy/Caddyfile.cbs.example` | Site `cbs.qouver.com` (web → 127.0.0.1:3005) + hostname API terpisah (→ 8095) + header keamanan (HSTS/XCTO/XFO/Referrer-Policy/CSP + `frame-ancestors`), `encode zstd gzip`; snippet transisi `api.qouver.com/cbs/*` (§21.5, audit §4 P2). |
| `ops/webhook/hook.cbs.json.example` | Hook `cbs`, `execute-command` deploy-vps.sh, argumen `repository.name`+`ref`, `trigger-rule` `payload-hmac-sha256` + `X-Hub-Signature-256`, secret placeholder (§21.4). |
| `ops/env/cbs-prod.env.example` | Bootstrap saja: `CBS_DATABASE_URL` + knob pool + `CBS_APP_NAME` (nama yang benar-benar dibaca `shared/platform-lib/db/config.nim`); sisa (port/role/KEK) dikomentari/penanda. Tanpa nilai bisnis & tanpa nilai asli (§21.5, §10, O-006). |

Perubahan executable bit: semua `ops/scripts/*.sh` = `755`.

---

## 2. Verifikasi (perintah + output)

Semua dijalankan lokal di `/Users/sachiel/Projects/cbs`. Tidak ada yang dijalankan di server.

### 2.1 Sintaks bash — `bash -n`

```
$ for f in ops/scripts/*.sh; do bash -n "$f" && echo "OK   $f"; done
OK   ops/scripts/audit-consistency.sh
OK   ops/scripts/backup-postgres.sh
OK   ops/scripts/backup-pre-deploy.sh
OK   ops/scripts/deploy-vps.sh
OK   ops/scripts/migrate.sh
OK   ops/scripts/rollback.sh
OK   ops/scripts/smoke.sh
```

Catatan: `sh -n` **tidak** dipakai — skrip adalah bash (`local`, herestring `<<<`), bukan
POSIX. BACKLOG menulis "`shellcheck`/`sh -n`"; yang setara untuk bash adalah `bash -n`.

### 2.2 `shellcheck` — TIDAK TERSEDIA

```
$ command -v shellcheck; echo $?
(exit 1 — tidak ada di PATH, juga tidak di /opt/homebrew/bin, /usr/local/bin, atau Cellar)
```

`shellcheck` tidak dipasang di lingkungan ini; tidak dipasang baru (aturan: tanpa dependency
baru). Verifikasi statik pengganti: `bash -n` (di atas) + review manual (kutip variabel,
tanpa `ls` parsing, `if` eksplisit untuk mutasi di bawah `set -e`).

### 2.3 JSON webhook valid

```
$ python3 -m json.tool ops/webhook/hook.cbs.json.example >/dev/null && echo OK
OK
```

### 2.4 Tidak ada secret/kredensial

```
$ grep -rniE 'BEGIN [A-Z ]*PRIVATE|ssh-rsa|ssh-ed25519|ghp_|AKIA|xox[baprs]-|password=[^ ]|passwd=[^ ]|secret=[^ ]' ops/
(bersih — tidak ada kredensial literal)

$ grep -rnoE '([0-9]{1,3}\.){3}[0-9]{1,3}' ops/ | sort -u
127.0.0.1   # hanya loopback (Caddy/env/health), bukan IP server publik
```

Placeholder yang memang ada: `CHANGE_ME`, `YOUR_WEBHOOK_HMAC_SECRET`. Tidak ada IP publik
server di dalam repo (alamat server untuk audit-consistency lewat env `CBS_VPS`).

### 2.5 md5 (bahan audit konsistensi)

```
bfb3afbec4efda861d535d4aadadcda3  ops/caddy/Caddyfile.cbs.example
e82fc38ea33a83e228b43895161e9759  ops/env/cbs-prod.env.example
5c21b47103b6678ea54c34a76392ea1a  ops/scripts/audit-consistency.sh
5ac3469acaef2bd9115349f73291c72e  ops/scripts/backup-postgres.sh
45588d42617fbe9205225550c9d22b3c  ops/scripts/backup-pre-deploy.sh
27c4f8bae8519c3e5747ca1de61b9305  ops/scripts/deploy-vps.sh
e9a88095a0687274bbde430856b11370  ops/scripts/migrate.sh
8b1c03f713896f23de79dff853241ebe  ops/scripts/rollback.sh
a6c66eb67d65ee67d443ee5281ea6f6e  ops/scripts/smoke.sh
2081cb19fc9d2c5c8ac07b20d9a00b03  ops/systemd/cbs-api.service
e2472ef68a39fd38713320f5a2a86778  ops/systemd/cbs-worker.service
db12a7ddc6c3c29c210b629a03ac6f9c  ops/webhook/hook.cbs.json.example
```

### 2.6 Uji perilaku lokal yang benar-benar dijalankan (bukan klaim server)

- `audit-consistency.sh` mode lokal (tanpa `CBS_VPS`): mencetak md5 tiap skrip lalu
  `[info] CBS_VPS kosong — perbandingan server dilewati.` → exit 0. ✔
- `migrate.sh` tanpa argumen & dengan `--bogus`: mencetak usage → exit 2. ✔
- `bash -n` semua skrip ✔ (lihat 2.1).

---

## 3. Yang TIDAK bisa diverifikasi (jujur)

- **Belum pernah dijalankan di server.** Tidak ada SSH/deploy (AGENTS.md §3). Semua perilaku
  runtime (build podman, ekstrak binary, restart unit, `/readyz`, rollback, `pg_dump`) belum
  diuji end-to-end.
- **`shellcheck` tidak tersedia** → tidak ada bukti lint penuh; hanya `bash -n` + review manual.
- **Kontrak CLI `--role=migrate|ctl` belum ada di kode** (Fase 0). `migrate.sh` dan FREEZE
  GATE menulis kontrak sesuai spec §21.4, menunggu implementasi role di `apps/api`.
- **Directive systemd namespace** (`ProtectSystem`/`ProtectHome`) dikomentari — belum
  diverifikasi apakah berlaku untuk user unit di Rocky Linux server.
- **Hostname API CBS** (`cbs-api.qouver.com` di contoh) belum final — keputusan pemilik/DNS;
  file hanya `.example`.
- **CSP awal** di Caddyfile bisa perlu penyesuaian setelah T-010 (aset SvelteKit).
- **`ops/env` bukan `.env` nyata** — hanya `*.example`; `.gitignore` sudah meng-whitelist
  `**/ops/env/*.env.example`.

---

## 4. Sisa pekerjaan / ketidakpastian

1. Saat implementasi role binary (`apps/api`), samakan `--role=migrate --check|--up` &
   `--role=ctl daycloser-status` dengan kontrak skrip, atau sesuaikan skrip.
2. `audit-consistency.sh` existing di repo `vps` masih menunjuk `deploy/deploy-vps.sh`;
   bila cbs ingin masuk daftar `REPOS` audit itu, orkestrator perlu memutuskan path
   (`ops/scripts/` vs `deploy/`) — di luar repo ini.
3. Filter backup (O-002) ditulis di `ops/scripts/backup-postgres.sh`; penerapan pada skrip
   server existing (`/srv/qouver/scripts/backup-postgres.sh`) tetap tindakan di luar repo
   (butuh akses server) — O-002 belum tertutup oleh T-013.
4. Restore test (§21.8) & WAL/PITR (§22) belum ada — item go-live terpisah (O-007).
