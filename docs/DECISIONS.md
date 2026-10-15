# DECISIONS — CBS

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
- **Keputusan**: satu `cbs.nimble` di root; direktori sumber di-`-p:` oleh `./task`.
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
- **Konsekuensi**: versi dipin di `cbs.nimble`; `yaml` dipakai **hanya** oleh `tools/paramgen`
  (build-time), tidak masuk jalur runtime API → risiko ekosistem terkurung.
- **Status**: diterima; kandidat diangkat jadi ADR-016 bila `paramgen` jadi alat kritis.

## D-004 — DB dev & integration test di server (bukan lokal)

- **Konteks**: uji integrasi butuh Postgres ≥16 (spec §21.3). Pemilik menolak setup Postgres
  lokal; server sudah punya `qouver-postgres` (Postgres 18.6).
- **Keputusan**: DB khusus `cbs_dev` + role `cbs_dev` di server tersebut, diakses dari laptop
  lewat tunnel SSH `127.0.0.1:55432 → 127.0.0.1:5432`. URL (berisi password) disimpan di
  `.local/dev.env` (gitignored, `chmod 600`). Env var: `CBS_DATABASE_URL`.
  CI **tidak** memakai server: `services: postgres:18` di GitHub Actions.
- **Konsekuensi**:
  - Uji integrasi **melewati dirinya sendiri** bila `CBS_DATABASE_URL` kosong (pola sama
    dengan repo keluarga `cbs-core`) → `./task test` aman tanpa DB, tapi tidak dianggap bukti.
  - DB `cbs_dev` ikut ter-backup harian server sampai skrip backup di server di-exclude
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
- **Keputusan**: `tools/devdb.sh` menerima `CBS_DEVDB_PERSIST` (default tetap 600 detik);
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
- **Keputusan**: `nimcrypto` (dipin `>= 0.7.3` di `cbs.nimble`), algoritma
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
  1. Sinyal realtime = trigger `AFTER INSERT` pada `platform.outbox` yang `pg_notify('cbs_outbox',
     outbox_id)` (migrasi 0007). Payload hanya id; isi peristiwa dibaca dari tabel. Dispatcher
     outbox tetap pemilik status `PENDING→DONE/DEAD`.
  2. Amplop peristiwa (`packages/contracts/events/realtime-envelope.v1.schema.json`) memakai
     `outbox_id` sebagai `id` **dan** resume token; urutan replay memakai kolom `seq`
     (`bigint identity`), bukan `occurred_at` (bisa sama). Token tak dikenal = replay dari awal,
     klien de-dup by `id`.
  3. Pump memulai dari peristiwa terakhir ("mulai dari sekarang"); backlog diambil klien lewat
     `resumeFrom` atau HTTP. Kesiapan pump diekspos lewat `pumpReady()`.
  4. Kebijakan topik default = **tolak semua** (`denyPolicy`) sampai T-012 memasang identitas sesi;
     identitas sudah dibaca dari cookie `cbs_session`/`Authorization: Bearer`. Topik yang ditolak
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
  1. `apps/web/vite.config.ts` meneruskan `/api`, `/healthz`, `/readyz` ke `cbs-api`
     (`CBS_API_TARGET`, default `http://127.0.0.1:8080`), dengan `ws: true` untuk upgrade
     `/api/v1/events/stream` (spec §19.3).
  2. Aplikasi web selalu berbicara same-origin (`baseUrl` klien kosong); tidak ada penanganan token
     di JS dan tidak ada konfigurasi CORS di API.
  3. Produksi memakai bentuk yang sama: satu origin di belakang Caddy (halaman + `/api`).
- **Alasan menolak alternatif**: melonggarkan `SameSite` melemahkan pertahanan CSRF yang justru
  diminta spec; CORS + `credentials` menambah jalur kode baru yang harus diuji di dua mode.
- **Konsekuensi**: `apps/web/playwright.config.ts` menyalakan API di port e2e (8099) dan menyetel
  `CBS_API_TARGET`, supaya e2e menguji origin tunggal yang sama seperti dev/produksi.

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

- **Konteks**: `cbs-api` tidak memasang penangan sinyal apa pun. `SIGTERM` (yang dikirim `systemctl
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
