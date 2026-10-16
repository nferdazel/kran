# KRAN

Core banking untuk standar Indonesia: koperasi (KSP/USP/KSPPS), BPR/BPRS, dan BMT. Satu
codebase melayani ketiga rumpun lewat *product & regulatory pack*: beda aturan ditaruh di
parameter dan pack, bukan di cabang kode.

Produk ini masih di permulaan. **Fase 0 (Fondasi) selesai; belum ada fitur bisnis.** Yang ada
adalah fondasi yang membuat aturan sulit dilanggar tanpa sengaja: platform (pool DB, migrasi,
outbox, audit hash-chain), parameter dengan maker-checker, auth + RBAC, kalender, hub realtime,
dan shell web (tema, i18n, a11y). Belum ada pilot, UAT, atau data nyata. Laporan penutup fase:
[`docs/milestones/M0-report.md`](docs/milestones/M0-report.md).

Nilai dan pasal regulasi yang belum terverifikasi ditandai `NEEDS-COMPLIANCE-REVIEW` di
kode/seed, dan area kritis (bunga, akrual, PPAP, pajak, rekonsiliasi, enkripsi, authz) ditandai
`HUMAN-REVIEW-REQUIRED` (`AGENTS.md` §1.8 dan §8). Repo ini tidak mengklaim kepatuhan apa pun;
register regulasi menunggu verifikasi compliance officer.

Nama produknya **KRAN**; seluruh identifier teknis mengikutinya: biner `kran-api`, env `KRAN_*`,
unit systemd `kran-*`, kontrak `kran-api.yaml`, paket npm `@kran/*` (D-039). Hanya `cbs-core`,
sistem lama yang masih berjalan dan akan di-cutover, yang tetap memakai namanya sendiri.

Stack: PostgreSQL 18 · Nim 2.2 (API; versi dipin persis di [`kran.nimble`](kran.nimble)) ·
SvelteKit + TypeScript (back-office). UI dibangun dengan WCAG 2.2 AA di dua tema (dark/light)
dan i18n id/en sejak fondasi.

Satu sumber kebenaran: [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md)
(PRD + technical spec). Aturan kerja untuk manusia maupun agen: [`AGENTS.md`](AGENTS.md).

## Sejauh mana sekarang

Snapshot `./task ci` di mesin dev, 15 Oktober 2026:

| Ukuran | Nilai |
|---|---|
| Pemeriksaan lulus (`[OK]`) | 482 (unit, property, integrasi Postgres, kontrak OpenAPI) |
| Uji browser (Playwright, axe 2 tema) | 23 |
| Berkas lolos `nim check` | 110 |
| Migrasi SQL | 9 |

Angka itu bergerak setiap task, dan hanya menggambarkan mesin itu. Yang tetap: `./task ci` harus
hijau sebelum sebuah task disebut selesai. Rencana, kemajuan, dan sisanya ada di
[`docs/BACKLOG.md`](docs/BACKLOG.md), [`docs/PROGRESS.md`](docs/PROGRESS.md), dan
[`docs/OPEN_ITEMS.md`](docs/OPEN_ITEMS.md) (item di sana memang masih terbuka, bukan dianggap selesai).

## Arsitektur

Clean architecture per modul: `domain` → `application` → `infrastructure`/`interface`. Antar
modul hanya bicara lewat `api.nim` dan event, dan batas itu ditegakkan
[`tools/archcheck`](tools/archcheck). Tiga aturan membentuk sebagian besar keputusan di repo
ini:

- **Uang dan rate punya tipe sendiri** (`Money`, `Rate` di `shared/kernel`), tanpa float.
  Float membulatkan angka uang secara tak terduga dan galatnya menumpuk di ledger; tipe
  fixed-point membuat itu gagal saat kompilasi, bukan saat rekonsiliasi.
- **Nilai bisnis tidak ada di kode.** Rate, limit, fee, kalender, dan ambang diambil dari
  parameter DB, dan kunci parameter hanya boleh lahir dari [`tools/paramgen`](tools/paramgen).
  Konstanta bisnis di kode gagal `lint-nomagic`. Alasannya: mengubah nilai harus lewat
  maker-checker saat berjalan, bukan lewat deploy.
- **Ledger immutable, koreksi lewat jurnal pembalik.** Batang buku tidak diubah atau dihapus;
  perbaikan ditulis sebagai jurnal baru. Prinsipnya sudah ditetapkan (ADR-006), tetapi modul
  ledger belum dibangun, jadi penegak mekanisnya belum ada.

Peta direktori:

```
apps/api        entrypoint Nim; satu biner, empat peran (api | migrate | ctl | worker)
apps/web        SvelteKit (back-office)
modules/<m>     bounded context: domain/ application/ infrastructure/ interface/ migrations/ seeds/ tests/ api.nim MODULE.md
shared/kernel   Money, Rate, BusinessDate, Result, Clock, Id (kecil dan stabil)
shared/platform-lib  http, pool Postgres, logging, bootstrap config
packages/       sisi TS: contracts (OpenAPI), api-client (generated), ui, i18n, config
packs/          segment dan regulatory pack (seed ter-versi)
tools/          archcheck, lint-nomagic, paramgen, i18ncheck, openapi, dbtools, scaffold
docs/           spec, adr, tasks, backlog, runbooks, spikes, milestones
ops/            artefak deploy (ditulis di repo, dijalankan di server oleh manusia)
```

