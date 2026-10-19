# BACKLOG — KRAN

Sumber kebenaran produk: `docs/spec/kran-prd-techspec.md` (§23 = daftar fase).
Status: `TODO` · `READY` · `IN_PROGRESS` · `DONE` · `BLOCKED`.

Aturan pengambilan task (AGENTS.md §4): ambil task `READY` teratas. Satu task = satu
berkas rencana di `docs/tasks/T-xxx.md`.

## Fase 0 — Fondasi (spec §23)

| ID | Status | Tujuan | Spec | Deps | Kriteria selesai (dapat diverifikasi mesin) |
|---|---|---|---|---|---|
| T-001 | DONE | Skeleton monorepo + satu pintu `./task` + CI dasar | §7, §21.1 | — | `./task check` hijau; tree direktori sesuai §7; `ci.yml` = pola existing (trigger/permissions/concurrency) |
| T-002 | DONE | `shared/kernel`: Money (fixed-point 10⁴), Rate, BusinessDate, Result, Clock, IdGen (UUIDv7), AuditContext | §5.2, §9.1(2/6/8), §12.1 | T-001 | `./task test` hijau; property test (asosiatif, pembulatan, tanpa overflow, round-trip) lolos; tidak ada `float` di kernel |
| T-003 | DONE | Tooling: `tools/archcheck`, `tools/lint-nomagic`, `tools/paramgen` (+ test tool) | §5.1, §5.2, §10.3, §10.4 | T-001, T-002 | archcheck menolak fixture pelanggaran; lint-nomagic menolak fixture magic; paramgen deterministik + `--check` gagal saat drift |
| T-004 | DONE | Skeleton `platform`: pg pool, migration runner (expand-only), outbox/inbox, audit hash-chain | §9, §12.4, §18.2 | T-002, T-003 | `./task test` dengan `KRAN_DATABASE_URL` hijau: migrasi idempotent (up 2× aman), outbox de-dup, hash-chain terverifikasi + terdeteksi saat dirusak |
| T-005 | DONE | Parameter framework: tabel + resolusi effective-dated + maker-checker + cache/NOTIFY + startup check | §10 | T-003, T-004 | Test: resolusi PRODUCT→BRANCH→INSTITUTION→SEGMENT→GLOBAL pada `as_of`; overlap ACTIVE ditolak EXCLUDE; ParamNotFound tanpa fallback; startup check gagal-cepat; invalidasi cache via NOTIFY |
| T-006 | DONE | Auth + RBAC + audit context + branch scoping dasar | §13, §18.2 | T-004, T-005 | Test authz matrix (role conflict + branch) hijau — `tauthz` 19 + `itauth` 13 test; audit context terisi (actor/cabang/IP/device/alasan/correlation); atribut cookie `HttpOnly; Secure; SameSite=Strict`. MFA & RLS lanjut di T-017/O-015 |
| T-007 | DONE | Kalender + business date (state OPEN/CLOSING/CLOSED, roll over) | §9.3, §11.2 | T-004, T-005 | Test: hari libur dari param/tabel, level close (EOD/EOM/EOQ/EOY) terpilih dari kalender, transisi state ditolak bila ilegal — `tcalendar` 29 test + `itcalendar` 11 test lulus |
| T-008 | DONE | OpenAPI skeleton + generate client TS + contract test | §13 | T-001, T-014 ✅ | OpenAPI lint hijau (`spectral --fail-severity warn`); klien TS sinkron tanpa diff + typecheck; contract test implementasi↔OpenAPI hijau (`tcontract` 4 + `tapi` 6 + `itapi` 2). Kontrak sengaja hanya memuat operasi yang sudah dilayani (health/readiness); auth/param/audit menyusul di T-012 |
| T-009 | DONE | Realtime hub (LISTEN/NOTIFY + outbox → klien WS, *resume token*) | §19.1, §13 | T-004, T-014 ✅ | `./task ci` hijau. `itrealtime` 5 + `itapi_ws` 11 + `trealtime` 26: peristiwa outbox sampai ke klien WS nyata, resume/resync terbukti, penolakan (426/401/403) & topik ditolak dilaporkan. Kebijakan default tolak-semua sampai T-012 memasang sesi (D-021). Sisa: O-028/O-029/O-030 |
| T-010 | DONE | `apps/web` shell + design tokens + tema dark/light + i18n Paraglide + a11y baseline | §14–§17 | T-001 | `./task e2e` hijau: axe 0 pelanggaran serious/critical × 2 tema × 2 locale; test kontras token; i18n check tanpa key yatim |
| T-011 | DONE | `tools/scaffold` (template modul) + modul contoh `hello` | §5.5, §27.B | T-002, T-004 | `tscaffold` 11 test; `modules/hello` hasil generate lolos `./task ci`; archcheck memeriksa `hello` (diuji dengan menyuntikkan pelanggaran); `MODULE.md` terisi |
| T-012 | DONE | End-to-end Fase 0: login → ubah parameter (maker-checker) → audit → event realtime di UI | §23 | T-005, T-006, T-008, T-009, T-010 | `./task ci` hijau. `flow.spec.ts` 6 test: alur dua konteks (maker & checker) dengan penanda `__guard` membuktikan nilai ACTIVE tampil di sesi maker **tanpa reload** (peristiwa `param.changed`), jejak audit memuat `param.submit` + alasan & `param.approve`, Keluar → `/login`; axe `/login` + `/app` × 2 tema bersih. API: `itapi_auth` 15 + `tapi` 10 `[OK]` (kebijakan realtime berbasis sesi, tanpa wildcard implisit). Sisa: O-031 (bootstrap user produksi), O-032 (saring per cabang), O-033 (tautan masuk di header) |
| T-013 | DONE | `ops/` sesuai §21.4–21.6 (**hanya berkas di repo**, tidak dijalankan di server) | §21.4–21.6 | T-001 | `bash -n` 7/7 skrip hijau (di-gate di `./task check`); `shellcheck` tidak terpasang di mesin ini — level `error` akan memblokir begitu tersedia; `md5` siap dibanding `audit-consistency.sh`; tanpa secret — **belum pernah dijalankan di server** |
| T-014 | DONE | Spike ADR-002: pilih HTTP server Nim (Mummy vs Prologue), tulis rekomendasi, **STOP minta keputusan** | §12.1, §25 | T-001 | Benchmark + rekomendasi tertulis di `docs/spikes/ADR-002-http-server.md` + entri `ESCALATIONS.md` — **keputusan pemilik masih terbuka (E-001)** |
| T-016 | DONE | Layanan parameter (lapisan application): cache in-proc per business date + konsumen NOTIFY, akses bertipe `params.get`, guard drift harian | §10.3, §10.4 | T-005 | `application/` tanpa driver DB (archcheck bersih + probe pelanggaran terbukti ditolak); cache invalid setelah NOTIFY (`itparamservice`); `get` bertipe OK; drift DB vs generated == 0 temuan. Sisa: watcher otomatis menunggu T-009 (O-018) |
| T-015 | DONE | Inventaris `cbs-core` (referensi, bukan port) → `docs/migration/cbs-core-inventory.md` | §23, §21.9 | T-001 | Dokumen memuat: fitur, skema, aturan bisnis tervalidasi, kandidat golden test; tanpa menyentuh repo `cbs-core` |

