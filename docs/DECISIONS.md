# DECISIONS — KRAN

Keputusan **engineering** yang diambil saat implementasi dan tidak ada di spec §25.
Keputusan arsitektur yang sudah bernomor di spec (`ADR-001`…`ADR-015`) tetap di
`docs/adr/`. Kalau sebuah keputusan di sini bertumbuh besar/mengubah arsitektur,
naikkan jadi ADR bernomor.

Format: konteks → keputusan → konsekuensi → alternatif → status.

---

## D-001 — Satu pintu perintah: skrip POSIX `./task`

- **Konteks**: AGENTS.md §2 dan spec §7 mewajibkan `task check|test|e2e|ci` sebagai satu pintu
  untuk developer dan CI. Spec menyebut `Taskfile`/`just`.
- **Keputusan**: memakai skrip POSIX `./task` di root repo, dijalankan sebagai `./task check`.
- **Alasan**: `task` (go-task) dan `just` tidak terpasang; memasangnya menambah dependensi
  tooling di laptop + installer baru di CI, padahal orkestrasinya sederhana. §5.3 KISS.
- **Konsekuensi**: perintah ditulis `./task …` (bukan `task …` tanpa `./`). Skrip wajib
  POSIX-sh (jalan di dash CI dan sh macOS). Kalau tim bertambah dan butuh fitur Taskfile
  (watch, deps graph), migrasi mudah: skrip ini tipis.
- **Alternatif**: `just`; `Taskfile` + `arduino/setup-task` di CI. Ditolak untuk sekarang.
- **Status**: diterima (bisa diveto pemilik).

## D-002 — Satu paket nimble untuk seluruh monorepo

- **Konteks**: spec §7 punya `shared/`, `modules/*`, `apps/api`, `tools/*` sebagai paket logis.
- **Keputusan**: satu `kran.nimble` di root; direktori sumber di-`-p:` oleh `./task`.
- **Alasan**: nimble workspace/multi-paket menambah konsep & langkah untuk nilai kecil di Fase 0.
  Satu resolusi dependensi = satu lockfile = satu nimcache.
- **Konsekuensi**: `nimble install -d -y` memasang seluruh dependensi. Modul tetap terpisah
  secara arsitektur lewat `archcheck` (bukan lewat batas paket nimble).
- **Alternatif**: satu `.nimble` per modul + `nimble develop`. Ditolak (overhead).
- **Status**: diterima; tinjau ulang bila jumlah modul membuat nimcache lambat.

## D-003 — Dependensi Nim Fase 0 dipin

- **Konteks**: spec §12.1 mewajibkan minim dependensi + ADR per dependensi (risiko ekosistem).
- **Keputusan**: `db_connector` 0.1.0 (PostgreSQL) dan `yaml` 2.2.1 (nimYAML, untuk
  `seeds/params.yaml`). Tidak ada dependensi lain (JSON, regex, times dari stdlib;
  property test memakai harness sendiri).
- **Konsekuensi**: versi dipin di `kran.nimble`; `yaml` dipakai **hanya** oleh `tools/paramgen`
  (build-time), tidak masuk jalur runtime API → risiko ekosistem terkurung.
- **Status**: diterima; kandidat diangkat jadi ADR-016 bila `paramgen` jadi alat kritis.

## D-004 — DB dev & integration test di server (bukan lokal)

- **Konteks**: uji integrasi butuh Postgres ≥16 (spec §21.3). Pemilik menolak setup Postgres
  lokal; server sudah punya `qouver-postgres` (Postgres 18.6).
- **Keputusan**: DB khusus `kran_dev` + role `kran_dev` di server tersebut, diakses dari laptop
  lewat tunnel SSH `127.0.0.1:55432 → 127.0.0.1:5432`. URL (berisi password) disimpan di
  `.local/dev.env` (gitignored, `chmod 600`). Env var: `KRAN_DATABASE_URL`.
  CI **tidak** memakai server: `services: postgres:18` di GitHub Actions.
- **Konsekuensi**:
  - Uji integrasi **melewati dirinya sendiri** bila `KRAN_DATABASE_URL` kosong (pola sama
    dengan repo keluarga `cbs-core`) → `./task test` aman tanpa DB, tapi tidak dianggap bukti.
  - DB `kran_dev` ikut ter-backup harian server sampai skrip backup di server di-exclude
    (di luar repo) → dicatat `docs/OPEN_ITEMS.md` O-002.
  - DB `cbs` milik `cbs-core` **tidak disentuh**; tidak ada perubahan config/backup/hook di server.
- **Alternatif**: Postgres lokal via Docker (ditolak pemilik); hanya CI (verifikasi lokal lemah).
- **Status**: diterima pemilik (dikonfirmasi di sesi 2026-10-13).

## D-005 — Skrip SQL multi-pernyataan dijalankan lewat `PQexec`, bukan `db_postgres.exec`

- **Konteks**: `db_connector` (`db_postgres.exec`) selalu memakai `PQexecParams`, yang hanya
  menerima **satu** pernyataan; berkas migrasi berisi banyak pernyataan, termasuk badan fungsi
  PL/pgSQL. Sebaliknya, parameterisasi query biasa tetap memakai API `db_connector`
  (`?` + argumen, di-escape client-side oleh `dbQuote`).
- **Keputusan**: `tools/dbtools.execScript` memanggil `pqexec` (libpq langsung) hanya untuk
  menjalankan berkas migrasi & bootstrap; semua query aplikasi tetap lewat `db_connector`.
- **Konsekuensi**: satu titik pemakaian API tingkat rendah, terkurung di runner migrasi; pesan
  error diambil dari `pqresultErrorMessage`/`pqerrorMessage`.
- **Alternatif**: memecah berkas migrasi per pernyataan, atau menambah dependensi runner lain
  (ditolak: nilai tambahnya kecil, risikonya lebih besar).

## D-006 — Hash rantai audit dihitung di database

- **Konteks**: hash chain harus tidak bisa dilewati oleh jalur tulis mana pun, dan hasil
  verifikasi harus stabil lintas sesi (timezone/`DateStyle` berbeda).
- **Keputusan**: trigger `platform.audit_log_chain` mengisi `prev_hash` + `hash` memakai
  `pgcrypto.digest('sha256')` atas payload kanonik (`platform.audit_log_payload()`, UTC
  eksplisit, tanggal ISO). Aplikasi tidak pernah menulis kolom hash.
- **Konsekuensi**: rantai ikut menyerialkan append (`pg_advisory_xact_lock`) — aman untuk
  volume Fase 0, dicatat sebagai risiko skala. Menambah/mengubah kolom payload = seluruh baris
  lama dianggap rusak sampai fungsi payload disesuaikan (didokumentasikan di `MODULE.md`).
- **Alternatif**: hash di Nim (ditolak: bisa dilewati, dan menambah implementasi hash sendiri).

## D-007 — Tunnel dev DB tidak boleh mati di tengah sesi

- **Konteks**: master koneksi SSH `ControlPersist=600` menutup tunnel setelah 10 menit idle →
  test integrasi gagal `Connection refused` di tengah sesi panjang (kejadian nyata 2026-10-13).
- **Keputusan**: `tools/devdb.sh` menerima `KRAN_DEVDB_PERSIST` (default tetap 600 detik);
  nilai panjang (7200) diset di `.local/dev.env` (mesin-lokal, gitignored).
- **Konsekuensi**: perilaku default repo tidak berubah; sesi kerja lokal tidak lagi terputus.

## D-008 — Baris SUPERSEDED tetap menjawab tanggal lampau; EXCLUDE mencakup ACTIVE + SUPERSEDED

- **Konteks**: saat nilai baru diaktifkan, nilai lama harus berhenti berlaku. Bila nilai lama
  hanya ditandai `SUPERSEDED` dan query `as_of` menyaring `status = 'ACTIVE'`, maka tanggal
  historis kehilangan nilai (gap) — terdeteksi oleh test resolusi/supersede (T-005).
- **Keputusan**: `approve` memangkas `effective_to` nilai lama (= `effective_from` baru) dan
  menandainya `SUPERSEDED`; query nilai berlaku menyertakan `ACTIVE` **dan** `SUPERSEDED`.
  EXCLUDE `btree_gist` menjangkau kedua status supaya riwayat tidak bisa dibuat ambigu.
- **Konsekuensi**: satu nilai tunggal per (key, scope, tanggal) tetap terjaga, riwayat utuh,
  dan PENDING/DRAFT/REJECTED tidak ikut menghalangi aktivasi.

## D-009 — Aturan tempat seed pack (paramgen) & makna ACTIVE untuk nilai pack

- **Konteks**: nilai awal pack harus ditulis di scope yang benar. Sebelumnya tool menebak
  (`scopes[0]`, mis. `INSTITUTION` dengan `scope_id = 'base'`) — `scope_id` palsu yang tidak
  akan pernah cocok dengan institusi nyata.
- **Keputusan**: `paramgen` menyemai di `SEGMENT` (scope_id = nama pack) bila parameter
  mengizinkan `SEGMENT`, selain itu `GLOBAL`; bila keduanya tidak diizinkan → **gagal** dengan
  pesan jelas. Sebagai konsekuensi, parameter yang butuh nilai awal menambahkan `GLOBAL` ke
  `scopes` (keputusan pemilik parameter, bukan tool).
- Nilai pack disemai sebagai `ACTIVE` oleh dua UUID sistem (pack generator & pack reviewer):
  pack adalah artefak repo yang di-review pada commit, bukan perubahan runtime — invarian
  `checker <> maker` tetap utuh.
- **Konsekuensi**: paket parameter tidak bisa lagi menyemai nilai untuk parameter yang hanya
  `INSTITUTION`/`BRANCH`/`PRODUCT`; itu memang harus diputuskan manusia.

## D-010 — `db_connector.getRow` tidak bisa dipakai untuk "tidak ditemukan"

- **Konteks**: `db_postgres.getRow` mengembalikan `Row` berisi kolom kosong (bukan `Row`
  kosong) bila hasilnya 0 baris, sehingga `row.len == 0` bukan penanda "tidak ada". Ini sudah
  menyesatkan implementasi parameternya (query lanjutan memakai string kosong sebagai tanggal).
- **Keputusan**: modul memakai helper `singleRow` di atas `getAllRows` untuk mengambil opsional
  satu baris; `getRow` tidak dipakai di repo platform.
- **Konsekuensi**: satu helper kecil dan jelas; jebakan ini didokumentasikan di MODULE.md/T-005.

## D-011 — Koreksi DDL spec §9.3 (`business_date`)

- **Konteks**: contoh DDL `platform.business_date` di spec §9.3 **tidak valid di PostgreSQL 18**
  (diuji langsung ke DB dev, bukan dari ingatan):
  1. `current_date` sebagai nama kolom tanpa kutip = `syntax error` (bentrok kata kunci
     `CURRENT_DATE`); memakai tanda kutip di semua query akan mudah salah.
  2. `PRIMARY KEY (scope_type, COALESCE(scope_id, '...'))` = `syntax error` — Postgres tidak
     menerima ekspresi di kolom PRIMARY KEY (ekspresi hanya boleh di `CREATE INDEX`/`EXCLUDE`).
- **Keputusan**: kolom dinamai `current_business_date`; keunikan scope dijaga
  `CREATE UNIQUE INDEX business_date_scope_uq (scope_type, COALESCE(scope_id, ''))`, dan
  `scope_id` tetap `NULL` untuk scope akar (institusi). `scope_id` bertipe `text` (bukan `uuid`)
  supaya seragam dengan `platform.param_value.scope_id` (spec §10.2) dan `platform.holiday`.
