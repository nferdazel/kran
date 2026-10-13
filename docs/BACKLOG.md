# BACKLOG — CBS

Sumber kebenaran produk: `docs/spec/cbs-prd-techspec.md` (§23 = daftar fase).
Status: `TODO` · `READY` · `IN_PROGRESS` · `DONE` · `BLOCKED`.

Aturan pengambilan task (AGENTS.md §4): ambil task `READY` teratas. Satu task = satu
berkas rencana di `docs/tasks/T-xxx.md`.

## Fase 0 — Fondasi (spec §23)

| ID | Status | Tujuan | Spec | Deps | Kriteria selesai (dapat diverifikasi mesin) |
|---|---|---|---|---|---|
| T-001 | IN_PROGRESS | Skeleton monorepo + satu pintu `./task` + CI dasar | §7, §21.1 | — | `./task check` hijau; tree direktori sesuai §7; `ci.yml` = pola existing (trigger/permissions/concurrency) |
| T-002 | TODO | `shared/kernel`: Money (fixed-point 10⁴), Rate, BusinessDate, Result, Clock, IdGen (UUIDv7), AuditContext | §5.2, §9.1(2/6/8), §12.1 | T-001 | `./task test` hijau; property test (asosiatif, pembulatan, tanpa overflow, round-trip) lolos; tidak ada `float` di kernel |
| T-003 | TODO | Tooling: `tools/archcheck`, `tools/lint-nomagic`, `tools/paramgen` (+ test tool) | §5.1, §5.2, §10.3, §10.4 | T-001, T-002 | archcheck menolak fixture pelanggaran; lint-nomagic menolak fixture magic; paramgen deterministik + `--check` gagal saat drift |
| T-004 | TODO | Skeleton `platform`: pg pool, migration runner (expand-only), outbox/inbox, audit hash-chain | §9, §12.4, §18.2 | T-002, T-003 | `./task test` dengan `CBS_DATABASE_URL` hijau: migrasi idempotent (up 2× aman), outbox de-dup, hash-chain terverifikasi + terdeteksi saat dirusak |
| T-005 | TODO | Parameter framework: tabel + resolusi effective-dated + maker-checker + cache/NOTIFY + startup check | §10 | T-003, T-004 | Test: resolusi PRODUCT→BRANCH→INSTITUTION→SEGMENT→GLOBAL pada `as_of`; overlap ACTIVE ditolak EXCLUDE; ParamNotFound tanpa fallback; startup check gagal-cepat; invalidasi cache via NOTIFY |
| T-006 | TODO | Auth + RBAC + audit context + branch scoping dasar | §13, §18.2 | T-004, T-005 | Test authz matrix (role conflict + branch) hijau; audit context terisi di use case; sesi cookie HttpOnly |
| T-007 | TODO | Kalender + business date (state OPEN/CLOSING/CLOSED, roll over) | §9.3, §11.2 | T-004, T-005 | Test: hari libur dari param, level close (EOD/EOM/EOQ/EOY) terpilih dari kalender, transisi state ditolak bila ilegal |
| T-008 | BLOCKED | OpenAPI skeleton + generate client TS + contract test | §13 | T-001, T-014 | OpenAPI lint hijau; client TS ter-generate ulang tanpa diff; contract test implementasi↔OpenAPI hijau — **bagian contract test tertahan keputusan ADR-002** |
| T-009 | BLOCKED | SSE hub (LISTEN/NOTIFY + outbox → klien, `Last-Event-ID`) | §19.1, §13 | T-004, T-014 | Test: event dari outbox sampai ke klien, reconnect tanpa kehilangan event — **tertahan ADR-002** |
| T-010 | TODO | `apps/web` shell + design tokens + tema dark/light + i18n Paraglide + a11y baseline | §14–§17 | T-001 | `./task e2e` hijau: axe 0 pelanggaran serious/critical × 2 tema × 2 locale; test kontras token; i18n check tanpa key yatim |
| T-011 | TODO | `tools/scaffold` (template modul) + modul contoh `hello` | §5.5, §27.B | T-002, T-004 | Scaffold menghasilkan modul yang langsung `./task ci` hijau; archcheck menerima, `MODULE.md` terisi |
| T-012 | BLOCKED | End-to-end Fase 0: login → ubah parameter (maker-checker) → audit → event SSE di UI | §23 | T-005, T-006, T-009, T-010 | Playwright: alur lengkap keyboard-only, axe hijau, bukti audit event + ParamChanged tampil di UI — **tertahan ADR-002** |
| T-013 | TODO | `ops/` sesuai §21.4–21.6 (**hanya berkas di repo**, tidak dijalankan di server) | §21.4–21.6 | T-001 | `shellcheck`/`sh -n` hijau; `md5` berkas skrip siap dibanding `audit-consistency.sh`; tanpa secret |
| T-014 | DONE | Spike ADR-002: pilih HTTP server Nim (Mummy vs Prologue), tulis rekomendasi, **STOP minta keputusan** | §12.1, §25 | T-001 | Benchmark + rekomendasi tertulis di `docs/spikes/ADR-002-http-server.md` + entri `ESCALATIONS.md` — **keputusan pemilik masih terbuka (E-001)** |
| T-015 | IN_PROGRESS | Inventaris `cbs-core` (referensi, bukan port) → `docs/migration/cbs-core-inventory.md` | §23, §21.9 | T-001 | Dokumen memuat: fitur, skema, aturan bisnis tervalidasi, kandidat golden test; tanpa menyentuh repo `cbs-core` |

### Catatan urutan

- T-014 harus dikerjakan cepat karena memblokir T-008/T-009/T-012.
- Task di luar daftar ini ditemukan saat kerja → tambahkan di sini, jangan disisipkan diam-diam.

## Fase 1+ (ringkas, dari spec §23)

| Fase | Fokus | Status |
|---|---|---|
| 1 | Core Ledger & Party | belum mulai |
| 2 | Deposit + Teller | belum mulai |
| 3 | Day-Close Framework | belum mulai |
| 4 | Lending | belum mulai |
| 5 | Koperasi Pack (MVP pilot) | belum mulai |
| 6 | Compliance & Reporting | belum mulai |
| 7 | BPR Pack | belum mulai |
| 8 | Syariah Pack (BPRS/BMT) | belum mulai |
| 9 | Integrasi & Hardening + cutover `cbs-core` | belum mulai |
