# PROGRESS — CBS

Log apa yang benar-benar selesai, dengan buktinya. Format: satu entri per task.

Aturan (AGENTS.md §5): klaim "sudah jalan" **wajib** disertai perintah + ringkasan output.
Tidak ada entri DONE di sini sebelum `./task ci` benar-benar dijalankan.

---

## 2026-10-13 — bootstrap sesi Fase 0

**Konteks**: repo masih kosong (belum ada commit; hanya `AGENTS.md` + `docs/spec/`).
Dikerjakan di branch `feat/fase0-fondasi` (tidak pernah push ke `main`).

**Keputusan awal** (detail di `docs/DECISIONS.md`):

- D-001 — satu pintu perintah = skrip POSIX `./task` (bukan Taskfile/just) → tanpa dependensi baru.
- D-002 — satu paket `cbs.nimble` untuk seluruh monorepo; direktori sumber lewat `-p:`.
- D-003 — dependensi Nim Fase 0: `db_connector` 0.1.0 + `yaml` 2.2.1 (nimYAML).
- D-004 — DB dev/integration di server (`cbs_dev`) via tunnel SSH; `CBS_DATABASE_URL` di `.local/dev.env`.

**Bukti provisioning DB dev** (dijalankan 2026-10-13):

```
$ ssh sachiel@43.133.148.191 'podman exec -i qouver-postgres psql -U qouver -Atc "select datname ..."'
cbs_dev|cbs_dev|btree_gist,pg_trgm,pgcrypto,plpgsql     <- role cbs_dev login, DB cbs_dev, ekstensi siap
$ psql "$CBS_DATABASE_URL" -Atc "select 'tunnel-ok'"
tunnel-ok
PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2)
```

---

## 2026-10-13 — T-003 tooling gate (archcheck, lint-nomagic, paramgen)

**Rencana/scope**: `docs/tasks/T-003.md`. Tiga tool + test, menggantikan SKIP di `./task check`.

**Bukti `./task ci`** (satu-satunya klaim "hijau" yang saya buat; log penuh `.build/ci-t003.log`):

```
$ ./task ci
== format (nimpretty)             ok: 29 berkas
== lint (nim check)               ok: 30 berkas
== archcheck                      archcheck: tidak ada pelanggaran batas arsitektur
== lint-nomagic                   lint-nomagic: tidak ada magic number bisnis di domain/application
== paramgen --check               paramgen: sinkron (0 berkas seeds/params.yaml)
== i18n check                     -- SKIP: packages/i18n/messages belum ada (T-010)
== unit + property test           12 berkas test (kernel 9 + tools 3), [OK] 97 / [FAILED] 0
== integration test (Postgres)    -- SKIP: belum ada test integrasi (T-004)
== contract test                  -- SKIP: packages/contracts/openapi belum ada (T-008)
== e2e                            -- SKIP: apps/web/package.json belum ada (T-010)
== CI hijau                       (exit 0)
```

**Bukti gate benar-benar menolak** (probe sementara di repo, lalu dihapus):

```
$ cat > modules/lending/domain/tmp_probe.nim   # berisi import deposit/infrastructure/pg_repo + 91 + 0.05 + "Rp 1.000.000"
$ ./task nomagic
lint-nomagic: 3 temuan
  modules/lending/domain/tmp_probe.nim:4: angka 91 bukan konstanta teknis; pakai parameter DB
  modules/lending/domain/tmp_probe.nim:5: literal desimal dianggap nilai bisnis: 0.05
  modules/lending/domain/tmp_probe.nim:6: literal string bernilai bisnis: "Rp 1.000.000"   (exit 1)
$ ./task archcheck
archcheck: 1 pelanggaran
  modules/lending/domain/tmp_probe.nim:2: [C] modul hanya lewat api.nim modul lain, bukan internalnya: deposit/infrastructure/pg_repo   (exit 1)
```

**Keputusan desain** (rincian di `docs/tasks/T-003.md`):

- Definisi parameter (pack-independent, `packs/base`) dipisah dari nilai per segment pack
  (`packs/<pack>/generated/param_values.sql`) — menghindari FK ke definisi yang belum ada.
- Kode hasil generate tidak diformat ulang nimpretty (`fmt_files()` di `./task`) tetapi tetap
  di-`nim check`; tanpa itu `./task fmt` akan merusak `paramgen --check`.
- Tiga tool sengaja tidak saling import (klasifikasi lapisan diduplikasi ~12 baris) supaya satu
  gate tidak bisa menjatuhkan gate lain.
- `paramgen` menolak `type: duration` sampai ada tipe `Duration` di kernel (tidak menebak satuan).
- Semua seed SQL ditandai `NEEDS-COMPLIANCE-REVIEW` (spec §1.8).

**Batas jujur**: `lint-nomagic` deteksi string berbasis pola, bukan semantik; efektivitasnya
pada modul nyata baru terbukti setelah T-004/T-007 menambah `modules/*/domain`.

---

## 2026-10-13 — T-004 skeleton `platform` (pool, migrasi, outbox/inbox, audit hash-chain)

**Rencana/scope**: `docs/tasks/T-004.md`.

**Bukti `./task ci`** (log penuh `.build/ci-t004.log`, exit 0):

```
$ ./task ci
== format (nimpretty)             ok: 44 berkas
== lint (nim check)               ok: 45 berkas
== archcheck                      tidak ada pelanggaran batas arsitektur
== lint-nomagic                   tidak ada magic number bisnis di domain/application
== paramgen --check               sinkron
== unit + property test           15 berkas (kernel 9, platform-lib 2, tools 4)
== integration test (Postgres)    modules/platform/tests/itplatform.nim
                                  shared/platform-lib/tests/itpool.nim
== i18n / contract / e2e          SKIP (T-010, T-008 menunggu E-001, T-010)
== CI hijau                       (153 assertion lulus, 0 gagal)
```

**Bukti langsung terhadap DB dev (`cbs_dev` via tunnel)**:

```
$ ./task dbtools migrate
dbtools migrate: 3 diterapkan, 0 dilewati (sudah ada)     # pertama kali
$ ./task dbtools migrate
dbtools migrate: 0 diterapkan, 3 dilewati (sudah ada)     # idempotent
$ ./task dbtools status
      1  platform/0001_platform_schema  sudah
      2  platform/0002_platform_audit_log  sudah
      3  platform/0003_platform_outbox_inbox  sudah
dbtools status: 3/3 diterapkan
```

Test integrasi yang lulus (14 + 7 assertion, ringkas): migrasi idempotent; checksum drift
ditolak; migrasi gagal tidak tercatat & tabelnya tidak ada (atomik); outbox de-dup `dedup_key`;
klaim `FOR UPDATE SKIP LOCKED` (IN_FLIGHT tidak diklaim ulang, `attempts` naik); backoff menunda
klaim; dead-letter setelah `maxAttempts`; re-drive; inbox de-dup per konsumen; rantai audit
terverifikasi; perusakan payload → `row_hash_ok=false`; perusakan + hash dihitung ulang →
`link_ok=false` di baris berikutnya; UPDATE/DELETE/TRUNCATE ditolak; pool: batas tunggu,
`withTx` commit/rollback, koneksi bocor bertransaksi di-ROLLBACK.

**Keputusan** (rincian `docs/DECISIONS.md` D-005…D-007, `docs/tasks/T-004.md`):

- Skrip SQL multi-pernyataan lewat `PQexec` (dbtools), query aplikasi tetap lewat `db_connector`.
- Hash rantai audit dihitung di DB (trigger + pgcrypto), payload kanonik UTC/ISO.
- `CBS_DEVDB_PERSIST` supaya tunnel dev tidak mati di tengah sesi (kejadian nyata: tunnel
  menutup setelah 10 menit idle → `Connection refused`).

**Open items baru**: O-009 (anchor harian rantai hash), O-010 (pemisahan privilege append-only),
O-011 (pool: polling + peminjaman paralel belum diuji).

**Batas jujur**: peminjaman koneksi paralel antar-thread belum diuji di CI (single-thread);
`itplatform` menghapus schema `platform` (aman hanya untuk DB dev `cbs_dev`); `CBS_DATABASE_URL`
hanya bentuk URL tanpa `sslmode`.

---

---

## 2026-10-13 — T-005 parameter framework (tabel, resolusi, maker-checker, NOTIFY, startup check)

**Rencana/scope**: `docs/tasks/T-005.md` (cakupan DB/repo; lapisan application dipisah ke T-016).

**Bukti `./task ci`** (log `.build/ci-t005.log`, exit 0):

```
$ ./task ci
== format (nimpretty)          ok: 48 berkas
== lint (nim check)            ok: 49 berkas
== archcheck / lint-nomagic    bersih
== paramgen --check            sinkron (3 definisi seed)
== unit + property test        17 berkas test (kernel 9, platform-lib 2, platform 2, tools 4)
== integration test (Postgres) itplatform.nim, itpool.nim, itparam.nim
== i18n / contract / e2e       SKIP (T-010; T-008 menunggu E-001)
== CI hijau                    (187 assertion lulus, 0 gagal)
```

**Test parameter (17, ringkas)**: seed `paramgen` dieksekusi nyata ke DB; key tak terdaftar &
scope di luar `allowed_scopes` & nilai melanggar schema ditolak; resolusi
PRODUCT→BRANCH→INSTITUTION→SEGMENT→GLOBAL dengan/tanpa tiap scope; efektif-dated (nilai
belum/sudah lewat tidak dipakai); overlap ACTIVE ditolak EXCLUDE; periode bersambung diterima;
submit→PENDING (belum terlihat aplikasi); approve→ACTIVE; self-approval ditolak DB; approve
bukan-PENDING ditolak; supersede memangkas nilai lama; reject; startup check melaporkan key
tanpa nilai aktif; NOTIFY diterima koneksi pendengar setelah approval.

**Keputusan**: `docs/DECISIONS.md` D-008 (SUPERSEDED tetap menjawab tanggal lampau + EXCLUDE
mencakup keduanya), D-009 (aturan tempat seed pack + ACTIVE oleh dua UUID sistem),
D-010 (jebakan `db_connector.getRow`).

**Bug nyata yang ketemu dan diperbaiki**: seed SQL `ARRAY[]` tanpa cast (ditolak Postgres);
`scope_id` palsu pada seed pack; gap nilai historis saat supersede (D-008);
`db_postgres.exec` menolak SELECT (dipakai untuk advisory lock → memakai `getValue`).

**Sisa pekerjaan (task baru T-016, bukan "selesai sebagian")**: cache in-proc + konsumen NOTIFY,
akses bertipe `params.get`, guard drift harian, UI Parameter Admin.

---

## Catatan proses (jujur, 2026-10-13)

1. **Commit `01094a1` tercampur.** Commit untuk spike ADR-002 memakai `git add -A` sehingga
   ikut menyeret draf `shared/kernel/**` dan `docs/migration/cbs-core-inventory.md` yang saat
   itu belum selesai. Tidak ada yang hilang, tetapi commit itu tidak lagi "satu perubahan
   logis" (AGENTS.md §3). Tidak saya tulis ulang karena rewrite history butuh persetujuan
   pemilik — dicatat di sini sebagai deviasi. Commit-commit setelahnya kembali satu-topik.
2. **Tiga percobaan subagent gagal** (T-002, T-003, T-015) dengan error `invalid request`
   dari sisi penyedia setelah prompt panjang terkirim; hanya T-015 yang akhirnya selesai
   (percobaan kedua/ketiga). Akibatnya: T-002 sempat meninggalkan `propgen.nim` versi
   berbeda + `tprop_rate.nim` yang tidak kompilasi (`out` sebagai nama variabel, API harness
   tidak cocok). Berkas itu ditulis ulang dengan harness final; `propgen.nim` subagent
   tertimpa versi final. T-003 akhirnya **tidak** dikerjakan subagent dan menjadi tanggungan
   sesi ini.
3. **Reviewer independen** (AGENTS.md §4 butir 5) belum dijalankan per task; rencananya satu
   review batch di akhir milestone atas area kritis (hash-chain audit, param framework,
   uang/rate), karena biaya dan karena task sejauh ini masih scaffolding + kernel. Keputusan
   ini dicatat supaya tidak terlihat seperti kelalaian.

## Status task

| Task | Status | Bukti ||---|---|---|
| T-001 | DONE | `./task ci` hijau; commit `5964665` |
| T-002 | DONE | `./task test kernel` → 52 assertion lulus, 0 gagal; `./task check` ok (20 berkas); grep non-komentar `float` = bersih |
| T-014 | DONE (spike) | `docs/spikes/ADR-002-http-server.md`: Mummy 54.341 rps / Prologue 46.094 / asyncnet 18.824 (`hey -n 10000 -c 50`, laptop 2026-10-13); Mummy 0.4.8 tanpa API streaming (endpoint stream → 501); keputusan menunggu E-001 |
| T-015 | DONE | `docs/migration/cbs-core-inventory.md` (600 baris). Angka kunci diverifikasi ulang dari `cbs-core`: 699 berkas Go, 370 `*_test.go`, 173 migrasi, README menyebut BPR/BPRS (bukan koperasi). 4 klaim ditandai `(belum diverifikasi)` |
| T-005 | DONE (DB/repo) | `./task ci` hijau (exit 0, `.build/ci-t005.log`): 187 assertion. 17 test parameter lulus: resolusi 5 scope, efektif-dated, EXCLUDE overlap, maker-checker (+ self-approval ditolak), supersede, startup check, NOTIFY diterima pendengar. Sisa lapisan application → T-016 |
| T-004 | DONE | `./task ci` hijau (exit 0, `.build/ci-t004.log`): 153 assertion lulus. `./task dbtools migrate` 2× = idempotent; 14 test integrasi platform + 7 test integrasi pool lulus (hash-chain tamper terdeteksi, outbox de-dup, migrasi atomik) |
| T-003 | DONE | `./task ci` hijau (exit 0, log `.build/ci-t003.log`): 29 berkas terformat, 30 `nim check`, archcheck/lint-nomagic/paramgen sinkron, 97 assertion test lulus (12 berkas). Gate dibuktikan menolak lewat probe nyata (3 temuan magic + 1 pelanggaran rule C) |
| T-007 | DONE | `./task ci` hijau: `tcalendar` 29 test + `itcalendar` 11 test lulus (kaskade EOD/EOM/EOQ/EOY, libur berulang, transisi state ilegal ditolak, CAS, rollover, mutation test `weekend_days`). Rincian: `docs/tasks/T-007.md` |
| T-016 | DONE | `./task ci` hijau: `tparamservice` 13 + `itparamservice` 6 test lulus. Cache invalid setelah NOTIFY (alur maker-checker nyata), guard drift == 0 temuan, archcheck menolak probe `import db_connector` di `application/`. Rincian: `docs/tasks/T-016.md` |
| T-011 | DONE | `tools/scaffold` + `modules/hello` hasil generate. Diverifikasi ulang di sesi ini: `./task scaffold uji-sementara --dry-run` mencetak berkas yang akan dibuat; nama tidak sah (`Hello`) & duplikat (`hello`) ditolak exit 1; `./task ci` hijau (termasuk `thello` + `tscaffold`). Dikerjakan subagent di worktree terpisah, di-cherry-pick (commit `15cd5ba`). Rincian: `docs/PROGRESS-T011.md` |
| T-006 | DONE | `./task ci` hijau: `tauthz` 19 + `tpassword` 12 + `itauth` 13 test lulus. Vektor PBKDF2 dihitung independen (Python hashlib). Audit context terisi lengkap; lockout & kebijakan dari parameter; SoD dua lapis (grant + otorisasi). Rincian: `docs/tasks/T-006.md` |
| T-013 | DONE (berkas) | `bash -n` 7/7 skrip (gate `./task check`), `audit-consistency.sh` lokal exit 0, `migrate.sh` exit 2 tanpa argumen, JSON webhook valid, tanpa secret. Belum dijalankan di server. Rincian: `docs/PROGRESS-T013.md` |

## T-007 — Kalender + business date (DONE, commit menyusul)

Scope, keputusan, dan batasan: `docs/tasks/T-007.md`. Ringkas bukti:

- Domain `modules/platform/domain/calendar.nim` + skema `0005_platform_calendar.sql`
  (`platform.holiday`, `platform.business_date`) + repo `infrastructure/calendar_repo.nim`.
- Parameter baru `platform.calendar.weekend_days` (json, GLOBAL/BRANCH) → artefak paramgen
  di-generate ulang; `./task paramgen --check` sinkron.
- `./task test tcalendar` → 29 test lulus; `./task test itcalendar` → 11 test lulus (DB dev via
  tunnel): kaskade EOD/EOM/EOQ/EOY, libur berulang tahunan, libur cabang, transisi state ilegal
  ditolak, CAS, rollover, dan mutation test param (`weekend_days` → `[5,6]` menggeser hari kerja).
- `./task ci` hijau. Dua test lama diperbaiki agar tidak mengunci jumlah migrasi (dulu hardcode
  `4`): sekarang dihitung dari `migrationsOf(root)`.
- Dua deviasi spec §9.3 dicatat di DECISIONS D-011 (setelah diuji langsung ke Postgres, bukan
  dari ingatan) dan D-012.
- Perbaikan kecil pada `tools/devdb.sh` (`psql` meneruskan argumen tambahan) dan `tools/paramgen`
  (reason seed menyebut scope sebenarnya, dulu selalu `'segment pack seed'` meski scope `GLOBAL`).

## T-013 — Artefak `ops/` (DONE, berkas saja)