- **Konsekuensi**: spec §9.3 perlu diperbarui saat ada kesempatan (bukan blocker). Tabel baru
  lain di modul `platform` mengikuti pola yang sama: `scope_id text` + unique index ekspresi.
- **Alternatif yang ditolak**: sentinel UUID untuk scope akar (mengubah makna "NULL = institusi"
  yang dipakai `param_value`) dan selalu mengutip `"current_date"` (rapuh, mudah terlewat).

## D-012 — `weekend_days` disemai di GLOBAL, bukan SEGMENT

- **Konteks**: parameter `platform.calendar.weekend_days` awalnya dideklarasikan dengan scope
  `[GLOBAL, BRANCH, SEGMENT]`. Aturan seed D-009 menyemai ke `SEGMENT` (scope_id = nama pack)
  bila `SEGMENT` diizinkan — akibatnya nilai awal hanya terbaca oleh pemanggil yang menyebut
  segmen `base`, dan pembacaan biasa (institusi/cabang) tidak menemukan nilai sama sekali.
- **Keputusan**: `scopes: [GLOBAL, BRANCH]` — nilai awal di `GLOBAL`, cabang boleh menimpa.
  Variasi pekan kerja per **segmen** ditunda; bila nanti dibutuhkan, itu mengubah aturan seed
  pack (D-009), bukan sekadar menambah baris seed.
- **Konsekuensi**: konsumen kalender tidak perlu tahu nama pack. Keterbatasan lookup institusi
  dari konteks cabang dicatat di OPEN_ITEMS O-012.

## D-013 — PBKDF2-HMAC-SHA256 (nimcrypto) untuk hashing password

- **Konteks**: T-006 butuh hashing password. Stdlib Nim 2.2 **tidak punya** SHA-256/HMAC
  (`std/sha1`, `std/md5` saja), sehingga pilihannya: menulis SHA-256 sendiri, memakai pustaka
  pure-Nim (`nimcrypto`, sudah terpasang 0.7.3 karena spike ADR-002), atau pustaka native
  (argon2/libsodium) yang harus tersedia di mesin dev **dan** server produksi.
- **Keputusan**: `nimcrypto` (dipin `>= 0.7.3` di `kran.nimble`), algoritma
  **PBKDF2-HMAC-SHA256** (RFC 2898 §5.2), parameter tersimpan bersama hash
  (`algo$iterasi$salt$digest`) sehingga perubahan kebijakan tidak mematahkan hash lama.
  Iterasi dari parameter `platform.security.password_pbkdf2_iterations` (default pack 600.000).
  Perbandingan digest waktu-tetap; token sesi di-hash dengan SHA-256 biasa (entropi 256-bit).
- **Alasan menolak alternatif**: menulis KDF sendiri = anti-pola kriptografi (dan tidak bisa
  diuji terhadap implementasi lain); dependensi native menambah beban operasional §21 tanpa
  manfaat di Fase 0.
- **Konsekuensi**: **HUMAN-REVIEW-REQUIRED** — area kriptografi. Vektor uji dihitung independen
  dengan Python `hashlib.pbkdf2_hmac` (`modules/platform/tests/tpassword.nim`). Bila institusi
  mensyaratkan Argon2id, penggantiannya lokal: hanya `password_hasher.nim` + satu ADR.

## D-014 — `platform.user` → `platform.app_user`

- **Konteks**: spec §9.2 menyebut tabel `platform.user`; `USER` adalah kata kunci SQL di
  PostgreSQL (reserved), sehingga nama itu harus dikutip di setiap query.
- **Keputusan**: tabel dinamai `platform.app_user`. Nama lain di daftar §9.2
  (`role`, `permission`, `role_permission`, `user_role`, `session`) aman dipakai apa adanya.
  Kolom tambahan buatan sendiri (spec hanya menyebut nama tabel): status/lockout/hash di
  `app_user`, `branch_id` di `user_role`, dan tabel `role_conflict` untuk matriks SoD §18.2.
- **Konsekuensi**: spec §9.2 perlu dikoreksi saat ada kesempatan. Bentuk kolom didokumentasikan
  di `modules/platform/MODULE.md`.

## D-015 — Bentuk katalog i18n: satu berkas datar per locale (+ plugin Paraglide dari CDN)

- **Konteks**: spec §16.2 mengusulkan `messages/{id,en}/<namespace>.json`. Saat implementasi,
  kompilasi Paraglide dengan pola `./messages/{locale}/{namespace}.json` **menghasilkan nol pesan**
  (compile "sukses", `_index.js` kosong) — diuji dengan dua bentuk isi (bersarang dan datar).
  Pola `./messages/{locale}.json` dengan isi datar bekerja.
- **Keputusan**: katalog = satu berkas datar per locale, key berprefiks namespace
  (`common_*`, nanti `deposit_*`). Namespace tetap dipaksakan sebagai **aturan key**
  (`tools/i18ncheck`: key wajib berbentuk `namespace_segmen`), jadi disiplin §16.2 tidak hilang,
  hanya lokasinya berpindah dari nama berkas ke nama key.
- **Keputusan kedua** (semula): plugin Paraglide diambil dari CDN jsdelivr versi pin, karena
  registry npm privat di mesin dev (`artifactory.pegadaian.co.id`) tidak resolve. **Direvisi pada
  2026-10-14** setelah ditemukan cara override registry (lihat D-018): plugin kini
  di-vendor sebagai devDependency `packages/i18n` dan dirujuk lewat jalur lokal
  (`./node_modules/@inlang/plugin-*/dist/index.js` dari direktori `packages/i18n`). Build web
  tidak lagi butuh jaringan.
- **Konsekuensi**: build web butuh jaringan sekali (atau plugin di-vendor setelah registry normal);
  dicatat O-021. Bila plugin versi baru memperbaiki pola `{namespace}`, migrasi murah karena
  prefix key sudah memisahkan namespace.

## D-016 — Kontrol tema & bahasa: grup radio native, bukan `<select>`

- **Konteks**: `page.keyboard` terhadap `<select>` **tidak mengubah nilai sama sekali** pada
  Chromium headless yang dipakai verifikasi (ArrowDown/Enter/End diabaikan), sehingga janji
  "alur kritis bisa keyboard-only" (§17.1) tidak dapat dibuktikan.
- **Keputusan**: tema (system/light/dark) dan bahasa (id/en) memakai `fieldset`+`legend`+radio
  native. Semantik lebih kaya, satu tab stop per grup, dan panah/`change` terbukti dapat diuji.
- **Konsekuensi**: jumlah locale yang besar nanti mungkin lebih nyaman dengan `<select>`; itu
  dapat ditinjau saat locale bertambah, dengan syarat jalur keyboard-nya bisa diuji.

## D-017 — `./task e2e` memakai binary lokal, bukan `pnpm run` (dan belum ada lockfile JS)

- **Konteks**: pnpm 10+ memasang ulang dependency lebih dulu bila menganggap `package.json`
  tidak sinkron dengan lockfile/store; di mesin ini install itu menyentuh registry privat yang
  tidak resolve sehingga perintah bisa menggantung (>10 menit, teramati).
- **Keputusan**: `./task e2e` memanggil `apps/web/node_modules/.bin/{playwright,svelte-check,
  svelte-kit,paraglide-js}` dan `packages/ui/node_modules/.bin/vitest` langsung. Deterministik
  lokal, dan tetap benar di CI setelah `pnpm install`.
- **Konsekuensi**: `pnpm-lock.yaml` **belum ada** — `pnpm install --lockfile-only` gagal
  (`ERR_PNPM_NO_OFFLINE_META` untuk `@bytecodealliance/jco-transpile`; registry privat tidak
  resolve). Versi dependency dipin eksak di `package.json` sebagai jaring sementara; job CI
  `web-e2e` memakai `pnpm install` sampai lockfile bisa dibuat (O-020).

## D-018 — Registry npm: override `pnpm_config_registry` + lockfile JS

- **Konteks**: dua upaya memasang paket baru gagal/menggantung karena `~/.npmrc` menunjuk
  `https://artifactory.pegadaian.co.id/repository/npm-group-1/` yang **tidak resolve** dari
  jaringan mesin ini (`nslookup` → NXDOMAIN, `curl` → 000). `npm_config_registry=…` **tidak**
  mengubah perilaku pnpm (pnpm membaca `pnpm_config_registry`), sehingga kegagalan tampak seperti
  masalah jaringan biasa.
- **Keputusan**: override registry lewat env var pnpm, hanya untuk perintah install:
  `pnpm_config_registry=https://registry.npmjs.org/ pnpm install …`. `~/.npmrc` milik pengguna
  tidak diubah (bukan milik repo).
- **Konsekuensi**: lockfile JS (`pnpm-lock.yaml`) **bisa** dibuat, lolos supply-chain policy pnpm
  organisasi, dan dipakai CI dengan `--frozen-lockfile`. Plugin Paraglide di-vendor lokal
  (D-015). Prosedur lengkap: `docs/runbooks/dev-web.md`.
- **Catatan**: perintah install tanpa override tetap akan menggantung, jadi runbook ini penting
  saat ada kontributor baru atau saat menambah dependency (mis. tooling OpenAPI di T-008).

## D-019 — ADR-002: Mummy sebagai server HTTP + WebSocket untuk realtime

- **Konteks**: spike T-014 mengukur Mummy 0.4.8 (54.341 rps), Prologue (46.094), hand-rolled
  `std/asyncnet` (18.824, terhukum `Connection: close`). Mummy tidak punya API streaming (SSE
  tidak mungkin tanpa soket mentah); Mummy/Prologue memanggil handler di thread sehingga handler
  **boleh blocking** — penting karena spec §12.1 mewajibkan `db_connector` sinkron (di model async
  satu query PG membekukan seluruh API; pengalaman `fond` D-17).
- **Keputusan (pemilik, 2026-10-14, menjawab E-001)**: **Mummy** untuk HTTP/REST + **WebSocket**
  untuk realtime. Deviasi spec §19.1 (SSE → WS) disetujui; spec §19.1/§13 diperbarui hari yang sama.
- **Konsekuensi**:
  - Endpoint realtime tetap `GET /api/v1/events/stream` (upgrade WS); amplop pesan tetap
    `id`/`topic`/`payload`; `Last-Event-ID` diganti *resume token* yang diputar ulang dari outbox.
  - Frontend memakai shim mirip `EventSource` di atas WS (satu tempat, T-009/T-012).
  - Binari multi-role (`--role=api|worker|migrate|ctl`) dan `/healthz`,`/readyz` yang ditunggu
    `ops/` (O-013, O-019) menjadi mungkin dan dikerjakan bersama server ini.
  - Mengganti server di kemudian hari hanya menyentuh lapisan transport (rute/handler terpisah
    dari use case), karena handler tetap memanggil use case yang sama.

## D-020 — Tooling kontrak API: `openapi-typescript` + `openapi-fetch` + Spectral

- **Konteks**: spec §13 menetapkan OpenAPI 3.1 sebagai sumber kebenaran, klien TS di-generate
  (`openapi-typescript` + pembungkus fetch tipis), dan "OpenAPI lint hijau" jadi kriteria T-008.
  Menulis generator/linter sendiri = memelihara parser OpenAPI (pekerjaan besar, mudah salah).