Peristiwa bisnis keluar lewat tabel outbox (transaksional, dengan de-dup dan dead-letter), lalu
disebarkan ke klien realtime lewat WebSocket dengan langganan yang izinnya diperiksa per topik.
Hal yang tidak bisa ditebak dari kode dijelaskan di `MODULE.md` tiap modul dan
[`docs/DECISIONS.md`](docs/DECISIONS.md).

## Penegak mekanis

Aturan yang hanya ditulis di dokumen akan dilanggar, jadi sebagian besar aturan di atas punya
penegak, dan penegaknya ikut diuji: [`tools/archcheck`](tools/archcheck) (batas modul),
[`tools/lint-nomagic`](tools/lint-nomagic) + [`tools/paramgen`](tools/paramgen) `--check` (nilai
bisnis), [`tools/i18ncheck`](tools/i18ncheck) (teks UI), [`tools/openapi`](tools/openapi) dengan
contract test (kontrak dan klien TS), dan [`tools/dbtools`](tools/dbtools) (migrasi expand-only).
Uang/rate ditegakkan tipe kernel dan tesnya. Aturan yang belum punya penegak (ledger immutable,
day-close lewat `daycloser`) dicatat terbuka dan baru datang bersama modulnya.

## Menjalankan dan menguji

Mulai cepat dari akar repo (`./task devdb up` membuka tunnel ke DB dev; runbooknya di
[`docs/runbooks/dev-db.md`](docs/runbooks/dev-db.md)):

```sh
./task devdb up                  # tunnel DB dev
./task dbtools migrate           # terapkan migrasi (idempoten)
./task dbtools seed --dev        # user + parameter contoh
./task build                     # binary ke .build/bin/kran-api
.build/bin/kran-api --role=api --port=8080 --address=127.0.0.1   # butuh KRAN_DATABASE_URL
pnpm install && pnpm --filter @kran/web dev   # back-office di http://127.0.0.1:5173 (registry: docs/runbooks/dev-web.md)
```

User hasil seed dev: `dev.maker` (mengajukan perubahan parameter) dan `dev.checker`
(menyetujui). Kata sandinya ada di
[`packs/base/seed/0001_dev_users.sql`](packs/base/seed/0001_dev_users.sql).

Satu pintu perintah: `./task` (skrip POSIX, tanpa dependensi tooling tambahan; D-001).

| Perintah | Isi |
|---|---|
| `./task check` | format + `nim check` + archcheck + lint-nomagic + paramgen `--check` + i18n check |
| `./task test` | unit + property + integration (Postgres) + contract |
| `./task e2e` | kontras token + svelte-check + Playwright (e2e, axe 2 tema, keyboard) |
| `./task openapi` | lint kontrak OpenAPI + cek klien TS sinkron |
| `./task ci` | semua di atas; harus hijau sebelum sebuah task dianggap selesai |
| `./task ci-repeat [N]` | ulangi gate penuh N kali (bawaan 3), untuk menangkap flake |
| `./task build` | bangun binary `kran-api` ke `.build/bin/` |
| `./task dbtools migrate\|status\|validate\|seed` | migrasi dan seed SQL (butuh `KRAN_DATABASE_URL`) |
| `./task scaffold <nama> [--dry-run]` | buat kerangka modul baru |
| `./task devdb up\|down\|status\|psql` | kelola tunnel ke DB dev |

Prasyarat:

- Nim 2.2 (`nimble install -d -y` untuk dependensi).
- PostgreSQL 18 untuk uji integrasi, **bukan di lokal**: pakai `./task devdb up` (D-004).
  Tanpa `KRAN_DATABASE_URL`, uji integrasi (dan sebagian e2e) melewati dirinya sendiri, jadi
  hasilnya bukan bukti.
- Node 24 + pnpm untuk `apps/web` (catatan registry:
  [`docs/runbooks/dev-web.md`](docs/runbooks/dev-web.md)).

## Alur kerja git dan rilis

Kerja di branch `feat/<id>-<slug>`, commit kecil (conventional commits), lalu buka PR atau
tinggalkan branch siap-review; merge ke `main` selalu keputusan manusia. Sejak repo ini punya
hook deploy (D-043), push ke `main` **men-deploy** lewat webhook dengan health gate dan
auto-rollback; branch lain ditolak ref-guard. Jangan push secret atau data nyata (data uji selalu
sintetis), dan jangan sentuh server, webhook, Caddy, atau `ops/` produksi kecuali sebuah task
eksplisit memintanya.

## Lisensi

Repo ini **publik agar dapat dibaca dan diaudit**, bukan untuk dipakai ulang: hak cipta
dipertahankan, dan lisensi apa pun hanya sah bila diberikan tertulis ([`LICENSE`](LICENSE),
D-044). Metadata `kran.nimble` bukan pemberian lisensi.

## Ke mana membaca selanjutnya

- [`docs/spec/kran-prd-techspec.md`](docs/spec/kran-prd-techspec.md): kontrak produk dan teknis (§23 = daftar fase).
- [`docs/DECISIONS.md`](docs/DECISIONS.md): keputusan engineering beserta alasannya.
- [`docs/BACKLOG.md`](docs/BACKLOG.md): rencana dan status task.
- [`docs/OPEN_ITEMS.md`](docs/OPEN_ITEMS.md): yang belum selesai dan butuh keputusan.
- [`docs/runbooks/`](docs/runbooks): prosedur operasional (dev DB, web, migrasi, CLI ops, deploy).
- [`AGENTS.md`](AGENTS.md): aturan kerja agen dan manusia, termasuk protokol per task.