## Pasca-M0 — Fase 0 dibersihkan (permintaan pemilik, 15 Okt 2026)

| Task | Item | Status |
|---|---|---|
| T-022 | Validasi bentuk permintaan parameter (O-035) | DONE |
| T-023 | Realtime aman-sesi (O-036) | DONE |
| T-024 | Shutdown bersih (O-025) | DONE |
| T-025 | Invarian kursor outbox + test balapan dua koneksi (O-037, O-040) | DONE |
| T-026 | Kontrak CLI multi-role + jalur skrip ops (O-013) | DONE |
| T-027 | Bootstrap admin produksi + endpoint ganti kata sandi (O-031) | DONE |
| T-028 | Kebijakan anti-enumerasi akun (O-034) | DONE |

Nomor T-017 tetap **dipesan** untuk usulan MFA (belum disetujui pemilik) supaya tidak bentrok.
Keputusan pemilik 15 Okt 2026 (D-034): O-031 (bootstrap: perintah sekali-jalan + wajib ganti, jadi
T-027), O-034 (status terkunci hanya setelah kata sandi benar + PBKDF2 tiruan, jadi T-028), O-039
(`requires_approval: false` ditolak `paramgen`, semantik menyusul di T-016), O-012 (tipe lookup
eksplisit, dikerjakan di T-016). Tidak ada lagi keputusan yang menggantung.

## Batch "Fase 0 tahan banting" (permintaan pemilik, 15 Okt 2026)

