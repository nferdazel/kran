# cbs

CBS standar Indonesia untuk koperasi (KSP/USP/KSPPS), BPR/BPRS, dan BMT.

**Sumber kebenaran**: [`docs/spec/cbs-prd-techspec.md`](docs/spec/cbs-prd-techspec.md)
(PRD + technical spec). Aturan kerja untuk agen/developer: [`AGENTS.md`](AGENTS.md).

Stack: PostgreSQL 18 · Nim 2.2 (backend) · SvelteKit + TypeScript (frontend).

> Status: **Fase 0 (Fondasi) berjalan**. Belum ada fitur bisnis. Lihat
> [`docs/BACKLOG.md`](docs/BACKLOG.md) dan [`docs/PROGRESS.md`](docs/PROGRESS.md).

## Perintah

Satu pintu: `./task` (skrip POSIX, tanpa dependensi tooling tambahan — `docs/DECISIONS.md` D-001).

| Perintah | Isi |
|---|---|
| `./task check` | format (nimpretty) + `nim check` + archcheck + lint-nomagic + paramgen `--check` + i18n check |
| `./task test` | unit + property + integration (Postgres) + contract |
| `./task e2e` | Playwright (e2e + axe 2 tema) |
| `./task ci` | semua di atas — **harus hijau** sebelum sebuah task dianggap selesai |
| `./task build` | bangun binary `cbs-api` ke `.build/bin/` |
| `./task fmt` | rapikan format (menulis) |
| `./task devdb up\|down\|status\|psql` | tunnel ke DB dev di server (`docs/runbooks/dev-db.md`) |

## Prasyarat

- Nim 2.2+ (`nimble install -d -y` untuk dependensi)
- PostgreSQL 18 untuk uji integrasi — **bukan di lokal**: pakai `./task devdb up`
  (`docs/DECISIONS.md` D-004). Tanpa itu, uji integrasi melewati dirinya sendiri.
- Node 24 + pnpm (hanya untuk `apps/web`, mulai T-010)

## Struktur

```
apps/api        entrypoint Nim (--role=api|worker|migrate|all)
apps/web        SvelteKit (back-office)
modules/<m>     bounded context: domain/ application/ infrastructure/ interface/ migrations/ seeds/ tests/ api.nim MODULE.md
shared/kernel   Money, Rate, BusinessDate, Result, Clock, Id (kecil & stabil)
shared/platform-lib  http, pg pool, logging, bootstrap config
packages/       sisi TS: contracts (OpenAPI), api-client (generated), ui, i18n, config
packs/          segment & regulatory pack (seed ter-versi)
tools/          archcheck, lint-nomagic, paramgen, scaffold, dbtools
docs/           spec, adr, tasks, backlog, runbooks, spikes
ops/            artefak deploy (dibuat di repo; dijalankan di server oleh manusia)
```

## Aturan yang tidak boleh dilanggar

Ringkas (lengkapnya di `AGENTS.md` §1): tidak ada nilai bisnis di kode (semua dari parameter
DB), uang hanya lewat tipe `Money`, tidak ada float untuk uang, ledger immutable (koreksi =
jurnal pembalik), teks UI lewat i18n (id+en), WCAG 2.2 AA di 2 tema, day-close hanya lewat
framework `daycloser`, tidak mengarang fakta regulasi.

**Jangan push/merge ke `main`**: push ke `main` = deploy produksi. Kerja di branch
`feat/<id>-<slug>` dan tinggalkan siap-review.
