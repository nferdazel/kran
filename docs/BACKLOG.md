# BACKLOG — CBS

Sumber kebenaran produk: `docs/spec/cbs-prd-techspec.md` (§23 = daftar fase).
Status: `TODO` · `READY` · `IN_PROGRESS` · `DONE` · `BLOCKED`.

Aturan pengambilan task (AGENTS.md §4): ambil task `READY` teratas. Satu task = satu
berkas rencana di `docs/tasks/T-xxx.md`.

## Fase 0 — Fondasi (spec §23)

| ID | Status | Tujuan | Spec | Deps | Kriteria selesai (dapat diverifikasi mesin) |
|---|---|---|---|---|---|
| T-001 | DONE | Skeleton monorepo + satu pintu `./task` + CI dasar | §7, §21.1 | — | `./task check` hijau; tree direktori sesuai §7; `ci.yml` = pola existing (trigger/permissions/concurrency) |
| T-002 | DONE | `shared/kernel`: Money (fixed-point 10⁴), Rate, BusinessDate, Result, Clock, IdGen (UUIDv7), AuditContext | §5.2, §9.1(2/6/8), §12.1 | T-001 | `./task test` hijau; property test (asosiatif, pembulatan, tanpa overflow, round-trip) lolos; tidak ada `float` di kernel |
| T-003 | DONE | Tooling: `tools/archcheck`, `tools/lint-nomagic`, `tools/paramgen` (+ test tool) | §5.1, §5.2, §10.3, §10.4 | T-001, T-002 | archcheck menolak fixture pelanggaran; lint-nomagic menolak fixture magic; paramgen deterministik + `--check` gagal saat drift |
| T-004 | DONE | Skeleton `platform`: pg pool, migration runner (expand-only), outbox/inbox, audit hash-chain | §9, §12.4, §18.2 | T-002, T-003 | `./task test` dengan `CBS_DATABASE_URL` hijau: migrasi idempotent (up 2× aman), outbox de-dup, hash-chain terverifikasi + terdeteksi saat dirusak |
| T-005 | DONE | Parameter framework: tabel + resolusi effective-dated + maker-checker + cache/NOTIFY + startup check | §10 | T-003, T-004 | Test: resolusi PRODUCT→BRANCH→INSTITUTION→SEGMENT→GLOBAL pada `as_of`; overlap ACTIVE ditolak EXCLUDE; ParamNotFound tanpa fallback; startup check gagal-cepat; invalidasi cache via NOTIFY |
| T-006 | DONE | Auth + RBAC + audit context + branch scoping dasar | §13, §18.2 | T-004, T-005 | Test authz matrix (role conflict + branch) hijau — `tauthz` 19 + `itauth` 13 test; audit context terisi (actor/cabang/IP/device/alasan/correlation); atribut cookie `HttpOnly; Secure; SameSite=Strict`. MFA & RLS lanjut di T-017/O-015 |
| T-007 | DONE | Kalender + business date (state OPEN/CLOSING/CLOSED, roll over) | §9.3, §11.2 | T-004, T-005 | Test: hari libur dari param/tabel, level close (EOD/EOM/EOQ/EOY) terpilih dari kalender, transisi state ditolak bila ilegal — `tcalendar` 29 test + `itcalendar` 11 test lulus |
| T-008 | DONE | OpenAPI skeleton + generate client TS + contract test | §13 | T-001, T-014 ✅ | OpenAPI lint hijau (`spectral --fail-severity warn`); klien TS sinkron tanpa diff + typecheck; contract test implementasi↔OpenAPI hijau (`tcontract` 4 + `tapi` 6 + `itapi` 2). Kontrak sengaja hanya memuat operasi yang sudah dilayani (health/readiness); auth/param/audit menyusul di T-012 |
| T-009 | READY | Realtime hub (LISTEN/NOTIFY + outbox → klien WS, *resume token*) | §19.1, §13 | T-004, T-014 ✅ | Test: event dari outbox sampai ke klien, reconnect tanpa kehilangan event (resume) |
| T-010 | DONE | `apps/web` shell + design tokens + tema dark/light + i18n Paraglide + a11y baseline | §14–§17 | T-001 | `./task e2e` hijau: axe 0 pelanggaran serious/critical × 2 tema × 2 locale; test kontras token; i18n check tanpa key yatim |
| T-011 | DONE | `tools/scaffold` (template modul) + modul contoh `hello` | §5.5, §27.B | T-002, T-004 | `tscaffold` 11 test; `modules/hello` hasil generate lolos `./task ci`; archcheck memeriksa `hello` (diuji dengan menyuntikkan pelanggaran); `MODULE.md` terisi |
| T-012 | READY | End-to-end Fase 0: login → ubah parameter (maker-checker) → audit → event realtime di UI | §23 | T-005, T-006, T-008, T-009, T-010 | Playwright: alur lengkap keyboard-only, axe hijau, bukti audit event + ParamChanged tampil di UI |
| T-013 | DONE | `ops/` sesuai §21.4–21.6 (**hanya berkas di repo**, tidak dijalankan di server) | §21.4–21.6 | T-001 | `bash -n` 7/7 skrip hijau (di-gate di `./task check`); `shellcheck` tidak terpasang di mesin ini — level `error` akan memblokir begitu tersedia; `md5` siap dibanding `audit-consistency.sh`; tanpa secret — **belum pernah dijalankan di server** |
| T-014 | DONE | Spike ADR-002: pilih HTTP server Nim (Mummy vs Prologue), tulis rekomendasi, **STOP minta keputusan** | §12.1, §25 | T-001 | Benchmark + rekomendasi tertulis di `docs/spikes/ADR-002-http-server.md` + entri `ESCALATIONS.md` — **keputusan pemilik masih terbuka (E-001)** |
| T-016 | DONE | Layanan parameter (lapisan application): cache in-proc per business date + konsumen NOTIFY, akses bertipe `params.get`, guard drift harian | §10.3, §10.4 | T-005 | `application/` tanpa driver DB (archcheck bersih + probe pelanggaran terbukti ditolak); cache invalid setelah NOTIFY (`itparamservice`); `get` bertipe OK; drift DB vs generated == 0 temuan. Sisa: watcher otomatis menunggu T-009 (O-018) |
| T-015 | DONE | Inventaris `cbs-core` (referensi, bukan port) → `docs/migration/cbs-core-inventory.md` | §23, §21.9 | T-001 | Dokumen memuat: fitur, skema, aturan bisnis tervalidasi, kandidat golden test; tanpa menyentuh repo `cbs-core` |

### Catatan urutan

- T-014 selesai; **keputusan pemilik 2026-10-14 = Opsi A: Mummy + WebSocket** (D-019,
  spec §19.1 diperbarui). T-008/T-009/T-012 kini `READY`, urutannya T-008 → T-009 → T-012.
- Task di luar daftar ini ditemukan saat kerja → tambahkan di sini, jangan disisipkan diam-diam.
- T-005 selesai untuk cakupan DB/repo; lapisan application dipisah ke T-016 supaya tidak ada
  pekerjaan yang "diam-diam setengah" (AGENTS.md §5).
- T-017 (usulan, dari T-006): MFA TOTP/enrolment + verifikasi saat login (spec §13/§18.2),
  plus kebijakan deteksi sesi ganda & unlock akun oleh admin. Belum masuk backlog resmi sampai
  pemilik menyetujui.
- T-013 selesai sebagai **berkas** saja (sesuai batas task): kontrak CLI `--role=migrate|ctl`
  (freeze gate & migration gate di `deploy-vps.sh`) belum ada di kode, jadi skripnya belum bisa
  dijalankan utuh. Dicatat di OPEN_ITEMS O-013.

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