Dikerjakan subagent latar (general) lalu **diverifikasi ulang sesi ini**: `bash -n` 7/7 skrip
(sekarang di-gate `./task check`), `audit-consistency.sh` mode lokal exit 0, `migrate.sh` tanpa
argumen exit 2, JSON webhook valid, scan rahasia bersih (hanya `127.0.0.1`/`CHANGE_ME`).
`shellcheck` tidak terpasang → level `error` di-gate bila tersedia, level `warning` dicatat
sebagai O-014. Laporan rinci subagent: `docs/PROGRESS-T013.md`; rencana: `docs/tasks/T-013.md`.
**Belum pernah dijalankan di server** — itu memang di luar batas task.


## T-006 — Auth + RBAC + audit context + branch scoping (DONE, commit menyusul)

Scope, keputusan, batasan: `docs/tasks/T-006.md`. Ringkas bukti:

- Skema `0006_platform_auth.sql` (`app_user`, `role`, `permission`, `role_permission`,
  `user_role` + `branch_id`, `role_conflict`, `session`); domain `authz.nim` + `scope.nim`;
  hasher PBKDF2 `password_hasher.nim`; repo `auth_repo.nim`; alur `auth_service.nim`.
- Keputusan baru: D-013 (nimcrypto/PBKDF2, **HUMAN-REVIEW-REQUIRED**), D-014 (`user` → `app_user`).
  Item baru: O-015 (MFA belum ada), O-016 (matriks SoD kosong), O-017 (tipe id cabang tidak seragam).
- Refactor kecil: `ScopeRef`/`lookupFor` dipindah ke `domain/scope.nim` (dipakai kalender + auth),
  dan aturan "tanpa fallback" parameter dikumpulkan di `param_repo.activeValueJson` (dulu hanya
  di `calendar_repo`).
- `./task test tauthz` 19, `./task test tpassword` 12, `./task test itauth` 13 — semuanya lulus;
  `./task ci` hijau.
- Dependensi baru: `nimcrypto >= 0.7.3` di `cbs.nimble` (sudah terpasang; pure Nim, tanpa lib native).


## T-016 — Layanan parameter lapisan application (DONE, commit menyusul)

Scope & keputusan: `docs/tasks/T-016.md`. Ringkas: `application/param_cache.nim`,
`application/param_service.nim` (port `ParamSource`, `get[T]` bertipe), `application/param_drift.nim`
(guard drift kode vs DB), adaptor `infrastructure/param_source_db.nim` (+ `watchParamChanges`
yang menerjemahkan NOTIFY → invalidasi cache). Nilai snapshot + aturan konversi tetap di
`domain/param.nim` (`ParamSnapshot`, `checkedSnapshot`) supaya hit cache & ambil-baru divalidasi
dengan aturan sama.

Bukti: `tparamservice` 13 test, `itparamservice` 6 test (termasuk invalidasi lewat NOTIFY nyata dan
drift == 0 setelah seed), `./task archcheck` bersih **dan** probe pelanggaran (`import
db_connector` di `application/probe_bad.nim`) benar-benar ditolak gate sebelum berkas probe
dihapus. `./task ci` hijau. Item baru: O-018 (watcher parameter belum punya thread/loop sendiri).

## T-010 — Shell aplikasi web (SvelteKit) + design token + tema + i18n + baseline a11y (DONE)

Scope & keputusan: `docs/tasks/T-010.md`. Ringkas: workspace pnpm (`apps/*`, `packages/*`),
`packages/config` (tsconfig bersama), `packages/ui` (token semantik light/dark, kelas komponen
dasar pada elemen semantik, test kontras), `packages/i18n` (katalog id/en + proyek inlang),
`apps/web` (SvelteKit 3 SPA: landmark + skip link + judul halaman + indikator business date +
kontrol tema/bahasa + live region), `tools/i18ncheck` (gate katalog §16.3), Playwright
(axe 2 tema × 2 locale + alur keyboard-only), job CI `web-e2e`.

Bukti: `./task e2e` hijau — vitest kontras 34 test, `svelte-check` 0 error/0 warning, Playwright
12 test (4 axe + 4 keyboard + 4 struktur/perilaku); `./task i18n` → `2 locale, 28 key/locale,
tidak ada temuan`; `ti18ncheck` 24 test. `./task ci` **exit 0** ("CI hijau"): format 78 berkas,
lint 79 berkas, archcheck/nomagic/paramgen bersih, bash -n 7 skrip, 23 unit + 6 integration Nim
test (311 `[OK]`), plus seluruh gate web di atas. Satu SKIP: contract test (T-008, menunggu
ADR-002/E-001).

Deviasi yang disengaja dan alasannya (detail + bukti di `docs/tasks/T-010.md`): SvelteKit 3 tanpa
`svelte.config.js` dan tanpa alias `$lib`; katalog i18n satu berkas datar per locale dengan
prefiks namespace pada key (pola `{locale}/{namespace}.json` terbukti menghasilkan nol pesan);
plugin Paraglide dari CDN versi pin; kontrol tema/bahasa berupa radio native (`<select>` tidak
dapat diubah lewat keyboard di Chromium headless sehingga tidak dapat diuji); jamak dipilih di
kode karena Paraglide v2 merusak sintaks ICU mentah.

Item baru: O-020 (lockfile JS belum bisa dibuat), O-021 (plugin Paraglide dari CDN), O-022
(visual regression ditunda), O-023 (ESLint a11y belum ada), O-024 (komponen headless menyusul).

### T-010 — lanjutan (2026-10-14): lockfile JS + plugin Paraglide lokal

Temuan lingkungan: registry npm di `~/.npmrc` (`artifactory.pegadaian.co.id`) tidak resolve
(NXDOMAIN), dan pnpm membaca `pnpm_config_registry` — bukan `npm_config_registry`. Dengan
override itu, `pnpm install` bekerja: `pnpm-lock.yaml` berhasil dibuat, lolos supply-chain policy
pnpm, dan `pnpm install --frozen-lockfile` bersih. Plugin Paraglide kini di-vendor sebagai
devDependency `packages/i18n` (tanpa CDN), sehingga build tidak butuh jaringan.

Bukti: `pnpm_config_registry=https://registry.npmjs.org/ pnpm install --lockfile-only` (159
entri, "Lockfile passes supply-chain policies"), lalu `pnpm install --frozen-lockfile` →
"Already up to date"; `./task e2e` tetap hijau (12 test + vitest 34 + svelte-check 0 error)
dengan `modules` menunjuk jalur lokal. Prosedur: `docs/runbooks/dev-web.md`.
Keputusan: D-018. Item O-020 & O-021 ditutup.

## T-008 — OpenAPI skeleton + klien TS + contract test (DONE)

Setelah keputusan ADR-002 (E-001 → Mummy + WebSocket, D-019), T-008 dikerjakan: kontrak
`packages/contracts/openapi/cbs-api.yaml` (operasi yang **sudah** dilayani saja), klien TS
(`packages/api-client`, tipe hasil generate + wrapper `openapi-fetch` + typecheck), dan binari
HTTP pertama `apps/api` (Mummy: `--role`, router dari tabel rute, `/healthz`, `/readyz`,
problem+json RFC 9457, probe DB). Tooling baru: `tools/openapi` (parity rute + validator subset
JSON Schema). Gate baru `./task openapi` + step CI `web-e2e`.

Bukti: `./task openapi` hijau (lint `--fail-severity warn`, klien sinkron, typecheck bersih);
`topenapi` 20 test, `tcontract` 4, `tapi` 6 (respons nyata vs kontrak: status, `Content-Type`,
bentuk JSON), `itapi` 2 (readiness dengan DB nyata: `database` ok). `./task ci` exit 0.
Bug nyata tertangkap smoke test: closure handler di dalam loop membuat `/healthz` melayani handler
`/readyz` — diperbaiki (`bindHandler`) dan dikunci oleh `tapi`.

Item baru: O-025 (shutdown `server.close()` crash di Mummy+ORC), O-026 (`schemathesis` belum ada),
O-027 (job CI `db-tests`/`traceability` belum ada). O-019 diperbarui: `/healthz`/`/readyz` sudah
ada (versi awal); O-013 tetap terbuka (role `migrate`/`ctl`/`worker` belum ada).

## T-009 — Realtime hub: outbox → klien WebSocket, resume token (DONE)

Peristiwa outbox kini mengalir ke UI: trigger `AFTER INSERT` di `platform.outbox` mengirim
`pg_notify('cbs_outbox', outbox_id)` (migrasi 0007); satu thread pump di `apps/api` memegang
koneksi `LISTEN`, membaca peristiwa setelah token dari tabel, lalu menyebarkannya lewat hub murni
(`modules/platform/application/realtime.nim`) ke koneksi WebSocket (`apps/api/src/events.nim`).
Kontrak: operasi `GET /api/v1/events/stream` (101/401/403/405/426/500/501) + skema amplop
`packages/contracts/events/realtime-envelope.v1.schema.json` (spec §12.4). `AppContext` dipindah ke
`apps/api/src/context.nim` agar modul fitur tidak membuat impor melingkar dengan `health`.

Bukti: `./task ci` exit 0. `trealtime` 26 test (topik, langganan, amplop, pesan kontrol, izin),
`itrealtime` 5 (INSERT → NOTIFY → pendengar → baca tabel → fanout; resume; token asing; dedup_key),
`itapi_ws` 11 dengan **klien WebSocket nyata** (`apps/api/tests/wsclient.nim`, ~170 baris, tanpa
dependensi baru): 426 tanpa upgrade, 401 tanpa identitas, 403 tanpa izin, pengiriman langsung,
`subscribed.denied` eksplisit, pesan tidak valid → frame error, unsubscribe berhenti, resume urut
(`resumed=2`), resync saat melebihi batas replay, token tak dikenal → replay dari awal. `tapi`
bertambah 1 test (rute realtime tanpa layanan → 501 sesuai kontrak).

Bug nyata yang tertangkap verifikasi: (1) topik langganan tidak diteruskan ke hub → peristiwa tidak
pernah dikirim (hanya terlihat oleh test ujung-ke-ujung); (2) `tools/openapi` bisa SIGSEGV saat
memvalidasi skema dengan properti bebas bentuk (`{}`→nil pada `additionalProperties`); (3) klien uji
"tidak pernah menerima" respons kecil karena `recv(size, timeout)` Nim menunggu seluruh `size` byte.
Test yang sempat flaky ±50% karena pump menyala terlambat (peristiwa uji dianggap riwayat)
diperbaiki dengan sinyal `pumpReady()` — bukan `sleep`.

Keputusan: D-021 (NOTIFY di INSERT, resume token `outbox_id`, pump "mulai dari sekarang", default
tolak-semua, batas protokol sebagai parameter) dan D-022 (perbaikan validator + override Spectral
yang sempit untuk respons 101). Item baru: O-028 (kuota antrean keluar per koneksi), O-029 (pump
mati belum diperiksa `/readyz`), O-030 (batas protokol belum parameter DB). O-018 sebagian
terjawab: jalur `LISTEN` kini ada di pump; invalidasi cache parameter tetap punya pompa sendiri.

## T-012 — End-to-end Fase 0: login → parameter (maker-checker) → audit → realtime di UI (DONE)

Fase 0 kini tertutup ujung-ke-ujung. HTTP layer baru (`identity.nim`, `access.nim`,
`handlers_auth/param/audit.nim`) memakai layanan yang sudah ada — `auth_service`, `param_repo`,
`audit_repo` — tanpa use case application-layer baru (D-023…D-026 untuk alasan keputusannya).
Sesi menjadi pemilik otorisasi realtime: topik dipetakan ke izin dan `*` selalu ditolak (D-024),
melunasi kebijakan "tolak semua" dari D-021. UI `/login` + `/app` berbicara same-origin lewat proxy
Vite/Caddy sehingga cookie `HttpOnly; Secure; SameSite=Strict` berlaku tanpa CORS (D-025).

Bukti: `./task ci` exit 0. Rinciannya — `itapi_auth` 15 `[OK]` (cookie, 401/403, alur
maker-checker HTTP 400/401/403/404/409, audit, dan **dua peristiwa `param.changed` nyata** lewat
klien WS); `tapi` 10 (7 rute tanpa layanan → 501 `problem+json` sesuai kontrak, pola rute, pemetaan
topik, tanpa wildcard implisit); Playwright 18 lulus termasuk `flow.spec.ts` 6 test (alur dua
konteks maker/checker dengan penanda `__guard` — nilai ACTIVE muncul di sesi maker **tanpa reload**;
audit memuat `param.submit` + alasan pengguna & `param.approve`; axe `/login` + `/app` × 2 tema
bersih); `svelte-check` 0 error; vitest kontras 34. Total 410 assertion Nim hijau.

Temuan nyata saat verifikasi: (1) `DYLD_*` tidak diwariskan ke `webServer` Playwright sehingga API
gagal memuat libpq — diperbaiki dengan me-`source` `.local/dev.env` di perintah API (D-026);
(2) proses API sisa sesi yang terputus memegang port 8099 dan memblokir run berikutnya (akar
masalah sama dengan O-025); (3) `getByLabel` juga cocok dengan seksi ber-`aria-labelledby`, jadi
pencarian label di spec dibuat eksak.

Item baru: O-031 (bootstrap user produksi — jangan ditebak di kode), O-032 (saring daftar
parameter/audit per cabang), O-033 (tautan masuk di header + penyesuaian test urutan Tab).
Laporan milestone: `docs/milestones/M0-report.md`.

### Review independen batch Fase 0 (2 ronde) — hasil & tindak lanjut

Ronde 1 (diff `5964665..1f681ac`) → **TIDAK APPROVE**, 2 MAJOR: (a) persetujuan ganda bisa lolos
(`approveValue` memeriksa status lewat SELECT, UPDATE aktivasi tanpa syarat status) dan (b)
kombinasi parameter kebijakan sesi yang sah per-key bisa membuat seluruh login gagal 500 tanpa
amplop. Keduanya diperbaiki (D-027) + test yang gagal bila penjaganya dilepas.

Ronde 2 (diff `1f681ac..a1b6dc5`) → penjaga double-approve dinyatakan **tertutup**, tetapi muncul
2 MAJOR baru pada pemeriksaan lintas-parameter: (c) jendela tanggal efektif **masa depan** — nilai
dinilai hanya pada tanggal buku hari ini, padahal `effectiveFrom` depan didukung, sehingga
kombinasi bisa menjadi tidak sah pada tanggal efektifnya (deterministik, tanpa balapan); dan (d)
balapan dua persetujuan lintas-key (satu `idle`, satu `absolut`) yang sama-sama lolos karena tidak
ada serialisasi. Diperbaiki dengan penilaian berbasis himpunan tanggal + `pg_advisory_xact_lock`
(D-028) + 2 test baru (repo & HTTP) yang gagal tanpa perbaikan itu.

Temuan MINOR/pertanyaan ronde 1–2 dicatat sebagai O-034…O-042 (tidak ditutup di sini sesuai
AGENTS.md §4 butir 6). Keputusan "percobaan ditolak tidak diaudit" dicatat di D-028.

### Review ronde 3 — 4 MAJOR (himpunan tanggal + test) ditutup

Ronde 3 memverifikasi serialisasi lintas-key **benar** dan mengakui penilaian tanggal-depan
menutup kasus paling sederhana, tetapi menemukan: (a) test HTTP tidak membedakan kode lama/baru
(kandidat 1001 sudah ditolak kode lama karena 1001 > 479), (b) cabang `committedFromDates` tidak
teruji, (c) aturan "tanggal tak dapat dinilai dilewati" bisa menelan tanggal efektif kandidat
sendiri, dan (d) baris `SUPERSEDED` ber-tanggal depan hilang dari himpunan tanggal. Semuanya
diperbaiki (D-029) dengan test yang diverifikasi **GAGAL** bila perbaikannya dikembalikan
(percobaan memasang perilaku lama sementara, lalu dikembalikan). `itauth` kini 18 test;
`itapi_auth` 18. Catatan kerangka parameter yang muncul: O-043.

### Review ronde 4 — 1 MAJOR (bukti pembeda `effectiveTo`) + 4 MINOR ditutup

Ronde 4 memverifikasi kode D-029 benar lewat mutation test-nya sendiri, tetapi menemukan test yang
tidak membedakan: mutasi "abaikan `effectiveTo`" membuat seluruh suite tetap hijau. Ditambahkan dua
test mandiri di `itauth` (periode calon & konteks scope `INSTITUTION:<id>`), keduanya diverifikasi
**GAGAL** di bawah mutasi yang bersangkutan. MINOR lain: hazard urutan test (komentar eksplisit +
test baru dibuat mandiri), nilai calon tanpa cek visibilitas scope (O-044), dan anotasi D-028
butir 5 yang sempat bertentangan dengan D-029 butir 3.

### Review ronde 5 — APPROVE

Ronde 5 memverifikasi sendiri daya tangkap dua test ronde 4 (masing-masing mutasi: tepat satu test
GAGAL, sisanya hijau), mengecek konsistensi angka dokumen (421 = 416 + 3 + 2; 37 berkas test =
27 `t*.nim` + 10 `it*.nim`), dan meng-enumerasi ulang himpunan tanggal `sessionPolicyCandidateProblem`
tanpa menemukan jendela yang belum tertutup/tercatat. **Verdict: APPROVE**, tanpa BLOCKER/MAJOR.
Dua MINOR ditangani: komentar test yang berlebihan dilunakkan, dan bentuk input tanggal rusak
(500 vs 400) ditajamkan ke O-035. Review batch Fase 0 selesai: 5 ronde (4× TIDAK APPROVE, ditutup
berurutan oleh D-027, D-028, D-029) — di dalam batas AGENTS.md §4 butir 7.

