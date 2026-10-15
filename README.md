# KRAN

Core banking untuk standar Indonesia: koperasi (KSP/USP/KSPPS), BPR/BPRS, dan BMT.

Nama produknya **KRAN**; seluruh identifier teknis mengikutinya — biner `kran-api`, env `KRAN_*`,
database `kran_dev`, unit systemd `kran-*`, kontrak `kran-api.yaml`, paket npm `@kran/*` (keputusan dan
daftar lengkapnya di `docs/DECISIONS.md` D-039). Hanya `cbs-core` — sistem lama yang masih berjalan dan
akan di-cutover — yang tetap memakai namanya sendiri.

Satu sumber kebenaran: [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md) (PRD +
technical spec). Aturan kerja untuk manusia maupun agen: [`AGENTS.md`](AGENTS.md).

Stack: PostgreSQL 18 · Nim 2.2 (API, peran CLI) · SvelteKit + TypeScript (back-office).

## Di mana posisinya sekarang

**Fase 0 (Fondasi) selesai.** Belum ada fitur bisnis. Yang ada adalah kerangka yang membuat aturan
sulit dilanggar tanpa sengaja, dan itu dianggap hasil yang sah untuk fase ini. Laporan penutupnya:
[`docs/milestones/M0-report.md`](docs/milestones/M0-report.md).

Snapshot `./task ci` di mesin dev, 15 Oktober 2026:

| Ukuran | Nilai |
|---|---|
| Pemeriksaan lulus (`[OK]`) | 464 (unit, property, integrasi Postgres, kontrak OpenAPI) |
| Uji browser (Playwright, axe 2 tema) | 23 |
| Berkas lolos `nim check` | 110 |
| Migrasi SQL | 9 |

Angka itu bergerak setiap task. Yang tetap: `./task ci` harus hijau sebelum sebuah task disebut
selesai. Rencana, kemajuan, dan sisa yang belum bisa ditutup ada di
[`docs/BACKLOG.md`](docs/BACKLOG.md), [`docs/PROGRESS.md`](docs/PROGRESS.md), dan
[`docs/OPEN_ITEMS.md`](docs/OPEN_ITEMS.md) (item di sana masih terbuka dan disimpan sebagai daftar kerja).

## Mulai cepat

```sh
./task devdb up                  # tunnel DB dev di server (docs/runbooks/dev-db.md)
./task dbtools migrate           # terapkan migrasi (idempoten)
./task dbtools seed --dev        # user + parameter contoh
./task build                     # binary ke .build/bin/kran-api
```

Jalankan API (butuh `KRAN_DATABASE_URL`; cara mendapatkannya ada di runbook dev-db di atas):

```sh
.build/bin/kran-api --role=api --port=8080 --address=127.0.0.1
```

Back-office (SvelteKit):

```sh
pnpm install                     # catatan registry ada di docs/runbooks/dev-web.md
pnpm --filter @kran/web dev       # http://127.0.0.1:5173
```

User hasil seed dev: `dev.maker` (mengajukan perubahan parameter) dan `dev.checker` (menyetujui).
Kata sandinya ada di [`packs/base/seed/0001_dev_users.sql`](packs/base/seed/0001_dev_users.sql).

## Yang membuat repo ini berbeda

Aturan yang hanya ditulis di dokumen akan dilanggar. Di sini sebagian besar aturan punya penegak
mekanis, dan penegaknya ikut diuji:

| Aturan | Penegak |
|---|---|
| Tidak ada nilai bisnis di kode; semua dari parameter DB | [`tools/lint-nomagic`](tools/lint-nomagic) + [`tools/paramgen`](tools/paramgen) (mode `--check` menolak nilai yang tidak lahir dari parameter) |
| Batas modul (`domain` → `application` → `infrastructure`, lintas modul hanya lewat `api.nim`/event) | [`tools/archcheck`](tools/archcheck) |
| Uang dan rate punya tipe sendiri, tanpa float | `shared/kernel` (`Money`, `Rate`) |
| Teks UI lewat i18n (id + en), tanpa string keras di komponen | [`tools/i18ncheck`](tools/i18ncheck) |
| Kontrak OpenAPI dan klien TS tidak boleh melenceng | [`tools/openapi`](tools/openapi) + contract test |
| Migrasi expand-only, tanpa drop/rename di jalur otomatis | [`tools/dbtools`](tools/dbtools) (`validate`, `migrate --check`) |

Aturan yang **belum** ada penegaknya juga dicatat terbuka: ledger immutable (koreksi lewat jurnal
pembalik) dan day-close lewat framework `daycloser` baru datang bersama modulnya di fase berikutnya.

## Arsitektur

```
apps/api        entrypoint Nim; satu biner, empat peran (api | migrate | ctl | worker)
apps/web        SvelteKit (back-office)
modules/<m>     bounded context: domain/ application/ infrastructure/ interface/ migrations/ seeds/ tests/ api.nim MODULE.md
shared/kernel   Money, Rate, BusinessDate, Result, Clock, Id (kecil & stabil)
shared/platform-lib  http, pg pool, logging, bootstrap config
packages/       sisi TS: contracts (OpenAPI), api-client (generated), ui, i18n, config
packs/          segment & regulatory pack (seed ter-versi)
tools/          archcheck, lint-nomagic, paramgen, i18ncheck, openapi, dbtools, scaffold
docs/           spec, adr, tasks, backlog, runbooks, spikes, milestones
ops/            artefak deploy (ditulis di repo, dijalankan di server oleh manusia)
```