- **Keputusan**: `openapi-typescript@7.13.0` (tipe), `openapi-fetch@0.17.0` (klien tipis tanpa
  runtime dependensi), `@stoplight/spectral-cli@6.17.0` + `spectral:oas` sebagai linter. Versi
  dipin eksak; semua masuk `pnpm-lock.yaml`. Gate: `./task openapi`
  (`spectral --fail-severity warn`, regen tanpa diff, `tsc -p packages/api-client --noEmit`).
- **Alasan menolak alternatif**: `@hey-api/openapi-ts` (bagus tapi menghasilkan runtime yang lebih
  besar dan tidak diminta spec); generator tulisan sendiri (menambah permukaan bug di area yang
  bukan keunggulan kita); tanpa linter (kriteria "lint hijau" jadi klaim kosong).
- **Konsekuensi**: ruleset awal = `spectral:oas` **tanpa override** supaya ambangnya ketat
  (fail-severity `warn`); bila nanti muncul aturan yang tidak relevan, override wajib disertai
  alasan tertulis di `.spectral.yaml`. Validator bentuk respons tetap milik kita
  (`tools/openapi`) dan hanya mendukung subset JSON Schema yang dipakai — batas ini dicatat.

## D-021 — Realtime: NOTIFY di INSERT outbox, resume token `outbox_id`, kebijakan tolak-semua

- **Konteks**: T-009 harus mengalirkan peristiwa platform ke UI (spec §19.1) **dan** menjamin
  reconnect tidak kehilangan peristiwa (§19.2), tanpa role dispatcher/worker yang berdiri (O-013)
  dan tanpa otorisasi sesi yang selesai (T-012 belum dikerjakan).
- **Keputusan**:
  1. Sinyal realtime = trigger `AFTER INSERT` pada `platform.outbox` yang `pg_notify('kran_outbox',
     outbox_id)` (migrasi 0007). Payload hanya id; isi peristiwa dibaca dari tabel. Dispatcher
     outbox tetap pemilik status `PENDING→DONE/DEAD`.
  2. Amplop peristiwa (`packages/contracts/events/realtime-envelope.v1.schema.json`) memakai
     `outbox_id` sebagai `id` **dan** resume token; urutan replay memakai kolom `seq`
     (`bigint identity`), bukan `occurred_at` (bisa sama). Token tak dikenal = replay dari awal,
     klien de-dup by `id`.
  3. Pump memulai dari peristiwa terakhir ("mulai dari sekarang"); backlog diambil klien lewat
     `resumeFrom` atau HTTP. Kesiapan pump diekspos lewat `pumpReady()`.
  4. Kebijakan topik default = **tolak semua** (`denyPolicy`) sampai T-012 memasang identitas sesi;
     identitas sudah dibaca dari cookie `kran_session`/`Authorization: Bearer`. Topik yang ditolak
     dilaporkan di balasan `subscribed.denied`.
  5. Batas protokol (32 topik, 128 karakter) adalah **konfigurasi transport** (`apps/api`) dan
     dikirim ke lapisan application sebagai `SubscriptionLimits` — lapisan application tidak memuat
     literal (spec §10.4), dan `lint-nomagic` tetap hijau tanpa escape hatch.
- **Alasan menolak alternatif**: NOTIFY dari dispatcher (UI bergantung pada komponen yang belum ada);
  hub dengan antrean/kuota per langganan (tidak ada sinyal "sudah terkirim" dari transport → gate
  palsu; kebutuhan itu dicatat O-028); membuka stream tanpa otorisasi (spec §18.2); menyimpan batas
  protokol sebagai angka di `application/` (melanggar §10.4 atau memaksa escape hatch `nomagic:ok`,
  dan itu otomatis dieskalasi per AGENTS.md §5).
- **Konsekuensi**: UI memakai shim mirip `EventSource` di atas WS (satu tempat, T-012); pump mati
  harus diperiksa `/readyz` (O-029); kuota klien lambat belum ada (O-028); nilai batas protokol
  belum parameter DB (O-030).

## D-022 — Dua bug yang ditemukan test T-009 (validator kontrak & ambang Spectral 101)

- **Konteks**: test ujung-ke-ujung T-009 memakai `tools/openapi` untuk memvalidasi amplop peristiwa
  dan memvalidasi respons 426 pada operasi realtime. Keduanya memunculkan masalah gate, bukan
  masalah fitur.
- **Keputusan**:
  1. `tools/openapi/lib.nim`: pemeriksaan `additionalProperties` memakai operator `{}`
     (`schema{"additionalProperties"}.kind`) yang mengembalikan **nil** bila kunci tidak ada →
     dereference nil → SIGSEGV. Diperbaiki dengan pemeriksaan `nil` eksplisit. Validator tidak
     boleh mati: ia harus melaporkan temuan atau tidak, tidak boleh menghentikan proses.
  2. `.spectral.yaml`: satu override untuk operasi `/api/v1/events/stream` mematikan aturan
     `operation-success-response`. Aturan itu menganggap hanya 2xx/3xx sebagai sukses, sedangkan
     WebSocket upgrade dijawab **101** (RFC 9110 §15.2.2). Alternatifnya (menambah respons 2xx yang
     tidak pernah dikirim) berarti mengubah perilaku demi lint. Override dipersempit ke satu
     operasi dan alasannya tertulis di berkas ruleset.
- **Konsekuensi**: deviasi gate tercatat dan sempit; bila nanti ada operasi 101 lain, override harus
  diperluas dengan alasan yang sama, bukan mematikan aturan secara global.

## D-023 — Seed user dev/e2e lewat `dbtools seed` (bootstrap produksi tetap terbuka)

- **Konteks**: alur T-012 (login → maker-checker → audit → realtime) butuh user nyata di DB dengan
  izin terpisah (pengaju vs penyetuju). Tanpa itu, alur ujung-ke-ujung hanya bisa diuji dengan
  menyuntik baris langsung di test — tidak menguji login/izin yang sebenarnya.
- **Keputusan**:
  1. `packs/base/seed/0001_dev_users.sql` memuat user sintetis `dev.maker`/`dev.checker`
     (kata sandi dev, izin `platform.param.submit` vs `platform.param.approve`) dengan penanda
     jelas di berkasnya: **DEV/TEST ONLY**.
  2. Perintah `./task dbtools seed [--dev]`: seed pack selalu idempoten; bagian dev **hanya**
     dijalankan dengan flag `--dev` (dipakai `./task e2e`, bukan bagian alur produksi).
  3. Nilai bisnis tidak ditanam di seed user (hanya identitas + izin role), dan `default_pack`
     parameter tetap satu-satunya tempat nilai awal (spec §10.3).
- **Alasan menolak alternatif**: menaruh user dev di migrasi (dijalankan produksi) akan mengirim
  akun dengan kata sandi yang diketahui ke lingkungan nyata; menyuntik baris di test menghilangkan
  cakupan login/otorisasi.
- **Konsekuensi / item terbuka**: **bootstrap user produksi belum diputuskan** (siapa admin pertama,
  kata sandi awal, wajib ganti saat login pertama) → `docs/OPEN_ITEMS.md` O-031. Jangan menebaknya
  di kode.

## D-024 — Otorisasi topik realtime mengikuti sesi, tanpa wildcard implisit

- **Konteks**: D-021 menetapkan kebijakan default **tolak semua** sampai ada identitas, dan T-012
  adalah tempat sesi dipasang. Muncul pertanyaan kedua: apakah klien boleh meminta `*`.
- **Keputusan**:
  1. `access.nim` memetakan topik yang diminta ke izin nyata (`param.changed` →
     `platform.param.read`) dan hanya mengizinkan topik yang **disebut eksplisit**.
  2. `*` selalu ditolak; topik yang ditolak dilaporkan di `subscribed.denied` supaya klien tahu
     bedanya "tidak ada peristiwa" dan "tidak berhak".
  3. Aturan ini sama dengan `splitAllowed` di hub: tidak ada dua definisi wildcard di dua lapisan.
- **Alasan menolak alternatif**: memperluas `*` menjadi "semua topik yang boleh" membuat arti
  langganan bergantung pada waktu (izin bisa berubah) dan menyembunyikan topik yang benar-benar
  dibutuhkan klien; juga menambah permukaan bagi bug izin yang senyap.
- **Konsekuensi**: klien wajib menyebut topiknya (UI T-012 mengirim `["param.changed"]`). Bila
  nanti jumlah topik per layar membengkak, urutanannya tetap eksplisit di sisi klien.

## D-025 — Satu origin: proxy dev/preview untuk `/api` (cookie `SameSite=Strict`, tanpa CORS)

- **Konteks**: spesifikasi menetapkan cookie sesi `HttpOnly` + `Secure` + `SameSite=Strict` (§13).
  Kalau halaman dilayani origin Vite dan API di origin/port lain, browser tidak akan mengirim
  cookie pada permintaan lintas-situs, sehingga pilihannya cuma melonggarkan cookie atau
  mengaktifkan CORS + `credentials` (dan tetap repot dengan `SameSite`).
- **Keputusan**:
  1. `apps/web/vite.config.ts` meneruskan `/api`, `/healthz`, `/readyz` ke `kran-api`
     (`KRAN_API_TARGET`, default `http://127.0.0.1:8080`), dengan `ws: true` untuk upgrade
     `/api/v1/events/stream` (spec §19.3).
  2. Aplikasi web selalu berbicara same-origin (`baseUrl` klien kosong); tidak ada penanganan token
     di JS dan tidak ada konfigurasi CORS di API.
  3. Produksi memakai bentuk yang sama: satu origin di belakang Caddy (halaman + `/api`).
- **Alasan menolak alternatif**: melonggarkan `SameSite` melemahkan pertahanan CSRF yang justru
  diminta spec; CORS + `credentials` menambah jalur kode baru yang harus diuji di dua mode.
- **Konsekuensi**: `apps/web/playwright.config.ts` menyalakan API di port e2e (8099) dan menyetel
  `KRAN_API_TARGET`, supaya e2e menguji origin tunggal yang sama seperti dev/produksi.

## D-026 — `webServer` Playwright me-`source` `.local/dev.env` (variabel `DYLD_*` tidak diwariskan)

- **Konteks**: `apps/api` memuat libpq lewat `dlopen`. Di mesin dev ini libpq Homebrew bersifat
  keg-only, jadi hanya ditemukan lewat `DYLD_FALLBACK_LIBRARY_PATH` dari `.local/dev.env`.
  `./task e2e` mengekspor variabel itu, tetapi `webServer` Playwright menjalankan perintahnya lewat
  shell perantara ber-hardened dan dyld **menghapus** variabel `DYLD_*` di batas proses seperti itu
  (diuji langsung: `node` melihat variabelnya, anak yang di-`spawn` lewat `sh -c` tidak). Akibatnya
  binary API gagal start dengan "could not load: libpq.dylib" — padahal dijalankan manual baik-baik
  saja.
- **Keputusan**:
  1. Perintah API di `apps/web/playwright.config.ts` me-`source` `.local/dev.env` sendiri
     (`set -a; [ -f … ] && . … ; set +a; exec …`) lalu `exec` binary-nya. Menyetel variabel di shell
     yang sama dengan `exec` membuatnya selamat; mengandalkan pewarisan lewat `env` webServer tidak.
  2. Lingkungan proses induk tetap diteruskan eksplisit (`...inheritedEnv`) supaya `PATH` dan
     variabel lain tidak hilang bila Playwright mengganti (bukan menggabung) lingkungan.
  3. Berkas `.local/dev.env` opsional: bila tidak ada (CI), perintah tetap berjalan dan sumber
     konfigurasi datang dari `env` webServer seperti semula.