## Pasca-M0 — T-023 realtime aman-sesi (O-036) DONE

Langganan realtime kini berumur **sesi**, bukan seumur soket: pump memeriksa ulang sesi tiap klien
berkala (`defaultSessionRecheckSeconds = 5`, di luar lock hub, memakai definisi identitas sah yang
sama dengan handshake). Sesi tidak sah → amplop `error` (`REALTIME_SESSION_ENDED`) lalu soket ditutup
dan langganan dilepas, memicu jalur klien yang sudah ada untuk kembali ke login (D-030).
`TopicPolicy.sessionValid` wajib diisi dan `newEventService` gagal keras bila kosong.
Bukti: `itapi_ws` (+1 test, interval 0 → deterministik) dan `itapi_auth` (+1 test: login → WS →
logout → error + close) — keduanya GAGAL bila `sweepSessions` dilepas. Sisa batas dicatat: O-046
(izin topik tidak diperiksa ulang).

## Pasca-M0 — T-024 berhenti bersih (O-025) DONE

`cbs-api` kini memasang penangan `SIGINT`/`SIGTERM`: handler hanya menyetel flag atomik, thread
penunggu menghentikan pump realtime lalu keluar **kode 0** (D-031). `server.close()` sengaja tidak
dipakai (jalur O-025) — dan probe minimal menunjukkan SIGSEGV itu tidak reput di bentuk minimal, jadi
O-025 diperkecil menjadi soal teardown in-process, bukan penghalang deploy. Bukti: manual (`kill
-TERM` → kode 0 + port bebas) dan e2e baru `shutdown.spec.ts`; mutasi (penangan dilepas) membuat test
GAGAL. Batasan dicatat: O-047 (in-flight dipotong, belum ada drain).

## Pasca-M0 — T-025 invarian kursor outbox + test balapan dua koneksi (O-037, O-040) DONE

Invarian "transaksi penulis event outbox menulis audit lebih dulu" kini tertulis di
`modules/platform/MODULE.md` (lock rantai audit menserialkan penulis → urutan commit == urutan `seq`)
dan dijaga `modules/platform/tests/itoutboxcursor.nim`: dua koneksi nyata membuktikan penulis kedua
menunggu, plus karakterisasi bahaya bila aturan dilanggar. Harness test kini dikompilasi
`--threads:on` (sama seperti biner API), dan `itparam.nim` mendapat test balapan double-approve dua
koneksi (tepat satu pemenang). Mutasi: lock audit dilepas → test invarian GAGAL; penjaga `AND status =
'PENDING'` dilepas → test balapan GAGAL. Keputusan: D-032.

## Pasca-M0 — T-026 kontrak CLI peran proses (O-013) DONE

Biner kini benar-benar multi-role sesuai yang sudah diandalkan skrip ops: `--role=migrate [--check|--up]`
(idempoten, memakai jalur `dbtools` yang sama; `--check` keluar 1 saat ada migrasi tertunda/drift) dan
`--role=ctl verify-audit|outbox-status` (read-only; `verify-audit` keluar 1 bila rantai audit tidak
utuh). Perintah yang dikenali tapi belum ada (`ctl daycloser-status`, `worker`) keluar kode **3** dengan
alasan, bukan kode 2. `main.nim` dipagari `when isMainModule` supaya perannya bisa diuji langsung:
`apps/api/tests/itapi_roles.nim` (7 test) + runbook baru `docs/runbooks/ops-cli.md`. `migrate.sh`
disamakan: `--contract`/`--down` ditolak (kode 3) → O-048. Keputusan: D-033. Sisa: worker + freeze gate
daycloser (O-013).

## Pasca-M0 — review independen batch hardening (T-022…T-026): APPROVE

Reviewer dengan konteks bersih memeriksa diff `e710dbf..HEAD` (T-022…T-026) terhadap spec, kontrak, dan
implementasi Mummy 0.4.8. Hasil: **APPROVE**, tanpa BLOCKER dan tanpa MAJOR. Empat temuan MINOR
semuanya diperbaiki di commit lanjutan, bukan ditunda:

1. `itapi_ws`: flag sesi uji dipindah ke `Atomic[bool]` (semula `bool` global yang ditulis thread test
   dan dibaca thread pump).
2. `itoutboxcursor`: transaksi "pelanggar" dibungkus `try`/`finally` + ROLLBACK, supaya koneksi tidak
   pernah kembali ke pool dalam keadaan transaksi terbuka.
3. `main.nim`: `--role=migrate --up` **menolak** (kode 3) migrasi berpenanda `-- dbtools:destructive`
   yang belum diterapkan, dan menyebut id berkasnya (D-033 addendum, O-048).
4. `ops/scripts/migrate.sh`: argumen tambahan pada `--check`/`--up` ditolak skrip dengan pesan jelas,
   bukan diteruskan sampai keluar kode 2 yang menyesatkan.

Tambahan dari catatan "benar tapi mudah rusak": kegagalan memverifikasi sesi (DB/pool) tidak lagi
memutus langganan atau mematikan pump; soket dibiarkan dan pemeriksaan diulang pada interval berikutnya.
Ketergantungan pada detail internal Mummy dicatat sebagai O-049.

## Pasca-M0 — keputusan pemilik dicatat, penegakan `requires_approval` aktif (D-034)

Empat keputusan yang menunggu pemilik sudah diambil (15 Okt 2026) dan dicatat di D-034:
O-031 bootstrap admin (perintah sekali-jalan + wajib ganti, butuh endpoint ganti kata sandi), O-034
anti-enumerasi akun (status terkunci hanya setelah kata sandi benar + PBKDF2 tiruan), O-039
`requires_approval: false` belum boleh dipakai, dan O-012 tipe lookup eksplisit.

Yang langsung dieksekusi hari ini: **O-039**. `paramgen` menolak definisi ber-`requires_approval:
false` di batas CLI (keluar 2, pesan menyebut O-039 → gate `--check` gagal di CI). Penegakan sengaja
tidak ditaruh di parser supaya fixture yang menguji parser dan emitter ber-`false` tidak kehilangan
cakupan sebelum semantiknya diputuskan di T-016; predikatnya diuji langsung dan daya tangkapnya
diverifikasi dengan menambahkan definisi ber-`false` ke seed asli (gagal, lalu dikembalikan).

Task turunan: **T-027** (bootstrap + endpoint ganti kata sandi) dan **T-028** (kebijakan
anti-enumerasi), keduanya READY dan keduanya menandai `HUMAN-REVIEW-REQUIRED`.

## T-027 — bootstrap admin + ganti kata sandi (O-031) SELESAI

Dijalankan sesuai keputusan D-034, dengan satu temuan yang mengubah cakupan: katalog izin & role
sistem hanya ada di seed dev (`dbtools seed` tidak menerapkannya tanpa `--dev`), sehingga admin
pertama di produksi akan dibuat tanpa izin apa pun. Katalognya dipindah ke migrasi
`0008_platform_rbac_catalogue.sql` (D-035), dan seed dev disederhanakan menjadi pengguna + pemberian
role saja.

Hasil: `POST /api/v1/auth/password` (+ kontrak + klien TS), penjagaan wajib-ganti di satu tempat
(`requirePermission`, plus `sessionCanWork` untuk realtime), `ctl bootstrap-admin` sekali-jalan
(kata sandi acak CSPRNG dicetak sekali), halaman `/app/password` + guard layout `/app`, dan e2e alur
wajib-ganti (axe 2 tema).

Bukti akhir: itapi_auth 28 `[OK]`, itapi_roles 12 `[OK]`, itauth 22 `[OK]`, tparamgen 20 `[OK]`,
e2e password 3 lulus, svelte-check 0 error, i18n check lengkap, dan `./task ci` **hijau**
(450 `[OK]`, e2e 22 lulus, 109 berkas `nim check`, 9 migrasi — angka README disamakan dengan run
ini). Biner diuji langsung untuk tiap kode keluar (0/2/3) dan barisnya diperiksa di DB dev, lalu
user uji dibersihkan.

Review independen (konteks bersih) mengeluarkan CHANGES-REQUIRED dengan **satu MAJOR**: tulisan
bootstrap belum atomik (pengguna + role + audit bisa ter-commit separuh). Diperbaiki dengan
`withRoleDb(..., useTx = true)` + `pg_advisory_xact_lock` (menutup celah check-then-act
sekali-jalan), plus `PasswordPolicyError` agar pelanggaran kebijakan membatalkan transaksi alih-alih
di-commit. Semua MINOR juga dikerjakan (klaim runbook, identifier Inggris, pertanyaan i18n role →
O-053). Dua kali e2e merah di CI: tenggang 5 s untuk aksi PBKDF2, lalu tes yang berbagi keadaan user
seed — keduanya dicatat di `docs/tasks/T-027.md` sebagai pelajaran, bukan dihapus dari sejarah.

Sisa yang dicatat jujur: O-050 (percobaan kata sandi lama tidak dibatasi/diaudit), O-051 (kebijakan
kata sandi tidak terbaca UI sebelum ditolak), O-052 (kedaluwarsa/riwayat/kualitas kata sandi).
Task berikutnya yang sudah READY: **T-028** (kebijakan anti-enumerasi akun, O-034).


## Batch "Fase 0 tahan banting" (T-028…T-037)

Batch dimulai setelah permintaan pemilik: selain hijau, Fase 0 harus tidak punya celah yang
**diketahui** pada jalur kebenaran, keamanan, dan ketahanan yang memang milik Fase 0. Batas fase lain
(metrics spec §22, DR drill §9, freeze gate `daycloser` fase 3) dicatat terpisah, bukan dipaksakan
masuk.

- **T-028 DONE** (O-034 selesai): kata sandi diverifikasi lebih dulu, `locked`/`inactive` hanya
  dibalas setelah kata sandi benar, akun tak dikenal mengerjakan PBKDF2 tiruan berbiaya setara.
  Bukti: itauth 23 `[OK]` (+ uji biaya KDF yang terbukti gagal bila hash tiruannya dimatikan),
  itapi_auth 29 `[OK]`, svelte-check 0, i18n lengkap. Pesan 403 di halaman login kini spesifik
  (aman, karena 403 hanya datang setelah kata sandi benar).

- **T-029 DONE** (O-029 selesai): pump realtime menyambung ulang dengan backoff (dulu mati permanen,
  dan `sweepSessions` ikut berhenti sehingga sesi tercabut tetap hidup), titik mulai tidak di-reset
  saat menyambung ulang, putus/pulih tercatat di stderr, dan `/readyz` melaporkan `realtime`.
  Bukti: itapi_ws 13 `[OK]` (uji memutus koneksi pump dengan `pg_terminate_backend`), itapi 7 `[OK]`
  (keputusan readiness), **dua mutasi terbukti membuat uji gagal** (tanpa penyambungan ulang;
  dengan penyambungan ulang tetapi titik mulai di-reset). Lag outbox tetap O-019.

- **T-030 DONE** (O-046 selesai): langganan realtime yang sudah terbuka kini diperiksa ulang izin
  topiknya (bukan hanya sesinya). Topik yang dicabut menutup langganan (`REALTIME_FORBIDDEN`); klien
  tanpa topik dibiarkan terhubung seperti perilaku handshake. Bukti: itapi_ws 14 `[OK]`, dan uji itu
  **gagal** bila penutupan langganan dihapus (mutasi). Gate penuh batch menyusul di T-031.

- **T-032 DONE** (O-047 selesai): SIGTERM tidak lagi memotong permintaan yang sedang berjalan.
  Urutannya: tandai berhenti (`/readyz` gagal) -> tunggu permintaan selesai (batas 10 detik) ->
  hentikan pump -> keluar 0. Bukti: itapi 8 `[OK]`, e2e shutdown 2 lulus (permintaan lambatnya nyata:
  login PBKDF2 600.000 iterasi), dan test drain **gagal** bila drain dimatikan (mutasi). Batas yang
  tetap: koneksi yang belum masuk handler, dan soket realtime ditutup oleh keluarnya proses.

- **T-033 DONE** (O-011 selesai): pool diuji paralel antar-thread (8 thread pada poolSize=3 dan
  poolSize=1), dan ditemukan celah nyata — `validateOnAcquire` cuma memeriksa `pqstatus`, jadi
  koneksi yang sudah mati di server tetap diserahkan ke pemanggil (permintaan pertama setelah restart
  DB gagal `DbError`). Sekarang validasi nyata (`select 1`) di luar lock. Bukti: itpool 10 `[OK]`,
  dan uji koneksi mati **gagal** bila validasi dimatikan (mutasi).

- **T-034 DONE** (O-049 selesai): dua ketergantungan pada internal Mummy (send & close lintas-thread)
  dinyatakan di kode, versi dibatasi `>= 0.4.8 & < 0.5.0` (terverifikasi `nimble check`), dan daftar
  periksa upgrade dicatat sebagai D-037. Bukti: itapi_ws 15 `[OK]` termasuk penjaga regresi 8 klien
  diputus serentak sambil peristiwa mengalir. Catatan jujur: penjaga itu bukan uji bermutasi.

- **T-037 DONE**: `docs/ACCEPTED-LIMITS.md` (register batas: dampak, cara mendeteksi, pemilik) +
  laporan penutup. Gate penutup `./task ci-repeat 3` atas tree `c2f7172` hijau 3 putaran: 464 `[OK]`
  per putaran (1392 total), e2e 23 lulus per putaran. Satu flake e2e sebelumnya (belum dijelaskan,
  tidak berulang) tercatat di `docs/tasks/T-031.md`, dan register menyatakan tegas bahwa gate hijau
  bukan jaminan bebas flake. Sisa batch: T-035 (migrasi contract/rollback, O-048) dan T-036 (semantik
  parameter O-012/O-039) — keduanya P3, rencananya sudah memuat hasil recon, dan keduanya
  HUMAN-REVIEW-REQUIRED.

- **T-039 DONE** (D-039): seluruh identifier teknis kini KRAN — biner `kran-api`, env `KRAN_*`, kanal
  NOTIFY `kran_outbox` (migrasi baru `0009`; `0007` tidak disentuh karena checksum-nya diverifikasi),
  unit `kran-*.service`, hook `kran`, paket `@kran/*`, kelas CSS `kran-*`, localStorage `kran-theme`,
  nama berkas kontrak/spec/env/Caddyfile, kode galat `KRAN-1xxx`, direktori `/srv/qouver/apps/kran`,
  dan `application_name` DB/logger. Yang tetap: `cbs-core` (sistem lama, masih berjalan) dan
  `cbs.qouver.com` + `/cbs/*` (DNS, keputusan pemilik). Bukti: `ci-repeat 3` hijau (464 `[OK]`/putaran,
  1392 total; e2e 23/putaran), DB+role dev di-rename di server (dbtools 10/10, itapi_ws 15 `[OK]`).
- Runbook baru `docs/runbooks/deploy-setup.md`: urutan deploy key + webhook, berisi fakta server hasil
  recon (container `cbs-api` masih memegang 8095; `/srv/qouver/apps/cbs` sudah ada) dan peringatan gh
  bahwa deploy key yang ditambahkan lewat CLI terikat pada token otentikasi.

- **T-040 DONE**: deploy key + hook webhook terpasang di server (user `sachiel`), di luar repo sehingga
  dicatat tersendiri. Deploy key `~/.ssh/kran_deploy` (read-only, terdaftar id 166514836) + alias
  `github-kran`; hook `kran` di `/srv/qouver/config/webhook.json` dengan `payload-hmac-sha256` (hook
  lama sha1, sengaja tidak diwariskan) + drop-in `KRAN_GIT_URL`; hook GitHub id 698395667. Bukti:
  `ssh -T github-kran` berhasil dari server; uji bertanda tangan benar -> 200 + `kran got matched` +
  `error in exec ... no such file or directory` (wiring benar, deploy belum mungkin jalan); uji bertanda
  tangan salah -> 500 `invalid payload signatures`. Lima hook lama tidak disentuh.

- **T-035 DONE**: migrasi dua tahap (contract) + rollback skema ada di biner, menutup O-048.
  Berkas bertanda `-- dbtools:contract <alasan>` dilewati `--up` dan hanya dijalankan `--contract`
  (yang menolak jalan bila ada migrasi expand tertunda); `--down N` membatalkan N migrasi terakhir
  yang diterapkan lewat pasangan `<nama>.down.sql`, dengan seluruh pasangan diperiksa **sebelum** satu
  pun dijalankan, satu berkas = satu transaksi bersama penghapusan baris `platform.schema_migration`.
  `ops/scripts/migrate.sh` meneruskan keduanya (tetap wajib `--yes`, `--down` wajib N); `--check` tidak
  menghitung contract sebagai tertunda. Bukti: `./task ci` hijau (479 `[OK]`, e2e 23) + 9 uji unit baru
  (28), 4 uji integrasi DB baru (itplatform 18), 1 uji kontrak CLI baru (itapi_roles 13); **bukti mutasi
  13 penjagaan**, masing-masing dilepas dan ada uji yang gagal. Dua temuan soal kualitas bukti:
  `check` di dalam proc pembantu tidak menggagalkan uji (helper `expectMigrateError`/`expectPlanError`
  diperbaiki supaya melempar), dan uji atomisitas pertama tidak diskriminatif (diganti: penghapusan
  barisnya dipaksa gagal). Keputusan D-040 + runbook baru `docs/runbooks/migrasi.md`.