Peristiwa bisnis keluar lewat tabel outbox (transaksional, ada de-dup dan dead-letter), lalu
disebarkan ke klien realtime lewat WebSocket dengan langganan yang izinnya diperiksa per topik.
Hal-hal yang tidak bisa ditebak dari kode dijelaskan di `MODULE.md` tiap modul dan
[`docs/DECISIONS.md`](docs/DECISIONS.md).

## Peran proses (CLI)

Satu biner, kontrak peran yang bisa dipanggil skrip ops:

| Peran | Perintah | Kode keluar |
|---|---|---|
| `api` | `kran-api --role=api [--port=8080] [--address=127.0.0.1]` | 0 saat berhenti tenang (SIGINT/SIGTERM) |
| `migrate` | `kran-api --role=migrate [--check\|--up]` | 0 selesai; 1 ada migrasi tertunda atau isi migrasi berubah |
| `ctl` | `kran-api --role=ctl verify-audit\|outbox-status\|help` | 0 normal; 1 hasil buruk (mis. rantai audit tidak utuh) |
| `ctl` | `kran-api --role=ctl bootstrap-admin --username=<nama>` | 0 admin dibuat (kata sandi dicetak **sekali**); 3 sudah ada pemegang role admin |
| `worker` | `kran-api --role=worker` | 3 belum ada pekerjaannya di Fase 0 |

Salah pakai atau `KRAN_DATABASE_URL` kosong menghasilkan kode 2 dengan pesan, bukan stack trace.
`bootstrap-admin` satu-satunya perintah `ctl` yang menulis; sebelum mengganti kata sandinya, admin itu
hanya bisa memakai `/auth/session`, `/auth/password`, dan `/auth/logout`.
Lengkapnya: [`docs/runbooks/ops-cli.md`](docs/runbooks/ops-cli.md).

## Perintah

Satu pintu: `./task` (skrip POSIX, tanpa dependensi tooling tambahan; `docs/DECISIONS.md` D-001).

| Perintah | Isi |
|---|---|
| `./task check` | format + `nim check` + archcheck + lint-nomagic + paramgen `--check` + i18n check |
| `./task test` | unit + property + integration (Postgres) + contract |
| `./task e2e` | kontras token + svelte-check + Playwright (e2e, axe 2 tema, keyboard) |
| `./task openapi` | lint kontrak OpenAPI + cek klien TS sinkron |
| `./task ci` | semua di atas; harus hijau sebelum sebuah task dianggap selesai |
| `./task build` | bangun binary `kran-api` ke `.build/bin/` |
| `./task dbtools migrate\|status\|validate` | migrasi SQL (butuh `KRAN_DATABASE_URL`) |
| `./task scaffold <nama> [--dry-run]` | buat kerangka modul baru |
| `./task devdb up\|down\|status\|psql` | tunnel ke DB dev di server |

## Prasyarat

- Nim 2.2+ (`nimble install -d -y` untuk dependensi).
- PostgreSQL 18 untuk uji integrasi, **bukan di lokal**: pakai `./task devdb up`
  (`docs/DECISIONS.md` D-004). Tanpa DB, uji integrasi melewati dirinya sendiri.
- Node 24 + pnpm untuk `apps/web` (catatan registry: [`docs/runbooks/dev-web.md`](docs/runbooks/dev-web.md)).

## Aturan yang tidak boleh dilanggar

Ringkas (lengkapnya `AGENTS.md` §1): tidak ada nilai bisnis di kode (semua dari parameter DB), uang
hanya lewat tipe `Money`, tidak ada float untuk uang, ledger immutable (koreksi = jurnal pembalik),
teks UI lewat i18n (id + en), WCAG 2.2 AA di dua tema, day-close hanya lewat framework `daycloser`,
tidak mengarang fakta regulasi.

Angka dan pasal regulasi yang belum terverifikasi ditandai `NEEDS-COMPLIANCE-REVIEW` di kode/seed,
dan area kritis (bunga, akrual, PPAP, pajak, rekonsiliasi, enkripsi, authz) ditandai
`HUMAN-REVIEW-REQUIRED`. Kebijakan lengkapnya: `AGENTS.md` §1 dan §8.

## Cara kerja per task

Ambil task berstatus `READY` dari [`docs/BACKLOG.md`](docs/BACKLOG.md): tulis rencana di
`docs/tasks/T-xxx.md`, kerjakan test-first untuk perhitungan, jalankan `./task check` sering,
lalu `./task ci` sebelum mengklaim selesai. Setelah itu review independen dengan konteks bersih
([`docs/agent/REVIEWER.md`](docs/agent/REVIEWER.md)); perbaiki semua BLOCKER/MAJOR, baru commit dan
perbarui `docs/PROGRESS.md`. Setiap klaim "sudah jalan" harus disertai perintah dan ringkasan
outputnya (`AGENTS.md` §5).

## Git dan rilis

**Jangan push atau merge ke `main`.** Push ke `main` sama dengan deploy produksi lewat webhook, dan
itu hanya dilakukan manusia. Kerja di branch `feat/<id>-<slug>`, commit kecil dan logis, lalu
tinggalkan branch siap-review. Data uji selalu sintetis; tidak ada secret atau data nyata di repo.