- **Konsekuensi**: konfigurasi e2e memuat satu baris shell yang spesifik mesin dev, dengan alasan
  tertulis. Bila kelak libpq tersedia di jalur sistem (atau API memakai driver tanpa `dlopen`),
  baris itu bisa dihapus.

## D-027 — Dua temuan MAJOR review batch Fase 0 dan cara menutupnya

- **Konteks**: review independen atas diff Fase 0 (`5964665..1f681ac`, konteks bersih, prompt di
  `docs/agent/REVIEWER.md`) memutuskan **TIDAK APPROVE** dengan dua temuan MAJOR. Keduanya di jalur
  akses/integritas, bukan soal gaya. Reviewer juga memverifikasi sendiri `./task check` dan
  `./task test` (exit 0, 410 `[OK]`) sehingga angka bukti di commit bukan klaim sepihak.
- **Temuan 1 — persetujuan ganda bisa lolos (4-eyes bocor)**. `approveValue` memeriksa status lewat
  SELECT (snapshot READ COMMITTED) dan UPDATE aktivasi akhirnya tidak menyebut status. Dua checker
  yang menyetujui nilai yang sama hampir bersamaan bisa dua-duanya "berhasil": dua audit
  `param.approve`, dua event `param.changed`, `checker` tertimpa, dan 409 `not_pending` yang
  dijanjikan kontrak tidak pernah terjadi.
  **Perbaikan**: langkah aktivasi dipisah ke `activatePending` dengan penjaga optimistik
  `AND status = 'PENDING'`. Yang kalah melihat 0 baris → `ValueError` → transaksi dibatalkan
  pemanggil → 409 `not_pending`. Supersede tetap dijalankan lebih dulu (urutan itu dibutuhkan
  EXCLUDE karena baris ACTIVE lama masih menutupi periode baru), dan pembatalan transaksi
  mengembalikan status baris lama — jadi tidak ada keadaan "lama sudah dipangkas, baru gagal".
  **Bukti**: test `itparam` "aktivasi hanya dari PENDING (penjaga anti double-approve)" — GAGAL bila
  klausa penjaganya dilepas (diverifikasi dengan melepasnya sementara, lalu dikembalikan).
  **Catatan jujur**: harness test belum memakai `--threads:on`, jadi balapan dua koneksinya tidak
  direproduksi; yang diuji adalah kontrak langkah aktivasi → O-040.
- **Temuan 2 — kombinasi parameter yang sah per-key bisa mematikan seluruh login**.
  `session_idle_minutes` (1..1440) dan `session_absolute_minutes` (5..1440) masing-masing sah
  menurut schema-nya, tetapi idle > absolut membuat `sessionPolicy` melempar `ValueError`. Handler
  login hanya menangkap `DbError` → 500 mentah tanpa amplop, dan pemulihannya mustahil lewat UI
  (memperbaiki parameter butuh login) sehingga butuh akses DB langsung.
  **Perbaikan**:
  1. `auth_service.sessionPolicyCandidateProblem` menilai **calon nilai** terhadap nilai sisi lain
     yang sedang aktif memakai aturan domain `sessionPolicy`; dipanggil saat pengajuan (400) dan
     saat persetujuan (409 `invalid_combination`) — di persetujuan juga perlu, karena dua pengajuan
     yang masing-masing sah bisa bertabrakan setelah salah satunya aktif.
  2. `handleLogin` menjawab `ValueError` kebijakan sebagai `problem+json` (kontrak `Problem` belum
     punya 503, jadi 500 + sebab di `detail`), dan perpanjangan best-effort di `handleSession`
     menelan `ValueError` tanpa menggagalkan permintaan.
  **Bukti**: `itapi_auth` "pengajuan yang membuat idle > absolut ditolak 400, tanpa efek samping"
  dan "persetujuan yang membuat kombinasi tidak sah ditolak 409 (dua pengajuan sah)"; `itauth` untuk
  fungsi pemeriksanya (batas sah, key lain, nilai bukan integer).
- **Alasan memilih pemeriksaan eksplisit, bukan mekanisme umum**: framework parameter belum punya
  konsep invariant lintas-key; menambahkannya adalah fitur (butuh ADR + bentuk deklarasi di
  `params.yaml`), bukan perbaikan temuan. Pasangan kebijakan sesi adalah satu-satunya aturan
  lintas-parameter yang diminta spec (§18.2). Fungsinya diberi nama dan alasan jelas supaya mudah
  digeneralisasi bila aturan kedua muncul (O-041).
- **Konsekuensi**: deskripsi 409 di kontrak OpenAPI menyebut `invalid_combination` (klien TS
  diregenerasi). Temuan MINOR dari review dicatat sebagai O-034…O-039, tidak ditutup di sini.

## D-028 — Pemeriksaan kebijakan sesi: timeline (bukan satu tanggal) + kunci serialisasi

- **Konteks**: ronde 2 review independen menilai penjaga double-approve (D-027) tertutup, tetapi
  menemukan bahwa pemeriksaan lintas-parameter masih bocor di dua jalan:
  1. **Jendela tanggal efektif depan** (deterministik): calon nilai dinilai hanya pada tanggal buku
     hari ini, sedangkan perubahan mendukung `effectiveFrom` masa depan. idle/absolut yang
     masing-masing sah hari ini bisa menjadi tidak sah pada tanggal efektifnya — dan lockout-nya
     baru muncul keesokan hari, tanpa balapan.
  2. **Balapan dua key**: dua persetujuan bersamaan (satu untuk `idle`, satu untuk `absolut`) yang
     masing-masing sah terhadap nilai lawan yang **sudah** commit bisa dua-duanya lolos, karena
     tidak ada serialisasi antar-key (kunci baris `supersede` hanya menyentuh key yang sama).
- **Keputusan**:
  1. Penilaian dilakukan pada **himpunan tanggal**, bukan satu tanggal: hari ini, tanggal efektif
     calon, dan tanggal mulai efektif sisi lainnya yang **sudah disetujui** (`ACTIVE`) dan belum
     lewat. Tanggal-tanggal itu adalah satu-satunya titik di mana kombinasi bisa berubah, sehingga
     perubahan ber-tanggal depan dinilai pada tanggal yang benar — termasuk perubahan sisi lain yang
     disetujui setelah perubahan kita.
  2. Nilai calon dipakai hanya untuk tanggal ≥ tanggal efektifnya.
  3. Bila salah satu sisi belum punya nilai pada tanggal itu, tanggal itu **dilewati** — bukan
     ditolak: keadaan belum lengkap harus tetap bisa **diperbaiki** lewat alur normal (prinsip yang
     sama dengan D-027 butir 2).
  4. `pg_advisory_xact_lock(hashtext('platform.security.session_policy'))` diambil **sebelum**
     pemeriksaan, di dalam transaksi pengajuan/persetujuan, sehingga "periksa lalu aktifkan"
     menjadi atomik untuk pasangan key ini. Dilepas otomatis di akhir transaksi.
  5. Penilaian memakai konteks scope yang sama dengan tempat aplikasi membaca kebijakan sesi
     (`institutionScope()`, spec §13/§18.2); untuk calon ber-scope lain, scope calon itu sendiri.
  **Revisi**: butir ini diubah oleh D-029 butir 3 — penilaian kini **selalu** memakai konteks baca
  aplikasi, termasuk untuk calon ber-scope lain.
- **Alasan menolak alternatif**: **trigger/constraint DB** akan memindahkan aturan domain ke SQL dan
  jauh lebih sulit dibaca/diuji (dan tetap butuh kunci advisory untuk serialisasi); **menolak
  perubahan ber-tanggal depan** untuk kedua key ini akan melarang fitur efektif-dated yang diminta
  spec §10.2; **daycloser** hanya mendeteksi setelah terlambat, sedangkan temuan ini soal mencegah.
- **Keputusan lain yang dicatat di sini (pertanyaan reviewer)**: percobaan yang **ditolak** (400/409)
  tidak ditulis ke audit maupun outbox. Alasannya: tidak ada perubahan keadaan yang perlu
  dipertanggungjawabkan, dan itu konsisten dengan 409 lain (`not_pending`, `self_approval`,
  `period_conflict`) serta percobaan login gagal yang sudah punya jalurnya sendiri
  (`auth.login.failure`). Bila kelak audit percobaan ditolak diperlukan (mis. kepatuhan), itu
  perubahan kebijakan audit tersendiri — bukan tambahan diam-diam di sini.
- **Konsekuensi**: pemeriksaan ini kini butuh membaca riwayat tanggal kedua key (satu query kecil
  per pemeriksaan) dan mengambil kunci advisory; keduanya hanya terjadi untuk pasangan parameter
  kebijakan sesi, bukan untuk semua perubahan parameter. Sisa keterbatasan: validasi hanya berlaku
  pada pasangan ini (aturan lintas-parameter lain belum ada di spec → O-041).

## D-029 — Ronde 3 review: memperketat himpunan tanggal pemeriksaan kebijakan sesi

- **Konteks**: ronde 3 review independen menilai serialisasi lintas-key **benar** (kunci advisory
  dilepas hanya saat commit; urutan kunci → audit selalu sama sehingga tidak menimbulkan deadlock
  baru) dan penilaian tanggal-depan **menutup kasus paling sederhana**, tetapi menemukan empat
  lubang di himpunan tanggal + test yang tidak membedakan kode lama/baru.
- **Keputusan**:
  1. `param_repo.committedFromDates` menyertakan `SUPERSEDED`, bukan hanya `ACTIVE` — baris
     ber-tanggal depan yang kemudian dipangkas baris yang lebih akhir tetap berlaku sampai
     `effective_to`-nya (pola riwayat effective-dated, `activeValueSql`/D-008), jadi tanggal
     mulainya tetap titik perubahan nilai. Tanpa ini, nilai absolut 2026-12-01 yang dipangkas
     2027-01-01 hilang dari penilaian dan kombinasi tidak sah 2026-12-01…2027-01-01 lolos.
  2. Pada tanggal yang tercakup periode calon, nilai sisi calon **tidak dibaca dari DB**. Kalau
     sisi itu ikut diwajibkan terbaca, satu periode berakhir tanpa penerus (`effective_to` tanpa
     baris pengganti) membuat seluruh tanggal — termasuk tanggal efektif calon — dilewati, dan
     pemeriksaan ini jadi tidak menangkap apa pun.
  3. Konteks scope penilaian disamakan dengan konteks baca aplikasi (`institutionScope()`,
     `handlers_auth` → `settingsOf`), termasuk untuk calon ber-scope `INSTITUTION`: baris
     INSTITUTION ber-id konkret memang tidak dibaca aplikasi selama O-012 belum dirapikan, jadi
     menilainya dengan id itu akan menghasilkan vonis yang tidak mencerminkan perilaku login.
  4. Periode calon dipatuhi (`[effectiveFrom, effectiveTo)`) saat menentukan tanggal mana yang
     memakai nilai calon.
  5. Test: setiap perbaikan di atas punya test yang **GAGAL bila perbaikannya dikembalikan**
     (diverifikasi dengan memasang sementara perilaku lama): `itauth` (tanggal mulai sisi lain,
     baris yang dipangkas, sisi calon tak terbaca) dan `itapi_auth` (kandidat mulai hari ini dengan
     absolut turun mulai besok — kasus yang lolos pada kode lama).
- **Alasan**: himpunan tanggal adalah inti kebenaran pemeriksaan ini; setiap tanggal yang hilang
  dari himpunan = jendela lockout yang tidak terdeteksi. Memilih "lebih banyak tanggal" aman karena
  penilaian hanya menolak kombinasi yang benar-benar tidak sah, dan aturan "tanggal tak dapat
  dinilai dilewati" dibatasi hanya pada sisi yang memang belum lengkap.