- **T-036 DONE**: dua keputusan pemilik yang menggantung (O-012, O-039) dilaksanakan.
  (1) Lookup scope parameter menjadi bertipe eksplisit: `ScopeValueLookup` mengembalikan
  `Option[string]`, sehingga "tidak diminta" (`none`) tidak lagi bermakna sama dengan "diminta tanpa id"
  (`some("")`) — nilai level `INSTITUTION` ber-`scope_id` NULL jadi terjangkau dari alur login, sedangkan
  id tak kosong dan tipe yang tidak diminta tidak berubah. Perubahan perilakunya dibuktikan dengan golden
  test yang dijalankan **sebelum** perubahan (hijau, memin perilaku lama) lalu harapannya dibalik, plus
  satu uji batas baru: id kosong bukan wildcard. Tidak ada fallback antar level yang ditambahkan —
  mencocokkan spec §10.2 sebagai rantai fallback adalah keputusan produk, dicatat sebagai O-056.
  (2) `requires_approval: false` diputuskan pemilik **tidak diizinkan** (setiap perubahan parameter wajib
  lewat maker-checker): penjagaan `paramgen` tetap, hanya alasannya berubah (`undefinedApprovalSemantics`
  → `disallowedApprovalSemantics`, pesan menyebut D-042). Bukti: `./task check` hijau dan `./task test`
  hijau 482 `[OK]`, 0 gagal; seluruh 8 nilai tersemai ber-scope `GLOBAL`/NULL, jadi tak ada nilai berlaku
  yang berpindah. Keputusan D-041 + D-042; sisa temuan dicatat sebagai O-057 (startup check lebih longgar
  dari resolusi). Ditandai **HUMAN-REVIEW-REQUIRED** (menyentuh nilai parameter kebijakan sesi).

## T-045/T-036 lanjutan — repo publik, CI GitHub, latihan deploy, peralihan domain (16 Okt 2026) SELESAI

Tiga hal yang belum pernah benar-benar dijalankan akhirnya dijalankan, dan ketiganya langsung
menemukan masalah yang tidak bisa dilihat gate lokal.

**CI GitHub.** Run pertama: job `Nim` dan `Security (gitleaks)` hijau, job `Web` gagal di
`pnpm exec playwright install --with-deps chromium` (`Command "playwright" not found`) — `playwright`
adalah devDependency `apps/web`, sedangkan `pnpm exec` dijalankan dari root. Sekarang lewat filternya
(`pnpm --filter @kran/web exec`); tiga run berikutnya hijau.

**Audit repo publik** (diminta pemilik, dijalankan agen review terpisah): tidak ada rahasia, private key,
DSN ber-kredensial, `.env`, data nyata, atau PII di working tree maupun seluruh riwayat; tidak ada kode
vendor pihak ketiga. Yang dilaporkan: IP VPS + user SSH ada di **71 commit** riwayat (dari default
`tools/devdb.sh` yang kini diwajibkan lewat env), detail infra produksi, tidak ada berkas LICENSE
(`kran.nimble` menyebut MIT — keputusan pemilik), dan guard seed dev hanya berupa flag `--dev`. Dicatat
sebagai O-058 (+ O-059 lock dependensi, O-060 worker, O-061 CSP).

**Latihan deploy (T-045).** Delapan kegagalan nyata berturut-turut di server, semuanya sudah diperbaiki
dan di-push: (1) host Rocky 9 tidak punya `libpq` sementara biner dibangun di image Debian → lib
di-*vendor* dari image ke `$APP_DIR/lib`; (2) deteksi perubahan memakai daftar satu-baris padahal
grep-nya `^`-anchored → build API dilewati, dan `tools/` tidak dianggap pemicu rebuild; (3)
`reportStatus` gagal di DB kosong (tabel riwayatnya belum ada) → sekarang read-only dan tahan, dengan uji
pembeda di `itplatform`; (4) gate migrasi menganggap "tertunda" sebagai kegagalan → sekarang hanya drift
yang membatalkan; (5) `pgcrypto` perlu ada sebelum checksum pertama dihitung → masuk `bootstrapSql`;
(6) ambang ukuran dump menolak dump kecil yang sah → dinilai dari isi; (7) jalur hook tidak mewarisi env
aplikasi → skrip deploy memuat env sendiri; (8) unit tidak meneruskan `--port`/`--address` padahal biner
tidak membaca `KRAN_PORT` → app memakai 8080 yang sudah dipakai container lain.

**Peralihan (D-043).** `kran-api` memegang `127.0.0.1:8095` dan `cbs.qouver.com` melayani KRAN:
`/` = 200, `/login` = 200, `/_app/version.json` = 200, `/api/v1/auth/session` = 401 bergaya KRAN, dengan
HSTS/nosniff/X-Frame-Options/Referrer-Policy/CSP. Container lama berhenti dan unit quadlet-nya di-`mask`
(berkas `.container`, `/srv/qouver/apps/cbs`, dan DB `cbs`/`cbs_verify*` tidak disentuh; rollback =
`unmask` + `start` + kembalikan upstream Caddy ke 3005). Penyebab 403/404 pertama hanyalah label SELinux
`var_t`: `restorecon` yang dijalankan sebagai root sebelum aturan `semanage fcontext` ada justru
mengembalikan label ke default — sekarang aturannya permanen (`httpd_sys_content_t`).

## Tindak lanjut audit repo publik + penutupan O-058…O-063 (16 Okt 2026) SELESAI

Keputusan pemilik dijawab dengan pekerjaan, bukan catatan: repo tetap publik, jadi yang dibereskan
adalah hal-hal yang membuat publikasi itu aman dan jujur.

**Lisensi (D-044)**: berkas `LICENSE` menyatakan proprietary/all-rights-reserved — publik untuk dibaca
dan diaudit, tanpa izin menyalin/memodifikasi/mendistribusikan/menjalankan sebagai layanan. Metadata
`kran.nimble` diubah ke `"Proprietary"`; sempat dicoba **menghapus** field itu dan Nimble menolaknya
(`Incorrect .nimble file ... does not contain a license field`), jadi field dipertahankan dengan
komentar bahwa `LICENSE` adalah sumber kebenaran. README sekarang menjelaskan status ini dan tidak lagi
memuat kontradiksi "jangan pernah push ke `main`" vs "push = deploy".

**CSP (D-045, O-061)**: `csp: { mode: "hash" }` di `apps/web/vite.config.ts` membuat Kit menerbitkan
hash ke `<meta>`. Saya cocokkan hash itu dengan SHA-256 script inline yang dihitung sendiri — identik.
Script tema di `app.html` pindah menjadi aset `static/theme.js`, karena Kit hanya menghash script
buatannya sendiri. Blok Caddy sengaja **tidak** memuat `script-src`: dua kebijakan CSP diirisan,
sehingga `script-src 'self'` di header tanpa hash justru memblokir script ber-hash milik Kit dan
halaman berhenti ter-hidrasi. Header hanya membawa `frame-ancestors 'none'`.

**Guard seed (O-062)**: `--dev` kini ditolak kecuali nama basis data di `KRAN_DATABASE_URL` berakhir
`_dev`/`_test` (fail-closed untuk URL yang tidak dikenali), keluar dengan kode 3; parsing URL dan
batasnya ditutup uji unit.

**Pin dependensi (O-059)**: dependensi dipin **persis** di `kran.nimble` (`db_connector == 0.1.0`,
`yaml == 2.2.1`, `nimcrypto == 0.7.3`, `mummy == 0.4.8`, `nim >= 2.2.0 & < 2.3.0`). Percobaan
`nimble lock` **dibatalkan** karena terbukti mematahkan build di mesin ini: dengan berkas lock,
compiler mencari dependensi di layout lokal (`nimbledeps/`) yang `nimble install -d` tidak membuat,
sehingga semua build gagal `cannot open file: mummy` — dibuktikan langsung dengan `nim check` (gagal
dengan lock, hijau tanpa). Sisa jujurnya dicatat: revisi git dependensi tidak ikut terpin.

**Insiden publikasi (O-058)**: hardening SSH dijalankan pemilik; aturan tetap — jangan menambah detail
infra baru ke repo, dan IP di riwayat diperlakukan sebagai konsekuensi permanen yang tercatat, bukan
sesuatu yang bisa dibereskan dengan mengedit berkas.

**README**: ditulis ulang untuk pembaca luar (157 baris): apa itu KRAN dan untuk siapa, sejauh mana
(Fase 0, belum ada pilot/UAT, tidak mengklaim kepatuhan apa pun), arsitektur + alasan tiap aturan, peta
direktori, penegak mekanis, perintah `./task` yang benar-benar ada, alur git, lisensi, dan bacaan
lanjutan. Tidak ada detail infra baru yang masuk; angka snapshot diberi tanggal dan batas maknanya.

Bukti: `./task ci` hijau (486 `[OK]`, Playwright 34/34, axe 23 lulus, exit 0) dan `./task check` hijau
pada pohon final.

## CSP diterapkan di produksi (16 Okt 2026) SELESAI

Blok `cbs.qouver.com` di Caddy sekarang hanya membawa `Content-Security-Policy "frame-ancestors 'none'"`
(backup: `/etc/caddy/Caddyfile.bak.kran-csp-20261016T135721`), sementara kebijakan lengkap datang dari
`<meta>` ber-hash yang diterbitkan Kit. Dua catatan dari pekerjaan ini, keduanya karena mudah salah:

- Sasaran penggantian harus **blok `cbs.qouver.com`**, bukan kemunculan pertama di berkas: berkas itu
  memuat kebijakan CSP situs lain (`qouver.com`, dengan sumber `analytics.qouver.com`) dan penggantian
  "yang pertama ketemu" akan merusak situs itu. File live sempat **tidak** tersentuh karena hal ini
  ketahuan sebelum diterapkan.
- Diverifikasi di browser sungguhan terhadap produksi (`https://cbs.qouver.com/login`): judul KRAN,
  `data-theme` dipasang `theme.js`, input kata sandi ada (hidrasi jalan), **0 pelanggaran CSP**, 0 error
  konsol. Plus header HSTS/nosniff/X-Frame-Options/Referrer-Policy tetap terkirim dan `/api/v1/auth/session`
  = 401 bergaya KRAN.

## Pasca-M0 — T-047 (O-036) DONE: register basi, tidak ada kode baru (16 Okt 2026)

`O-036` dan baris backlog `T-047` (juga duplikatnya `T-043`) masih `READY` padahal pekerjaannya sudah
selesai lebih dulu: **T-023** (`6742b2f`, D-030) memasang `TopicPolicy.sessionValid` + `sweepSessions`
berkala (interval `defaultSessionRecheckSeconds = 5`, di luar lock hub) yang menutup soket ter-subscribe
saat sesi tidak sah, dan **T-030** (`c9d290b`) menambah pemeriksaan ulang **izin** topik (O-046). Di
produksi keduanya tersambung lewat `access.nim` (`realtimePolicy.sessionValid = sessionCanWork`, resolusi
principal dari DB sehingga sesi yang dicabut/kedaluwarsa dan pengguna non-aktif tertangkap).

Karena kriteria register ("koneksi ter-subscribe ditutup; test ada di suite realtime") sudah terpenuhi,
**tidak ada kode/test yang ditulis** — mengulang T-023 akan menduplikasi perilaku yang sudah diuji.

Bukti dijalankan ulang pada tree saat ini:

- `./task test` → **486 `[OK]`, 0 `[FAILED]`**; termasuk `itapi_ws` "sesi dicabut → amplop error, soket
  ditutup, langganan dilepas" dan `itapi_auth` "logout mengakhiri stream yang sudah terbuka (O-036)".
- `./task ci` → **CI hijau** (e2e 23 lulus / 26.1s, svelte-check 0 error; `itapi_ws` O-036 suite `[OK]`).

Tindakan: `O-036` ditutup di `docs/OPEN_ITEMS.md`, `T-047` → DONE dan `T-043` → DONE (duplikat) di
`docs/BACKLOG.md`. Rencana + bukti: `docs/tasks/T-047.md`. Sisa jujur: jendela ≤ 5 detik sebelum soket
ditutup, dan biaya satu resolusi principal per klien per interval (keduanya tercatat di D-030/O-046).
Tidak ada test/gate yang dilonggarkan.

## Pasca-M0 — T-048 (O-057) DONE & T-049 (O-035) register basi (16 Okt 2026)

**T-048 (O-057): satu definisi "aktif".** `missingActiveKeys` (startup check) memakai aturan lebih
longgar daripada resolusi: `scopeId.len == 0` diperlakukan sebagai wildcard, sehingga kandidat
`INSTITUTION:<id apa pun>` sudah dianggap memenuhi padahal `resolveCandidate` menuntut id yang sama.
Sekarang fungsinya memakai **jalur yang sama** dengan pembacaan runtime
(`resolveCandidate(candidatesOf(...), lookupFor(ScopeRef(...)))`) — satu sumber kebenaran, bukan
logika salinan.

Temuan recon yang mengubah bingkai masalah: `resolveCandidate` (`domain/param.nim:67`) **selalu**
mencocokkan `GLOBAL`, jadi "GLOBAL selalu memenuhi" **bukan** kelonggaran melainkan perilaku resolusi
yang memang begitu; yang tidak konsisten hanya wildcard `scopeId` kosong. Karena itu penyelarasan ini
**tidak** membuat `GLOBAL` berhenti dianggap cukup. Fakta tambahan (penting untuk kekhawatiran
startup): `missingActiveKeys` **belum** dipanggil jalur start biner — grep seluruh repo hanya menemukan
pemakaian di `itparam.nim`, dan `main.nim` tidak memanggilnya — jadi perubahan ini tidak bisa membuat
deploy sehat sekarang menolak start (8 nilai tersemai semuanya `GLOBAL`/NULL, dan `GLOBAL` tetap
memenuhi).

Bukti: suite baru `itparam` "param: startup check = visibilitas resolusi (O-057)" dengan 2 uji. Yang
membedakan aturan lama vs baru: nilai hanya di `INSTITUTION:<id konkret>` sementara pemanggil institusi
akar → resolusi `none`, startup check melaporkan hilang. Diuji dengan fungsi **lama** dikembalikan
sementara: `./task test itparam` **GAGAL** tepat di uji itu (uji `GLOBAL` tetap `[OK]`); setelah
implementasi baru dipulihkan, keduanya `[OK]`. `./task check` hijau; `./task test` **488 `[OK]`, 0
`[FAILED]`** (naik dari 486); `./task ci` **hijau** (e2e 23 lulus / 24.2 dtk, axe 2 tema × 2 locale).

**T-049 (O-035): register basi, tanpa kode.** Semua kasus yang disebut O-035 (tanggal non-ISO,
tanggal tak ada di kalender, `scopeId` pada `GLOBAL`, kombinasi/scope tak dikenal, `paramValueId`
non-uuid) ternyata sudah tertutup sejak **T-022** — validasi di `handlers_param.nim:114`/`http_util.nim`
`isIsoDate`/`parseId` **sebelum** `withDbTx`, teruji di `itapi_auth.nim:437` (7 kasus → 400 +
`problem+json`) dan `:466` (non-uuid → 404). Pola yang sama seperti O-036/T-047 (baris backlog
tertinggal `READY`). Tidak ada kasus yang masih 500, jadi tidak ada kode/test baru dan tidak ada baris
backlog turunan.

Tindakan: `O-057` dan `O-035` ditutup di `docs/OPEN_ITEMS.md`; `T-048`/`T-049` → DONE di
`docs/BACKLOG.md`; rencana + bukti di `docs/tasks/T-048.md` dan `docs/tasks/T-049.md`. Sisa jujur:
`missingActiveKeys` belum tersambung ke start biner; resolusi masih di `infrastructure` (D-034 butir 4
/ T-016). Tidak ada test/gate yang dilonggarkan.

## Fondasi enkripsi field-level — T-054 (O-006) DONE (16 Okt 2026)

Register O-006 menyebut "KEK belum ada tempat aman"; kenyataannya mekanisme enkripsi field **belum ada
sama sekali** — tidak ada `.nim` yang menyebut `KRAN_KEK*`/`encryptField`, `KRAN_KEK_FILE` hanya komentar
di template env, `pgp_sym_encrypt` nol di migrasi (yang ada cuma masking untuk log). Pemilik memutuskan
ini bagian **fondasi** → dikerjakan sekarang, bukan menunggu data anggota nyata (menambah enkripsi setelah
baris berisi = backfill + seremoni kunci di bawah tekanan).

Yang dibangun: `shared/platform-lib/crypto/fieldcrypto.nim` — KEK di berkas terpisah mode 600
(`KRAN_KEK_FILE`), DEK per tabel **diturunkan** `HMAC-SHA256(KEK, "kran:dek:v1:"||tabel)` (tidak disimpan
di DB → tidak ada materi kunci di dump), ciphertext self-describing
`kran:enc:v1:<kid>:<nonce>:<ct||tag>` (AES-256-GCM dari nimcrypto `rijndael`+`bcmode`, **tanpa
dependensi baru**, AAD = nama tabel, nonce 96-bit CSPRNG), blind index dengan kunci turunan **terpisah**
(hex) + `normalizeDigits` untuk field angka. Aktivasi tanpa fallback senyap (O-056/D-046 butir 6):
`KRAN_KEK_FILE` kosong → start apa adanya tetapi enkripsi/dekripsi menolak eksplisit
(`NotConfiguredError`); diset → fail-fast saat startup `--role=api` (hilang/rusak/mode bukan 600/kid tidak
sah → `KekError`, exit 2). Keyring disimpan di `AppContext`. Keputusan: **ADR-017**, **D-048**; runbook
`docs/runbooks/field-encryption.md`; baris ADR-017 ditambahkan ke registri ADR spec §25.