Tujuan: Fase 0 bukan sekadar hijau sekali, tetapi tidak punya celah yang **diketahui** pada jalur
kebenaran, keamanan, dan ketahanan yang memang milik Fase 0. Batas fase lain (metrics spec §22,
DR drill §9, freeze gate `daycloser` fase 3) tidak dipaksakan masuk; ia masuk register batas (T-037).

| Task | Item | Prioritas | Status |
|---|---|---|---|
| T-028 | Kebijakan anti-enumerasi akun (O-034) | P1 | DONE |
| T-029 | Pump realtime pulih setelah koneksi putus (O-029) | P1 | DONE |
| T-030 | Izin langganan realtime diperiksa ulang (O-046) | P1 | DONE |
| T-031 | CI stabil: audit flake + aturan isolasi tes + `ci-repeat` | P1 | DONE |
| T-032 | Drain permintaan berjalan saat SIGTERM (O-047) | P2 | DONE |
| T-033 | Pool DB: bukti aman paralel + rapikan klaim (O-011) | P2 | DONE |
| T-034 | Kurangi ketergantungan pada internal Mummy (O-049) | P2 | DONE |
| T-035 | Migrasi contract & rollback (O-048) | P3 | DONE |
| T-036 | Semantik scope institusi & `requires_approval` (O-012, O-039) | P3 | DONE |
| T-037 | Register batas Fase 0 + laporan penutup | P3 | DONE |
| T-039 | Seluruh identifier teknis mengikuti KRAN (D-039) | P2 | DONE |
| T-040 | Setup deploy key + webhook di server (prasyarat deploy) | P2 | DONE |
| T-041 | `/readyz` memeriksa migrasi & lag outbox (O-019) | P2 | DONE |
| T-042 | Teardown in-process Mummy (O-025) | P3 | DONE |
| T-043 | Soket realtime ditutup saat sesi dicabut (O-036) | P2 | DONE (duplikat T-023/T-047 — tidak ada pekerjaan tambahan) |
| T-044 | Flake e2e di dalam gate: diagnosis terbatas (T-031). **17 Okt 2026**: satu gejala deterministik di kelas yang sudah dikenal ditutup — assertion audit tanpa `.first()` membuat `./task e2e` merah pada **setiap** run kedua di mesin dev (audit log append-only, terbukti; akumulasi antar-run, bukan dobel-tulis) → diperbaiki `flow.spec.ts:238` lewat eskalasi D-054. Flake intermiten (menggantung 9-12 menit) **masih terbuka** | P1 | READY **19 Okt 2026**: diagnosis diperbarui (`docs/tasks/T-044.md`) — kelas "menggantung" terbukti: jalur DB tanpa batas waktu klien (`pqsetdbLogin`; `pingConn` di luar deadline `acquire`), eksperimen black-hole menggantung > 20 s vs 0,52 s port tertutup. Magnitudo 9–12 menit belum tertutup (hipotesis: suspend mesin / runner menunggu worker). Perbaikan dipisah ke **T-061…T-063** |
| T-045 | Latihan deploy + peralihan di server (D-043) | P2 | BLOCKED (izin push) |

Urutan kerja: T-028 → T-029 → T-030 → T-031 → T-032 → T-033 → T-034 → T-035 → T-036 → T-037.
Satu putaran review independen di akhir batch atas diff seluruh batch (pola batch T-022…T-026).

### Catatan urutan

- T-014 selesai; **keputusan pemilik 2026-10-14 = Opsi A: Mummy + WebSocket** (D-019,
  spec §19.1 diperbarui). T-008 → T-009 → T-012 seluruhnya `DONE`: **Fase 0 lengkap** (semua task
  T-001…T-016 berstatus DONE; laporan milestone di `docs/milestones/M0-report.md`). Tidak ada lagi
  task `READY` di Fase 0 — menunggu keputusan manusia untuk membuka Fase 1 (spec §23).
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

## Pasca-M0 — batch keputusan pemilik 16 Okt 2026 (D-046)