- **Konsekuensi**: satu batas pemeriksaan yang tetap: keadaan "satu sisi tanpa nilai aktif sama
  sekali" dilewati supaya bisa diperbaiki lewat alur normal (D-027 butir 2). Kerangka parameter yang
  membuat celah nilai (baris ACTIVE ber-`effective_to` tanpa penerus) dicatat sebagai O-043.

### Tambahan D-029 — ronde 4: bukti pembeda untuk `effectiveTo` & konteks scope

Ronde 4 menyatakan kode D-029 **benar** (mutation test-nya sendiri mengonfirmasi dua perbaikan
GAGAL bila dikembalikan), tetapi menemukan bahwa (a) cabang `effectiveTo` belum punya test pembeda —
mutation "abaikan `effectiveTo`" membuat **seluruh suite hijau** — dan (b) perubahan konteks scope
(D-029 butir 3) belum diuji dengan baris `INSTITUTION:<id>` nyata. Keduanya ditutup dengan dua test
mandiri di `itauth` (membuat barisnya sendiri, tanggal jauh di depan, supaya tidak bergantung urutan
test lain):

- "periode calon dipatuhi: nilai kandidat tidak dipakai setelah `effectiveTo`" — GAGAL bila
  `effectiveTo` diabaikan (diverifikasi dengan memasang mutasinya sementara).
- "baris ber-scope `INSTITUTION` dengan id konkret tidak mengubah vonis" — GAGAL bila konteks
  penilaian memakai id institusi konkret (baris itu jadi terlihat dan vonisnya berubah).

Catatan tambahan: hazard urutan test diakui eksplisit (komentar di awal suite) dan test baru dibuat
mandiri; sisa hazard dicatat sebagai keterbatasan, bukan dianggap tidak ada. Nilai calon yang
dipakai tanpa memeriksa visibilitas scope dicatat sebagai O-044 (sifatnya konservatif, sudah ada
sebelum D-029). Butir 5 D-028 sudah dianotasi agar tidak bertentangan dengan D-029 butir 3.

## D-030 — Sesi diperiksa berkala pada stream realtime; soket ditutup saat sesi berakhir (O-036)

- **Konteks**: otorisasi realtime hanya terjadi **saat handshake** (`canOpen`) dan saat `subscribe`.
  Sesi yang dicabut (logout, penggantian password, pencabutan oleh admin) atau yang lewat batas
  idle/absolut tidak memutus soket yang sudah terbuka, sehingga klien itu terus menerima
  `param.changed` — isi parameter keuangan mengalir ke sesi yang seharusnya sudah berakhir.
- **Keputusan**:
  1. Pump memeriksa ulang sesi tiap klien secara **berkala** (bukan per peristiwa), dengan interval
     teknis `defaultSessionRecheckSeconds = 5` dan penilaian memakai `resolvePrincipal` — definisi
     "identitas sah" yang **sama** dengan handshake (`canOpen`), sehingga pengguna yang dinonaktifkan
     pun ikut tertangkap.
  2. Pemeriksaan dijalankan **di luar lock hub** (I/O DB tidak boleh menahan fan-out) dan hasilnya
     dicatat per klien (`lastSessionCheck`) supaya biayanya satu pemeriksaan per klien per interval.
  3. Sesi tidak sah → amplop `error` (`REALTIME_SESSION_ENDED`, `i18nKey = error_unauthorized`) lalu
     soket **ditutup** server-side, dan langganan dilepas. Amplop dipakai supaya klien punya alasan
     eksplisit; penutupan memicu jalur klien yang sudah ada (`realtime.ts handleClose` → cek
     `/api/v1/auth/session` → 401 → kembali ke layar login), jadi tidak ada putaran sambung-ulang
     tanpa akhir. Kunci i18n sengaja memakai kunci yang **sudah ada** (`error_unauthorized`) supaya
     tidak menambah katalog pesan hanya untuk frame protokol.
  4. `TopicPolicy.sessionValid` **wajib** diisi; `newEventService` menolak dengan galat jelas bila
     nil, karena tipe object Nim tidak bisa memaksa closure terisi dan lupa mengisinya = lubang ini
     kembali terbuka tanpa jejak.
- **Alasan memilih polling berkala, bukan hanya sinyal dari jalur logout**: jalur pencabutan ada
  beberapa (logout, `logoutAll`, ganti password, pencabutan admin) dan **kedaluwarsa** idle/absolut
  sama sekali tidak punya sinyal — jarum jam tidak mengirim peristiwa. Satu pemeriksaan berkala
  menutup semuanya dengan satu mekanisme, dan biayanya terukur (satu resolusi principal per klien
  per interval). Alternatif "tutup soket saat logout" tetap dicatat sebagai penghematan yang bisa
  ditambahkan kemudian, bukan pengganti.
- **Batasan yang tetap ada (dicatat, bukan disembunyikan)**:
  - **Perubahan izin topik** tidak diperiksa ulang; langganan yang sudah disetujui tetap berlaku
    sampai klien `subscribe` lagi atau sesinya berakhir (O-046).
  - Interval 5 detik berarti ada jendela ≤ 5 detik sebelum soket yang sesinya dicabut berhenti
    menerima; nilainya teknis dan bisa diturunkan bila perlu.
  - Biaya satu pemeriksaan = satu resolusi principal (beberapa query); bila jumlah klien nyata besar,
    langkah berikutnya adalah cache principal berumur pendek (tercatat di komentar `sweepSessions`).
- **Bukti**: `itapi_ws` "sesi dicabut → amplop error, soket ditutup, langganan dilepas" (interval 0,
  deterministik) dan `itapi_auth` "logout mengakhiri stream yang sudah terbuka" (server nyata,
  cookie nyata, interval default). Keduanya **GAGAL** bila `sweepSessions` dilepas (diverifikasi
  dengan memasang mutasinya sementara, lalu dikembalikan).

## D-031 — Berhenti bersih lewat sinyal: hentikan pump lalu keluar kode 0 (O-025)

- **Konteks**: `kran-api` tidak memasang penangan sinyal apa pun. `SIGTERM` (yang dikirim `systemctl
  restart` / deploy) mematikan proses sebagai sinyal — kode keluar 143, tanpa jalur penutupan — dan
  proses lama bisa tertinggal berjam-jam (dua proses sisa berumur 16 jam ditemukan saat task ini).
  O-025 melaporkan `server.close()` mematikan proses (SIGSEGV), sehingga jalur itu tidak dipakai.
- **Keputusan**: `SIGINT`/`SIGTERM` → handler hanya menyetel flag atomik (tanpa I/O, aman di konteks
  sinyal) → thread penunggu menghentikan pump realtime (batas tunggu 2 detik), menulis satu baris log,
  lalu `quit(0)`. `server.close()` **tidak** dipanggil: berhenti bersih tidak membutuhkannya, dan itu
  jalur yang dilaporkan bermasalah. Probe minimal 15 Okt 2026 tidak mereproduksi SIGSEGV-nya; karena
  itu O-025 diperkecil menjadi pertanyaan teardown *in-process* (test harness), bukan penghalang
  produksi — dan tidak ditutup diam-diam.
- **Batasan yang dicatat**: permintaan HTTP yang sedang berjalan dipotong (belum ada drain) → O-047.
- **Bukti**: manual (`kill -TERM` → kode 0, log "berhenti dengan tenang", port bebas) dan otomatis
  (`apps/web/tests/e2e/shutdown.spec.ts`). Daya tangkap: penangan sinyal dilepas sementara → test
  GAGAL; dikembalikan → lulus.

## D-032 — Invarian kursor outbox ditegakkan lewat urutan audit, dan test balapan dua koneksi (O-037, O-040)

- **Konteks**: (a) `platform.outbox.seq` dialokasikan saat INSERT, bukan saat COMMIT, sehingga urutan
  commit bisa berbeda dari urutan `seq`; pump realtime membaca tabel dengan kursor `seq`, jadi
  peristiwa yang commit belakangan bisa **terlewat** — bukan tertunda. Invarian yang menyelamatkan
  (audit lebih dulu) hanya hidup di kepala penulis kode, tidak tertulis dan tidak diuji.
  (b) Harness test dikompilasi tanpa `--threads:on`, jadi balapan dua koneksi (double-approve) hanya
  bisa diuji lewat kontrak langkah, bukan interleaving sungguhan.
- **Keputusan**:
  1. Aturan penulis ditulis di `modules/platform/MODULE.md`: transaksi yang menulis peristiwa outbox
     wajib menulis entri audit **lebih dulu, di transaksi yang sama**; trigger rantai audit memegang
     `pg_advisory_xact_lock(hashtext('platform.audit_log'))` sampai commit sehingga urutan commit
     mengikuti urutan `seq`.
  2. Test baru `modules/platform/tests/itoutboxcursor.nim` menjaga dua sisi: invarian berlaku antar
     dua koneksi nyata (penulis kedua menunggu, `seq`-nya lebih besar) dan karakterisasi bahaya bila
     aturan dilanggar (kursor melewatkan peristiwa yang commit belakangan).
  3. Test dikompilasi/di-check dengan `--threads:on` (`TESTFLAGS` di `task`), sama seperti biner API.
     Test balapan double-approve ditambahkan di `itparam.nim`: dua thread, dua koneksi, gate bersama →
     tepat satu pemenang, satu audit approve, satu event outbox.
- **Alternatif yang dipertimbangkan dan ditolak**: (a) kursor tahan-bolong (lookback + de-dup `id`) —
  menambah kompleksitas di setiap pembaca dan menyembunyikan pelanggaran alih-alih mencegahnya;
  (b) constraint/trigger DB yang memastikan "ada entri audit di transaksi yang sama" — di Postgres
  hanya bisa didekati lewat trik `xmin`/constraint trigger yang rapuh, dan dirasa terlalu berisiko
  untuk nilai yang didapat. Sisa risikonya dicatat di O-037: aturannya ditegakkan disiplin penulis +
  test, bukan DB.
- **Bukti**: `itoutboxcursor` (2 test) — lock audit dilepas sementara → test invarian **GAGAL**;
  `itparam` (25 test) — penjaga `AND status = 'PENDING'` dilepas sementara → test balapan **GAGAL**.
  Keduanya hijau setelah dikembalikan.

## D-033 — Kontrak CLI peran proses: kode keluar eksplisit, `ctl` read-only (O-013)

- **Konteks**: `ops/scripts/migrate.sh` dan `deploy-vps.sh` (T-013, berkas repo, belum pernah
  dijalankan di server) sudah mengandalkan `--role=migrate --check|--up` dan
  `--role=ctl daycloser-status`, sedangkan biner hanya punya `--role=api` dan menggagalkan peran lain.
  Kontraknya harus ada di repo dan bisa diuji tanpa menyentuh server.