Bukti (dijalankan, bukan diklaim):
- `./task ci` **exit 0** pada pohon gabungan: **517 `[OK]`, 0 `[FAILED]`**, e2e 23 lulus (axe 2 tema ×
  2 locale), `== CI hijau` — saya jalankan sendiri.
- `./task test fieldcrypto`: 29 `[OK]` (26 unit + 3 integrasi) — roundtrip (kosong/multibyte/100 iterasi),
  tamper 1 bit (ciphertext/tag/nonce/kid/versi), AAD lintas tabel, keyring hilang/rusak/mode, blind index,
  dan e2e tabel sementara (cari lewat blind index; ciphertext diubah di DB → gagal).
- Vektor AES-256-GCM + KDF **independen** dari Node `node:crypto` (perintah pembuatnya dicatat di header
  `tests/tfieldcrypto.nim`; nilai di-hardcode, bukan memanggil Node saat test): nimcrypto dan Node
  menghasilkan ciphertext/tag identik, termasuk plaintext kosong.
- Verifikasi saya sendiri atas modulnya: derivasi ber-domain per tabel, AAD = nama tabel, nonce CSPRNG,
  gagal dekripsi selalu `DecryptError` (tidak pernah mengembalikan plaintext/kosong), `burnMem`/`ctx.clear`,
  pesan galat tanpa materi kunci/plaintext.
- Tambahan saya: `ops/systemd/kran-api.service` diberi `RestartPreventExitStatus=2` — tanpa itu KEK yang
  salah membuat API restart-loop tiap 3 detik (`Restart=always` + exit 2 = galat permanen); worker sudah
  memakai pola ini untuk exit 3.

Sisa jujur: belum ada kolom PII yang dienkripsi (ini mekanisme; kolomnya mendarat di Fase 1) sehingga belum
ada jalur enkripsi nyata di produksi, dan `KRAN_KEK_FILE` sengaja belum diset di server (kosong = no-op,
deploy sehat sekarang tidak terpengaruh). Rotasi KEK tidak bisa independen per tabel; rotasi kunci blind
index membatalkan indeks lama (perlu reindex); normalisasi Unicode nama/alamat belum ditetapkan. Manajemen
kunci `sops`/`age` masih rencana (tercatat di O-006 sebagai sisa, bukan blocker). **HUMAN-REVIEW-REQUIRED**:
kriptografi + manajemen kunci (AGENTS.md §8) — wajib review manusia sebelum dipakai untuk data nyata.

## Pasca-M0 — T-041 (O-019) DONE: `/readyz` memeriksa migrasi & lag outbox (16 Okt 2026)

Baris register O-019 ("`/readyz` belum memeriksa migrasi/outbox lag") ternyata **sebagian** sudah basi:
handler `/healthz`/`/readyz` sudah ada sejak T-008 (+ DB/realtime T-029 + drain T-032). Yang **belum**
memang dua probe itu; keduanya dikerjakan sekarang.

Yang dibangun:
- **Probe migrasi** (`readiness.migrationProbe(pool, root)`): pakai ulang `dbtools` (`migrationsOf` +
  `pendingExpand`) lewat `appliedMigrationIds` (satu query, tanpa checksum, supaya gate deploy cepat).
  Migrasi **expand** tertunda → `csFailed`; contract/destructive tidak dihitung (sama `--check`, D-040).
  Akar repo tidak terbaca → `csOk` + `detail` eksplisit, **bukan** gagal: `/readyz` dipakai health gate
  deploy **dengan auto-rollback**, jadi fail-closed pada akar tak terkonfigurasi akan membuat deploy
  mundur tanpa henti.
- **Probe lag outbox** (`pumpLagProbe(svc, pool)`): usia peristiwa outbox tertua yang belum diproses
  pump (`outbox_repo.oldestUndeliveredSeconds`, `seq` > kursor) > `pumpLagSeconds` (30 dtk, konstanta
  teknis) → `csFailed`. `events.nim` menambah `pumpCursor` (getter ber-lock; penetapan titik mulai ikut
  di-lock). Ini rumusan "lag outbox" yang memang dipakai `docs/ACCEPTED-LIMITS.md` §2 (konsumen =
  pump; dispatcher/worker belum ada, O-013).

Bukti: `./task check` hijau; `./task test` **526 `[OK]`, 0 `[FAILED]`** (486→488 pada T-048, lalu naik
lagi oleh tugas lain + 9 uji T-041); `./task ci` **hijau** (e2e 23 lulus / 24.4 dtk). Uji baru: keputusan
murni `migrationCheck`/`pumpLagCheck` (`itapi.nim`) + probe & `/readyz` 503/200 (`itapi_ws.nim`), termasuk
lag yang dibuat deterministik (pump dinyalakan lalu dihentikan sebelum peristiwa tua ditulis).

Tindakan: `O-019` ditutup di `docs/OPEN_ITEMS.md` (dengan sisa jujur); `T-041` → DONE di `docs/BACKLOG.md`;
baris `ACCEPTED-LIMITS.md` §2 diganti residual baru; `ops/systemd/kran-api.service` diberi
`--root=/srv/qouver/apps/kran/monorepo`. Sisa jujur utama: unit server **belum tersinkron otomatis**
(deploy hanya sync `ops/scripts/*.sh`) sehingga sampai diperbarui manual, probe migrasi "tidak
diverifikasi" (tetap 200 — tidak rapuh, tapi juga belum protektif); ambang lag = konstanta teknis, bukan
parameter DB (alasan di `readiness.nim`); "lag outbox" baru mencakup pump, bukan dispatcher yang belum ada.
Tidak ada test/gate yang dilonggarkan.

## Pasca-M0 — T-042 (O-025) DONE: teardown in-process Mummy — repro deterministik + urutan aman (16 Okt 2026)

Baris register O-025 menyebut `server.close()` pada Mummy 0.4.8 + ORC pernah SIGSEGV; audit
menyatakan shutdown produksi sudah beres (T-024/D-031), sisanya teardown in-process untuk uji.
Gejala itu **berhasil direproduksi deterministik** dan penyebabnya ternyata **thread**, bukan
pool/pump/WebSocket: `destroy(true)` memanggil `=destroy(server[])` (mummy.nim:1143) di thread
pelayan, sedangkan closure handler dialokasikan thread lain — ORC menyimpan pembukuan siklus
per-thread, jadi menghancurkannya lintas-thread membaca state salah → SIGSEGV di
`orc.nim nimDecRefIsLastCyclicDyn`/`unregisterCycle`. Server minimal tak memicunya karena tak punya
closure yang dikelola ORC — itu sebabnya probe 15 Okt tidak reput.

Urutan aman: **bangun dan layani server di thread yang sama**, `close()` dari thread lain (ia hanya
memicu sinyal shutdown; `destroy` tetap di thread pelayan) → aman, termasuk dengan klien WebSocket
hidup. Uji baru `apps/api/tests/itapi_teardown.nim` menjalankan 2 siklus penuh (server + pool + pump
+ WS) lalu teardown in-process penuh (`stopPump` → `close` → `joinThread` → `pool.close()`) dan
memeriksa port benar-benar bebas.

Bukti: `./task test itapi_teardown` 2 `[OK]`; `./task check` hijau; `./task test` **528 `[OK]`,
0 `[FAILED]`**; `./task ci` hijau (e2e 23 lulus). Tindakan: `O-025` ditutup di `docs/OPEN_ITEMS.md`;
`T-042` → DONE di `docs/BACKLOG.md`; spike + `ACCEPTED-LIMITS.md` diperbarui; komentar di `tapi.nim`
diluruskan. Sisa jujur: `Server` yang sudah di-`close()` menjadi pointer menggantung; upgrade Mummy
belum diambil (pin + D-037, tak ada bukti perbaikan hulu). Tidak menyentuh jalur shutdown produksi;
tidak ada test/gate yang dilonggarkan.

## Catatan lingkungan — kenapa gate saya sempat merah (16 Okt 2026; bahan untuk T-044)

`./task ci` di pohon T-041+T-042 gagal dua kali **bukan karena kode**, dan penyebabnya sama:

1. `itapi_auth` gagal: *"connection to server at 127.0.0.1:55432 failed: server closed the connection
   unexpectedly"* → tunnel dev-DB putus di tengah run.
2. Run berikutnya: 3 test e2e timeout `toHaveURL` — `flow.spec.ts:197` (alur login→maker→checker),
   `password.spec.ts:120` (wajib ganti), `flow.spec.ts:319` (axe `/app` tema dark) — dan **total e2e
   membengkak jadi 10 menit** dari biasanya 25 detik. Ketiganya test yang butuh login → `/app`
   (membaca DB); test statis lolos. Run ketiga bahkan menggantung >30 menit di fase `check` karena
   output ter-buffer saat dialihkan, jadi tidak bisa dipakai untuk menunjuk lokasi masalah.

Setelah tunnel distabilkan (watchdog membuka ulang tiap 20 detik), semuanya kembali normal:
`./task check` exit 0 (1 m 58 s), `./task e2e` exit 0 **23 lulus dalam 25 detik**, dan unit+integrasi
dari run ci saya **528 `[OK]`, 0 `[FAILED]`**.

Pelajaran untuk T-044: sebelum menyalahkan Playwright sebagai "flake", **periksa tunnel dev-DB dulu**
(`nc -z 127.0.0.1 55432` / `./task devdb up`). Tunnel hari itu putus tiga kali; hari ini `devdb up`
hanya membuka ControlMaster `ControlPersist=7200` dan tidak ada yang membukanya kembali saat koneksi
mati. Ini juga alasan kenapa jam gate jadi tidak bisa dipegang sebagai bukti apa pun saat tunnel mati.

## T-053 — batch kecil O-042/O-045/O-030/O-033 (17 Okt 2026)

Empat butir selesai, satu dikeluarkan. Commit: `b0d33a1` (O-042 test), `3567f11` (O-045 alasan
berkode), `169a90d` (O-030 batas realtime jadi parameter), `62adb09` (O-033 tautan Masuk + D-049).

Bukti gate: `./task check` hijau; `./task test` **529 `[OK]`, 0 `[FAILED]`**; `./task e2e`
**23 lulus dalam 24,5 s**. Kelima uji O-045 yang sempat merah ternyata bukan cacat kode: tunnel
dev-DB putus di tengah run (gejala: handler mengembalikan 500 alih-alih 400/409, lalu `itapi_auth`
segfault saat teardown — batas O-025 yang sudah diterima). Setelah watchdog tunnel hidup, run ulang
hijau tanpa mengubah satu baris pun kode uji.

**O-018 dikeluarkan** dari T-053 → `T-055` (BLOCKED). Pemeriksaan menunjukkan `ParamService`/
`param_cache` tidak dipakai proses `api` sama sekali (`grep ParamService apps/api/src` = nol hasil);
`api` membaca parameter lewat `param_repo` per permintaan. Menyambungkan cache ke produksi berarti
memutuskan lebih dulu apakah `api` perlu cache lintas-proses — keputusan arsitektur, bukan batch
kecil. Menambah `LISTEN` tanpa konsumen hanya akan jadi kode mati, jadi tidak dikerjakan.

**Seed parameter produksi (disetujui pemilik).** O-030 membaca parameter saat start dengan
gagal-cepat, sementara DB produksi `kran` masih skema-saja (`param_definition=0`, `param_value=0`,
`app_user=0`) — jadi batch ini tidak boleh mendarat sebelum produksi punya parameter. Dijalankan
lewat `dbtools seed` (bukan `psql` langsung) karena tool ini **mencatat berkas yang diterapkan di
`platform.schema_migration`**; melewatinya akan membuat `status`/`--check` salah. Hasil: 10 definisi /
10 nilai, kedua kunci `platform.realtime.*` aktif GLOBAL sejak `1970-01-01`; seed ulang tetap 10/10
(idempotent). Gate migrasi deploy aman karena `--check` hanya menanyakan "apakah tiap berkas migrasi
di disk sudah tercatat", bukan sebaliknya. Catatan: `app_user` masih 0 → produksi belum bisa
mengautentikasi siapa pun sampai `--role=ctl bootstrap-admin` dijalankan (pekerjaan kesiapan pilot,
bukan bagian task ini).

**Temuan lingkungan (bahan T-050/T-044):** `./task dbtools ...` **memuat `.local/dev.env` sendiri**
(`task:36-38`), sehingga `KRAN_DATABASE_URL=... ./task dbtools` tetap menulis ke DB dev. Untuk
menargetkan DB lain, panggil biner `.build/bin/dbtools` langsung **dan** set
`DYLD_FALLBACK_LIBRARY_PATH` dari `.local/dev.env` (tanpa itu: `could not load: libpq.dylib`).
Ini jebakan yang mudah menjatuhkan operasi produksi — layak dipertimbangkan saat mengerjakan T-050.

**CI merah 9470a4c diperbaiki** (`920159c`): gitleaks menandai frasa `migrasi/outbox` di
`docs/OPEN_ITEMS.md` sebagai `generic-api-key` (entropi 3.52 vs ambang 3.5) — temuan palsu, bukan
kredensial. Repo belum punya `.gitleaks.toml`, jadi ditambahkan dengan daftar-putih **sempit** untuk
frasa itu; `docs/**` sengaja tidak dikecualikan menyeluruh agar kredensial nyata di catatan
server/log tetap ketahuan. Sintaks `[allowlist]` tunggal dipakai karena versi CI (8.24.3) mengabaikan
`[[allowlists]]` **tanpa pesan kesalahan**. Dibuktikan lokal dengan biner 8.24.3 (versi CI): tanpa
konfigurasi rentang `0891725^..9470a4c` → `leaks found: 1`; dengan konfigurasi → `no leaks found`;
rahasia palsu yang ditanam tetap terdeteksi (scanner tidak buta). Run CI `39002990740` setelah push:
ketiga job `success`, termasuk `Security (gitleaks)`.

## T-053 mendarat di produksi (17 Okt 2026)

Push `581dc60` → deploy otomatis: `.deployed_rev=581dc605b60f`, unit `active`, `/healthz` 200,
`/readyz` `{"database":"ok","migrations":"ok","realtime":"ok"}`, log deploy berakhir
"Deployment completed successfully". Ini sekaligus **bukti O-030 di produksi**: API start dengan
batas langganan dari parameter `platform.realtime.*` — tanpa seed parameter yang disetujui pemilik,
start-nya akan gagal-cepat dan health gate memundurkan deploy.

## T-056 — deploy memasang unit systemd dari repo (17 Okt 2026)

Disetujui pemilik. `sync_units()` + `restore_units()` ditambahkan ke `ops/scripts/deploy-vps.sh`
(D-050): bandingkan `cmp` → validasi `systemd-analyze verify` sebelum menimpa → cadangkan `.prev` →
pasang; jalur rollback mengembalikan `.prev` + `daemon-reload` sebelum restart.

Bukti: `bash -n` ✓, `shellcheck -S warning` bersih ✓, dan harness lokal 5/5 — pasang unit baru;
identik → tanpa aksi; berubah → `.prev` berisi isi lama; rollback → unit lama pulih; unit tidak sah →
deploy dibatalkan **dan** unit lama tetap utuh. `systemd-analyze verify` diperiksa langsung di server
(exit 0 untuk kedua unit; peringatan yang muncul berasal dari unit lain). Unit terpasang saat ini
identik dengan repo → jalur ini no-op di deploy berikutnya.

Sisa jujur: jalur "unit benar-benar berubah" dibuktikan harness, belum oleh deploy nyata.

**Catatan lingkungan:** `shellcheck` kini terpasang di mesin ini (`brew`), jadi gate `./task check`
tidak lagi turun ke `bash -n` saja — relevan untuk T-050(b).

## T-050 — CI `db-tests` + shellcheck jadi gate sungguhan (17 Okt 2026)

Bagian yang bisa dibuktikan hari ini dikerjakan; bagian yang butuh dependensi baru dipisah.

**(a) Job `db-tests`** ditambahkan ke `ci.yml`: `services: postgres:18`, `KRAN_DATABASE_URL` ke
`kran_test`, langkah `dbtools migrate` → `dbtools seed --dev` → `./task test`. Sebelum ini test
integrasi melewati dirinya sendiri di CI, jadi CI hijau tidak pernah membuktikan jalur DB.

Dua jebakan yang ditemukan saat menyusunnya (sudah didokumentasikan di `docs/ci-jobs.md`):
`dbtools seed --dev` **fail-closed** — hanya DB berakhiran `_test`/`_dev` yang diizinkan (O-062),
jadi nama `kran_ci` akan langsung gagal exit 3; dan `parseDatabaseUrl` menolak URL berquery string
(`?sslmode=require`), jadi URL harus bentuk polos. YAML divalidasi dengan ruby (empat job terbaca).

**(b) `shellcheck` level warning jadi gate** (`O-014` ditutup). Sebelumnya hanya level `error` yang
memblokir, dengan alasan "tool tidak terpasang di mesin pengembang" — alasan itu tidak berlaku lagi:
`shellcheck -S warning ops/scripts/*.sh` bersih untuk ketujuh skrip (exit 0, 0 temuan). Gate kini
juga **fail-closed**: tanpa shellcheck, `./task check` merah kecuali `KRAN_SKIP_SHELLCHECK=1`
(pelepasan sadar, bukan senyap). CI memasang shellcheck eksplisit di job `nim-check`.