Urutan pengerjaan yang disetujui pemilik: keamanan/kebenaran dulu (T-048 → T-049; T-047 dilewati karena
ternyata duplikat dan sudah selesai — lihat T-043), lalu CI
supaya gate benar-benar mewakili (T-050), lalu aturan kebijakan (T-051), lalu integritas audit dengan
review manusia (T-052), lalu batch kecil (T-053). MFA (T-046) sengaja **terakhir**: pemilik menilai
belum perlu, yang diminta hanya bootstrap tanpa pengaktifan.
Catatan 16 Okt 2026: T-047 ternyata **sudah selesai** lebih dulu lewat T-023 (sesi, D-030) + T-030
(izin, O-046); barisnya basi. Diverifikasi ulang dan ditutup tanpa perubahan kode (lihat
`docs/tasks/T-047.md`). Lanjut ke T-048.

Catatan 16 Okt 2026 (kedua): pemilik memutuskan **enkripsi field-level itu fondasi**, jadi tidak menunggu
data anggota nyata — menambah enkripsi setelah baris berisi berarti backfill + seremoni kunci di bawah
tekanan. Karena itu **T-054** (ADR-017/D-048) dikerjakan sekarang dan menutup mekanisme **O-006**;
`sops`/`age` tetap tercatat sebagai sisa. T-054 tidak mengubah urutan T-050…T-046.

Catatan 19 Okt 2026: **batch D-046 tuntas** — T-048, T-049, T-050, T-051, T-052, T-053, T-054, dan
terakhir T-046 semuanya DONE; T-056/T-058 (temuan lanjutan) juga DONE, disusul **T-059** (harness
`itapi_roles`) dan **T-060** (anggaran PBKDF2, O-068) DONE 19 Okt 2026. Yang tersisa: T-044 (flake
e2e — diagnosis 19 Okt 2026; perbaikannya T-061…T-063), T-055/T-057 (diputuskan tidak sekarang),
plus open item yang butuh keputusan pemilik (O-071 MFA aktivasi, O-067, O-066 seed produksi).