- **Keputusan**:
  1. `--role=migrate [--check|--up] [--root=<dir>]` memakai `tools/dbtools/lib` — jalur migrasi yang
     **sama** dengan `./task dbtools migrate`/`validate`, supaya tidak ada dua implementasi migrasi.
     `--check` read-only dan keluar **1** bila ada migrasi tertunda atau isi migrasi berubah (drift).
  2. `--role=ctl <perintah>` hanya berisi perintah **read-only** (`verify-audit` → 0 utuh / 1 tidak
     utuh, `outbox-status`, `help`), karena skrip otomatis memanggilnya tanpa pengawasan. Versi
     perintah yang menulis data (re-drive outbox) menyusul dengan `--yes` sendiri.
  3. Perintah yang **dikenali tapi belum ada** (`ctl daycloser-status`, `worker`) keluar dengan kode
     **3** dan pesan yang menyebut alasannya — bukan kode 2 "tidak dikenal", supaya skrip ops bisa
     membedakan "salah ketik" dari "belum ada di fase ini".
  4. `--contract`/`--down` (migrasi destruktif/rollback) **tidak** diam-diam diperlakukan sebagai
     `--up`: biner belum mendukungnya dan `ops/scripts/migrate.sh` menolaknya dengan kode 3 (O-048).
  5. `main.nim` dipagari `when isMainModule` supaya peran bisa dipanggil langsung dari test tanpa
     menjalankan server (kontrak diuji tanpa bergantung hasil `./task build`).
- **Kode keluar**: 0 sukses, 1 hasil buruk (drift/rantai audit tidak utuh), 2 salah pakai/konfigurasi
  (mis. `KRAN_DATABASE_URL` kosong), 3 dikenali tapi belum diimplementasikan. Ini kontrak yang dibaca
  skrip ops; mengubahnya berarti memperbarui skrip (dicatat di `docs/runbooks/ops-cli.md`).
- **Bukti**: `apps/api/tests/itapi_roles.nim` (7 test) + runbook `docs/runbooks/ops-cli.md`. Sisa
  yang jujur: peran `worker` dan freeze gate daycloser belum ada (O-013) — skrip `ops/` belum pernah
  dijalankan di server.

### D-033 addendum (review independen, 15 Okt 2026) — `--up` menolak migrasi bertanda destruktif

Reviewer menemukan celah yang belum tercatat: `--role=migrate --up` akan menerapkan **berkas migrasi
berpenanda** `-- dbtools:destructive` yang belum dijalankan (`applyMigrations` hanya menolak DDL
destruktif yang *tidak* berpenanda). Itu bertabrakan dengan janji `ops/scripts/migrate.sh --up`
("migrasi expand-only") dan dengan spec §21.7, meski efeknya laten karena belum ada berkas seperti itu.

Keputusan: `--up` sekarang **menolak** dan keluar kode 3 bila ada migrasi berpenanda destruktif yang
belum diterapkan, dengan menyebut id berkasnya dan menunjuk O-048. Alternatif "biarkan saja, catat
dokumen" ditolak karena kegagalannya akan muncul di server, bukan di laptop. Kontrak `--contract` yang
sesungguhnya tetap menyusul di O-048.

## D-034 — Empat keputusan pemilik: bootstrap, anti-enumerasi akun, `requires_approval`, arti `scope_id` kosong

Diputuskan pemilik 15 Oktober 2026 setelah opsi dan konsekuensinya dibahas (O-031, O-034, O-039,
O-012). Dicatat sebagai keputusan, bukan sekadar niat, supaya task turunannya punya rujukan.

1. **O-031 bootstrap user produksi.** Prosedur: satu perintah **sekali-jalan** yang membuat admin
   pertama dan mencetak kata sandi acak sekali, dengan wajib-ganti pada login pertama
   (`mustChangePassword` sudah ada di `SessionInfo`). Konsekuensi yang diterima: perintah ini butuh
   **endpoint ganti kata sandi** yang belum ada (kontrak saat ini hanya `login`/`session`/`logout`),
   jadi endpoint itu dikerjakan sebagai task pendamping, bukan ditunda terpisah. Alternatif "admin
   pertama dengan kata sandi yang dimasukkan manusia" ditolak karena mengundang kata sandi lemah
   yang tidak pernah diganti. Task: **T-027**.
2. **O-034 enumerasi akun.** Status `locked`/`inactive` dibalas **hanya setelah kata sandi benar**,
   dan akun tak dikenal menjalankan PBKDF2 tiruan (dummy hash) dengan biaya setara supaya waktu
   responsnya tidak membedakan. Konsekuensi yang diterima: pengguna yang terkunci dan salah mengetik
   kata sandi mendapat pesan generik, lalu baru melihat alasan terkunci saat kata sandi benar; itu
   pertukaran yang disengaja. Task: **T-028**.
3. **O-039 `requires_approval: false`.** Untuk sekarang `false` **tidak boleh dipakai**: kalau ada
   definisi seperti itu di `modules/*/seeds/params.yaml`, `paramgen` menolak (keluar **2** dengan
   pesan yang menyebut O-039) sehingga gate `./task paramgen --check` gagal di CI. Semantik
   sebenarnya (maker boleh langsung ACTIVE untuk peran tertentu, dengan audit eksplisit) ditetapkan
   bersama **T-016**. Batas penegakan: dijalankan di **batas CLI** (`tools/paramgen/main.nim`), bukan
   di parser, karena repo ini sengaja menguji parser dan emitter dengan fixture ber-`false`
   (`tools/paramgen/tests/fixtures/.../deposit/seeds/params.yaml`) supaya plumbing kolomnya tidak
   ikut terhapus sebelum semantiknya diputuskan. Predikat `undefinedApprovalSemantics` yang dipakai
   CLI diuji langsung (`tparamgen`), dan daya tangkapnya diverifikasi dengan menambahkan definisi
   ber-`false` ke seed asli: `paramgen` gagal, lalu dikembalikan.