Bukti harness `cmd_shlint` (fungsi diekstrak dari `./task`, cara yang sama dengan harness T-056):
tanpa tool → DIE; `KRAN_SKIP_SHELLCHECK=1` → lolos dengan pesan; skrip pemicu `SC2034` → DIE (dulu
hanya dilaporkan — inilah perubahan perilakunya); skrip ops asli → OK. `./task check` exit=0 dengan
baris `ok: 7 skrip lolos bash -n + shellcheck (level warning)`.

**(c) ESLint (`O-023`) tidak dikerjakan** → `T-057` (BLOCKED, butuh keputusan pemilik). Koreksi
catatan lama: hambatannya **bukan** tooling — `pnpm` berjalan di mesin ini. Faktanya `eslint` dan
`eslint-plugin-svelte` tidak ada di `pnpm-lock.yaml` (empat kemunculan "eslint" di sana hanya
metadata peer `@typescript-eslint/types`), dan `packages/config/package.json` sudah mengekspor
`./eslint` → `eslint.js` yang belum pernah ditulis. Menambahkannya berarti dependensi baru + ADR
(AGENTS §1.6), jadi dipisah, bukan diselundupkan ke task ini.

Sisa `O-027`: job `traceability` (requirement ↔ kontrol/test) masih belum ada — dicatat di barisnya
sendiri supaya tidak terlihat selesai.

**Bukti CI (17 Okt 2026).** Run `39004290391` (commit `9b35fe5`) **sukses keempat job**, termasuk
`DB (integrasi, Postgres 18)` — jadi test integrasi benar-benar berjalan di CI untuk pertama kalinya,
bukan hanya di mesin dev. Sekaligus deploy `9b35fe5` mendarat: `.deployed_rev=9b35fe5f22dc`, unit
`active`, `/healthz` 200, `/readyz` semua `ok`; log deploy memperlihatkan `sync_units` berjalan tanpa
satu pun baris perubahan unit — no-op yang memang diharapkan karena unit terpasang identik dengan
repo. Itu jejak pertama kode T-056 di produksi.

## Dua keputusan tertunda + satu cacat gate yang ditemukan sekalian (17 Okt 2026)

Dua baris `BLOCKED` yang menunggu keputusan pemilik diselesaikan dengan analisis ahli (dua subagent
read-only: tooling/a11y dan arsitektur platform) yang klaim kuncinya saya periksa sendiri di kode —
satu klaim bahkan **salah** (`i18ncheck` ternyata juga memeriksa string hardcode yang jelas di
komponen, `tools/i18ncheck/lib.nim:2`), jadi tidak ada item palsu yang tercatat.

**T-055 / O-018 — parameter: cache atau baca per permintaan? → dibaca per permintaan (D-052).**
Bukti yang mengubah sifat pertanyaan: `settingsOf` (`auth_service.nim:50-65`) = 6 pembacaan
baris-tunggal dan hanya di jalur auth (`handlers_auth.nim:64/115/179`), bukan per permintaan umum;
tabel parameter puluhan baris (10 definisi di DB dev); indeks parsial `param_value_lookup_idx`
memang tidak menopang query resolusi (`status IN ('ACTIVE','SUPERSEDED')` vs predikat
`WHERE status='ACTIVE'`) tetapi tak terasa pada skala itu. Opsi cache diberatkan `param_cache` tanpa
TTL + `NOTIFY` yang tak dijamin sampai → kelas bug "nilai basi tanpa error" di jalur keamanan.
Pemicu tinjau ulang terukur dicatat di D-052 supaya keputusan ini bisa dibatalkan dengan bukti.

**T-057 / O-023 — ESLint → tidak sekarang; celah a11y ditutup tanpa dependensi baru (D-053).**
Celah nyatanya bukan "tidak ada ESLint", melainkan "warning a11y tidak pernah memblokir". Buktinya
empiris: dengan `<img src="/x.png">` tanpa `alt` yang ditanam sementara, `svelte-check` **tanpa**
`--fail-on-warnings` → `exit=0` (warning lolos), **dengan** flag itu → `exit=1` dengan pesan
`a11y_missing_attribute` yang sama. Probe dihapus, `git status` bersih. Setelah diaktifkan: `0 error,
0 warning` (baris gate: `ok: 0 error, 0 warning`). Sisa O-023 dipersempit ke lint statis generik (`svelte/*` non-a11y, `typescript-eslint`)
dan dijadwalkan bersama T-012; batasannya (minimumReleaseAge, `typescript-eslint` wajib, job
`nim-check` tanpa `pnpm install`) sudah dicatat di `docs/tasks/T-057.md` supaya tidak ditemukan ulang.

**Cacat gate yang ditemukan saat verifikasi (D-054).** `./task e2e` merah pada run lokal kedua:
assertion audit di `flow.spec.ts:238` tanpa `.first()` menemukan 2 baris. Penyebabnya deterministik,
bukan flake: `platform.audit_log` append-only (terbukti — `DELETE` ditolak trigger
`audit_log_immutable`), jadi tiap run menambah satu baris beralasan identik; tiga baris yang diperiksa
punya `audit_id`/`recorded_at`/`request_id` berbeda semua → akumulasi antar-run, bukan dobel-tulis.
CI tidak pernah melihatnya karena selalu mulai dari DB kosong. Diperbaiki dengan `.first()`
(konsisten dengan baris 239 di berkas yang sama) — **bukan** pelonggaran: tidak ada assertion yang
dihapus, tidak ada ambang diturunkan. Bukti: `./task e2e` **dua run berturut-turut** `23 passed`,
`exit=0` (25,2 s dan 29,9 s), sementara baris audit tetap berakumulasi (5).

Catatan lingkungan jujur: run lokal pertama bahkan tidak sampai ke Playwright karena port 4173
(patok keras di `apps/web/playwright.config.ts:12`) dipegang `vite preview` dari repo lain; setelah
proses itu dihentikan atas izin pemilik, barulah cacat D-054 terlihat.

## Pasca-M0 — T-051 bagian authz (O-032 + O-044/D-047): SELESAI, T-051 belum DONE (D-055)

Keputusan pemilik D-046 butir 6 dan D-047 dijalankan pada jalur baca/tulis parameter. Aturan "grant
mana menutupi scope mana" sekarang hidup satu kali (`readableScopeFilter` di
`modules/platform/domain/authz.nim`); `mayReadScope` diturunkan dari padanya dan repo hanya
menerjemahkan hasilnya ke SQL. `paramValueRows`/`listAudit` menerima `ScopeFilter` dan menyaring **di
query** — bukan setelah `LIMIT`, supaya halaman tidak terisi baris yang tidak boleh dilihat. Pengajuan
nilai memeriksa wewenang baca scope pengaju lebih dulu → `403 scope_not_readable` (PRODUCT/SEGMENT/ROLE
gagal-tertutup: belum ada model keanggotaannya). Pembacaan cabang di luar cabang tugas pemanggil
meninggalkan entri audit `param.read_cross_branch` per cabang.