| ID | Status | Tujuan | Spec | Deps | Kriteria selesai (dapat diverifikasi mesin) |
|---|---|---|---|---|---|
| T-048 | DONE | O-057: samakan `missingActiveKeys` dengan aturan resolusi | §10.2 | — | Uji: kasus yang tidak pernah "terlihat" oleh resolusi tidak dihitung aktif, dan sebaliknya; tidak ada kelonggaran tersisa (2 uji baru `itparam`: wildcard `scopeId` kosong ditolak, `GLOBAL` tetap memenuhi; uji pembeda GAGAL pada aturan lama) |
| T-049 | DONE | O-035: validasi bentuk input sebelum menyentuh DB (tanggal ISO, uuid, kombinasi scope) → 400/404, bukan 500 | §17 | — | **Sudah dicakup lebih dulu (T-022, 15 Okt 2026)** — register basi. Bukti: `itapi_auth.nim:437` (7 kasus bentuk → 400 + `problem+json`), `:466` (`paramValueId` non-uuid → 404), kontrol sah 201; validasi di `handlers_param.nim:114`/`http_util.nim:51`/`parseId` sebelum `withDbTx`. Tidak ada kode baru |
| T-050 | DONE | O-027 (sebagian) + O-014: job CI `db-tests` (service Postgres) + `shellcheck -S warning` jadi gate. **Dipersempit**: bagian ESLint (O-023) dikeluarkan → T-057 | §21.3 | — | Job `db-tests` ada di `ci.yml` dan hijau; `shellcheck` level warning memblokir di `./task check` dan fail-closed tanpa tool (bukti: 7 skrip ops bersih + harness 4 skenario). Sisa O-027 (`traceability`) dan O-023 dicatat di barisnya sendiri |
| T-057 | TODO | O-023 (dipersempit): lint statis **generik** Svelte/TS (aturan `svelte/*` non-a11y + `typescript-eslint`). Bagian a11y sudah ditutup tanpa dependensi baru | §17.2 | T-012 (komponen bisnis nyata) | **Diputuskan 17 Okt 2026 (D-053): tidak sekarang.** Alasan: aturan a11y plugin = pemetaan ulang warning kompilator Svelte, sedangkan celah nyatanya ("warning a11y tidak pernah memblokir") sudah ditutup lewat `svelte-check --fail-on-warnings` (terbukti: warning ditanam → `exit=1`). Bila dikerjakan: `minimumReleaseAge` membatasi versi, `typescript-eslint` wajib (semua `<script>` ber-`lang="ts"`), dan memanggilnya dari `./task check` memerahkan job CI `nim-check` yang tidak menjalankan `pnpm install` |
| T-051 | DONE | O-032 + O-043 + O-050 + O-052 + **O-044/D-047** (pengajuan hanya untuk scope yang boleh dibaca pengaju — aturan ini **tidak tercantum** di baris ini sebelum 17 Okt 2026, hanya ada di D-047): visibilitas params/audit per scope, tolak `effectiveTo` tanpa penerus, audit+batas percobaan kata sandi lama, kebijakan kata sandi (tanpa kedaluwarsa, riwayat 5, kualitas sebagai parameter) | §10, §13 | D-046, D-047 | Rencana + peta kode: `docs/tasks/T-051.md`. Test izin lintas scope; pengajuan tanpa penerus ditolak 400; percobaan salah tercatat audit; angka kebijakan berasal dari parameter; **bagian authz (O-032/O-044) → HUMAN-REVIEW-REQUIRED**. **Selesai 17 Okt 2026**: reviewer independen ronde 1 APPROVE (tanpa BLOCKER/MAJOR), deploy `3659599` hijau (CI 39040329104, keempat job). Bukti: `docs/tasks/T-051.md`, `docs/PROGRESS.md` |
| T-052 | DONE | **O-038** (dipersempit 17 Okt 2026, D-060): urutan `seq` vs advisory lock — verifikasi rantai mengikuti `prev_hash`, bukan `lag(seq)`. O-009 dikeluarkan (butuh framework `daycloser`, Fase 3) | §18.2 | — | ✅ `0011` (`audit_verify` + indeks `hash`/`prev_hash`); suite `itplatform` (interleaved + cabang) hijau; CI 39051572992 4/4 hijau; deploy `6c0fa71` — indeks + definisi fungsi terverifikasi di DB produksi, `ctl verify-audit` exit 0. Reviewer: APPROVE putaran 2 (MAJOR putaran 1 diperbaiki). **HUMAN-REVIEW-REQUIRED** (D-061) |
| T-053 | DONE | Batch kecil: O-042 (batas test dari `packs/*/generated`), O-045 (pesan 400 per-field ke i18n), O-030 (batas realtime jadi parameter), O-033 (tautan Masuk di header + DECISIONS urutan Tab). **O-018 dikeluarkan** → T-055 | §10, §15, §19 | — | `./task check` hijau; `./task test` 529 `[OK]` / 0 `[FAILED]`; `./task e2e` 23 lulus (24,5 s); O-033 disertai D-049 karena mengubah urutan Tab. O-018 pindah ke T-055: cache parameter tidak dipakai proses `api`, jadi menyambungkannya keputusan arsitektur, bukan batch kecil |
| T-054 | DONE | Fondasi enkripsi field-level: KEK (berkas 600) → DEK turunan per tabel + AES-256-GCM + blind index — menutup O-006 mekanismenya | §18.2 | — | `./task test fieldcrypto` 29 `[OK]`; `./task ci` hijau (517 `[OK]`, e2e 23); vektor AES-GCM/KDF independen (Node); uji e2e tabel sementara; ADR-017 + runbook. Sisa: `sops`/`age` sebelum data nyata; `HUMAN-REVIEW-REQUIRED` |
| T-046 | DONE | O-015: bootstrap MFA **tanpa pengaktifan** — skema, parameter, jalur enrolment/verifikasi; per akun opt-in, default mati | §13 | T-051 | ✅ Kerangka selesai 19 Okt 2026 (D-063): primitif TOTP RFC 6238 + HOTP RFC 4226 + base32 RFC 4648 di `shared/platform-lib/crypto/totp.nim` (vektor uji diambil dari **teks RFC**), migrasi expand-only `0012` (`platform.user_mfa`, rahasia 160-bit **terenkripsi** field crypto, `digits`/`period_seconds` per baris, `last_used_step`), 5 parameter GLOBAL `platform.security.mfa.*` (`enabled` default `false`), tiga rute self-service tanpa izin baru. Bukti: `ttotp` 12 `[OK]`, `itapi_mfa` 16 `[OK]`, `itapi_auth` 43 `[OK]` (**alur login tidak berubah**), `tcontract`/`tapi`/`./task openapi`/`./task check` hijau; review independen putaran 1 **APPROVE** (4 MINOR ditindaklanjuti). Sisa MFA dipisah → **O-071** (aktivasi login, kode pemulihan, pembatasan percobaan verifikasi, UI + i18n, hapus/ganti faktor). CI run `39193819169` 4/4 hijau; ter-deploy (`.deployed_rev` `d17e5eb`, migrasi `0012` terpasang, `migrate --check` bersih, `ctl verify-audit` utuh); 0 nilai `platform.security.mfa.*` di produksi → rute MFA inert 403. **HUMAN-REVIEW-REQUIRED (autentikasi/kripto)** |
| T-055 | DONE | O-018: parameter di proses `api` — **diputuskan**: tetap dibaca per permintaan, tanpa cache lintas-proses | §10.4 | — | D-052 (17 Okt 2026). Bukti: `settingsOf` = 6 pembacaan baris-tunggal **hanya di jalur auth** (`auth_service.nim:50-65`; `handlers_auth.nim:64/115/179`), tabel parameter puluhan baris; opsi cache diberatkan `param_cache` tanpa TTL + `NOTIFY` yang tak dijamin sampai → kelas bug "nilai basi tanpa error" di jalur keamanan. Pemicu tinjau ulang terukur dicatat di D-052. Tidak ada kode baru |
| T-056 | DONE | Deploy memasang `ops/systemd/*.service` dari repo: verify + cadangan `.prev` + pulih saat rollback | §21.4, §21.5 | — | Harness 5/5 (pasang, no-op saat identik, cadangan saat berubah, pulih saat rollback, tolak unit tidak sah tanpa merusak yang lama); `bash -n` + `shellcheck -S warning` bersih; unit terpasang identik dengan repo → no-op di deploy berikutnya |
| T-059 | DONE | Temuan sampingan T-058 (bukan regresi): `itapi_roles` bergantung pada nilai parameter hasil `dbtools seed --dev`. Dijalankan setelah test yang membuat ulang schema `platform` (mis. `itplatform`), `ctl bootstrap-admin` keluar 1 (bukan 3) karena `platform.security.password_min_length` tidak punya nilai aktif → test gagal tanpa sebab yang terbaca | §21.3 | — | Test/harness menyiapkan prasyaratnya sendiri (seed idempoten) atau gagal dengan pesan yang menyebut sebabnya; terbukti: `./task test itapi_roles` hijau tanpa menjalankan seed manual lebih dulu **19 Okt 2026 DONE**: harness menanam prasyarat sendiri (`applyMigrations` + `seedFiles` idempoten + verifikasi lewat `settingsOf`). Tanpa patch: `itplatform` → `itapi_roles` **gagal**; dengan patch: **exit 0, 13 `[OK]`, 0 `[FAILED]`** tanpa seed manual; `./task check` exit 0 |
| T-058 | DONE | O-032 (bagian kedua, keputusan pemilik 17 Okt 2026 / D-059): gerbang izin HTTP dua tingkat + atribusi cabang audit. Rencana menyebut lebih dulu cabang target per endpoint + sumber atribusi cabang audit (syarat D-059); keputusan = **D-062** | §13, §18.2 | T-051 (D-055) | Grant yang hanya ber-cabang mulai berlaku (dan ditolak `branch_not_allowed` di cabang lain); baris audit HTTP ber-`branch_id` (uuid). Bukti: `tauthz` 29 `[OK]`, `itapi_auth` 43 (5 test baru), `itparam` 34, `itplatform` 24, `itapi_roles` 13, `./task check` + `./task openapi` exit 0, svelte-check 0 error/0 warning. Reviewer putaran 1 CHANGES-REQUIRED (1 BLOCKER klien TS + 1 MAJOR test atribusi + 3 MINOR) → semuanya diperbaiki; **putaran 2 APPROVE**. CI `39186325331` 4/4 hijau; deploy `47af256` (unit aktif, `/readyz` 200, `migrate --check` 0/0). Sisa dipisah: **O-017** (pengenal cabang non-uuid) + **O-070** (realtime belum disaring per cabang); temuan urutan test → T-059. **HUMAN-REVIEW-REQUIRED (authz)** |
| T-060 | DONE | O-068: biaya PBKDF2 ganti kata sandi kini **N+3** derivasi (bukan "dua kali"); ukur + anggarkan eksplisit + perbaiki klaim/tenggang lama | §13, §21.3 | T-051 (D-058) | Alat ukur `./task bench-password` (fungsi kripto nyata, release, tanpa dependensi baru); anggaran `< 2 s` (N=5) berbasis ukur M2 release (N=5 = 637 ms); klaim "dua kali" dikoreksi di `docs/ci-jobs.md`, `docs/tasks/T-027.md`, komentar `password.spec.ts`; tanpa assertion latency CI. Rencana + batas jujur: `docs/tasks/T-060.md`. **19 Okt 2026 DONE**: ukur orkestrator (release, reps=5) `N=0` 250 ms / `N=5` 671 ms (anggaran < 2 s lolos); biner debug (e2e) `N=0` 5,05 s / `N=5` 13,61 s ≈ 20x; `./task check` exit 0 |
| T-061 | DONE | T-044 H1: jalur DB tidak punya batas waktu klien — `pqconnectdb(conninfo)` + `connect_timeout` (`KRAN_DB_CONNECT_TIMEOUT_MS`) dan keepalive untuk koneksi membeku; test regresi black-hole | §21.3 | T-044 | **19 Okt 2026 DONE** (D-064): `pqconnectdb(connInfo)` menggantikan `pqsetdbLogin`; `connect_timeout` dari `KRAN_DB_CONNECT_TIMEOUT_MS` (default 5000, minimum libpq 2 s) + `keepalives=1 keepalives_idle=5 keepalives_interval=5 keepalives_count=2`; nilai conninfo di-quote (password berkutip/backslash diuji unit). Bukti: `tdbconnect` 6 `[OK]` — black-hole gagal **2,01 s** (tanpa fix: menggantung), kontrol port tertutup tetap cepat; `tconfig` diperluas (`0` ditolak); `itpool` 10 `[OK]`; `itapi_auth` 43 `[OK]`; `./task check` exit 0. Sisa jujur: **deadline per-query** belum ada (keepalive ±15 s) — D-064. **HUMAN-REVIEW-REQUIRED (jalur koneksi produksi)** |
| T-062 | DONE | T-044: proses `kran-api` bocor di `apps/web/tests/e2e/shutdown.spec.ts` — `startApi()` di luar `try/finally` | §21.3 | T-044 | Bila `startApi()` gagal/timeout, tidak ada anak `kran-api` tersisa; subset e2e `shutdown` hijau. **19 Okt 2026 DONE**: helper membersihkan dirinya sendiri (`SIGKILL` + tunggu `exit`, galat membawa `pid`) dan punya opsi `healthPath`/`readyTimeoutMs`; test baru membuktikan PID mati setelah gagal-disengaja (rute 404, batas 1,5 s). Bukti: `playwright test shutdown.spec.ts` **3 passed** (9,1 s), tanpa proses sisa (`pgrep kran-api` kosong) |
| T-065 | TODO | Deadline **per-query** (D-064 sisa): koneksi yang membeku di tengah kueri baru diputus keepalive ±15–20 s | §12.1 | T-061 | Kueri pada koneksi beku gagal ≤ 5 s (libpq nonblocking + `PQsocket`/`PQconsumeInput`), atau batas diterima dicatat ulang di `docs/ACCEPTED-LIMITS.md` dengan alasan baru; test regresi tidak boleh menggantung |
| T-064 | DONE | Daftar audit terurut **leksikografis** setelah ledger melewati 100 baris (`ORDER BY seq` menunjuk kolom keluaran `seq::text`), sehingga baris terbaru hilang dari halaman — ditemukan lewat e2e `flow.spec.ts` merah | §18.2 | T-044 | **19 Okt 2026 DONE**: `ORDER BY audit_log.seq DESC` (kolom tabel). Bukti: `GET /api/v1/audit?limit=20` mengembalikan `99,98,…,90,9,89,…,81` padahal `max(seq)=231`; test regresi `itplatform` (menulis >100 baris, tuntut baris teratas = `max(seq)`) **FAILED** dengan SQL lama (uji mutasi) dan OK dengan SQL baru (`./task test itplatform` 25 `[OK]`); `playwright test flow.spec.ts` 6 passed |
| T-063 | DONE | T-044 H2/H3: `globalTimeout` Playwright 8–10 menit + eksperimen pemisah (suspend vs runner) | §21.3 | T-044 | **19 Okt 2026 DONE**: `globalTimeout: 8 * 60_000` (run normal 25 s Playwright). Eksperimen dicatat di T-044: `caffeinate -i ./task e2e` 24 passed (25,0 s, tanpa `Entering Sleep`), `PWTEST_CHILD_PROCESS_TIMEOUT=20000 ./task e2e` 24 passed (26,2 s, nol "did not exit within") → **hasil nol** (tidak ada run macet; H2/H3 belum terpisah) |