4. **O-012 arti `scope_id` kosong.** Tipe lookup dibuat eksplisit (`Option[Id]`, sehingga "tidak
   diminta" dan "kosong" tidak lagi berarti sama) dan dikerjakan bersama pemindahan resolusi ke
   lapisan application di **T-016**, dengan test golden sebelum perilakunya berubah. Tidak ada
   perubahan kode hari ini.

## D-035 — T-027: admin pertama, katalog RBAC di migrasi, dan penjagaan sesi wajib-ganti

Keputusan pemilik 15 Okt 2026 (D-034) yang paling besar konsekuensinya: prosedur bootstrap admin
pertama. Saat dikerjakan, satu hal ternyata **tidak** bisa sekadar "panggil perintah baru":

**Katalog izin & role sistem dipindah dari seed dev ke migrasi.** `dbtools seed` menerapkan
`packs/*/generated/*.sql` selalu, tetapi `packs/*/seed/*.sql` hanya dengan `--dev`; katalog izin
(`platform.param.read` dst.) dan role (`param_maker`, `param_checker`) hanya ada di seed dev. Di
produksi, admin pertama karena itu akan dibuat **tanpa satu pun izin** — dengan kata lain bootstrap
yang "berhasil" tetapi tidak bisa dipakai. Katalognya sekarang ada di
`modules/platform/migrations/0008_platform_rbac_catalogue.sql`; seed dev hanya menjaga pengguna dan
pemberian rolenya. Alasan memilih migrasi, bukan jalur seed produksi baru: kode izin terikat kode
program (`apps/api/src/access.nim`), jadi ia struktural, ikut versi, dan ikut jalur expand-only —
bukan nilai bisnis yang bisa diubah institusi.

Keputusan lain di task ini, dengan alasan yang perlu diketahui pembaca berikutnya:

1. **Penjagaan "wajib ganti kata sandi" ada di `requirePermission`**, bukan di tiap handler. Satu
   tempat berarti rute baru tidak bisa lupa. Rute yang **tidak** butuh izin (`getSession`, `logout`,
   `changePassword`) tidak melewatinya, jadi alurnya tetap bisa diselesaikan. Jalur realtime memakai
   definisi yang sama (`sessionCanWork`), supaya sesi berkata-sandi-sementara tidak bisa menyedot
   data lewat langganan.
2. **Kata sandi lama yang salah dijawab 403, bukan 401.** Sesi memang masih sah; 401 akan membuat
   klien memperlakukannya sebagai "sesi berakhir" dan mengeluarkan pengguna hanya karena salah
   mengetik. `params.reason` (`old_password_mismatch`, `password_policy`) adalah yang membedakan
   sebabnya untuk UI.
3. **Mengganti kata sandi mencabut sesi lain, tetapi tidak sesi yang sedang dipakai.** Kalau kata
   sandi diganti karena diduga bocor, sesi lama tidak boleh tetap hidup; pemiliknya sendiri tidak
   perlu masuk ulang. Repo mendapat `revokeSessionsExcept` untuk itu.
4. **`bootstrap-admin` adalah satu-satunya perintah `ctl` yang menulis**, dan sekali-jalan bukan
   lewat flag melainkan lewat keadaan data: ditolak bila username sudah ada **atau** sudah ada
   pemegang role admin. Flag bisa dilewatkan karena tergesa-gesa; keadaan data tidak.
5. **Seed dev menyetel ulang pengguna dev (`ON CONFLICT (username) DO UPDATE`)**, bukan
   `DO NOTHING`: e2e alur wajib-ganti mengubah kata sandi `dev.firstlogin`, jadi seed harus bisa
   mengembalikannya agar `./task e2e` bisa dijalankan berulang.

Tidak ada gate yang dilonggarkan di sini: yang berubah adalah tempat katalog RBAC hidup, dan itu
**memperbaiki** jalur produksi yang sebelumnya tidak punya izin sama sekali (dua item baru dicatat:
O-050 percobaan kata sandi lama tidak dibatasi/diaudit, O-051 kebijakan kata sandi tidak terbaca UI,
O-052 kebijakan lanjutan kata sandi).

## D-036 — Nama produk: KRAN (saat itu: identifier teknis tetap `cbs` — lihat D-039)

Keputusan pemilik 15 Okt 2026: nama produknya **KRAN**. Ekspansi "KRAN Rapid Accounting Network"
adalah lelucon rekursif (gaya WINE/HURD/GNU) dan **bukan** klaim yang ditampilkan di UI, dokumen,
atau kontrak; dokumen hanya memakai "KRAN", sedangkan kategori produknya ditulis apa adanya
("core banking untuk koperasi, BPR/BPRS, BMT").

Kenapa bukan "CBS": di Indonesia "CBS" sudah menjadi **istilah kategori** yang dipakai vendor sebagai
label produk (CorSys CBS, CBS BPR/ARB+, IBS Core, Microsys, Assist BPR.Net, Hexa Core), jadi ia tidak
membedakan. Selain itu spec §23 memakai nama `cbs-core` untuk sistem lama yang akan di-cutover —
nama produk yang berbeda justru mengurangi salah-tafsir.

Batas perubahan: **nama tampilan saja** — i18n (`common_app_title`, `common_home_intro`,
`login_intro`), `README.md`, dan `info.title` kontrak OpenAPI. Identifier teknis **tidak** diubah:
biner `cbs-api`, prefix env `CBS_*`, `cbs.nimble`, direktori kerja, nama berkas kontrak, dan nama
berkas spec. Alasan: mengganti identifier berarti menyentuh skrip ops, unit systemd, konfigurasi dev,
dan test — risiko tanpa manfaat produk, sementara yang dilihat pengguna sudah tercakup.

Hasil pengecekan nama (dicatat jujur sebagai jejak): "KRAN" dipakai KRAN Consulting Pvt. Ltd. (India)
yang juga membuat software keuangan pemerintah, KRANAPP (Depok), dan CV. KRAN Indonesia (Malang).
Pengecekan merek resmi (PDKI/eDJKI) dan domain belum dilakukan dan bukan wewenang agen; pemilik
memutuskan tetap memakai KRAN setelah fakta ini disampaikan.

**Diperbarui (D-038):** bagian "identifier teknis tidak diubah" tidak lagi mencakup nama berkas
paket — `cbs.nimble` menjadi `kran.nimble` setelah repo GitHub dinamai ulang. Biner `cbs-api`, prefix
env `CBS_*`, dan nama berkas kontrak/spec tetap `cbs`.

**Diperbarui (D-039):** batas di atas dicabut atas keputusan pemilik — seluruh identifier teknis ikut
KRAN. Lihat D-039 untuk daftar lengkap dan apa yang sengaja **tidak** diubah (`cbs-core`).

## D-037 — Batas versi Mummy dan daftar periksa upgrade (O-049)

`apps/api/src/events.nim` memakai dua sifat Mummy yang **tidak** dijanjikan API publiknya:

1. `WebSocket.send` aman dipanggil dari thread lain (pump) sambil handler memakai soket yang sama —
   yang menjaminnya adalah antrean kirim per koneksi di dalam Mummy.
2. `WebSocket.close` aman dari thread lain (close frame dimasukkan ke antrean yang sama), dan
   pemanggilan setelah `forget` tidak menutup soket klien lain.

Keputusan: **`kran.nimble` membatasi `mummy >= 0.4.8 & < 0.5.0`,** dan versi 0.4.8 adalah yang diuji.
Alasan: sifat di atas adalah detail implementasi; kenaikan versi minor bisa mengubahnya tanpa
kegagalan kompilasi, sehingga bugnya hanya muncul sebagai soket yang menggantung atau pesan yang
hilang saat beban.

Daftar periksa bila nanti versi Mummy dinaikkan (jalankan sebelum mengganti batas):

- [ ] `./task test "tests/itapi_ws"` — termasuk suite "banyak klien diputus serentak" (8 klien
      diputus bersamaan sambil peristiwa mengalir; server harus tetap melayani klien baru).
- [ ] `./task test "tests/itapi_realtime"` dan `./task test "tests/itapi"` (jalur hub & HTTP).
- [ ] `./task e2e` — khususnya spec realtime (langganan, resume, drop) dan shutdown.
- [ ] Periksa ulang dua asumsi di atas dengan membaca ulang kode Mummy (`websocket.nim`), karena
      inilah satu-satunya bagian repo yang bersandar pada internalnya.
- [ ] Catat hasilnya di entri DECISIONS baru; jangan hanya menaikkan batas versi.

Batas yang diketahui (tidak ditangani, tetap sebagai item): antrean kirim keluar per koneksi tidak
dibatasi (O-028), dan ukuran antrean tidak bisa dibaca dari luar sehingga kuota klien lambat belum
bisa dipasang tanpa memakai internal Mummy lagi.

## D-038 — Nama berkas paket: `kran.nimble` (selaras nama repo)

Pemilik mengganti nama repo GitHub menjadi `kran` dan memutuskan identifier paket ikut: `cbs.nimble`
menjadi **`kran.nimble`**, sehingga nama paket Nim menjadi `kran` — `nimble check` membaca nama paket
dari nama berkas (`Success: The package "kran" is valid.`).

Batasnya, supaya perubahan ini tidak melebar tanpa keputusan: yang berubah **hanya** nama berkas
paket dan `description` di dalamnya. Yang tetap `cbs`: biner `cbs-api`, prefix env `CBS_*`, nama
direktori kerja, nama berkas kontrak, dan nama berkas spec. Alasannya sama seperti D-036 — `cbs-api`
dan `CBS_*` muncul di unit systemd server, berkas env produksi (`/srv/.../env/*.env`), skrip webhook,
dan prosedur backup; menggantinya adalah perubahan ops yang butuh keputusan sendiri, bukan efek
samping rename repo.

Dampak yang sudah ditangani: kunci cache dependency `hashFiles('cbs.nimble')` di
`.github/workflows/ci.yml` **wajib** ikut berubah — kalau tidak, cache di-key oleh nama berkas yang
sudah tidak ada. `./task build` tidak terpengaruh sama sekali: ia memanggil `nim c` langsung
(`task:339`) dan tidak pernah membaca berkas `.nimble`.

Entri dan task yang sudah selesai (`docs/PROGRESS.md`, `docs/tasks/T-001.md`, `T-034.md`, serta item
O-049 yang sudah ditutup) sengaja **tidak** ditulis ulang: itu catatan apa yang benar saat itu, bukan
dokumen hidup. Dokumen hidup (`README.md`, `MODULE.md`, `DECISIONS.md`) diperbarui.

**Diperbarui (D-039):** daftar "yang tetap `cbs`" di atas tidak berlaku lagi — lihat D-039.

## D-040 — Migrasi dua tahap: penanda `contract`, `--check` yang tidak menghitung contract, dan `--down` yang menghapus barisnya

Konteks: sampai T-035 jalur migrasi hanya expand-only (`--up` menolak berkas destruktif, dan skrip
menolak `--contract`/`--down`). Aman, tetapi berarti **tidak ada jalan rollback skema sama sekali**
(O-048) — dicatat sebagai batas yang diterima, bukan dibiarkan tak terlihat. T-035 menutupnya.

Empat keputusan, semuanya mengikuti aturan yang sudah ada:

1. **Penanda di berkasnya sendiri.** Berkas contract ditandai `-- dbtools:contract <alasan>`, mengikuti
   pola `-- dbtools:destructive <alasan>`: alasan wajib, dan penandanya tinggal di berkas yang sama
   supaya tidak bisa terpisah dari SQL-nya. Berkas contract yang memuat DDL merusak tetap wajib memuat
   penanda destruktif juga — satu aturan, tanpa pengecualian tersembunyi.
2. **`--up` melewati, `--contract` menerapkan** — dan tidak sebaliknya: berkas tanpa penanda contract
   tidak pernah dijalankan jalur contract. Contract menolak jalan selama masih ada migrasi expand yang
   belum diterapkan: contract di atas skema yang belum lengkap menghasilkan keadaan yang tidak pernah
   diuji siapa pun.
3. **`--check` tidak menghitung contract sebagai tertunda.** Alternatifnya membuat gate deploy gagal
   selamanya begitu sebuah berkas contract dirilis, padahal berkas seperti itu memang menunggu operator
   memutuskan kapan (spec §21.4). Yang tetap diperiksa: migrasi expand tertunda, dan isi migrasi yang
   sudah diterapkan berubah (checksum).
4. **`--down` menghapus baris `platform.schema_migration` setelah pembatalan berhasil.** Membiarkan
   barisnya membuat `status`/`--check` berbohong: mengaku diterapkan padahal DDL-nya sudah dibatalkan.
   Harga yang dibayar: tidak ada riwayat "pernah diterapkan lalu dibatalkan" di DB; jejaknya hanya di
   log operator dan di kontrol versi berkas pasangannya. Untuk Fase 0 itu diterima, dan ditopang
   fail-closed: seluruh pasangan diperiksa sebelum satu pun dijalankan, dan satu berkas = satu transaksi.

Menyertainya: berkas pasangan `.down.sql` diperiksa sekeras berkas migrasi (tidak boleh
`BEGIN`/`COMMIT`/`ROLLBACK`, tidak boleh kosong). Kalau tidak, transaksi yang membungkusnya bisa
berakhir lebih awal dan janji "satu berkas = satu transaksi" hilang tanpa jejak.

Ditutup: O-048. Prosedur: `docs/runbooks/migrasi.md`. Bukti: `docs/tasks/T-035.md`.

## D-039 — Seluruh identifier teknis mengikuti KRAN

Keputusan pemilik 15 Okt 2026: batas "nama tampilan saja" (D-036) dan "hanya berkas paket" (D-038)
dicabut. Seluruh identifier teknis memakai KRAN. Alasan waktu: **sekarang saat termurah** — belum ada
satu pun proses produksi berjalan (T-013 belum pernah dieksekusi), jadi belum ada berkas env produksi,
unit systemd hidup, atau hook webhook yang harus dimigrasikan.

| Sebelum | Sesudah |
|---|---|
| biner `cbs-api` | `kran-api` |
| prefix env `CBS_*` | `KRAN_*` |
| database dev `cbs_dev` | `kran_dev` (**butuh aksi di server** — lihat bawah) |
| kanal NOTIFY `cbs_outbox` | `kran_outbox` (migrasi baru `0009`; `0007` tidak disentuh) |
| unit systemd `cbs-api.service`, `cbs-worker.service` | `kran-api.service`, `kran-worker.service` |
| hook webhook `cbs` (`hook.cbs.json.example`) | `kran` (`hook.kran.json.example`) |
| paket npm `@cbs/*`, `cbs-monorepo` | `@kran/*`, `kran-monorepo` |
| kelas CSS `cbs-*` | `kran-*` |
| kunci localStorage `cbs-theme` | `kran-theme` |
| berkas `cbs-api.yaml`, `cbs-prd-techspec.md`, `cbs-prod.env.example`, `Caddyfile.cbs.example` | `kran-*` |
| kode galat mesin `CBS-1xxx` (`shared/kernel/`) | `KRAN-1xxx` |
| direktori aplikasi di server `/srv/qouver/apps/cbs` (default) | `/srv/qouver/apps/kran` |
| `application_name` koneksi DB & `app` logger (`cbs`) | `kran` |

Yang **tidak** diubah, dan alasannya:

- **`cbs-core`** — nama sistem lama yang **masih berjalan** di VPS dan akan di-cutover (spec §23).
  Menggantinya akan membuat dokumen berbohong; sistem lama tetap memakai namanya sendiri.
- **`cbs.qouver.com` dan path `/cbs/*`** di `Caddyfile.kran.example` — itu DNS/hostname, bukan
  identifier di repo. Mengubahnya keputusan pemilik domain, bukan efek samping rename.
- **Catatan historis** (`docs/PROGRESS*.md`, `docs/tasks/**`, `docs/spikes/**`, `docs/milestones/**`,
  `docs/ESCALATIONS.md`, `docs/migration/**`, entri DECISIONS lama) — rekaman apa yang benar saat itu;
  kebijakan sama seperti D-038.
- **Migrasi `0007`** tidak disentuh: sudah diterapkan, dan `dbtools` memverifikasi checksum berkas
  migrasi yang sudah diterapkan. Kanal diganti lewat migrasi baru `0009` (non-destruktif: tanpa
  DROP/TRUNCATE/RENAME).

Sudah dikerjakan di server (15 Okt 2026, superuser `qouver` lewat `podman exec qouver-postgres`):

- `ALTER DATABASE cbs_dev RENAME TO kran_dev` dan `ALTER ROLE cbs_dev RENAME TO kran_dev`. Dibuktikan
  sesudahnya: `dbtools status` 10/10 migrasi utuh dan `itapi_ws` 15 `[OK]` menembus DB+role baru.
- Yang **tidak** disentuh: DB `cbs` (sistem lama), 7 DB `cbs_verify*`, role `cbs_app`, dan
  `/srv/qouver/apps/cbs` (65 MB, ada sejak 2 Sep 2026). Container sistem lama `cbs-api`
  (`127.0.0.1:8095`) dan `cbs-web` (3005) dibiarkan berjalan.

Masih butuh manusia (dicatat sebagai O-054/O-055): status `/srv/qouver/apps/cbs` dan container sistem
lama, kepemilikan 7 DB `cbs_verify*`, penetapan domain KRAN, dan alias deploy key `github-kran`
(dibuat saat setup webhook — langkahnya di `docs/runbooks/deploy-setup.md`).

Catatan proses (jujur, bagian dari keputusannya): rename dilakukan mekanis lalu diperiksa, dan dua
kesalahan di ronde itu ketemu dan diperbaiki — (1) `ops/systemd/*.service` awalnya terlewat karena
ekstensi `.service` tidak masuk daftar berkas yang diproses, sehingga unit masih menunjuk biner lama;
(2) `docs/DECISIONS.md` sempat rusak maknanya karena kalimat "kenapa bukan CBS" di D-036 ikut ter-rename
jadi "kenapa bukan KRAN" — terbalik dari maksud aslinya.

## D-041 — Lookup scope parameter bertipe eksplisit: "tidak diminta" ≠ "id kosong" (menutup O-012)

Diputuskan pemilik 15 Okt 2026 (D-034 butir 4) dan dilaksanakan di T-036.

`ScopeLookup` — proc yang menjawab "id scope apa yang diminta pemanggil untuk tipe ini?" — dulu
mengembalikan `string`, sehingga `""` berarti dua hal sekaligus: "tipe ini tidak diminta" **dan**
"diminta tanpa id". Akibatnya `institutionScope()` (tipe `INSTITUTION`, id `""`) tidak pernah bisa
mencocokkan nilai ber-`scope_id` NULL: nilai level institusi akar tak terjangkau, dan pemanggil itu
hanya melihat `GLOBAL`.

Sekarang tipenya `ScopeValueLookup* = proc(scopeType: ParamScopeType): Option[string]`:

- `some(id)` — tipe itu diminta dengan id tersebut; `some("")` **sah** dan berarti id kosong
  (institusi akar, `scope_id` NULL).
- `none` — tipe itu tidak diminta, jadi tidak pernah cocok.

Perubahan perilaku yang disengaja, dan **hanya** itu: pencocokan scope ber-id kosong pada tipe yang
memang diminta. Kasus lain tidak berubah — id tak kosong tetap dibandingkan persis, tipe yang tidak
diminta tetap dilewati — dan itu dipin golden test yang dijalankan **sebelum** perubahannya
(`docs/tasks/T-036.md`). Perubahan tipe (termasuk namanya) dipilih supaya pemanggil lama tidak bisa
diam-diam tetap mengembalikan `string`: kompilator menuntut setiap pemakaian diperiksa.

Yang **tidak** ikut berubah, dan alasannya:

- **Tidak ada fallback antar level.** Pemanggil tetap hanya melihat scope-nya sendiri + `GLOBAL`;
  nilai `BRANCH` tidak otomatis terbaca dari konteks `INSTITUTION`. Urutan di spec §10.2
  (`PRODUCT → BRANCH → INSTITUTION → SEGMENT → GLOBAL`) dipakai sebagai **prioritas antar kandidat**,
  bukan rantai fallback antar level — dan uji `tparam`/`itparam` memin "tanpa fallback diam-diam".
  Menambahkan rantai itu mengubah nilai mana yang berlaku, jadi ia keputusan produk, bukan perbaikan
  tipe; dicatat sebagai O-056. `branchScope("")` tidak dipakai siapa pun; kalau nanti dipakai, artinya
  "akar level cabang", bukan "semua cabang".
- **Pemindahan resolusi ke lapisan application** (bagian lain D-034 butir 4) belum dikerjakan: T-036
  hanya menyentuh tipe lookup dan pemanggilnya. Sisa itu tetap milik T-016.

Ditutup: O-012. Diubah: `modules/platform/domain/param.nim`, `domain/scope.nim`, MODULE.md (invarian 9).

## D-042 — `requires_approval: false` tidak diizinkan (menutup O-039)

Keputusan pemilik 16 Okt 2026: setiap perubahan nilai parameter wajib lewat maker-checker, jadi definisi
parameter dengan `requires_approval: false` **tidak diizinkan** — bukan "belum diputuskan". Pertanyaan
yang menggantung sejak D-034 dijawab dengan pilihan yang paling ketat, dan sejalan dengan spec §10.4
(Governance: semua perubahan parameter lewat maker-checker + audit; `CRITICAL` lebih ketat lagi).

Yang berubah hanyalah **alasan**, bukan penegakannya:

- Dulu: `paramgen` menolak definisi ber-`false` karena artinya belum disepakati (pesan menyebut O-039).
- Sekarang: `paramgen` menolaknya karena memang tidak boleh dipakai. Predikatnya berganti nama dari
  `undefinedApprovalSemantics` menjadi `disallowedApprovalSemantics`, dan pesannya menyebut D-042.

Yang **tidak** berubah: penegakan tetap di **batas CLI** (`tools/paramgen/main.nim`, keluar 2), bukan di
parser — parser dan emitter tetap menangani `false` dan fixture sengaja mengujinya, supaya plumbing
kolom `requires_approval` tidak ikut terhapus kalau kelak ada jalur "maker boleh mengaktifkan sendiri".
Tidak ada kode fast-path baru dan tidak ada constraint DB baru: `submitValue` memang selalu membuat baris
PENDING, jadi hari ini tidak ada nilai yang bisa aktif tanpa checker — penjagaan `paramgen` mencegah
definisi yang *berniat* begitu masuk, sebelum ada kode yang membacanya.

## D-043 — KRAN menggantikan `cbs-api`/`cbs-web` di tempat; domain tetap `cbs.qouver.com`

Keputusan pemilik 16 Oktober 2026. Skemanya **replace**, bukan berdampingan: KRAN mengambil alih peran
sistem lama di host yang sama — `kran-api` memakai `127.0.0.1:8095` dan `kran-web` `127.0.0.1:3005`,
yaitu port yang sekarang dipegang container `cbs-api`/`cbs-web`. Domainnya **tidak berubah**:
`cbs.qouver.com` tetap dipakai KRAN, jadi DNS tidak disentuh dan Caddy hanya perlu diarahkan ke upstream
KRAN saat peralihan.

Konsekuensinya langsung: default di tooling ops (`deploy-vps.sh`: `KRAN_HEALTH_URL=...:8095/readyz`;
`smoke.sh`: `KRAN_BASE_URL=...:8095`; `kran-prod.env.example`: `# KRAN_PORT=8095`) memang **disengaja**,
bukan sisa nama lama. Sebelumnya ini terbaca sebagai tabrakan port yang menunggu keputusan; sekarang
maknanya jelas — peralihan berarti mengganti upstream, bukan menambah aplikasi di port lain.

Menutup **O-055** (domain): tidak ada domain baru yang perlu diputuskan.

### Bukti recon 16 Okt 2026 (read-only, dari server)
- Container `cbs-api` (`127.0.0.1:8095`) dan `cbs-web` (`127.0.0.1:3005`) berjalan (`Up 2 days`).
- Tetapi **72 jam terakhir `cbs-api` tidak melayani satu pun permintaan pengguna**: dari 12.750 baris log
  hanya `/metrics` 6.378, `/api/v1/app-info` 3.190, `/healthz` 3.173. Artinya yang masih menyentuhnya
  adalah pemantauan, bukan orang.
- DB `cbs` kecil dan isinya condong ke data referensi/demo: `ojk_kabupaten` 514, `ojk_sektor_ekonomi`
  476, `system_config` 207, `group_permissions` 132, `journal_lines` 118, `loan_schedules` 108,
  `accounts` 93, `chart_of_accounts` 89. Tujuh DB `cbs_verify*` ada; tidak disentuh.

### Deviasi dari spec §21.9 (disengaja, tercatat)
Spec §21.9 berbunyi `cbs-core` **tetap melayani sampai KRAN lulus UAT pilot**. Keputusan ini
memindahkan peralihan lebih awal untuk *layanan HTTP-nya* (yang nyatanya hanya menerima probe
pemantauan). Yang **tidak** dibuang: container lama hanya **dihentikan**, tidak dihapus, dan data
(`/srv/qouver/apps/cbs`, DB `cbs`, `cbs_verify*`) tetap tinggal — jadi jalan mundur tetap ada: nyalakan
container lama + kembalikan upstream Caddy. Inventaris `cbs-core` (T-015) tetap berlaku sebagai
referensi sampai cutover selesai.

Urutan yang dipegang: latihan `deploy-vps.sh` manual di server dulu (T-013) → peralihan → baru
mempertimbangkan pembersihan. Menghapus container/DB lama **belum** dilakukan dan bukan bagian tugas
agen sampai ada perintah eksplisit setelah peralihan terbukti sehat.

---

## D-044 — Lisensi: publik untuk dibaca, tanpa izin pakai ulang (16 Okt 2026)

**Keputusan pemilik**: repositori tetap **publik**; lisensinya ditentukan agen dengan syarat "aman dan
sesuai dengan proyeknya".

**Keputusan**: lisensi **proprietary / all rights reserved**, ditulis di berkas `LICENSE`. Repo boleh
dibaca dan diaudit (dan di-fork untuk review), tetapi tidak ada izin menyalin, memodifikasi,
mendistribusikan, atau menjalankannya sebagai layanan tanpa izin tertulis.

**Alasan**: KRAN adalah produk komersial untuk koperasi/BPR. Lisensi permissive (MIT/Apache-2.0) akan
memberi siapa pun hak menjual ulang atau menawarkan layanan berbasis kode ini — itu bertentangan dengan
maksud mempublikasikannya (transparansi/audit), bukan hibah lisensi. Tanpa berkas `LICENSE`, hukum
defaultnya sudah "all rights reserved", jadi ini membuat status yang berlaku menjadi eksplisit.
Field `license = "MIT"` di `kran.nimble` **dihapus** karena metadata Nimble bisa terbaca sebagai izin
bebas. Kalau kelak lisensi lain diinginkan (mis. komersial terbatas, atau terbuka untuk koperasi),
cukup ganti berkas `LICENSE` — tidak ada kode yang bergantung padanya.

**Ikut diputuskan**: aturan README/`AGENTS.md` "jangan pernah push ke `main`" berlaku saat repo belum
punya hook deploy. Sejak D-043 hook itu ada dan men-deploy dengan health gate + auto-rollback, jadi
**push ke `main` diizinkan untuk alur repo ini sebagai keputusan pemilik** (branch lain tetap ditolak
ref-guard). Merge tetap keputusan manusia.

## D-045 — CSP: kebijakan dari `<meta>` (hash), header hanya `frame-ancestors` (16 Okt 2026)

**Masalah**: spec §21.5 meminta CSP, tetapi build SvelteKit memuat script inline; `script-src 'self'`
tanpa hash/nonce mematikan hidrasi. Solusinya bukan melonggarkan CSP, melainkan menerbitkan hash.

**Keputusan**: `csp: { mode: "hash" }` di `vite.config.ts` (halaman di-prerender, jadi hash — nonce
tidak sah untuk prerender), dan blok Caddy **tidak** memuat `script-src` sama sekali: header hanya
membawa `frame-ancestors 'none'` (satu-satunya direktif yang diabaikan browser bila ditulis di `meta`).

**Alasan (jebakan yang mudah salah)**: kalau ada dua kebijakan CSP, browser menerapkan **irisan**
keduanya. Hash diterbitkan per build, jadi tidak bisa ditulis statis di header; header
`script-src 'self'` **tanpa** hash karena itu justru memblokir script ber-hash milik Kit — dan halaman
berhenti ter-hidrasi tanpa galat yang jelas di sisi server. Dengan kebijakan lengkap hanya di `<meta>`,
tidak ada irisan yang saling mematikan. `style-src` tetap memakai `'unsafe-inline'` (Svelte menyuntik
`<style>` saat runtime; risikonya jauh lebih kecil daripada injeksi script).

**Verifikasi**: build mengandung `<meta http-equiv="content-security-policy">` berisi `sha256-…`;
suite e2e (Playwright menyajikan hasil build, bukan dev server) lulus — artinya halaman tetap
ter-hidrasi di bawah kebijakan itu. O-061 ditutup dengan ini.