Bukti (semua `exit=0`): `./task test tauthz` (10 test murni baru), `itparam` (suite "visibilitas daftar
per scope", termasuk baris PRODUCT yang tetap gagal-tertutup dan bukti bahwa `LIMIT` berlaku setelah
penyaringan), `itplatform` (suite "daftar audit — visibilitas per cabang", 3 test), `itapi_auth` (403
`scope_not_readable` + nilai BRANCH lewat maker-checker + jejak `param.read_cross_branch` di DB);
`./task check` hijau (setelah `./task fmt`), dan `./task test` penuh hijau — 542 `[OK]`, 0 FAILED.
Invariannya masuk `modules/platform/MODULE.md` (param #10); dua batasan jujurnya masuk
`docs/ACCEPTED-LIMITS.md`.

Dua temuan yang tidak boleh disamarkan, keduanya dicatat di D-055 dan OPEN_ITEMS O-032:

1. **Penyaringan audit belum berefek hari ini.** `auditContextFor` tidak mengisi `branchIds`, jadi
   setiap baris audit dari jalur HTTP `branch_id` NULL (diperiksa di DB dev: 54 baris, 0 bercabang) dan
   terbaca sebagai tingkat institusi. Aturannya diuji di lapis repo dengan konteks yang memang membawa
   cabang — satu-satunya cara mengujinya sekarang.
2. **Grant khusus cabang belum bisa memakai endpoint HTTP mana pun.** `authorized` memeriksa dengan
   `targetBranch = ""` (`access.nim:82-90`), sehingga aturan visibilitas yang benar ini belum punya
   efek di produksi. Menyalakan scoping cabang mengubah perilaku secara luas → keputusan pemilik, bukan
   diselipkan ke T-051.

Sisa T-051: O-043 (`effectiveTo` tanpa penerus), O-052 (parameter kata sandi + riwayat hash), O-050
(audit + batas percobaan kata sandi lama). Bagian authz ditandai `HUMAN-REVIEW-REQUIRED` sampai
reviewer menyatakan APPROVE.


## Pasca-M0 — T-051 bagian O-043: SELESAI (D-056)

**17 Okt 2026.** `effectiveTo` tanpa penerus sekarang **ditolak**, bukan diterima apa adanya
(O-043, keputusan pemilik D-046 butir 8).

Yang mendarat:

- `param_repo.effectiveToGapProblem` — satu vonis: penerus harus baris (key, scope) sama, berstatus
  `ACTIVE`/`SUPERSEDED`/`PENDING`, mulai pada atau setelah `effective_from` kandidat, dan berlaku pada
  tanggal `effectiveTo`. Batas `effective_from` itu disengaja: persetujuan memangkas nilai ACTIVE yang
  mulai lebih awal, jadi nilai lama yang masih terbuka **bukan** penerus (kasus pembeda yang dikunci
  test).
- Ditegakkan di dua pintu, pola yang sama dengan pemeriksaan lintas-parameter: pengajuan → 400
  `effective_to_without_successor`; persetujuan → 409 alasan sama (penerus bisa hilang di antara
  keduanya).

Bukti (semua `exit=0`): `./task test itparam` (suite "effectiveTo tanpa penerus", 5 test) dan
`./task test itapi_auth` (suite "akhir periode tanpa penerus lewat HTTP": 400 menolak, kontrol 201
dengan penerus yang sudah diajukan, 409 saat penerus hilang sebelum persetujuan); `./task check` hijau.

Sisa yang tidak dianggap selesai: penanda eksplisit "nilai ini memang berakhir" belum dibuat (O-064),
dan tidak ada endpoint HTTP untuk menolak pengajuan (O-065) — karena itu jendela sisa "penerus ditolak
setelah persetujuan" hanya bisa datang dari operasi DB langsung, dengan startup check O-057 sebagai
backstop. Invarian di `MODULE.md` param #11, batas di `ACCEPTED-LIMITS.md`.

**Gate penuh tidak hijau di laptop, dan itu bukan kode ini.** `./task test` gagal di `itpool`
(`PoolError: timeout menunggu koneksi DB`) dan `./task e2e` gagal 2 spec (timeout UI). **Kontrol**:
perubahan ini di-`git stash` → pada pohon bersih `itpool` gagal dengan pola sama dan `e2e` lebih buruk
(4 gagal). Penyebab terukur: RTT ke VPS ~150 ms, tiap pemanggilan `psql` lewat tunnel ~0,8 s, sedangkan
`itpool` menunggu 15 s dan Playwright 10–30 s. Dicatat di `ACCEPTED-LIMITS.md`; bukti gate penuh
diambil dari CI (`db-tests` + `web-e2e` memakai Postgres runner sendiri).

Sisa T-051: O-052 (parameter kata sandi + riwayat hash), O-050 (audit + batas percobaan kata sandi
lama). Bagian authz ditandai `HUMAN-REVIEW-REQUIRED`.

## Pasca-M0 — T-051 bagian O-050: SELESAI (D-057)

**17 Okt 2026.** Percobaan kata sandi lama yang salah di `POST /api/v1/auth/password` tidak lagi
senyap (O-050, D-046 butir 8). 403 `old_password_mismatch` tetap, tetapi sekarang **dihitung** dan
**tercatat**.

Yang mendarat:

- `changePassword` memakai penghitung gagal yang **sama** dengan login (`recordLoginFailure`) dengan
  angka dari parameter yang sudah ada (`max_failed_logins`, `lockout_minutes`) — tanpa parameter atau
  kebijakan kedua. Login yang berhasil tetap mengosongkannya, jadi batasnya "N kegagalan beruntun,
  apa pun jenisnya".
- Audit `user.password_change.failure`: `reason`, `failed_attempts`, `status` — tidak pernah bahan
  kata sandi. Sesi yang sedang dipakai tetap tidak dicabut (salah ketik bukan alasan mengeluarkan
  orang).
- Dua bantahan yang diperiksa sebelum memilih mekanisme bersama (D-057 butir 2): DoS "kunci akun
  korban" **tidak** bertambah — itu sudah bisa dipicu siapa pun lewat login gagal tanpa sesi; dan
  peringatan `Risiko` di `T-051.md` soal mencampur semantik penghitung dijawab dengan definisi
  eksplisit (kegagalan pembuktian kredensial beruntun), bukan kemiripan kolom.

Bukti (semua `exit=0`): `./task test itapi_auth` (2 test baru: penghitung + audit; akun terkunci
sampai batas parameter lalu login berikutnya ditolak 403 `locked`), `./task test itauth` (23 test),
`./task test itplatform` (22 test), `./task fmt`, `./task check`.

Temuan saat uji: batas terkunci harus dibaca lewat `activeParamInt` + `lookupFor` (resolusi server),
bukan query `status = 'ACTIVE'` — query naif itu mengambil baris sembarang saat ada beberapa baris
ACTIVE ber-tanggal dan terbaca 7 padahal nilai efektifnya 6.

Sisa T-051: O-052 (parameter kebijakan kata sandi + riwayat hash 5 + kualitas dari parameter).

## Pasca-M0 — T-051 bagian O-052: SELESAI (D-058)

**17 Okt 2026.** Kebijakan kata sandi lanjutan sesuai D-046 butir 8: kualitas **sebagai parameter**,
riwayat 5, dan **tanpa** kedaluwarsa — yang terakhir itu keputusan pemilik, bukan kekurangan yang
menunggu dikerjakan.

Yang mendarat:

- Dua parameter lewat `paramgen` (bukan SQL manual): `platform.security.password_min_classes` (base 3,
  1..4) dan `platform.security.password_history_count` (base 5, 0..24). `min_classes = 1` berarti hanya
  panjang yang mengikat, jadi institusi yang tidak menginginkan aturan keragaman cukup menurunkan
  parameternya.
- Migrasi `0010_platform_password_history.sql` + `auth_repo.supersededPasswordHashes` /
  `recordSupersededPassword`: tabel menyimpan hash yang **sudah digantikan** saja, dipangkas ke N
  terakhir di jalur tulis (tanpa tugas terjadwal). Hash yang sedang berlaku tetap tunggal di
  `app_user.password_hash`.
- Domain: `passwordClasses` (huruf kecil/besar/angka/simbol) dan `passwordProblems(minLength,
  minClasses, …)` dengan alasan baru `TOO_SIMPLE`/`REUSED`; `changePassword` memeriksa riwayat
  **setelah** bentuknya lolos — PBKDF2 tidak dijalankan untuk kata sandi yang toh ditolak.
- Akun yang belum punya baris riwayat (hasil `ctl bootstrap-admin`) tetap tidak bisa "ganti" ke kata
  sandi yang sama, karena pemeriksaan selalu menyertakan hash yang berlaku.
- `ctl bootstrap-admin` kini harus menghasilkan kata sandi yang lolos kebijakan institusi, dan
  generatornya **menjamin** kelas karakter yang dituntut — tanpa itu, kebijakan baru bisa mematikan
  perintah penyelamat itu sendiri, persis saat tidak ada jalan masuk lain.
- Kedaluwarsa tidak dibangun; yang ada justru test yang menahannya (kata sandi berumur lima tahun
  tetap bisa dipakai, `itauth`).

Bukti (semua `exit=0`): `./task fmt`, `./task check` (format/lint/archcheck/nomagic/paramgen/i18n/
shellcheck), `./task test tauthz`, `./task test itauth` (**25 OK**), `./task test itapi_auth`
(**38 OK** — termasuk tiga jalur lewat HTTP: kata sandi yang berlaku, kata sandi yang ada di riwayat,
dan kontrol yang belum pernah dipakai), `./task test itparam`, `./task test itplatform`. Ditandai
`HUMAN-REVIEW-REQUIRED` (penyimpanan hash kata sandi, AGENTS.md §8).

**Prasyarat produksi yang belum terpenuhi (butuh pemilik).** Parameter dibaca tanpa fallback
(D-046 butir 5), dan `ops/scripts/deploy-vps.sh` **tidak** menerapkan seed pack — hanya migrasi. Jadi
selama `dbtools seed` belum dijalankan pada DB produksi (12 definisi / 12 nilai), kode ini akan
gagal-cepat di jalur login, dan health gate deploy tidak melihatnya (ia memeriksa `/readyz`, bukan
login). Jalur manual ini sudah pernah ditempuh untuk O-030 (T-053) dengan persetujuan pemilik; celah
strukturalnya dicatat sebagai **O-066** dan tidak dikerjakan diam-diam di sini.

Sisa T-051: **tidak ada** — O-032/O-044, O-043, O-050, O-052 selesai. Yang tertinggal hanya tinjauan
reviewer (dan O-066).

## T-051 mendarat di produksi + review independen ronde 1 (17 Okt 2026)

**Yang berubah sejak catatan di atas:** seed produksi **sudah dijalankan** (persetujuan pemilik) —
`dbtools --root . seed` → 2 berkas diterapkan, 10 → **12 definisi / 12 nilai**; `password_min_classes = 3`
dan `password_history_count = 5` aktif. Kode lalu dipush (`784e8da..9e08370` → `main`, D-044) dan
deploy terverifikasi di server: `.deployed_rev = 9e08370…`, unit `kran-api` `active`, migrasi
`0010_platform_password_history` diterapkan (tabel `platform.user_password_history` ada,
`platform.schema_migration` 10 → 11 baris). CI `main` run **39036108214 hijau** (Nim, DB integrasi,
Web svelte-check+axe+Playwright, Security/gitleaks). Smoke produksi: `/` 200, `/readyz` 200,
`/api/v1/params` 401. Jadi kalimat "selama seed belum dijalankan…" di atas sudah tidak berlaku; yang
tetap terbuka adalah **O-066** (seed pack bukan bagian jalur deploy → parameter berikutnya butuh langkah
manual lagi).

**Review independen ronde 1 (konteks bersih, diff `56a988b..9e08370`): APPROVE**, tanpa BLOCKER/MAJOR,
5 MINOR + 2 pertanyaan. Reviewer memverifikasi sendiri hal yang saya minta: test O-050/O-052 **gagal**
bila logikanya dihapus (bukan test yang selalu lolos).

Perbaikan yang dikerjakan dari temuan itu (bukti di `docs/tasks/T-051.md`):

- `randomPassword` kini **menjamin** kelas karakter yang dituntut (satu wakil per kelas di posisi tetap)
  — sebelumnya ~0,4% kata sandi panjang 20 keluar tanpa angka saat `minClasses = 3`, dan `bootstrap-admin`
  gagal tepat saat tidak ada jalan masuk lain. Ada test unit baru di `apps/api/tests/tapi.nim`.
- Rasional `PENDING`/EXCLUDE yang **salah** dikoreksi di empat tempat (`param_repo.nim`, `MODULE.md`,
  D-056 butir 3, komentar test `itapi_auth`): menyetujui penerus lebih dulu memang **bisa**; yang benar,
  urutan itu memangkas nilai lama sampai `effective_from` penerus sehingga nilai terbatas di rentang itu
  tidak bisa lagi diaktifkan.
- Dua kode alasan baru (`effective_to_without_successor`, `scope_not_readable`) masuk deskripsi OpenAPI,
  klien TS di-regenerate, dan dipetakan ke pesan i18n id+en lewat `errors.ts`.

Gate lokal yang dijalankan untuk commit ini: `./task check` hijau, `./task test tapi` (tapi + itapi*,
tunnel dev DB) `exit=0`, `./task openapi` hijau, `./task i18n` hijau (115 key/locale), paraglide +
`svelte-check --fail-on-warnings` 0 error/0 warning. Playwright lokal tidak dijalankan (alasan sama
seperti `ACCEPTED-LIMITS.md`); CI yang jadi sinyalnya.

Ditunda dengan catatan: **O-067** (penerus wajib satu scope — lebih ketat dari kebutuhan) dan **O-068**
(PBKDF2 kini 1+N+1 derivasi; klaim lama "dua kali per permintaan" tidak lagi utuh). Insiden kecil hari
ini: kata sandi peran DB produksi terbaca saat operasi seed karena redaksi `sed` gagal — dilaporkan ke
pemilik dengan saran rotasi; nilainya tidak ditulis di repo.

## Ops produksi 17 Okt 2026 — rotasi sandi peran DB + bootstrap admin (blocker pilot ditutup)

Diminta langsung oleh pemilik ("jalankan semua"), di luar daftar task Fase 0. Host `43.133.148.191`,
unit user `kran-api`/`kran-worker`, env `…/apps/kran/env/kran-prod.env`.

1. **Rotasi sandi peran `kran_app`** (sandi lamanya terbaca di sesi 17 Okt karena redaksi `sed` gagal):
   `ALTER ROLE … PASSWORD` dikirim lewat **stdin** `podman exec -i` (tidak lewat argv), URL di berkas
   env diganti di tempat, unit di-restart. Bukti setelah perbaikan: `kran-api=active`, `/readyz` **200**,
   `pg_stat_activity` → `kran_app`, `kran-api --role=migrate --check` → `11/11 diterapkan, 0 isinya
   berubah` (exit 0). `.local/prod.env` ikut diperbarui (URL tunnel `127.0.0.1:55432`).
   **Insiden (jujur)**: percobaan pertama menggandakan prefix `KRAN_DATABASE_URL=` di berkas env
   (kesalahan saya: `${OLD_URL}` sudah memuat nama kunci), API gagal start **±1 menit** (`/readyz` 000).
   Diperbaiki di langkah berikutnya; cadangan berisi sandi lama dihapus setelah `readyz` 200. Celah
   prosedurnya dicatat sebagai **O-069**.
2. **Bootstrap admin produksi**: `kran-api --role=ctl bootstrap-admin --username=admin` → exit 0. Kata
   sandi awal **tidak** masuk catatan ini; tertulis di berkas mode 600
   `/srv/qouver/apps/kran/bootstrap-admin.txt`. Uji masuk dari server (sandi dibaca dari berkas, tidak
   pernah dicetak): `POST /api/v1/auth/login` → **200**. Tindak lanjut pemilik: masuk sebagai `admin`,
   ganti sandi saat diminta, lalu **hapus berkas itu**.
3. **Bukan insiden**: `kran-worker` berstatus `failed` memang begitu di Fase 0 (`--role=worker` keluar 3,
   `RestartPreventExitStatus=3`, O-013) — diperiksa, jurnal bersih, tidak ada banjir restart.

Keputusan lanjutan dari sesi yang sama: **D-059** (scoping cabang diaktifkan di jalur HTTP → task
**T-058**) dan **D-060** (O-009 ditunda; **T-052** dipersempit ke O-038).

## T-052 (O-038) — verifikasi rantai audit tahan urutan commit (17 Okt 2026)

Aturan verifikasi rantai dipindahkan dari urutan `seq` ke `prev_hash` (migrasi
`0011_platform_audit_verify_prev_hash.sql`), sehingga keadaan **sah** yang dulu dilaporkan rusak
(dua transaksi bersisipan) tidak lagi jadi alarm palsu — tanpa melemahkan deteksi perusakan.
Keputusan: **D-061**; O-038 ditutup.

- **Reproduksi deterministik** (sebelumnya hanya "potensi"): jendela antara alokasi identity dan
  advisory lock diperlebar dengan trigger uji (2,5 s) → baris ber-`seq` kecil merantai ke hash baris
  ber-`seq` besar, sementara 85/85 baris tetap terjangkau dari genesis (rantai **linear**, bukan
  putus). Suite baru di `modules/platform/tests/itplatform.nim` memakai mekanisme yang sama; jendelanya
  ditunggu lewat jabat tangan `pg_stat_activity` (`application_name` worker), bukan `sleep` tetap.
- **Review independen**: putaran 1 **CHANGES-REQUIRED** — MAJOR: versi pertama aturan baru kehilangan
  deteksi rantai **bercabang** yang dimiliki pola lama. Perbaikan: `link_ok` mensyaratkan juga "tidak
  ada baris lain ber-`prev_hash` sama" (indeks `audit_log_prev_hash_idx`), dengan test yang **gagal**
  bila syarat itu dicabut. Putaran 2 **APPROVE**; satu MINOR (race `PgSleep`) ikut diperbaiki.
- **Bukti**: `./task test itplatform` → 24 `[OK]`, exit 0; `./task test itapi_auth` → 38 `[OK]`, exit 0;
  `./task test itapi_roles` → 13 `[OK]`, exit 0 (kontrak `ctl verify-audit` vs `verifyChain`);
  `./task check` hijau. Test perusakan lama **tidak diubah** dan tetap lulus.
- **Batas yang tetap berlaku** (ditulis di migrasi + `modules/platform/MODULE.md`): siklus tanpa
  genesis (membuatnya butuh titik tetap fungsi hash) dan penulisan ulang seluruh ekor rantai oleh
  penyerang ber-hak-tulis-penuh (O-009, ditunda D-060).
- **Catatan lingkungan (bukan regresi)**: dua kali test terdampak gagal karena tunnel dev mati di
  tengah jalan (`ControlPersist=600` → master ssh keluar setelah ±10 menit tanpa klien), gejalanya
  "connection refused/closed" pada `127.0.0.1:55432`. Dijalankan ulang dengan
  `KRAN_DEVDB_PERSIST=86400` sesuai `docs/runbooks/dev-db.md` §"Umur tunnel".
- **CI + produksi (18 Okt 2026)**: CI run `39051572992` untuk `6c0fa71` — 4/4 job hijau (Nim, DB
  integrasi Postgres 18, Web svelte-check+axe+Playwright, Security/gitleaks). Deploy webhook selesai:
  `.deployed_rev` = `6c0fa71`, `kran-api` aktif, `/readyz` 200. Bukti migrasi benar-benar jalan di DB
  produksi: indeks `audit_log_hash_idx` **dan** `audit_log_prev_hash_idx` ada, dan
  `pg_get_functiondef('platform.audit_verify')` memuat predikat `c.prev_hash = a.prev_hash`;
  `kran-api --role=ctl verify-audit` → "rantai audit utuh (2 entri)", exit 0.

## T-058 — scoping cabang di jalur HTTP (O-032 ditutup, 19 Okt 2026)

Menutup dua sisa temuan D-055: baris audit dari jalur HTTP tak pernah ber-cabang
(`auditContextFor` tidak mengisi `branchIds`) dan grant khusus cabang tak pernah cocok
(`authorized` memakai `targetBranch = ""`). Keputusan: **D-062** (ditulis agen sesuai mandat D-059,
pemilik menjawab "lanjut" tanpa menjawab tiga pertanyaan detailnya → task tetap
`HUMAN-REVIEW-REQUIRED (authz)`); O-032 ditutup, sisa yang jujur dipisah ke O-017 (pengenal cabang
non-uuid tak bisa diatribusi) dan O-070 (langganan realtime belum disaring per cabang).

- **Bentuk perbaikannya: gerbang izin dua tingkat.** Rute daftar memakai `authorizeAnyBranch`
  (`requirePermission`) — izin cukup dipegang di suatu cabang, penyaringan **per baris** yang
  menentukan apa yang terlihat; rute yang menyentuh **satu** objek menambah `authorizedAtBranch`
  dengan cabang objek itu (pengajuan: `scopeId` ber-scope `BRANCH`; persetujuan: cabang baris PENDING,
  diperiksa **sebelum** alasan 409). `targetBranch = ""` selalu berarti institusi, jadi grant khusus
  cabang tidak diam-diam jadi izin institusi. Atribusi audit mengikuti **objek** yang disentuh (nilai
  parameter; cabang yang dibaca untuk `param.read_cross_branch`) — bukan cabang tugas pelaku: auditor
  cabang itulah yang berkepentingan, termasuk saat pusat yang membaca. Realtime sengaja **tetap**
  institusi (fail-closed) sampai peristiwanya disaring per cabang → O-070.
- **Bukti**: `./task test tauthz` 29 `[OK]`, `itapi_auth` **43** `[OK]` (5 test suite baru, dari 38),
  `itparam` 34, `itplatform` 24, `itapi_roles` 13 (butuh `./task dbtools seed --dev` lebih dulu),
  `./task check` exit 0, `./task openapi` exit 0 (klien TS diregenerasi), svelte-check 0 error/0 warning.
- **Review independen**: putaran 1 `CHANGES-REQUIRED` — BLOCKER: klien TS tidak diregenerasi setelah
  prosa kontrak berubah (`./task openapi` merah → CI merah); MAJOR: test HTTP atribusi
  `param.read_cross_branch` belum ada, jadi klaim atribusi tak terbukti (uji lama memakai cabang
  non-uuid sehingga jalur baru tak pernah dieksekusi); tiga MINOR (pesan 403 cabang kosong untuk aksi
  institusi, kode alasan tanpa entri i18n, status task/PROGRESS). Semuanya diperbaiki; **putaran 2
  APPROVE** (reviewer memverifikasi sendiri dengan menjalankan `./task openapi`, `itapi_auth`,
  `tauthz`, `check`, `i18n`, dan menelusuri seluruh pemanggil `requirePermission`). Satu MINOR
  bookkeeping putaran 2 (status BACKLOG vs berkas task) diselaraskan ke `VERIFIKASI (menunggu CI)`.
- **CI + produksi (19 Okt 2026)**: CI run `39186325331` untuk `47af256` — 4/4 job hijau (Nim, DB
  integrasi Postgres 18, Web svelte-check+axe+Playwright, Security/gitleaks). Deploy webhook selesai:
  `.deployed_rev` = `47af256`, `kran-api` aktif, `/readyz` 200, `migrate --check` 0/0,
  `ctl verify-audit` → "rantai audit utuh (2 entri)" exit 0. Tugas ini **tanpa migrasi**, dan
  produksi tidak punya grant ber-cabang (seed menulis `branch_id = NULL`), jadi perilakunya di
  produksi inert — yang berubah adalah kemampuan sistem + test.
- **Catatan temuan sampingan (bukan regresi)**: `itapi_roles` bergantung pada nilai parameter hasil
  seed — kalau dijalankan setelah test yang membuat ulang schema `platform` (mis. `itplatform`),
  `ctl bootstrap-admin` keluar 1 (bukan 3) karena `platform.security.password_min_length` tidak punya
  nilai aktif. Urutan yang benar: `./task dbtools seed --dev` → `itapi_roles`.

## Pasca-M0 — T-046 kerangka MFA TOTP tanpa pengaktifan (O-015 dikerjakan, D-063)

- **Lingkup**: spec §13/§18.2 meminta MFA TOTP, repo belum punya satu baris pun. D-046 butir 9
  (pemilik): MFA **belum perlu diaktifkan** — jadi T-046 mengerjakan kerangkanya saja (skema,
  parameter, jalur enrolment/verifikasi teruji), dengan **alur login tidak berubah**.
- **Yang dibangun**: primitif TOTP RFC 6238 + HOTP RFC 4226 + base32 RFC 4648 di
  `shared/platform-lib/crypto/totp.nim` (di atas `nimcrypto` yang sudah dipakai → tanpa dependensi
  baru); migrasi expand-only `0012` (tabel `platform.user_mfa`, PK `user_id`, status
  `PENDING`/`ACTIVE`, `last_used_step`); 5 parameter GLOBAL `platform.security.mfa.*` (`enabled`
  default `false`); repo + layanan + 3 rute self-service (`GET /api/v1/auth/mfa`,
  `POST …/mfa/enrolment`, `POST …/mfa/verify`).
- **Invarian yang dijaga**: rahasia 160-bit CSPRNG disimpan **terenkripsi** (field crypto T-054,
  AAD = `user_mfa`) dan tidak pernah bisa dibaca ulang lewat API; `digits`/`periode` per baris
  (parameter berubah tidak membatalkan rahasia terdaftar); audit `auth.mfa.*` tanpa rahasia/kode/URI;
  `mfaSettingsOf` terpisah dari `settingsOf` sehingga seed MFA yang belum jalan hanya mematikan rute
  MFA (403 `mfa_disabled`), bukan login.
- **Bukti**: `./task test ttotp` → 12 `[OK]` (vektor dari **teks RFC**, bukan angka karangan);
  `./task test itapi_mfa` → 16 `[OK]` (gerbang 403 default **dan urutannya vs keyring maupun
  kebijakan yang belum tersemai**, rahasia sekali-kembali, ciphertext `kran:enc:v1` di DB,
  bentuk kode dari parameter tapi dibekukan di baris,
  kode salah 403 tetap `PENDING`, kode benar → `ACTIVE`, 409 saat sudah aktif, penjagaan anti-replay
  di lapisan repo, audit bebas rahasia, login tanpa penanda MFA);
  `./task test itapi_auth` → 43 `[OK]` (tanpa regresi jalur login/sesi/kata sandi);
  `./task test tcontract`/`tapi` hijau; `./task openapi` hijau; `./task check` exit 0.
- **Review**: putaran 1 dengan konteks bersih → **APPROVE** tanpa BLOCKER/MAJOR; 4 temuan MINOR
  ditindaklanjuti (urutan gerbang fitur vs keyring — dokumen tadinya menjanjikan 403 tapi kode
  menjawab 501; respons ditulis setelah transaksi selesai; `Cache-Control: no-store` pada respons
  rahasia; batas `mfa.digits` dipersempit ke 6–8 sesuai RFC 4226 §5.3). Satu temuan lagi ditemukan
  sebelum deploy: kebijakan MFA yang **belum tersemai** (keadaan produksi, O-066) menjawab 500, bukan
  403 — saklar kini dibaca lewat `param_repo.activeValueOpt` sehingga tidak ada nilai = fitur mati.
- **Sisa (O-071)**: aktivasi (tantangan kode saat login + `recordUsedStep`), kode pemulihan,
  pembatasan percobaan verifikasi, UI + kunci i18n-nya, alur hapus/ganti faktor.
- **CI + deploy**: run `39193819169` (sha `d17e5eb`) → **4/4 job hijau** (gitleaks, web
  svelte-check+axe+Playwright, Nim check+unit/property, DB integrasi Postgres 18).
  `.deployed_rev` = `d17e5ebac6e1400b3d872762f5b676eeff704d73`, `kran-api` active,
  `smoke.sh` `/healthz` + `/readyz` OK, `migrate --check` → `0/0`, `ctl verify-audit` → rantai
  utuh. DB produksi: `platform.schema_migration` terbaru `0012_platform_user_mfa.sql`, tabel
  `platform.user_mfa` ada, **0** nilai `platform.security.mfa.*` → rute MFA inert (403).
  Permintaan ber-sesi ke rute MFA di produksi tidak dilakukan (butuh kata sandi admin produksi).
- **HUMAN-REVIEW-REQUIRED** (autentikasi/kripto, AGENTS.md §8).


## T-059 — harness `itapi_roles` menyiapkan prasyarat parameternya sendiri — DONE (19 Okt 2026)

- **Lingkup**: temuan sampingan T-058. `itapi_roles` bergantung pada nilai parameter hasil
  `dbtools seed --dev`; setelah suite yang membuat ulang schema `platform` (mis. `itplatform`),
  `ctl bootstrap-admin` keluar 1 (parameter tidak punya nilai aktif) alih-alih 3 → test gagal tanpa
  sebab yang terbaca.
- **Perubahan** (`apps/api/tests/itapi_roles.nim`): blok prasyarat idempoten sebelum `suite` —
  `applyMigrations(db, ".")` + `seedFiles(".")` (pack `generated/`, semua `ON CONFLICT`) + verifikasi
  lewat `settingsOf(db, institutionScope(), …)` (pembaca yang sama dengan produksi). Bila prasyarat
  tidak siap: cetak `itapi_roles: prasyarat T-059 (parameter keamanan) tidak siap: <pesan>` lalu
  `quit(1)`. Tidak ada assertion yang dilemahkan; tidak ada jalur produksi yang diubah.
- **Bukti** (orkestrator, DB dev): tanpa patch `./task test itplatform` → `./task test itapi_roles`
  **GAGAL**; dengan patch urutan yang sama → **exit 0**, **13 `[OK]`**, 0 `[FAILED]`, tanpa seed
  manual. `./task fmt` + `./task check` exit 0.
- **Batas jujur**: jalur "prasyarat tidak bisa disiapkan" tidak dipicu sengaja (butuh merusak DB);
  pesannya dibaca dari kode. Verifikasi DB hanya pada urutan terburuk (`itplatform` → `itapi_roles`).

## T-044 — flake e2e: diagnosis 19 Okt 2026 (task tetap READY untuk magnitudo)

- **Kelas "menggantung" terbukti** (H1): jalur DB tidak punya batas waktu klien —
  `shared/platform-lib/db/pool.nim:54` memakai `pqsetdbLogin` (tanpa `connect_timeout`);
  `statement_timeout` berlaku server-side; `pingConn` (`pool.nim:118`) berjalan **sebelum**
  pemeriksaan deadline `acquire` (`:135`). Eksperimen: listener TCP accept-tapi-diam di 55432 →
  `ctl verify-audit` menggantung > 20 s tanpa keluaran; port tertutup → selesai 0,52 s. Klaim ini
  diperiksa ulang langsung di tree utama (bukan hanya laporan agen).
- **Artefak run gagal 17 Okt** (4/4 test login/DB, tanpa pesan galat DB) cocok dengan pola "tidak
  pernah selesai", termasuk `1 permintaan masih berjalan setelah 10.0 detik (O-047)`.
- **Magnitudo 9–12 menit belum tertutup**: hipotesis berperingkat (a) mesin suspend — `pmset`:
  100 `Entering Sleep`/16 Okt + `Clamshell Sleep`; (b) runner Playwright menunggu worker
  (5 menit/worker). Tidak ada klaim yang dinaikkan jadi fakta.
- **Tindak lanjut** (dipisah): T-061 (timeout koneksi DB), T-062 (proses bocor `shutdown.spec.ts`),
  T-063 (`globalTimeout` + eksperimen `caffeinate`).
- **Batas jujur**: tunnel DB mati saat diagnosis → `./task e2e` penuh tidak dijalankan.

## T-060 — alat ukur + anggaran biaya PBKDF2 ganti kata sandi (O-068) — DONE (19 Okt 2026)

- **Lingkup**: O-068 (temuan review T-051 ronde 1). Klaim lama "PBKDF2 dua kali per permintaan"
  (`docs/tasks/T-027.md`) dan model "batas 5 s" (`docs/ci-jobs.md`) tidak lagi menggambarkan biaya
  setelah O-052 menambah verifikasi N hash riwayat. Belum ada alat ukur maupun anggaran.
- **Model yang benar**: `changePassword` menjalankan **N+3** derivasi PBKDF2 — verifikasi kata sandi
  lama (1) + kata sandi baru terhadap hash berlaku (1) + N hash riwayat + hash kata sandi baru (1);
  N = `platform.security.password_history_count` (basis 5) → **8 derivasi** terburuk.
  Formula O-068 (1+N+1) kurang satu (langkah "kata sandi baru vs hash berlaku" tidak dihitung).
- **Yang dibangun**: `tools/bench-password/main.nim` + `./task bench-password` (dibangun
  `-d:release`, fungsi kripto nyata `password_hasher`, tanpa dependensi baru; `--iterations`,
  `--history-count`, `--reps`). Tanpa DB — jalur kode nyata untuk komponen CPU yang berlipat
  bersama N.
- **Anggaran**: `< 2 s` wall untuk ganti kata sandi terburuk (N=5) pada biner release di dev/CI
  2 vCPU. Dasar: ukur Apple M2 release → N=0 239 ms, N=5 **637 ms** (reps=5), ≈80 ms/derivasi
  (build debug ≈1,7 s/derivasi, ~20x lebih lambat — biner e2e memakai debug). Tidak dipasang
  sebagai gerbang latency CI (terlalu dekat batas → flaky). Rincian + batas jujur: `docs/tasks/T-060.md`.
- **Koreksi dokumen**: `docs/ci-jobs.md` (aturan isolasi test), `docs/tasks/T-027.md` (catatan
  kegagalan e2e pertama), komentar `apps/web/tests/e2e/password.spec.ts`, `docs/OPEN_ITEMS.md`
  (O-068), `docs/BACKLOG.md` (baris T-060).
- **Bukti sejauh ini**: `./task fmt` + `./task check` hijau; `./task bench-password --iterations
  600000 --reps 5` (release) → tabel di `docs/tasks/T-060.md`.
- **Ukur orkestrator** (19 Okt 2026, mesin dev, `./task bench-password --iterations 600000
  --reps 5`): release `N=0` **250 ms**, `N=5` **671 ms** → anggaran `< 2 s` lolos; biner debug yang
  dipakai e2e `N=0` **5,05 s**, `N=5` **13,61 s** (≈20x) → tenggang e2e tidak diubah. `./task check`
  exit 0.
- **Review independen: APPROVE** (tanpa BLOCKER/MAJOR; 4 MINOR diperbaiki): baris T-061…T-063
  dipindah ke tabel BACKLOG 6 kolom; `bench-password` kini keluar **2** untuk argumen non-numerik
  (parsing di `benchlib.nim` + `tests/tbench.nim` 7 `[OK]`); angka "1+N+1" di `docs/tasks/T-051.md`
  dikoreksi; rujukan baris H3 di T-044 diperbaiki. `./task check` + `./task test tbench` exit 0.
- **HUMAN-REVIEW-REQUIRED** hanya bila parameter kripto harus diubah untuk memenuhi anggaran
  (tidak terjadi; AGENTS.md §8).

## T-061 — jalur DB punya batas waktu klien (T-044 H1) — DONE (19 Okt 2026)

- **Masalah**: `pqsetdbLogin` tidak menerima `connect_timeout`; peer yang menerima TCP lalu diam
  membuat `acquire`/`dbtools`/`/readyz` menunggu **tanpa batas** (`statement_timeout` server-side
  tidak menolong: koneksi belum hidup).
- **Perubahan** (D-064): `pqconnectdb(connInfo)` menggantikan `pqsetdbLogin`; `connect_timeout` dari
  `KRAN_DB_CONNECT_TIMEOUT_MS` (default 5000, minimum libpq 2 s — `0` = tanpa batas, karena itu
  ditolak parser), nilai conninfo di-*quote* (escape `\` dan `'`), plus keepalive 5/5/2 supaya
  koneksi yang **sudah** hidup lalu membeku (tunnel mati tanpa RST) terdeteksi kernel ±15 s.
- **Bukti**: `./task test tdbconnect` 6 `[OK]` — listener black-hole (listen tanpa `accept`) gagal
  dalam **2,01 s** dengan `PoolError` "gagal menyambung" (tanpa fix: menggantung), kontrol port
  tertutup tetap gagal cepat; `./task test tconfig` hijau; `./task test itpool` 10 `[OK]`;
  `./task test itapi_auth` 43 `[OK]`; `./task check` exit 0.
- **Sisa jujur**: deadline **per-query** belum ada — koneksi yang membeku di tengah kueri dibatasi
  keepalive (±15 s), bukan batas milidetik. Itu butuh libpq nonblocking + `PQsocket`; dicatat di
  D-064, tidak diklaim selesai.
- **HUMAN-REVIEW-REQUIRED** (jalur koneksi produksi, AGENTS.md §8).

## T-062 — `startApi()` tidak lagi membocorkan proses `kran-api` — DONE (19 Okt 2026)

- **Masalah**: `shutdown.spec.ts` memanggil `startApi()` **sebelum** `try`; bila readiness gagal
  (API tidak siap dalam 20 s), `finally` tidak pernah terpasang dan proses `kran-api` tetap hidup di
  port bebas — persis kelas "sisa proses" yang membuat T-044 sulit dibaca.
- **Perubahan**: helper membunuh anaknya sendiri (`SIGKILL` + tunggu `exit`) sebelum melempar galat
  yang membawa `pid`; opsi `healthPath`/`readyTimeoutMs` ditambahkan (default sama).
- **Bukti**: test baru "kesiapan gagal → proses anak tidak ditinggalkan" (rute 404, batas 1,5 s,
  memeriksa `process.kill(pid, 0)` gagal). `playwright test shutdown.spec.ts` → **3 passed** (9,1 s);
  `pgrep -fl kran-api` kosong setelah run; `tsc --noEmit` tanpa galat di berkas ini (satu galat
  lama `src/routes/app/+layout.ts` bukan dari perubahan ini).

## T-064 — daftar audit terurut leksikografis (temuan e2e, 19 Okt 2026)

- **Gejala**: e2e `flow.spec.ts` merah pada assertion "alasan pengajuan terlihat di Jejak audit"
  walau barisnya ada di DB. `GET /api/v1/audit?limit=20` mengembalikan `99,98,…,90,9,89,…,81`
  padahal `max(seq)=231`.
- **Akar**: `ORDER BY seq DESC` di `listAudit` menunjuk kolom **keluaran** `seq::text` (PostgreSQL
  memprioritaskan nama keluaran), jadi urutannya leksikografis — `'99' > '100'`. Bug laten; baru
  muncul setelah ledger dev melewati 100 baris.
- **Perbaikan**: `ORDER BY audit_log.seq DESC` (kolom tabel). Tanpa perubahan kontrak.
- **Bukti**: test baru `itplatform` "urutan daftar = seq numerik, bukan teks (melewati 100)"
  **FAILED** dengan SQL lama (uji mutasi) dan `[OK]` dengan SQL baru; `./task test itplatform`
  25 `[OK]`, exit 0; `playwright test flow.spec.ts` 6 passed.

## T-063 — run e2e macet menjadi gagal terbaca (19 Okt 2026)

- `apps/web/playwright.config.ts`: `globalTimeout: 8 * 60_000` — run normal ±25 s, jadi batas ini
  tidak memotong run sehat tetapi mengubah macet menjadi kegagalan yang menyebut global timeout.
- **Eksperimen H2/H3 (hasil nol, dicatat di T-044)**: `caffeinate -i ./task e2e` → 24 passed
  (Playwright 25,0 s, total 33 s, tanpa `Entering Sleep`); `PWTEST_CHILD_PROCESS_TIMEOUT=20000
  ./task e2e` → 24 passed (26,2 s, nol "did not exit within"). Tidak ada run yang macet, jadi H2
  (~65%) vs H3 (~40%) tidak terpisah oleh data ini — tidak diklaim terbukti.

## T-065 — deadline per-query: spike, keputusan dibutuhkan (19 Okt 2026)

- **Temuan**: klaim D-064 bahwa keepalive membatasi koneksi beku ±15 s **tidak lengkap**. Dengan
  perantara TCP yang meneruskan lalu berhenti (socket tetap terbuka, kernel tetap meng-ACK — pola
  tunnel hidup dengan jalur remote mati), `psql ... -c "select 1"` **menggantung > 30 s** (dibunuh
  manual) tanpa galat. `statement_timeout` tidak berlaku karena kueri tak sampai server.
- **Kendala**: target "≤ 5 s" bertabrakan dengan `statement_timeout` 15 s (kueri sah bisa 15 s).
  Deadline klien harus > statement_timeout (usul 20 s), atau statement_timeout juga diturunkan.
- **Keputusan pemilik**: opsi A (watchdog di pool). **Selesai** (D-065): modul `db/deadline.nim`
  (satu thread pemantau, `shutdown(fd)` saat batas lewat), `withConn`/`withTx`/`acquire(ping)`
  memasang batas `KRAN_DB_QUERY_DEADLINE_MS` (default `statement_timeout + 5000`, wajib di atas
  statement_timeout), koneksi yang kena batas dibuang dan blok gagal dengan `PoolError`.
- **Bukti**: `tdeadline` 3 `[OK]`; `itpool` suite "koneksi beku" OK (< 2 s dengan deadline 700 ms,
  `created == 0`); mutasi deadline 3 s → uji gagal (`elapsed 3,03 s`); `tconfig` OK; `./task check`
  exit 0. Baris "tidak ada deadline per-query" dihapus dari `ACCEPTED-LIMITS` dan masuk daftar bukti
  mutasi. **HUMAN-REVIEW-REQUIRED** (jalur koneksi).
- **Review independen** (konteks bersih, 2 putaran): putaran 1 CHANGES-REQUIRED — 1 MAJOR race
  `shutdown` di luar lock (fd bisa sudah di-`pqfinish`), 1 MAJOR semantik anggaran per blok vs
  `statement_timeout` per statement (termasuk `COMMIT` yang sudah sukses bisa dilaporkan gagal),
  MINOR lain. Diperbaiki: `shutdown` di dalam lock, penanda pemantau diset setelah thread benar-benar
  ada, blok yang selesai mengembalikan hasil (hanya koneksi dibuang), `withTx` gagal tetap ROLLBACK
  eksplisit (di bawah anggaran) sehingga `leakedTx` tidak naik, jam monotonik, uji gagal-cepat bila
  mekanisme mati. **Putaran 2: kode T-065 APPROVE**; satu-satunya MAJOR yang tersisa adalah *scope*
  (perombakan deploy quadlet milik sesi lain ada di worktree yang sama) — **tidak** ikut di-commit.
  MINOR ditunda: log/metrik saat pemantau terdegradasi → **T-066**.
- **Mutasi**: deadline 3 s → uji gagal (`elapsed 3,06 s`); deadline 60 s (mekanisme mati) → uji gagal
  dalam ~5 s, bukan menggantung. `./task test` 614 `[OK]`, exit 0.

## T-067/T-068 — layanan container + rollback sadar container (19 Okt 2026)

- **T-067 (D-066)**: API/worker kini container quadlet (`ops/systemd/kran-{api,worker}.container`,
  image `localhost/kran-api`), dipasang deploy dari repo (`sync_units` + `.prev` + `restore_units`).
  Dikerjakan lewat sesi lain atas permintaan pemilik; sesi ini mengaudit hasilnya dan menutup
  dokumen yang hilang (D-066, T-067, §21.5/§21.6 spec, runbook §D2, `ACCEPTED-LIMITS`).
- **Fakta produksi** (read-only): `kran-api` active, `kran-worker` failed exit 3 by design,
  `127.0.0.1:8095->8095/tcp`, network `qouver` (10.89.0.31), `/readyz` `{"status":"ok"}` dengan
  `database`/`migrations`/`realtime` ok; deploy `aafc715` "API sehat"; unit terpasang identik repo.
- **Insiden cutover** (tercatat di komentar deploy + D-066): unit native bernama sama menang atas
  unit generator; deploy pertama me-restart biner lama dan health gate membaca biner itu juga.
  Perbaikan: unit lama ke `ops/systemd/superseded/` + penjaga fail-closed di deploy.
- **T-068**: `ops/scripts/rollback.sh` disamakan dengan model container — tag `:prev` → `:local`,
  pulihkan web/unit `.prev`/biner gate, tolak unit native, poll `/readyz` (gagal = exit 1).
  Bukti harness 4/4; skrip lama pada keadaan `:prev` hilang **exit 0** tanpa `podman tag`
  (sukses palsu) → perilaku baru diskriminatif. `bash -n` + `shellcheck -S warning` bersih.
- **Sisa**: T-069 (retensi tag image), KEK belum di-mount (butuh mount + `UserNS`), latihan rollback
  di server belum dilakukan (T-013).
