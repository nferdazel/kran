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

**Verifikasi di produksi (16 Okt 2026)**: setelah header Caddy diubah menjadi `frame-ancestors 'none'`,
`https://cbs.qouver.com/login` dibuka dengan Chromium sungguhan: judul halaman KRAN, `data-theme`
terpasang oleh `theme.js` (bukti script eksternal lolos `script-src 'self'`), input kata sandi ada
(bukti hidrasi, jadi script inline ber-hash lolos), **0 pelanggaran CSP**, 0 error konsol.

---

## D-046 — Batch keputusan pemilik 16 Okt 2026 (open items yang butuh manusia)

Pemilik menjawab daftar item yang benar-benar butuh keputusan (bukan pekerjaan teknis). Semua
rekomendasi agen disetujui, dengan dua koreksi dan satu perubahan rencana.

1. **O-001 (compliance)**: nilai/pasal §4 yang bertanda `V?`/`V!` tetap **belum** terverifikasi, dan
   tetap wajib bertanda `NEEDS-COMPLIANCE-REVIEW`. Review compliance dijadwalkan **sebelum** fitur
   Fase 1 yang bergantung angka (bunga, akrual, PPAP, SHU). Tidak ada nilai yang boleh dipakai untuk
   hitungan nyata sebelum itu.
2. **O-004 (pilot)**: target pilot ditetapkan **1 koperasi, 1 cabang, < 5.000 anggota**.
3. **O-003 (data `cbs-core`)**: dikonfirmasi pemilik bahwa isinya **bukan data nyata** — itu hasil uji
   dengan data yang dibuat "seasli mungkin". Karena itu O-003 ditutup, dan kekhawatiran "jangan
   menyentuh data nyata" tidak berlaku untuk DB lama. **DB `cbs` tetap tidak dihapus** sampai ada
   perintah eksplisit (perlindungan rollback), bukan karena dianggap berisi data nyata.
4. **O-002 (backup harian)**: filter DB non-prod **diterapkan** di skrip live server
   (`/srv/qouver/scripts/backup-postgres.sh`, dipakai timer 02:00): `postgres`, `%_verify%`, `%_test%`,
   `%_dev%` dikecualikan. Diverifikasi: daftar DB yang tersisa `bm, cbs, fond, fond_nim, kran, qouver,
   sds, skyward`. Drop DB `*_verify*` lama **belum** dilakukan (tindakan destruktif; menunggu perintah
   eksplisit, walaupun isinya sekali pakai).
5. **O-054 (sisa sistem lama)**: pemilik memilih **lebih cepat**, jadi pembersihan dijalankan segera
   (bukan menunggu dua minggu/sebulan): `handle /cbs/*` di `api.qouver.com` **dihapus** (backend-nya
   container lama yang sudah mati; diverifikasi `/cbs/healthz` = 404 dan situs lain tetap normal), dan
   container `cbs-api`/`cbs-web` **dihapus**. Yang tetap tinggal: image `localhost/cbs-api|cbs-web`,
   `/srv/qouver/apps/cbs` (berisi `deploy-vps.sh`), dan DB `cbs` + `cbs_verify*` — jalan mundur masih
   utuh. Backup Caddyfile: `/etc/caddy/Caddyfile.bak-kran-nocbs-20261016T142811`.
6. **O-056 (rantai fallback parameter)**: **dipertahankan eksplisit** — pemanggil menyebut levelnya,
   tanpa fallback senyap `PRODUCT → BRANCH → INSTITUTION → SEGMENT → GLOBAL`. Deviasi dari spec §10.2
   diterima sadar: nilai parameter kebijakan yang "diam-diam berlaku" lebih berbahaya daripada repot
   menyebut level. Ini bukan utang teknis, melainkan pilihan.
7. **O-032 (visibilitas params/audit)**: `GLOBAL` selalu tampak; level lain hanya untuk pengguna yang
   memang ber-scope itu; pembacaan lintas cabang masuk audit. Dikerjakan di T-051.
8. **O-043 (`effective_to` tanpa penerus)**: **ditolak saat pengajuan** — `effectiveTo` hanya boleh
   bila ada penerus (atau penanda eksplisit bahwa nilai itu memang berakhir). Bukan task pembersih.
9. **O-050 + O-052 (kata sandi)**: percobaan kata sandi lama yang salah **diaudit + dibatasi** (angkanya
   parameter, bukan konstanta). Kebijakan lanjutan: **tidak** ada kedaluwarsa sekarang, riwayat 5,
   kualitas minimum sebagai parameter. Final menunggu review compliance (butir 1).
10. **O-015 (MFA)**: **belum perlu diaktifkan**. Pemilik memilih sifatnya bila nanti dipakai:
    per akun bisa memilih memakai MFA atau tidak, **default mati**, demi kemudahan login dan pengujian.
    Yang diminta sekarang: **siapkan bootstrap-nya** (skema, parameter, jalur verifikasi) tanpa
    mengaktifkan apa pun — direncanakan sebagai T-046 dan **tidak** dikerjakan sebelum batch lain.
11. **O-016 (matriks SoD)**: diisi bersama compliance setelah butir 1; tidak dikarang sekarang.
12. **O-006 (KEK)**: tetap seperti sekarang — berkas terpisah mode 600 di luar backup DB — plus rencana
    `sops`/`age` **sebelum** data pilot nyata masuk.
13. **O-005 / ADR-002 (HTTP server)**: **ditutup**: Mummy 0.4.8 dipakai dan sudah diuji (termasuk
    dua sifat non-publiknya di D-037). ADR tanpa keputusan hanya membingungkan.

Butir 7–9, 11–12 menjadi task T-051/T-053/T-046; butir 10 sengaja terakhir.

---

## D-047 — Nilai kandidat parameter hanya untuk scope yang boleh dilihat pengaju (O-044)

**Keputusan pemilik (16 Okt 2026)**: menyetujui rekomendasi agen — pengaju hanya boleh mengusulkan
nilai untuk scope yang **dia sendiri boleh baca**. Aturannya sama dengan yang dipakai untuk visibilitas
pembacaan parameter (O-032, D-046 butir 7), sehingga tidak ada dua aturan berbeda antara membaca dan
mengusulkan.

**Alasan**: tanpa itu, pengaju bisa menanam nilai pada scope yang tidak terlihat olehnya (mis. cabang
lain) dan akibatnya baru muncul sebagai "nilai yang berlaku dari mana?" — jenis kekacauan yang sudah
berulang di register ini (O-012/O-044/O-056). Satu aturan untuk baca dan tulis jauh lebih mudah
diaudit daripada dua.

**Pelaksanaan**: masuk T-051 bersama O-032/O-043/O-050/O-052; uji izinnya harus mencakup sisi
pengajuan, bukan hanya pembacaan.

---

## D-048 — Enkripsi field-level: envelope KEK→DEK turunan + blind index (ADR-017)

- **Konteks**: spec §18.2 mewajibkan field-level encryption (envelope, blind index) untuk NIK/NPWP/
  no. HP/alamat; Fase 1 `party` akan mendaratkannya. Register O-006 menyebut "KEK belum ada tempat
  aman", tetapi kenyataannya **belum ada mekanisme enkripsi field sama sekali** (keputusan pemilik:
  kerjakan kini sebagai fondasi, bukan menunggu data nyata). Detail + alternatif: `docs/adr/017-field-level-encryption.md`.
- **Keputusan**: mekanisme di `shared/platform-lib/crypto/fieldcrypto.nim` — KEK di berkas terpisah
  mode 600 (`KRAN_KEK_FILE`), **DEK per tabel diturunkan** `HMAC-SHA256(KEK, "kran:dek:v1:"||tabel)`,
  ciphertext `kran:enc:v1:<kid>:<nonce>:<ct||tag>` (AES-256-GCM dari nimcrypto, AAD = nama tabel),
  dan blind index dengan kunci turunan **terpisah** (`kran:bidx:v1:`). Tanpa dependensi baru.
- **Alasan**: tidak ada materi kunci di dump/backup DB, tidak ada tabel/kopling lintas-modul baru,
  dan KEK yang sudah seragam 256-bit membuat HKDF penuh tidak menambah keamanan (HMAC langsung =
  inti Expand). Rinci di ADR-017.
- **Konsekuensi (jujur)**: rotasi tidak bisa independen per tabel (DEK terikat KEK → re-enkripsi
  saat rotasi KEK); rotasi kunci blind index membatalkan indeks (perlu reindex); **KEK hilang = data
  tak terbaca** (berkas KEK tidak ikut backup DB — inti O-006); konvensi "kunci aktif = entri
  terakhir". Aktivasi **tanpa fallback senyap** (O-056/D-046 butir 6): `KRAN_KEK_FILE` kosong →
  aplikasi start apa adanya, enkripsi/dekripsi gagal eksplisit; diset → fail-fast saat startup.
- **Alternatif ditolak**: DEK terbungkus di tabel registry DB (menaruh kunci di DB); pgcrypto/
  `pgp_sym_encrypt` (kunci lewat SQL, terkopel ke DB); HKDF penuh (tanpa manfaat di KEK 256-bit);
  envelope per-record (kompleks tanpa manfaat pada skala pilot).
- **Status**: diterima; **HUMAN-REVIEW-REQUIRED** sebelum dipakai untuk data anggota nyata (area
  kriptografi, AGENTS.md §8). Uji: vektor independen Node + roundtrip/tamper/AAD/keyring/blind index
  (`tfieldcrypto.nim`) dan e2e tabel sementara (`itfieldcrypto.nim`).

---

## D-049 — Tautan "Masuk" di header mengubah urutan Tab shell (O-033)

- **Konteks**: navigasi ke `/login` sebelumnya hanya mungkin lewat URL langsung; header hanya
  memuat satu tautan ("Beranda"). `keyboard.spec.ts` mengunci urutan Tab shell
  (skip link → tema → bahasa → tautan navigasi → konten), sehingga menambah tautan mengubah
  urutan itu. Sesi tidak dipegang layout (`AppContext` bukan urusan header), sedangkan aksi
  "Keluar" sudah ada di toolbar `/app` yang punya konteks sesi.
- **Keputusan**: tambahkan satu tautan statis **Masuk → `/login`** sebagai item kedua di
  `<nav>` header, dan perbarui `keyboard.spec.ts` agar mengunci urutan baru
  (… → Beranda → Masuk). Tidak ada tautan "Keluar" di header: aksi itu butuh konteks sesi dan
  tetap di `/app`.
- **Alasan**: tautan statis tidak memaksa setiap halaman membaca sesi (menghindari permintaan
  `/auth/session` di header shell) dan tetap memenuhi kebutuhan navigasi ke halaman masuk.
- **Konsekuensi**: urutan Tab shell bertambah satu langkah; `keyboard.spec.ts` adalah kontrak
  urutan itu dan ikut diperbarui. Tautan tampak juga saat sudah masuk — dapat diterima di Fase 0
  (halaman `/login` menangani sesi yang sudah ada); bila kelak header jadi sadar-sesi, tautannya
  yang disesuaikan, bukan urutannya disembunyikan.

---

## D-050 — Deploy memasang unit systemd dari repo (T-056)

- **Konteks**: `deploy-vps.sh` menjalankan `daemon-reload` + `restart`, tetapi tidak pernah memasang
  `ops/systemd/*.service` dari repo. Akibatnya perubahan unit di repo adalah konfigurasi mati sampai
  ada yang menyalinnya manual — dan itu sudah terjadi: `RestartPreventExitStatus=2` (T-054) harus
  dipasang tangan di server. Gejalanya menyesatkan: yang tampak bukan deploy gagal, melainkan
  perilaku restart yang berbeda dari repo.
- **Keputusan**: tambahkan `sync_units` (plus `restore_units` untuk jalur rollback) ke langkah
  self-update deploy. Unit dibandingkan dengan `cmp`, divalidasi `systemd-analyze verify` **sebelum**
  ditimpa (tidak lolos → deploy dibatalkan), dan cadangan lama disimpan sebagai `.prev`. Health gate
  yang gagal mengembalikan `.prev` lalu `daemon-reload` sebelum restart.
- **Alasan**: menyamakan perlakuan unit dengan binary/web (`.prev` + rollback) menutup kelas bug
  "repo dan produksi berbeda tanpa ada yang tahu". `verify` dipakai sebagai gate karena unit rusak
  baru terlihat jauh dari penyebabnya (restart-loop di health gate). Hanya kode keluar `verify` yang
  dipakai — peringatan tentang unit lain di server adalah hal normal.
- **Konsekuensi**: deploy kini menyentuh `$HOME/.config/systemd/user` (dapat diarahkan lewat
  `KRAN_UNIT_DIR`). Perubahan unit di repo berlaku pada deploy berikutnya tanpa langkah manual.
  Terverifikasi lokal lewat harness 5/5 + `bash -n` + `shellcheck -S warning`; di produksi jalur ini
  berjalan sebagai no-op karena unit terpasang sudah identik dengan repo.

---

## D-051 — `shellcheck` level warning memblokir, dan job CI `db-tests` (T-050)

- **Konteks**: gate `./task check` hanya memblokir pada `shellcheck -S error`; temuan `warning`
  sekadar dilaporkan, dengan alasan eksplisit "shellcheck tidak terpasang di mesin pengembang".
  Test integrasi juga hanya berjalan di mesin dev: tanpa `KRAN_DATABASE_URL` mereka melewati
  dirinya sendiri, jadi CI hijau tidak membuktikan apa pun tentang jalur DB.
- **Keputusan**: (a) tambahkan job `db-tests` di `ci.yml` (`services: postgres:18`,
  `KRAN_DATABASE_URL` → `kran_test`, `dbtools migrate` + `seed --dev`, lalu `./task test`);
  (b) naikkan gate shellcheck ke level `warning` dan jadikan **fail-closed** bila tool tidak ada —
  pelepasan sadar lewat `KRAN_SKIP_SHELLCHECK=1`; CI memasang shellcheck eksplisit di job
  `nim-check`.
- **Alasan**: (a) jalur integrasi yang tidak pernah berjalan adalah "hijau palsu" dengan bentuk yang
  sama seperti job kosong; (b) gate yang hilang diam-diam saat toolnya tidak ada juga hijau palsu.
  Kenaikan ke `warning` sudah punya bukti: `shellcheck -S warning ops/scripts/*.sh` bersih untuk
  ketujuh skrip (17 Okt 2026).
- **Konsekuensi**: nama basis data CI wajib berakhiran `_test`/`_dev` (seed dev fail-closed, O-062)
  dan URL harus bentuk polos (`parseDatabaseUrl` menolak query string). Mesin tanpa shellcheck kini
  merah sampai tool dipasang atau pelepasan sadar dilakukan. ESLint (O-023) **tidak** termasuk di
  sini: butuh dependensi baru → `T-057` menunggu keputusan pemilik.

---

## D-052 — Parameter di proses `api` dibaca per permintaan, tanpa cache lintas-proses (T-055, menutup O-018)

- **Konteks**: O-018 membuka pertanyaan apakah proses `api` perlu cache parameter yang dihangatkan
  lalu di-invalidasi lintas-proses lewat `NOTIFY platform_param_changed`. `ParamService`/`param_cache`
  sudah ada di `modules/platform` tetapi nol pemakai di `apps/api` (satu-satunya konsumen kanal itu
  adalah test `itparamservice`), jadi pertanyaannya bukan "menambahkan `LISTEN`" melainkan "bangun
  cache atau jangan".
- **Keputusan**: parameter tetap dibaca dari DB per permintaan. `settingsOf`
  (`modules/platform/infrastructure/auth_service.nim:50-65`) = 6 pembacaan baris-tunggal dan hanya
  dipanggil di jalur auth (`apps/api/src/handlers_auth.nim:64`, `:115`, `:179`); `realtimeLimits`
  sekali saat start. Cache tidak dibangun; ditinjau ulang **hanya** bila salah satu pemicu terukur
  ini muncul: `settingsOf` > 10% p95 waktu DB api, > 50 permintaan auth/detik per proses, `api`
  berjalan > 1 replika, atau > 10 parameter per permintaan.
- **Alasan**: bebannya tidak terukur pada skala pilot (1 koperasi/1 cabang/< 5.000 anggota, satu
  proses `api`, tabel parameter puluhan baris). Sebaliknya cache lintas-proses bersandar pada `NOTIFY`
  yang **tidak dijamin sampai** (PostgreSQL tidak memutar ulang notifikasi) sementara `param_cache`
  sengaja tanpa TTL, sehingga notifikasi yang hilang menghasilkan nilai basi **tanpa error** — kelas
  bug yang paling berbahaya di jalur keamanan/uang dan bertentangan dengan semangat "tanpa fallback
  senyap" (D-046 butir 5).
- **Konsekuensi**: O-018 ditutup sebagai keputusan, bukan sebagai implementasi; tidak ada koneksi
  `LISTEN` tambahan per replika dan tidak ada kelas bug "basi tanpa error" yang perlu dijaga. Pemicu
  tinjau ulang dicatat di sini supaya keputusan ini dibatalkan dengan bukti, bukan selera. Catatan
  jujur: indeks parsial `param_value_lookup_idx` berpredikat `WHERE status='ACTIVE'` tidak menopang
  query resolusi (`status IN ('ACTIVE','SUPERSEDED')`) — tidak terasa pada tabel puluhan baris, tetapi
  jadi relevan bila pemicu di atas tercapai.

---

## D-053 — Warning `svelte-check` memblokir; ESLint tidak ditambahkan sekarang (T-057, O-023)

- **Konteks**: O-023 meminta ESLint + `eslint-plugin-svelte` dengan aturan a11y sebagai error.
  Pemeriksaan ulang: hambatannya bukan tooling (pnpm 11.25.0 jalan, registry terjangkau), melainkan
  penambahan dependensi baru + ADR + plumbing CI. Celah yang sebenarnya terasa berbeda: `./task e2e`
  menjalankan `svelte-check` tanpa `--fail-on-warnings`, sehingga diagnostik a11y kompilator
  (`a11y_*`) hanya jadi warning dan **tidak pernah menggagalkan gate**.
- **Keputusan**: (a) `./task e2e` memakai `svelte-check --fail-on-warnings` — warning memblokir,
  termasuk seluruh diagnostik `a11y_*`; (b) ESLint **tidak** ditambahkan sekarang; T-057 tetap ada
  sebagai task tertunda dengan lingkup dipersempit ke lint statis generik (`svelte/*` non-a11y,
  `typescript-eslint`) dan dikerjakan bersama T-012 saat komponen bisnis nyata lahir.
- **Alasan**: aturan a11y `eslint-plugin-svelte` sebagian besar memetakan ulang warning kompilator
  Svelte yang sudah ada — nilai barunya adalah menjadikannya error, dan itu dicapai tanpa satu pun
  dependensi baru. Terbukti bersih saat diaktifkan (17 Okt 2026: 0 error, 0 warning), jadi ini
  penguatan gate. Menambah lima paket + ADR + langkah CI (job `nim-check` tidak menjalankan
  `pnpm install`) untuk lima komponen Fase 0 adalah abstraksi dini (KISS).
- **Konsekuensi**: gate web kini memblokir pada warning, jadi komponen dengan CSS tak terpakai atau
  atribut a11y yang hilang merah lebih awal — itu tujuannya, dan sifatnya satu baris untuk dibatalkan
  bila terbukti mengganggu saat T-012. Batasan yang tercatat untuk T-057 bila nanti dikerjakan:
  `minimumReleaseAge` di `pnpm-workspace.yaml`, `typescript-eslint` wajib (semua `<script>`
  ber-`lang="ts"`), dan `packages/config/eslint.js` masih belum ada. Ambang axe (`serious`/
  `critical`) **tidak** diubah di sini.

---

## D-054 — Assertion e2e atas audit log append-only memakai `.first()` (T-044)

- **Konteks**: saat memverifikasi D-053, `./task e2e` gagal pada run lokal kedua: strict-mode
  violation karena `getByText(reason)` menemukan 2 baris. Penyelidikan: `platform.audit_log` bersifat
  **append-only** (trigger `platform.audit_log_immutable` menolak `DELETE` — dicoba langsung, ditolak
  dengan pesan spec §9.1(3)), dan tiap run e2e menambah satu baris dengan alasan identik
  (`TEXT.reason` konstan). Diperiksa atas tiga baris yang ada: `audit_id`, `recorded_at`, dan
  `request_id` semuanya berbeda → akumulasi antar-run, **bukan** dobel-tulis dalam satu aksi. Karena
  CI selalu mulai dari DB baru, cacat ini tidak pernah terlihat di CI dan hanya memerahkan mesin dev
  pada run kedua dan seterusnya.
- **Keputusan**: `apps/web/tests/e2e/flow.spec.ts:238` memakai `.first()`, konsisten dengan baris
  berikutnya (`param.submit` sudah `.first()` sejak awal). Assertion tetap menuntut baris itu
  **terlihat**; yang berubah hanya toleransi terhadap baris kembar yang sah pada log append-only.
- **Alasan**: alternatif "bersihkan baris lama" justru dilarang skema — dan memang tidak boleh,
  karena audit log append-only adalah invarian yang sengaja ditegakkan. Jadi yang salah bukan
  fixture-nya, melainkan assertion yang hanya benar pada DB yang baru direset.
- **Konsekuensi**: gate e2e bisa dijalankan berulang di mesin dev (dibuktikan: dua run berturut-turut
  `23 passed`, `exit=0`, dengan baris audit tetap berakumulasi menjadi 5). Ini **bukan** pelonggaran:
  tidak ada assertion yang dihapus dan tidak ada ambang yang diturunkan. Sisa pekerjaan T-044 (flake
  yang benar-benar intermiten) tetap terbuka; temuan ini deterministik dan tercatat di
  `docs/tasks/T-044.md`.
- **Eskalasi (AGENTS §8)**: kelas gejala ini sudah dikenali T-044/T-031, dan `docs/tasks/T-044.md`
  melarang melonggarkan assertion. Karena itu perubahan ini **tidak** diputuskan diam-diam: entri ini
  adalah eskalasinya, dan pemilik dapat membalikkannya (satu commit) bila menilai assertion tersebut
  memang harus ketat. Alasan tetap dipertahankan: yang salah adalah assertion yang hanya benar pada DB
  yang baru direset, dan tanpa perbaikan ini `ci-repeat 3` — salah satu kriteria selesai T-044 itu
  sendiri — tidak akan pernah hijau di mesin dev.

---

## D-055 — Visibilitas parameter per scope, wewenang pengajuan, dan pembacaan lintas-cabang (T-051: O-032 + O-044/D-047)

- **Konteks**: D-046 butir 6 menetapkan "GLOBAL selalu terlihat, scope lain sesuai wewenang, pembacaan
  lintas-cabang diaudit"; D-047 (O-044) menetapkan pengaju hanya boleh mengusulkan nilai untuk scope
  yang **ia sendiri** boleh baca. Sebelum ini `GET /api/v1/params` (`handlers_param.nim:48`) dan
  `GET /api/v1/audit` (`handlers_audit.nim:38`) menyaring `status`/`action` saja, dan pengajuan hanya
  memeriksa `allowed_scopes` definisi — bukan wewenang pengaju.
- **Keputusan**:
  1. Aturan "grant mana menutupi scope mana" hidup **satu kali**: `platform/domain/authz.
     readableScopeFilter` (ringkasan grant → `allBranches` + himpunan cabang), dan `mayReadScope`
     diturunkan dari padanya. Repo hanya **menerjemahkan** hasilnya ke SQL (`paramValueRows`,
     `listAudit`) — bukan tempat kedua aturannya.
  2. Penyaringan dilakukan **di query**, bukan setelah `LIMIT`: kalau disaring belakangan, baris yang
     tidak boleh dibaca memakan jatah halaman dan daftar bisa tampak kosong padahal masih ada baris
     yang boleh dibaca. Dikunci dua test (`itparam`/`itplatform`: dengan `limit = 1` hasilnya bukan
     halaman kosong).
  3. GLOBAL terlihat oleh siapa pun yang memegang izin bacanya. INSTITUTION hanya untuk grant **tanpa
     batas cabang**. BRANCH hanya cabang yang ditutup grant. PRODUCT/SEGMENT/ROLE **gagal-tertutup**
     (tidak terlihat siapa pun) karena `Grant` hanya mengenal cabang — tidak ada model keanggotaan
     untuk ketiganya, jadi menampilkannya = membocorkan nilai yang keanggotaannya tidak bisa
     dievaluasi.
  4. Pengajuan: `mayReadScope` diperiksa **sebelum** validasi definisi → `403 scope_not_readable`.
     Dipilih 403, bukan 400, supaya penolakan tidak membocorkan (key, scope) mana yang didukung;
     wewenang yang kurang adalah 403 sepanjang aplikasi ini.
  5. Pembacaan lintas-cabang dicatat audit: **satu entri per (permintaan, cabang)** yang dibaca di luar
     cabang tugas pemanggil — `action=param.read_cross_branch`, `resource_type=param_branch`,
     `resource_id=<scopeId>`, `reason=cross_branch_read`. "Cabang tugas" = cabang yang benar-benar
     ditutup grant berizin-baca (grant tanpa batas cabang tidak menjadikannya cabang tugas).
     Tanpa de-duplikasi: audit append-only, dan granularitas per-cabang menjaga barisnya kecil.
     Penulisannya di jalur baca dan **tidak** dimaafkan: bila pencatatan audit gagal, permintaan
     daftar ikut gagal (500) — "menyajikan tanpa jejak" adalah persis yang dilarang butir ini.
  6. Daftar audit disaring dengan aturan yang sama; aksi **tanpa** cabang selalu terlihat (tidak ada
     yang dilindungi dengan menyembunyikannya). Pembacaan daftar audit **tidak** menulis audit baru:
     kalau ya, setiap pembacaan mengubah isi daftar yang sedang dibaca — dan butir 5 di atas sengaja
     dibatasi hanya pada **pembacaan nilai parameter**, bukan pada pembacaan jejaknya.
- **Alasan**: keputusan pemilik (D-046 butir 6/D-047) dijalankan apa adanya untuk GLOBAL/INSTITUTION/
  BRANCH; satu-satunya titik yang benar-benar tidak bisa dijawab dari grant adalah keanggotaan
  PRODUCT/SEGMENT/ROLE, dan untuk itu gagal-tertutup adalah pilihan paling aman (dan paling mudah
  dibalik: begitu model keanggotaannya ada, predikatnya tinggal diisi).
- **Konsekuensi & dua temuan yang harus dibaca sebagai bagian keputusan ini**:
  - **Penyaringan audit belum berefek hari ini.** Setiap baris `platform.audit_log` yang ditulis dari
    jalur HTTP punya `branch_id` NULL — `auditContextFor` (`access.nim:92`) tidak mengisi `branchIds`,
    jadi semuanya terbaca sebagai tingkat institusi dan terlihat oleh semua pemegang
    `platform.audit.read` (diperiksa langsung di DB dev: 54 baris, 0 bercabang). Aturan penyaringannya
    diuji di lapis repo dengan konteks yang memang membawa cabang (`itplatform.nim`), bukan lewat HTTP
    — dan itu memang satu-satunya cara mengujinya sekarang. Atribusi cabang per permintaan HTTP adalah
    bagian **kedua** O-032 yang belum diputuskan.
  - **Grant ber-cabang belum bisa memakai endpoint HTTP mana pun.** `authorized` memeriksa dengan
    `targetBranch = ""` (`access.nim:82-90`), sehingga grant khusus cabang tidak pernah cocok. Jadi
    aturan visibilitas ini benar dan teruji (`tauthz` murni + `itparam` di lapis repo), tetapi efeknya
    di produksi masih **nol** sampai scoping cabang diaktifkan. Menyalakannya mengubah perilaku
    secara luas (permintaan yang lolos bisa mulai ditolak) → keputusan pemilik, bukan diselipkan di
    T-051 (rencana T-051 sudah menandai opsi ini sebagai di luar lingkup).
- **Bukti**: `tauthz` (10 test murni: matriks mayReadScope + deteksi lintas-cabang),
  `itparam` ("visibilitas daftar per scope", termasuk baris `PRODUCT` yang tetap gagal-tertutup),
  `itplatform` ("daftar audit — visibilitas per cabang", 3 test), `itapi_auth` (403
  `scope_not_readable` untuk PRODUCT; nilai BRANCH lewat maker-checker + jejak
  `param.read_cross_branch` di DB). Semua `exit=0`.
- **HUMAN-REVIEW-REQUIRED (authz)**: keputusan gagal-tertutup PRODUCT/SEGMENT/ROLE dan granularitas
  audit lintas-cabang (tanpa de-duplikasi) diminta ditinjau manusia; keduanya dapat dibalik dalam satu
  commit tanpa menyentuh jalur data lain.

## D-056 — `effectiveTo` tanpa penerus ditolak di dua pintu (O-043)

- **Konteks**: O-043 — baris `ACTIVE` ber-`effective_to` tanpa pengganti meninggalkan celah nilai di
  masa depan; CHECK/EXCLUDE hanya mencegah periode **tumpang tindih**, bukan periode yang berakhir
  tanpa penerus. D-046 butir 8 memutuskan: **ditolak saat pengajuan**, dengan opsi penanda eksplisit
  bahwa nilai itu memang berakhir. Pelaksanaannya butuh satu keputusan teknis: apa itu "penerus".
- **Keputusan**:
  1. **Penerus** = baris lain pada (key, scope) yang sama, `status` di `{ACTIVE, SUPERSEDED, PENDING}`,
     mulai pada atau setelah `effective_from` kandidat, dan **berlaku** pada tanggal `effective_to`
     kandidat (`effective_from <= effectiveTo` dan `effective_to IS NULL OR > effectiveTo`).
     `DRAFT` tidak dihitung (tidak ada jalur kode yang membuatnya; draf belum tentu diajukan).
  2. Batas `effective_from >= effective_from kandidat` disengaja: persetujuan memangkas nilai `ACTIVE`
     yang mulai lebih awal (`supersedePreviousValues`), jadi nilai lama yang kebetulan masih terbuka
     **bukan** penerus. Tanpa batas itu, pengajuan ber-`effectiveTo` lolos dan celahnya baru muncul
     saat pengaktifan — persis yang harus dicegah. Ini kasus pembeda yang dikunci test.
  3. `PENDING` dihitung sebagai penerus karena saat nilai terbatas diajukan, penerusnya memang masih
     PENDING — urutan sahnya: ajukan penerus → setujui nilai terbatas → setujui penerus.
     **Koreksi 17 Okt 2026 (temuan review ronde 1, MINOR):** alasan yang ditulis di sini semula
     ("penerus tidak bisa disetujui lebih dulu karena bersinggungan dengan nilai lama yang terbuka,
     EXCLUDE") **tidak benar**: EXCLUDE hanya berlaku untuk `ACTIVE`/`SUPERSEDED`, dan
     `supersedePreviousValues` berjalan sebelum `activatePending`, jadi penerus *bisa* disetujui lebih
     dulu — nilai lama lalu dipangkas sampai `effective_from` penerus. Urutannya tetap seperti di atas
     karena sebab lain: setelah pangkasan itu, nilai terbatas di dalam rentang sebelumnya selalu
     bertabrakan dengan baris riwayat hasil pangkasan (EXCLUDE), jadi "penerus dulu" bukan buntu
     urutan melainkan membuat nilai terbatas tidak bisa diaktifkan. Konsekuensinya ada jeda sementara
     yang tidak terbaca di antara kedua persetujuan itu; itu bagian alur maker-checker, bukan celah
     permanen (dan tetap terdeteksi startup check O-057).
  4. Penegakan **di dua pintu**, pola yang sama dengan `sessionPolicyCandidateProblem`: pengajuan
     (400 `effective_to_without_successor`) dan persetujuan (409 alasan sama), karena penerus bisa
     hilang di antara keduanya. Vonisnya satu fungsi (`effectiveToGapProblem`) di lapis repo.
  5. Penanda eksplisit "nilai ini memang berakhir" dari D-046 butir 8 **belum dibuat** (belum ada field
     permintaannya di kontrak). Karena itu hari ini nilai tidak bisa diakhiri tanpa penerus —
     dicatat sebagai open item, bukan dianggap selesai.
- **Jendela sisa (jujur)**: penerus yang ditolak **setelah** nilai terbatas disetujui tetap
  meninggalkan celah. Hari ini keadaan itu hanya bisa datang dari operasi DB langsung, karena **tidak
  ada endpoint HTTP untuk menolak pengajuan** (hanya `rejectValue` di repo) — juga dicatat sebagai open
  item. Backstop-nya startup check O-057.
- **Alternatif yang ditolak**: (a) memeriksa hanya saat pengajuan — penerus bisa hilang sebelum
  persetujuan; (b) hanya `ACTIVE` yang dihitung sebagai penerus — buntu urutan (lihat butir 3);
  (c) trigger DB — butuh pembacaan lintas baris di dalam trigger dan pesan errornya tidak bisa
  diterjemahkan UI menjadi alasan berkode.
- **Bukti**: `itparam` ("effectiveTo tanpa penerus", 5 test vonis + kasus pembeda nilai lama terbuka),
  `itapi_auth` ("akhir periode tanpa penerus lewat HTTP", 3 test: 400 menolak, kontrol 201, 409 saat
  penerus hilang sebelum persetujuan). Semua `exit=0`; `./task check` hijau.

## D-057 — Kata sandi lama yang salah dibatasi & diaudit lewat mekanisme yang sudah ada (O-050)

- **Konteks**: O-050 — `/auth/password` menjawab 403 `old_password_mismatch` tanpa menambah penghitung
  gagal dan tanpa entri audit, berbeda dari `authenticate` yang punya lockout dari parameter (§18.2).
  D-046 butir 8 memutuskan: audit **dan** batasi percobaannya.
- **Keputusan**:
  1. Jalur gagal `changePassword` menaikkan penghitung yang **sama** dengan login
     (`recordLoginFailure`) dengan angka dari parameter yang sudah ada
     (`max_failed_logins`, `lockout_minutes`) — bukan parameter baru, bukan kebijakan kedua. Login yang
     berhasil tetap mengosongkannya (`recordLoginSuccess`), jadi batasnya "N kegagalan beruntun (nilai
     parameter), apa pun jenisnya".
  2. Akibatnya penguncian berlaku juga untuk login berikutnya: kata sandi benar sekalipun ditolak 403
     `locked`. Disengaja — pelaku yang memegang sesi sah tidak boleh menebak kata sandi lama tanpa
     batas. Dua bantahan yang diperiksa dan ditolak: (a) ini membuka DoS baru untuk mengunci akun
     korban — **tidak**, karena penguncian akun sudah bisa dipicu siapa pun lewat N login gagal tanpa
     perlu sesi sama sekali, jadi kemampuan itu tidak bertambah; (b) semantik penghitung jadi
     tercampur (`Risiko` di `docs/tasks/T-051.md` memperingatkan hal ini) — yang dicampur bukan
     "kolom yang mirip", melainkan satu definisi yang eksplisit: kegagalan pembuktian kredensial
     beruntun pada satu akun, apa pun jalurnya. Itu justru definisi yang diinginkan untuk sebuah
     penguncian; mekanisme kunci kedua hanya menambah permukaan yang bisa salah.
  3. Audit `user.password_change.failure` memakai namespace `user.password_change` yang sudah ada
     (satu filter `action` menangkap riwayat ganti kata sandi), berisi `reason`, `failed_attempts`,
     `status` — tanpa bahan kata sandi (invarian #12).
  4. Sesi yang sedang dipakai **tidak** dicabut pada percobaan gagal; perilaku 403 yang sudah ada
     dipertahankan supaya salah ketik tidak jadi pengeluaran paksa.
- **Alternatif yang ditolak**: (a) parameter + penghitung terpisah khusus ganti kata sandi — dua
  kebijakan yang harus dijaga selaras tanpa kebutuhan nyata; (b) mencabut sesi setelah N kegagalan
  (opsi yang disebut O-050) — DoS sepele bagi pemegang sesi sah lainnya.
- **Bukti**: `itapi_auth` (2 test: penghitung + audit `user.password_change.failure`; akun terkunci
  sampai batas parameter, dan login berikutnya ditolak 403 `locked`); `itauth` (23 test lama tetap
  hijau); `./task fmt` + `./task check` hijau.

## D-058 — Kebijakan kata sandi lanjutan: kelas karakter + riwayat sebagai parameter, tanpa kedaluwarsa (O-052)

- **Konteks**: D-046 butir 8 memutuskan tiga hal untuk fase pilot — riwayat 5, kualitas kata sandi
  **sebagai parameter**, dan **tanpa** kedaluwarsa. Fase 0 baru punya panjang minimum, larangan
  sama-dengan-username, dan larangan spasi (`domain/authz.nim`).
- **Keputusan**:
  1. Dua parameter baru di `modules/platform/seeds/params.yaml` (lewat `paramgen`, tanpa SQL manual):
     `platform.security.password_min_classes` (base **3**, rentang 1..4) dan
     `platform.security.password_history_count` (base **5**, rentang 0..24).
  2. Kelas karakter dihitung ASCII-style: huruf kecil, huruf besar, angka, dan "selain itu" (simbol —
     termasuk aksara non-ASCII, yang jatuh ke kelas simbol). `min_classes = 1` berarti hanya panjang
     yang mengikat; institusi yang tidak menginginkan aturan keragaman menurunkannya lewat parameter,
     bukan lewat perubahan kode.
  3. Riwayat disimpan di tabel baru `platform.user_password_history` (`0010`), berisi hash kata sandi
     yang **sudah digantikan** saja. Hash yang sedang berlaku tetap tunggal di
     `app_user.password_hash` — satu kata sandi tidak pernah punya dua tempat, dan tabel riwayat tidak
     bisa dipakai memverifikasi kredensial aktif.
  4. Pemangkasan ke N terakhir terjadi di jalur tulis (`recordSupersededPassword`), bukan tugas
     terjadwal: jumlah baris per pengguna selalu = nilai parameter saat perubahan terakhir, dan tidak
     ada tabel yang tumbuh tanpa batas tanpa pembersih yang harus diingat.
  5. Arti "N" adalah **jendela**, bukan larangan selamanya: kata sandi yang sudah keluar dari N
     terakhir boleh dipakai lagi. Diuji langsung (`itauth`), supaya tidak diam-diam jadi "semua kata
     sandi lama terlarang".
  6. Pemeriksaan riwayat dijalankan **setelah** bentuk kata sandi lolos (PBKDF2 mahal dan tidak
     berguna untuk kata sandi yang toh ditolak), dan **selalu** menyertakan hash yang sedang berlaku:
     akun yang lahir sebelum tabel riwayat ada (termasuk hasil `bootstrap-admin`) tidak punya satu pun
     baris riwayat, jadi tanpa itu "ganti" ke kata sandi yang sama akan lolos.
  7. **Kedaluwarsa tidak dibangun**: tidak ada kolom umur, tidak ada penolakan karena umur, tidak ada
     tugas rotasi. D-046 butir 8 memutuskan rotasi berkala tidak diwajibkan; yang diuji adalah
     ketiadaannya (`itauth`: kata sandi berumur lima tahun tetap bisa dipakai).
  8. Kata sandi acak yang dibuat `ctl bootstrap-admin` kini harus lolos kebijakan yang sama, dan
     generatornya **menjamin** kelas karakter yang dituntut (bukan mengandalkan kebetulan) — kalau
     tidak, perintah penyelamat itu gagal persis saat tidak ada jalan masuk lain.
  9. **Prasyarat operasional**: parameter baru harus sudah ada di DB sebelum kode yang membacanya
     berjalan (resolusi parameter tanpa fallback, D-046 butir 5). Seed pack produksi dijalankan
     pemilik lewat `dbtools seed` — bukan bagian dari `ops/scripts/deploy-vps.sh`; celah itu dicatat
     sebagai **O-066**.
- **Alternatif yang ditolak**: (a) aturan keragaman di kode — melanggar §10 (tidak ada nilai bisnis di
  kode) dan tidak bisa dilonggarkan institusi tanpa rilis ulang; (b) larangan memakai ulang seluruh
  kata sandi lama (tanpa jendela) — bukan yang diminta, dan tidak bisa dijamin tanpa menyimpan hash
  selamanya; (c) memangkas riwayat lewat tugas terjadwal — menambah pekerjaan operasional untuk
  tabel yang bisa dijaga ukurannya di jalur tulis; (d) memangkas berdasarkan `recorded_at` — dua
  perubahan pada detik yang sama bisa membuat urutan tidak pasti; `seq` (identity) tidak.
- **Bukti**: `tauthz` (hitung kelas + pelanggaran dikumpulkan, bukan berhenti di yang pertama),
  `itauth` (jendela riwayat + kematian kedaluwarsa, 25 test), `itapi_auth` (38 test, termasuk tiga
  penolakan/keberhasilan lewat HTTP: kata sandi yang berlaku, yang di riwayat, dan kontrol yang
  belum pernah dipakai), `itparam` + `itplatform` hijau, `./task fmt` + `./task check` hijau.
- **HUMAN-REVIEW-REQUIRED**: menyentuh penyimpanan hash kata sandi (AGENTS.md §8).

## D-059 — Scoping cabang diaktifkan di jalur HTTP (temuan D-055 ditindaklanjuti)

- **Konteks**: D-055 mencatat dua temuan yang membuat aturan visibilitas per scope belum berefek di
  produksi: (a) `authorized` memeriksa dengan `targetBranch = ""` (`apps/api/src/access.nim:82-90`),
  sehingga grant yang **hanya** ber-cabang tidak pernah cocok dengan endpoint HTTP mana pun; (b)
  `auditContextFor` (`apps/api/src/access.nim:92`) tidak mengisi `branchIds`, jadi setiap baris audit
  yang ditulis dari jalur HTTP punya `branch_id` NULL dan terbaca sebagai tingkat institusi.
- **Keputusan pemilik (17 Okt 2026)**: **kerjakan sekarang**, bukan dicatat sebagai batas diterima.
  Alasan: pilot memang 1 koperasi/1 cabang sehingga efeknya belum terasa, tetapi menyalakannya nanti
  berarti mengubah perilaku authz setelah ada data dan kebiasaan pemakaian; sekarang permukaan HTTP
  masih kecil dan teruji.
- **Konsekuensi**:
  1. Menjadi task tersendiri **T-058**, bukan diselipkan ke task lain (rencana T-051 sudah menandai
     opsi ini sebagai di luar lingkupnya).
  2. Perubahan perilaku yang harus dinyatakan terang: grant yang **hanya** ber-cabang mulai berlaku
     (sebelumnya selalu ditolak karena tidak pernah cocok), dan baris audit dari jalur HTTP mulai
     ber-`branch_id` sehingga pembacaan daftar audit mulai tersaring per cabang.
  3. Dua hal **belum** diputuskan di sini dan wajib ditulis di rencana T-058 sebelum kode: cabang mana
     yang menjadi "cabang target" untuk tiap endpoint, dan dari mana atribusi cabang baris audit
     diambil (cabang tugas pemanggil vs cabang yang disentuh permintaan).
- **HUMAN-REVIEW-REQUIRED (authz)** — AGENTS.md §8.

## D-060 — O-009 ditunda; T-052 dipersempit ke O-038

- **Konteks**: O-009 meminta anchor hash audit harian disimpan di tempat terpisah **dan diverifikasi di
  day-close** (spec §18.2). Kriteria itu tidak bisa dipenuhi di Fase 0: framework `daycloser` belum ada
  (`apps/api/src/main.nim:349` → `ctl daycloser-status` sengaja mengembalikan 3; AGENTS.md §1.7
  melarang batch/cron di luar framework itu). Anchor tanpa jalur verifikasi day-close hanya memindahkan
  masalah, dan membangun `daycloser` sekarang berarti melompat ke pekerjaan Fase 3.
- **Keputusan pemilik (17 Okt 2026)**: **kerjakan O-038 saja**; O-009 tetap terbuka menunggu
  `daycloser`. T-052 dipersempit: kriteria "anchor tersimpan dan diverifikasi di day-close" dihapus.
- **Konsekuensi**: rantai audit masih bisa ditulis ulang oleh penyerang ber-hak-tulis-penuh — batas yang
  sudah dinyatakan jujur di kepala migrasi `0002_platform_audit_log.sql` dan di O-009, jadi tidak ada
  klaim keamanan yang berubah. Alternatif yang ditolak: anchor lewat `ctl` tanpa hook day-close —
  menambah jalur tulis kedua untuk audit dan hanya menutup separuh O-009 (verifikasi otomatis tetap
  tidak ada).
- **Rujukan**: T-052 (dipersempit), O-009, O-038, spec §18.2.

## D-061 — Verifikasi rantai audit mengikuti `prev_hash`, bukan urutan `seq` (O-038/T-052)

- **Konteks**: `seq` audit dialokasikan identity **sebelum** BEFORE-trigger rantai mengambil advisory
  lock (`modules/platform/migrations/0002_platform_audit_log.sql:74-76`), jadi baris ber-`seq` lebih
  besar bisa commit lebih dulu dan baris berikutnya merantai ke hash baris itu. Rantainya tetap
  **linear**; yang salah adalah anggapan lama bahwa urutan `seq` = urutan rantai. `audit_verify()`
  lama memverifikasi tautan dengan `lag(hash) OVER (ORDER BY seq)`, sehingga keadaan yang sah itu
  dilaporkan `link_ok=false`. Direproduksi deterministik di DB dev 17 Okt 2026 (jendela diperlebar
  dengan trigger uji 2,5 s): `seq` 84 menunjuk hash `seq` 85, 85/85 baris tercapai dengan mengikuti
  `prev_hash` dari genesis, dan pola lama menandai kedua baris itu.
- **Keputusan**: `link_ok` = `prev_hash` adalah sentinel genesis (`repeat('0',64)`) **atau** ada baris
  lain ber-`hash` sama — migrasi `0011_platform_audit_verify_prev_hash.sql`, plus indeks
  `audit_log_hash_idx (hash)` supaya pemeriksaan tidak O(n²). Tanda tangan fungsi dan kolom hasil
  **tidak berubah**, jadi `verifyChain` (`audit_repo.nim:56`) dan `ctl verify-audit` tidak disentuh.
  Alternatif yang ditolak: (a) menetapkan `seq` di dalam trigger setelah lock — butuh mengubah kolom
  identity, bukan expand-only, dan urutan commit tetap tidak bisa dipaksakan; (b) verifikasi rekursif
  dari genesis dengan menandai baris di luar rantai — mengubah arti hasil (baris hilir ikut dinyatakan
  rusak saat satu baris hulu dirusak) dan memaksa test lama diubah tanpa kebutuhan.
- **Deteksi tidak melemah**: test perusakan lama lulus **tanpa diubah** — payload diubah →
  `row_hash_ok=false`; hash dihitung ulang → baris berikutnya kehilangan pendahulunya (`EXISTS` gagal);
  `TRUNCATE`/`UPDATE`/`DELETE` tetap ditolak trigger.
- **Yang tetap tidak terdeteksi**: rantai bercabang (dua baris menunjuk pendahulu yang sama — hanya
  bisa dibuat dengan menulis langsung tanpa trigger) dan penulisan ulang seluruh ekor rantai
  (O-009, ditunda oleh D-060). Keduanya dicatat di `modules/platform/MODULE.md`.
- **Bukti**: suite baru di `modules/platform/tests/itplatform.nim` (prasyarat mekanisme `seq` terbalik
  + aturan baru menyatakan rantai utuh + **kontrol** pola lama menandai dua baris); `./task test
  itplatform` hijau; `./task check` hijau.
- **Temuan review independen (17 Okt 2026)**: versi pertama aturan baru **melemahkan** deteksi —
  pola lama (lewat `lag(seq)`) menolak rantai **bercabang** (dua baris menunjuk pendahulu yang sama),
  aturan berbasis keanggotaan `hash` saja menerimanya. Diperbaiki di migrasi `0011` yang sama:
  `link_ok` juga mensyaratkan **tidak ada baris lain ber-`prev_hash` sama** (indeks
  `audit_log_prev_hash_idx`), jadi deteksi cabang kembali ada dan tetap tidak bergantung urutan `seq`.
  Perbaikan ini menandai **kedua** sisi cabang (baris sah yang pendahulunya kini dirampas ikut
  ditandai — itu memang konsekuensinya), sedangkan kasus urutan-terbalik yang sah tetap utuh karena
  `prev_hash` baris-barisnya berbeda. Diuji eksplisit di suite yang sama (baris cabang ditulis dengan
  hash yang benar agar yang dinilai murni `link_ok`). Siklus tanpa genesis tetap tidak terdeteksi:
  membuatnya butuh titik tetap fungsi hash, dan hash yang ditulis tangan sudah ketahuan lewat
  `row_hash_ok`.
- **HUMAN-REVIEW-REQUIRED (integritas audit)** — AGENTS.md §8.

## D-062 — Dua tingkat gerbang izin HTTP + atribusi cabang pada audit (T-058, O-032 ditutup)

**Konteks.** D-055 menyisakan dua temuan: (1) setiap baris audit dari jalur HTTP punya `branch_id`
NULL — `auditContextFor` tidak mengisi `branchIds`, jadi penyaringan audit per cabang tak berefek;
(2) `authorized` memakai `targetBranch = ""` sehingga grant khusus cabang tidak pernah cocok di
endpoint mana pun. D-059 memutuskan keduanya dibereskan sebagai task sendiri (T-058), dengan syarat
**rencananya menyebut lebih dulu** dari mana cabang target dan atribusi audit per endpoint diambil.
Rencana itu ada di `docs/tasks/T-058.md` (endpoint × cabang target, sumber atribusi, pilihan yang
ditolak). Keputusan di bawah adalah isi rencana tersebut; pemilik menjawab "lanjut" tanpa menjawab
tiga pertanyaan detailnya, jadi keputusan ini berlaku sebagai **keputusan implementasi** dan T-058
tetap ditandai `HUMAN-REVIEW-REQUIRED` (authz, AGENTS.md §8) sampai ditinjau manusia.

**Keputusan.**

1. **Gerbang izin punya dua tingkat; yang berbeda hanya dimensi cabangnya.**
   - Rute ber-izin memakai gerbang **tanpa dimensi cabang** (`authorizeAnyBranch` di
     `modules/platform/domain/authz.nim`, dipakai `requirePermission` D-055). 403 di situ berarti
     "izin tidak dipegang di cabang mana pun". Untuk permintaan **daftar**
     (`GET /api/v1/params`, `GET /api/v1/audit`) inilah gerbang yang benar: hasilnya disaring
     **per baris** (`readableScopeFilter`/`auditScopeFilter`), tidak ada satu cabang target, dan
     menuntutnya akan menolak pembacaan sah yang seharusnya cuma tersaring.
   - Rute yang menyentuh **satu** objek ber-cabang menambah gerbang **per cabang**
     (`authorizedAtBranch`) begitu cabang objeknya diketahui:
     `POST /api/v1/params/{key}/changes` (cabang = `scopeId` bila `scopeType = BRANCH`, selain itu
     `""`) dan `POST /api/v1/params/changes/{paramValueId}/approve` (cabang = cabang baris PENDING
     yang diaktifkan). `targetBranch = ""` = aksi **tingkat institusi**: hanya grant tanpa batas
     cabang yang berlaku, jadi grant khusus cabang tidak diam-diam menjadi izin institusi.
   - Perubahan perilaku yang disengaja (dinyatakan D-059): grant khusus cabang kini **bekerja** di
     HTTP, dan pengajuan/persetujuan atas nilai cabang di luar wewenang kini dibalas 403
     `branch_not_allowed` (kode stabil baru, masuk daftar `params.reason` kontrak).
2. **Di persetujuan, wewenang cabang diperiksa lebih dulu daripada alasan 409.** Penolakan wewenang
   tidak boleh bergantung pada keadaan barisnya (dan tidak membocorkan masalah kombinasi/periode
   kepada yang memang tidak berwenang).
3. **Atribusi cabang audit berasal dari objek yang disentuh, bukan cabang tugas pelaku.** Sumbernya:
   nilai parameter yang diajukan/disetujui, dan **cabang yang dibaca** untuk
   `param.read_cross_branch` (satu entri per cabang, tetap digagalkan bila pencatatannya gagal).
   Alasannya semantik: yang berkepentingan atas baris itu adalah auditor cabang tersebut — termasuk
   ketika pusat yang membacanya.
4. **Pengenal non-uuid tidak dipaksa masuk kolom uuid.** `platform.audit_log.branch_id` bertipe uuid
   dan ditulis lewat `NULLIF(?, '')::uuid`; pengenal cabang di tempat lain bertipe teks
   (`param_value.scope_id`, `user_role.branch_id`). Pengenal non-uuid membuat `parseId` gagal →
   baris auditnya tetap tanpa cabang, dan pengenalnya tetap utuh di `resource_id`/payload. Tidak ada
   cast paksa: itu akan melempar `DbError` → 500 untuk permintaan yang sebenarnya sah. Kesenjangan
   tipe ini sudah tercatat **O-017** dan **tidak** ditutup di sini.
5. **Langganan realtime tetap tingkat institusi (fail-closed).** `topicsAllowedFor` masih memakai
   `authorized` (`targetBranch = ""`): topik `param.changed` tidak disaring per baris, jadi
   membukanya bagi grant khusus cabang berarti mengirim **seluruh** peristiwa parameter lintas cabang.
   Sisa pekerjaan dicatat **O-070**.

**Pilihan yang ditolak.** (a) `targetBranch`/`branchIds` dari **cabang tugas pelaku** — salah secara
semantik (pusat yang sah membaca cabang lain akan tercatat tanpa cabang, dan auditor cabang tidak
melihatnya); (b) gerbang per-baris di `requirePermission` — tidak mungkin, satu permintaan daftar
tidak punya satu cabang; (c) **tanpa** gerbang cabang di pengajuan/persetujuan (hanya mengandalkan
`mayReadScope` D-047) — izin baca bukan izin tulis, dan satu grant memuat keduanya untuk cabang yang
sama, jadi menolak di gerbang tulis adalah satu-satunya tempat yang membedakannya.

**Konsekuensi.** Kontrak `packages/contracts/openapi/kran-api.yaml` menyebut `branch_not_allowed`
pada 403 pengajuan + persetujuan, dan prosa `GET /api/v1/params` yang masih berbunyi "belum disaring
per scope/cabang" diperbarui (sudah tidak benar sejak D-047/T-052). Dua baris
`docs/ACCEPTED-LIMITS.md` §2 yang menyatakan scoping cabang dorman dan atribusi audit selalu NULL
diganti dengan batas yang sebenarnya tersisa (O-017, O-070). Tanpa migrasi: tidak ada kolom/tabel
baru.

**HUMAN-REVIEW-REQUIRED (authz)** — AGENTS.md §8.

## D-063 — MFA TOTP: kerangka tanpa pengaktifan (T-046, O-015 dikerjakan)

**Konteks.** Spec §13/§18.2 menyebut MFA TOTP, tetapi repo tidak punya satu baris pun kode MFA.
D-046 butir 9 (pemilik): MFA **belum perlu diaktifkan** sekarang. T-046 karena itu dikerjakan
sebagai **kerangka**: skema, parameter, dan jalur enrolment/verifikasi yang nyata diuji — dengan
**alur login tidak berubah**. Mengaktifkan (meminta kode saat masuk) adalah keputusan terpisah.

**Keputusan.**

1. **TOTP RFC 6238** (HMAC-SHA-1, 6 digit, 30 detik) di atas HOTP RFC 4226 + base32 RFC 4648,
   memakai `nimcrypto` yang **sudah** jadi dependensi lewat field crypto (T-054) → tanpa dependensi
   baru, tidak butuh ADR. Vektor ujinya diambil dari **teks RFC** (4226 App D, 6238 App B, 4648 §10),
   bukan angka karangan; primitifnya punya test unit sendiri (`shared/platform-lib/tests/ttotp.nim`).
2. **Rahasia 160-bit dari CSPRNG OS, disimpan terenkripsi** lewat `encryptField`/`decryptField`
   (AAD = nama tabel `user_mfa`). Bentuk teksnya base32 tanpa padding supaya sama dengan yang
   diminta `otpauth://`. Rahasia TOTP setara kata sandi: menyimpannya plaintext akan membuat
   bocoran DB langsung berarti bocornya faktor kedua.
3. **Satu baris per akun** (`platform.user_mfa`, PK `user_id`) dengan status `PENDING`/`ACTIVE`.
   `digits`/`period_seconds` disimpan **per baris** dan dipakai saat verifikasi — pola yang sama
   dengan `password_algo`/`password_hash`: nilai parameter yang berubah tidak boleh diam-diam
   membatalkan rahasia yang sudah terdaftar. `last_used_step` (anti-replay) ikut disiapkan.
4. **Parameter baru** `platform.security.mfa.{enabled,issuer,digits,period_seconds,drift_steps}`,
   scope GLOBAL, `enabled` **default `false`**. Dibaca lewat `mfaSettingsOf` **hanya di jalur MFA**;
   `settingsOf` (login) tidak disentuh, sehingga parameter MFA yang belum tersemai hanya mematikan
   rute MFA (fail-closed), bukan login.
5. **Tiga rute self-service** tanpa izin baru (pola `/api/v1/auth/password`, D-057):
   `GET /api/v1/auth/mfa` → `{featureEnabled, status}`; `POST …/mfa/enrolment` → 201 dengan rahasia
   **sekali saja** (409 `mfa_already_active` bila sudah `ACTIVE`); `POST …/mfa/verify {code}` → 204
   saat kode cocok (status → `ACTIVE`), 403 `mfa_code_invalid`, 409 `mfa_no_pending_enrolment`.
   Fitur mati → 403 `mfa_disabled` untuk ketiganya, diputuskan **sebelum** apa pun menyentuh kripto.
6. **Kode salah dibalas 403, bukan 401.** Sesi pemanggil sah; yang salah hanya kodenya. 401 akan
   membuat klien memperlakukan pengguna sebagai "sesi berakhir" di tengah pendaftaran — preseden yang
   sama dengan `old_password_mismatch` (D-057).
7. **Audit** `auth.mfa.enrol`, `auth.mfa.verify`, `auth.mfa.verify_failure` — tanpa kode, rahasia,
   atau URI (spec §18.2). Test memeriksa isi audit, bukan hanya jumlahnya.
8. **Mengganti faktor `ACTIVE` tidak lewat jalur enrolment** (409): penghapusan/penonaktifan faktor
   adalah operasi pemulihan yang butuh alur sendiri (keputusan pemilik, izin, audit) → **O-071**.

**Pilihan yang ditolak.** (a) menyimpan rahasia plaintext atau menurunkannya dari kata sandi —
bocoran DB lalu sama dengan bocornya faktor kedua; (b) membaca `digits`/periode dari parameter saat
verifikasi — mengubah parameter akan membatalkan rahasia terdaftar tanpa sebab yang terlihat;
(c) mengaktifkan tantangan MFA di login sekarang — keputusan pemilik terpisah (D-046 butir 9) dan
akan mengunci pengguna yang belum mendaftar; (d) WebAuthn — butuh dependensi dan kebijakan perangkat
yang belum diminta; (e) rute dengan izin baru — faktor itu milik pemilik sesi, bukan wewenang role.

**Konsekuensi.** Migrasi `0012` (expand-only; tidak menyentuh tabel lain). Parameter baru tetap butuh
seed di produksi (O-066), tetapi ketiga rute menjawab 403 selama `mfa.enabled` default mati — deploy
tanpa seed pun inert dan tidak merusak apa pun. Login, sesi, izin, kontrak lama, dan UI **tidak
berubah**. Sisa pekerjaan MFA dipisahkan ke **O-071** (aktivasi login, kode pemulihan, pembatasan
percobaan verifikasi, UI, penghapusan faktor) dan **O-015 ditutup** sebagai kerangka.

**HUMAN-REVIEW-REQUIRED (autentikasi/kripto)** — AGENTS.md §8: ini faktor kedua, dan test hijau
tidak membuktikan implementasi TOTP benar dengan sendirinya (yang membuktikannya adalah vektor RFC
yang diambil dari teksnya, bukan dari kode sendiri).

**Tambahan putaran review (19 Okt 2026).** Reviewer independen (konteks bersih) menyatakan APPROVE
dengan 4 temuan MINOR; semuanya ditindaklanjuti dan dua di antaranya menyentuh perilaku:

1. **Urutan gerbang fitur vs keyring.** `KRAN_KEK_FILE` diperiksa **setelah** `mfa.enabled`. Kalau
   dibalik, instalasi tanpa KEK menjawab 501 saat fiturnya mati — kontradiksi dengan janji dokumen
   ("403 `mfa_disabled`") sekaligus membocorkan status konfigurasi enkripsi server ke pemanggil tak
   terautentikasi-status. Dikunci dua test (403 saat fitur mati tanpa keyring; 501 fail-closed saat
   fitur hidup tanpa keyring).
2. **Respons hanya ditulis setelah transaksi selesai.** Respons di dalam closure `withDbTx` bisa
   terkirim dua kali di koneksi yang sama bila COMMIT gagal (klien menerima 403/201 palsu padahal
   tulisannya batal). Semua cabang sekarang mengumpulkan hasil dulu, menjawab kemudian.
3. **Respons berisi rahasia memakai `Cache-Control: no-store`.** Rahasia TOTP adalah kredensial
   berumur panjang; cache perantara/peramban tidak boleh menyimpannya.
4. **`platform.security.mfa.digits` dibatasi 6–8**, bukan 6–10: RFC 4226 §5.3 hanya menyebut
   "MUST extract a 6-digit code at a minimum and possibly 7 and 8-digit code", dan tidak ada aplikasi
   authenticator yang menampilkan kode di atas 8 digit. Parameter yang bisa diisi nilai tak terpakai
   adalah jebakan konfigurasi, bukan keluwesan.

**Fail-closed saat kebijakan belum tersemai (ditemukan sebelum deploy, 19 Okt 2026).** `mfaSettingsOf`
semula membaca saklar dengan `activeValueJson`, yang **melempar** bila belum ada nilai aktif. Karena
`dbtools seed` bukan bagian dari deploy (O-066), produksi tepat setelah deploy ini tidak punya lima
nilai `platform.security.mfa.*` — akibatnya ketiga rute akan menjawab **500**, bukan 403, bertentangan
dengan dokumen ini dan dengan dugaan "inline inert". Perbaikannya: saklar dibaca lewat `activeValueOpt`
(`param_repo`, ditambahkan untuk kasus ini) — nilai tidak ada → fitur **mati** (403 `mfa_disabled`);
nilai ada tetapi bukan boolean → tetap galat (konfigurasi rusak tidak disembunyikan); nilai lain
(issuer/digits/periode/drift) hanya dibaca **setelah** saklarnya hidup, jadi kebijakan setengah
tersemai tetap gagal keras alih-alih memakai bentuk kode yang tak diputuskan siapa pun. Aturan "tanpa
fallback diam-diam" (spec §10.6) tidak dilanggar: level scope tetap disebut pemanggil; yang berubah
hanya pengartian "tidak ada nilai" untuk saklar keamanan. Dikunci test `itapi_mfa` "kebijakan MFA
belum tersemai sama sekali → 403 mfa_disabled, bukan 500".

## D-064 — Koneksi DB dibuka lewat conninfo: `connect_timeout` + keepalive (T-061, T-044 H1)

**Konteks.** T-044 membuktikan `pqsetdbLogin` tidak punya batas waktu klien: peer yang menerima TCP
lalu diam membuat `acquire`/`/readyz`/`ctl` menunggu **tanpa batas**. `statement_timeout` tidak
menolong karena berlaku server-side, setelah koneksi hidup.

**Keputusan.**

1. **`pqconnectdb(conninfo)`** menggantikan `pqsetdbLogin`; `connect_timeout` diambil dari
   `KRAN_DB_CONNECT_TIMEOUT_MS` (default 5000; libpq menafsirkan < 2 detik sebagai 2 detik, dan 0
   berarti tanpa batas — jadi nilai minimum dipaksa 2). Nilai conninfo di-*quote* (escape `\` dan `'`),
   sehingga password berkutip/backslash tetap valid — diuji unit, bukan diasumsikan.
2. **TCP keepalive eksplisit** (`keepalives=1 keepalives_idle=5 keepalives_interval=5
   keepalives_count=2`). Koneksi yang **sudah** hidup lalu membeku (tunnel mati tanpa RST) terdeteksi
   kernel dalam ±15–20 detik alih-alih menunggu berjam-jam.
3. **Bentuk galat dipertahankan** (`PoolError` "gagal menyambung ke host:port/db: …") supaya
   pemanggil dan test yang ada tidak berubah.

**Sisa yang diterima saat itu.** Deadline **per-query** belum ada: kueri yang sedang berjalan pada
koneksi yang membeku masih bergantung pada keepalive (±15 s), bukan batas milidetik. Dicatat di
register `docs/ACCEPTED-LIMITS.md` dan dijadwalkan sebagai **T-065** — lihat koreksi di bawah.

**Bukti.** `shared/platform-lib/tests/tdbconnect.nim`: listener black-hole (listen tanpa `accept`)
→ `PoolError` jauh di bawah 10 detik; kontrol port tertutup tetap gagal cepat; regresi tanpa fix
adalah menggantung, bukan gagal. `./task test itpool` 10 `[OK]`, `./task check` exit 0.
**HUMAN-REVIEW-REQUIRED** (jalur koneksi produksi, AGENTS.md §8).

**Koreksi (19 Okt 2026, T-065 → D-065).** Klaim "keepalive ±15 s" di atas hanya berlaku bila **peer
TCP** berhenti menjawab probe. Bila ada perantara yang tetap meng-ACK (tunnel SSH hidup tetapi jalur
remote mati), kueri pada koneksi hidup menggantung **tanpa batas** — terbukti > 30 s dengan
perantara TCP yang membeku (`psql` lewat proxy yang berhenti meneruskan). `statement_timeout` tidak
menolong karena kueri tidak pernah sampai server. Perbaikannya di D-065.

## D-065 — Batas waktu blok kerja DB lewat pemantau socket (T-065, sisa D-064)

**Konteks.** Batas waktu klien yang ada hanya mencakup pembukaan koneksi (`connect_timeout`) dan
keepalive TCP. Kueri pada koneksi hidup bisa menggantung tanpa batas bila ada perantara yang tetap
meng-ACK (tunnel hidup, jalur remote mati) — dibuktikan > 30 s, lihat koreksi D-064. Target
"≤ 5 detik" tidak bisa dipakai apa adanya: `statement_timeout` default 15 s, jadi kueri sah boleh
berjalan sampai 15 s; deadline klien 5 s akan membunuhnya.

**Keputusan (opsi A dari `docs/tasks/T-065.md`, dipilih pemilik).**

1. **Pemantau socket, bukan libpq nonblocking.** Modul baru `db/deadline.nim`: satu thread pemantau
   per proses, tabel slot `(fd, batas)`, tick 50 ms. Saat batas lewat → `shutdown(fd, SHUT_RDWR)`;
   I/O libpq yang sedang menunggu gagal seketika. Tidak ada perubahan pada jalur kueri/konversi baris.
2. **Cakupan = satu blok kerja**, bukan per kueri: `withConn`/`withTx` mendaftar sekali; semua kueri
   dalam blok berbagi anggaran. `acquire` juga membungkus `pingConn` dengan batas yang sama.
3. **Koneksi yang kena batas dibuang**, tidak dikembalikan ke idle (status protokolnya tidak bisa
   dipercaya). Blok gagal dengan `PoolError` yang menyebut batas + galat asli.
4. **`KRAN_DB_QUERY_DEADLINE_MS`**: default `statement_timeout + 5000` (= 20000), dan nilai eksplisit
   **harus** > `statement_timeout` (ditolak saat config dibangun, bukan dibetulkan diam-diam).
5. **Batas memakai jam monotonik** (`getMonoTime`), bukan jam dinding.
6. **Blok yang panggilan terakhirnya sudah kembali tetap dianggap sukses** walau batas terlanjur
   lewat tepat setelah kueri terakhir/`COMMIT` mengembalikan jawaban: hasilnya dikembalikan, hanya
   koneksinya yang dibuang. Menggagalkan pekerjaan yang sudah commit akan mendorong pemanggil
   mengulang dan menggandakan efek. Batas ini **tidak** menyelamatkan jawaban `COMMIT` yang hilang:
   bila `exec(COMMIT)` melempar, hasilnya tetap tidak pasti dan dilaporkan gagal — pemanggil wajib
   memperlakukan galat itu sebagai "status tidak diketahui", bukan "pasti rollback".

**Konsekuensi jujur.** Batas efektif ±20 s, bukan ≤5 s — konsekuensi langsung dari `statement_timeout`
15 s. Anggarannya **per blok**, sedangkan `statement_timeout` per statement: `withTx` dengan banyak
statement yang totalnya >20 s akan gagal (server rollback), jadi use case panjang harus muat dalam
anggaran atau menaikkan nilainya. Koneksi yang kena batas hilang dari pool (satu koneksi per
kejadian). Jalur `pool.acquire()` langsung — pump `LISTEN` yang hidup selama proses — **tidak**
memakai anggaran ini (desain koneksi panjang, dicatat di `docs/ACCEPTED-LIMITS.md`). Bila kelak
butuh batas per kueri presisi ≤5 s, itu tetap pekerjaan nonblocking (opsi B), bukan tambalan di sini.

**Bukti.** Uji unit `tdeadline` (socket diputus, `disarm` melaporkan fired, tanpa batas = guard kosong);
uji integrasi `itpool` "kueri pada koneksi beku gagal <= batas" memakai perantara TCP yang berhenti
meneruskan → `PoolError` dalam < 2 s dengan deadline 700 ms, `created == 0` (koneksi dibuang).
**Mutasi**: deadline dinaikkan ke 3 s → uji gagal (`elapsed 3,03 s`), jadi uji benar-benar menjaga
batas. **HUMAN-REVIEW-REQUIRED** (jalur koneksi produksi, AGENTS.md §8).

## D-066 — Layanan API/worker KRAN berjalan sebagai container quadlet (T-067, permintaan pemilik)

**Konteks.** Sampai 19 Okt 2026 layanan berjalan sebagai **biner native**: dua systemd user unit
(`kran-api.service`, `kran-worker.service`) menjalankan `$APP_DIR/bin/kran-api`, dan deploy hanya
mengekstrak biner itu dari image untuk dipakai unit. Aplikasi lain di VPS yang sama sudah berjalan
sebagai container quadlet; pemilik meminta KRAN mengikuti pola yang sama supaya operasinya seragam
(permintaan pemilik, 19 Okt 2026 — dikerjakan di sesi terpisah, dicatat di sini karena mengubah
§21.5 spec).

**Keputusan.**

1. **Satu image, dua peran.** `apps/api/Dockerfile` (multi-stage, Debian bookworm, user `kran`
   uid 10001) menghasilkan `localhost/kran-api`; peran ditentukan argumen (`Exec=--role=api|worker`)
   persis seperti unit native sebelumnya. Tag: `:local` (dipakai quadlet), `:<12-hex sha>` (jejak
   deploy), `:prev` (cadangan sebelum build berikutnya).
2. **Unit ada di repo, dipasang deploy.** `ops/systemd/kran-api.container` dan
   `kran-worker.container`; `sync_units` menyalin ke `~/.config/containers/systemd` dengan `cmp`
   (identik = no-op), penjaga seksi `[Container]`, cadangan `.prev`, dan `restore_units` saat
   auto-rollback. `systemd-analyze verify` tidak berlaku untuk berkas quadlet; validasi sebenarnya
   adalah `daemon-reload` + HEALTH GATE.
3. **Fail-closed terhadap unit native bernama sama.** `~/.config/systemd/user/kran-api.service`
   **menang** atas unit hasil generator quadlet. Deploy menolak jalan bila berkas itu ada. Kejadian
   nyata 19 Okt 2026: deploy pertama setelah cutover me-restart biner lama sementara health gate
   membaca biner lama itu juga — deploy "sukses" tanpa ada yang berubah. Karena itu berkas lama
   dipindah ke `ops/systemd/superseded/` (tidak ada glob `*.service` yang bisa memasangnya kembali).
4. **Biner host tinggal untuk gate.** FREEZE GATE dan MIGRATION GATE berjalan di host sebelum
   layanan di-restart, jadi `bin/kran-api` (+ `bin/kran-api.prev`, lib runtime vendored) tetap
   diekstrak dari image. Layanan sendiri tidak lagi memakai jalur itu.
5. **Mount minimal, bukan seluruh monorepo.** `--root=/monorepo` hanya butuh
   `modules/<mod>/migrations` untuk probe `/readyz`; yang di-mount hanya `modules/` (`:z,ro`).
   `:z` wajib (label `var_t` ditolak untuk `container_t`), dan me-relabel 399 MB setiap restart
   bukan ongkos yang perlu dibayar.
6. **Bind `0.0.0.0`.** Port rootless di-forward ke IP bridge `qouver` (10.89.0.0/24); bind loopback
   membuat container hidup tapi tidak terjangkau dari host. Publikasi tetap
   `127.0.0.1:8095:8095`.
7. **Worker tidak ikut boot.** `kran-worker.container` sengaja tanpa `[Install]` (paritas unit
   native yang `disabled`): perannya belum ada sampai `daycloser` (O-013/O-060). Ia keluar status 3
   "belum dikonfigurasi" dan `RestartPreventExitStatus=3` menahan restart-loop. Deploy tetap
   me-restart-nya secara eksplisit.
8. **KEK belum di-mount.** `KRAN_KEK_FILE` kosong di produksi, jadi fitur yang membutuhkannya
   (field crypto/MFA) inert. Saat diaktifkan: mount berkas (600, milik sachiel) **dan**
   `UserNS=keep-id:uid=10001,gid=10001` — dicatat di komentar unit + `ACCEPTED-LIMITS`.
9. **Rollback mengikuti model yang sama.** `ops/scripts/rollback.sh` mengembalikan
   `:prev` → `:local`, memulihkan `web.prev`, unit `.prev`, dan biner gate; lalu memeriksa
   `/readyz` dan **gagal** bila tidak sehat. Versi lama menyalin biner dan mencetak "selesai" tanpa
   menyentuh image — pada layanan container itu sukses palsu (T-068).

**Konsekuensi.** Spec §21.5 (unit native + `bin/kran-api`) **digantikan** butir 1–9 ini; §21.6
(struktur `ops/`) diperbarui. Deploy menulis `~/.config/containers/systemd` (bukan
`~/.config/systemd/user`). Nama unit tetap sama, jadi `systemctl --user restart kran-api` masih
berlaku; `is-enabled` melaporkan `generated` — normal untuk quadlet, dan boot tetap jalan karena
generator membuat symlink `default.target.wants` sendiri. Tag image menumpuk per deploy (T-069).
Tidak ada perubahan pada DB, port, domain, maupun Caddy (D-043/D-045 tetap).

**Bukti.** Produksi 19 Okt 2026: `systemctl --user is-active kran-api` = `active`,
`kran-worker` = `failed` (exit 3, by design), `podman ps` → `127.0.0.1:8095->8095/tcp`, network
`qouver`, `/readyz` → `{"status":"ok"}` dengan `database`/`migrations`/`realtime` ok; deploy
`aafc715` berakhir `API sehat` + `Deployment completed successfully`; unit terpasang identik dengan
repo (`sync_units` no-op); berkas native hanya tersisa sebagai `*.disabled`/`*.reinstalled-*`.
Rollback: harness 4/4 (tag `:prev`→`:local`, unit `.prev` pulih, tolak `:prev` hilang, tolak unit
native, health gate gagal → exit 1); skrip lama pada keadaan `:prev` hilang **exit 0** tanpa
memanggil `podman tag` (bukti sukses palsu).

---

## D-067 — CIF `party`: pola = parameter, algoritme check digit = kode (T-070)

**Konteks.** Spec §10.5 menyebut "Format nomor (…), check digit" sebagai wajib database-driven,
sementara T-070 harus menghasilkan nomor CIF. Menaruh **algoritme** check digit di parameter berarti
menyimpan kode program di DB (tak bisa diuji tipe, rawan salah tulis, dan tidak ada jalur migrasi
untuk mengubahnya kelak).

**Keputusan.**
1. Yang **data** (parameter `party.cif.format`, GLOBAL/INSTITUTION, tipe string): pola lengkap —
   prefix/suffix literal, token `{seq:N}` (satu, wajib, lebar dari data), dan token `{check}` yang
   hanya boleh di akhir. Rentang panjang pola juga dibatasi schema parameter (`minLength`/
   `maxLength`), bukan kode.
2. Yang **kode** (invarian matematis, bukan nilai bisnis): algoritme check digit **Luhn mod 10**
   (`domain/cif.nim`), sama kelasnya dengan aritmetika `Money`/`Rate` di §1.3 — tidak punya
   "nilai bisnis" yang bisa disetel operator.
3. Batas 32 karakter hasil adalah **batas kolom** `party.party.cif`, dinyatakan sekali di kode
   sebagai konstanta teknis (`# nomagic:ok`) dan sekali di CHECK migrasi; bukan ambang bisnis.
4. Kegagalan konfigurasi (parameter hilang/salah, nomor urut melewati lebar `{seq:N}`) dijawab
   **500** dengan pesan non-internal, bukan 400 — permintaannya sah, server yang belum siap
   (spec §10.6, §13). Diimplementasi lewat tipe `CifConfigError`.

**Konsekuensi.** Kalau kelak perlu algoritme check digit lain (mis. modulus 11) atau Luhn dengan
varian, itu perubahan kode + ADR baru — **bukan** perubahan nilai parameter. Nomor CIF boleh
berlubang (sequence, bukan counter tabel) karena transaksi batal tidak boleh memakai ulang nomor.

**Bukti.** `tparty` (Luhn vektor klasik, format dari pola, token salah ditolak), `itparty`
(sequence naik, CIF unik, audit+outbox satu transaksi), `itapi_party` (jalur HTTP + kontrak; CIF
diverifikasi dengan fungsi produksi, bukan regex).

---

## D-069 — Dokumen identitas terenkripsi: ciphertext + blind index + bentuk tersamar (T-071)

**Konteks.** Spec §18.2 mewajibkan *field-level encryption* untuk NIK/NPWP/no. HP/alamat dengan
**blind index** untuk pencarian, dan *masking* sebagai tampilan default. T-071 adalah pemakaian
pertama kolom PII yang nyata; format penyimpanannya diputuskan di sini supaya tidak berubah lagi
setelah ada data.

**Keputusan.**
1. `party.identity_doc` menyimpan tiga turunan nomor, tidak pernah nomornya:
   - `number_enc` = ciphertext field crypto (`kran:enc:v1:…`, AAD = nama tabel `identity_doc`);
   - `number_bidx` = blind index HMAC-SHA256 ber-domain (hex 64) untuk pencarian & duplikat;
   - `number_last2` = dua karakter terakhir untuk tampilan tersamar tanpa dekripsi.
2. Nomor dinormalkan lebih dulu (huruf besar, hanya `A-Z 0-9`) sehingga blind index deterministik
   dan spasi/tanda hubung tidak memecah identitas yang sama.
3. Duplikat dicek antar party lewat `UNIQUE (doc_type, number_bidx)`: **satu nomor = satu baris per
   jenis dokumen**. Jenis dokumen berbeda punya ruang nomor sendiri (KTP 16 digit vs NPWP 15 vs
   paspor alfanumerik), jadi nomor yang sama di jenis berbeda **tidak** dianggap duplikat — batas
   yang disengaja, diuji di `itkyc` dan disebut di `MODULE.md`. API menjawab 409; pengecekan di
   handler hanya untuk pesan yang jelas, constraint DB tetap jaring terakhir terhadap balapan.
4. Membuka nomor = *unmask*: endpoint terpisah, izin `party.identity_doc.read` (bukan izin baca
   biasa), **alasan wajib**, dan audit `party.identity.unmask` tanpa nomor. Daftar dokumen/profil
   KYC tidak pernah memuat nomor.
5. Tanpa KEK (`KRAN_KEK_FILE` kosong) endpoint yang butuh enkripsi/dekripsi menjawab **501**
   (fail-closed, pola MFA T-046) — bukan menyimpan plaintext, bukan 500 yang menyesatkan.
6. CHECK `number_enc LIKE 'kran:enc:v1:%'` dan `number_bidx ~ '^[0-9a-f]{64}$'` membuat
   penyimpanan bentuk salah **gagal di DB**, bukan hanya di kode.

**Konsekuensi. Rotasi KEK wajib mendahului reindex blind index.** `number_bidx` diturunkan dari
kunci KEK **aktif**, jadi setelah rotasi baris lama tidak lagi cocok dengan indeks yang dihitung
kunci baru: deteksi duplikat gagal-terbuka (409 berhenti muncul, dan constraint unik pun tidak
menolong karena nilainya sudah berbeda). Sampai ada jalur reindex, langkah rotasi harus mencakup
"hitung ulang `number_bidx` dengan kunci baru" — dicatat sebagai **O-073**.

CHECK bentuk ciphertext mengikat versi format: kenaikan versi crypto (v2) butuh
migrasi expand baru yang memperbarui CHECK — disengaja, supaya perubahan format tidak lewat tanpa
keputusan. `number_last2` adalah bentuk tersamar, bukan rahasia: dua karakter terakhir bisa
memperkecil ruang tebak bila DB bocor, dan itu dinilai sebanding dengan manfaatnya (UI bisa
menampilkan petunjuk tanpa membuka nomor). Nama resmi/tanggal lahir/alamat **belum** ada di sini →
task turunan **T-078** (mereka butuh kolom terenkripsi sendiri).

**Bukti.** `tkyc` (normalisasi/validasi/aritmetika re-KYC), `itkyc` (ciphertext berawalan
`kran:enc:v1`, plaintext tidak ada di kolom, blind index deterministik, duplikat ditolak DB,
riwayat risiko append-only, rollback bersih), `itapi_kyc` (jalur HTTP penuh: 401/403/404/400/409,
audit tanpa nomor, event `party.risk_changed`, 501 tanpa KEK, nomor tidak muncul di badan respons).

**HUMAN-REVIEW-REQUIRED**: area kriptografi/PII (AGENTS.md §8) — perlu review manusia sebelum data
nyata masuk.

---

## D-070 — COA & periode T-072: kode = parameter, sisi normal = kode, seed COA lewat migrasi

**Konteks.** T-072 adalah fondasi jurnal double-entry. Tiga hal harus diputuskan sebelum ada data:
(1) mana yang parameter dan mana yang invarian, (2) bagaimana periode dicegah tumpang tindih,
(3) bagaimana COA awal sampai ke produksi tanpa langkah manual.

**Keputusan.**
1. **Format kode akun = parameter** `ledger.coa.code_pattern` (regex, GLOBAL/INSTITUTION), dicocokkan
   **seluruh string**. Spec §10.5 menyebut format kode sebagai database-driven; pola regex dipilih
   (bukan parser token sendiri) karena cukup satu nilai, bisa diuji, dan tidak menambah dependensi
   (`std/re`). Pola rusak = **500** (konfigurasi), kode tidak cocok = **400** (permintaan).
2. **Sisi normal = kode**, bukan parameter: ASSET/EXPENSE = DEBIT, LIABILITY/EQUITY/REVENUE =
   CREDIT. Ini invarian akuntansi (kelas yang sama dengan aritmetika `Money`), disimpan eksplisit
   agar laporan tidak menghitung ulang, dan dijaga CHECK DB supaya tidak bisa menyimpang.
3. **Periode = rentang inklusif** `[starts_on, ends_on]`, tumpang tindih ditolak
   `EXCLUDE USING gist (daterange(...,'[]') WITH &&)`. Constraint DB, bukan pemeriksaan aplikasi:
   dua permintaan bersamaan tidak bisa lolos. Urutan penutupan (periode lebih awal harus tutup
   dulu) **tidak** ditegakkan di T-072 — itu orkestrasi `daycloser` (Fase 5).
4. **COA awal lewat migrasi idempoten** (`0002_ledger_coa_base.sql`), bukan `packs/*/seed/`:
   direktori seed pack hanya diterapkan `dbtools seed --dev`, sehingga produksi tidak akan pernah
   mendapatkannya (O-066). Isinya **contoh struktur** bertanda `NEEDS-COMPLIANCE-REVIEW`
   (REG-011 `V!`) — bukan klaim patuh SAK/PSAK.
5. Semua endpoint COA/periode bersifat **institusi** (tanpa cabang), berbeda dari `party`. GL
   dimiliki institusi pada Fase 1 (spec §9).

**Konsekuensi.** Mengubah format kode COA hanya berlaku untuk akun **baru** (tidak ada endpoint
update; koreksi = akun baru + nonaktifkan yang lama). Mengubah huruf/ejaan tidak relevan (pola
regex), tetapi mengganti pola yang lebih ketat membuat kode lama “tidak sah” bila kelak divalidasi
ulang — karena itu kode lama tidak divalidasi ulang, hanya kode baru.

**Konsekuensi lanjutan (review putaran 1).**
- Aksi COA/periode adalah aksi **institusi**, jadi dijaga **dua gerbang**: `requirePermission`
  (izin dipegang di cabang mana pun) + `authorizedAtBranch(db, principal, "", permission)` di dalam
  transaksi. Grant yang dibatasi cabang → **403 `branch_not_allowed`** (D-062).
- Penutupan periode bersamaan: `UPDATE` yang mengenai 0 baris diperlakukan **409**, dan audit/event
  **tidak** ditulis. Status `OPEN` di `SELECT` sebelumnya bukan pengunci; pemeriksaan hasil
  `UPDATE`-lah yang menutup balapan.
- **Akun kontra belum bisa dimodelkan**: CHECK `normal_side` mewajibkan ASSET/EXPENSE = DEBIT,
  sehingga akun seperti CKPN/akumulasi penyusutan (saldo normal kredit pada kelompok aset) tidak
  punya tempat. Dicatat **O-075**; keputusan penanda `contra` menunggu accounting/compliance owner
  sebelum T-075/T-076.
- `postable = false` masih **konvensi** sampai T-073: belum ada jurnal, jadi belum ada yang menolak
  posting ke akun header/non-`ACTIVE`. T-073 wajib menegakkannya di DB.
- Daftar COA/periode dibatasi **200 baris** (batas ukuran respons, bukan aturan bisnis); paginasi
  menyusul bila COA tumbuh melewati itu.

**Bukti.** `tledger` (13 unit: tipe/sisi normal, pencocokan pola penuh termasuk pola tanpa anchor
dan pola cocok-kosong, tanggal 31 Feb ditolak, rentang terbalik), `itledger` (seed 15 akun, kode
unik, CHECK sisi normal, EXCLUDE: tumpang tindih sebagian/persis/satu hari vs periode bersambung,
tutup periode + penutupan kedua = hasil kosong, rollback), `itapi_ledger` (401/403/400/404/409/500
lewat HTTP, filter, audit create/open/close, event `period.closed`, pola rusak → 500, grant
bercabang → 403). `./task ci` hijau — 709 `[OK]`, e2e 24 passed.

---

## D-071 — Izin tetap pemilik: migrasi, push, dan kerja paralel (20 Okt 2026)

**Konteks.** Pemilik memberi tiga izin tetap supaya alur kerja tidak berhenti menunggu konfirmasi
untuk hal yang sudah jelas.

**Keputusan.**
1. **Eksekusi migrasi selalu diizinkan** — `./task dbtools migrate|status|validate`, reset schema
   DB dev, dan penerapan migrasi ke DB dev/prod tidak perlu izin per kejadian. Tetap berlaku:
   migrasi expand-only, perubahan destruktif butuh `-- dbtools:destructive <alasan>` + keputusan
   terpisah, dan tidak menyentuh server di luar repo tanpa task eksplisit (AGENTS §3).
2. **Push diizinkan, tetapi dibatch** — jangan push terlalu sering karena deploy ke `main`
   membangun image container dan menumpuk tag (T-069 sudah memangkas 12-hex lama, tetapi tetap
   lebih murah tidak membangun). Push ke branch fitur tidak membangun image; merge ke `main` tetap
   keputusan manusia, dan push ke `main` hanya setelah gate hijau (D-044), sebaiknya digabung
   dengan perubahan lain yang siap.
3. **Kerja paralel antartask yang tidak tumpang tindih** — task lain boleh dikerjakan bersamaan
   dengan loop yang sama: implementasi → audit/review independen → perbaiki → ulangi sampai
   APPROVE. Task yang berbagi berkas panas (`routes.nim`, kontrak OpenAPI, modul yang sama) tetap
   berurutan.

**Konsekuensi.** Review independen tetap wajib sebelum `DONE` (AGENTS §4.5–4.7) dengan konteks
bersih; yang berubah hanya izin operasional (migrasi/push) dan pengizinan paralelisasi.

**Ditegaskan ulang (20 Okt 2026).** Pemilik meminta paralelisasi dijalankan agresif untuk pekerjaan
yang **tidak berbagi berkas**: jangan menunggu review task sebelumnya selesai untuk memulai task
berikutnya. Review tetap berjalan di commit yang sudah jadi; perbaikan temuan masuk commit susulan.
Yang tetap berurutan hanya: task yang mengedit berkas sama (`routes.nim`, kontrak OpenAPI, modul
yang sama), dan langkah yang butuh verdict review sebelum menandai `DONE`.

---

## D-072 — Jurnal T-073 tanpa partisi pada Fase 1 (spec §9.3 = acuan, bukan final)

**Konteks.** Spec §9.3 memberi contoh DDL `ledger.journal … PARTITION BY RANGE (business_date)`.
T-073 harus memilih: ikuti partisi sejak awal, atau tunda.

**Keputusan.** Fase 1 memakai tabel **tanpa partisi**. Alasan:
1. Volume pilot (1 koperasi, <5.000 anggota) tidak membutuhkan partisi; biaya operasionalnya
   (partisi default, pemeliharaan bulanan, `ATTACH`/`DETACH` untuk arsip) lebih besar dari manfaat.
2. FK `journal_line → journal` dan **constraint trigger deferred** (keseimbangan per jurnal) jauh
   lebih sederhana tanpa partisi; kombinasi partisi + constraint trigger + FK menambah risiko yang
   tidak bisa dibuktikan dengan test di T-073.
3. Spec sendiri menyebut blok DDL itu *acuan, bukan final*.

**Konsekuensi.** Sebelum go-live bervolume besar (multi-cabang), partisi/arsip per `business_date`
harus ditinjau ulang — konversi ke tabel terpartisi adalah migrasi tersendiri (expand/contract,
bukan edit migrasi lama). Indeks `journal_business_date_idx` sudah mendukung query per tanggal.
Retensi/arsip mengikuti parameter retensi platform (belum aktif di Fase 1).

**Bukti.** `itledger`/`itjournal`/`itapi_journal` menguji immutability, keseimbangan deferred,
periode OPEN, akun postable/ACTIVE, idempotency, dan pembalik pada tabel tanpa partisi.

---

## D-073 — Posting rule sebagai data + konsumen outbox `ledger` (T-074)

**Konteks.** Modul bisnis tidak menulis jurnal; mereka memancarkan accounting event. T-074 harus
memetakan event → jurnal tanpa menaruh mapping di kode, dan tanpa membuat jurnal ganda saat event
dikirim ulang.

**Keputusan.**
1. **Mapping = data** di `ledger.posting_rule` (+ `posting_rule_line`). Rule awal lewat migrasi
   idempoten bertanda `NEEDS-COMPLIANCE-REVIEW` (REG-011 `V!`), sama alasannya dengan COA (D-070):
   seed pack hanya untuk `--dev` dan produksi tidak akan menerimanya.
2. **Pemilihan rule**: `event_type` sama; `product_code` (bila diisi) sama dengan `payload.product`;
   `conditions` harus **subset** payload (containment JSON). Rule paling spesifik (kondisi
   terbanyak) menang; seri → `priority` terkecil; masih seri → **ambigu = gagal terlihat**
   (`DEAD` + `last_error`), bukan dipilih diam-diam.
3. **Event akuntansi ditandai header `accounting: true`** di outbox. Event tanpa header itu
   diabaikan konsumen (`DONE` tanpa jurnal). Event akuntansi **tanpa rule** = `markFailed` →
   `DEAD` setelah `ledger.posting.max_attempts`; jurnal kosong tidak pernah dibuat.
4. **Idempotensi berlapis**: `platform.inbox (consumer, event_id)` + `journal.idempotency_key =
   "outbox:<eventId>"`. Pengiriman ulang (redelivery/redrive setelah crash) tidak menambah jurnal.
5. **Template Fase 1: tepat satu DEBIT + satu CREDIT**, nominal = `payload.amount` (desimal 4),
   `branchId` wajib di payload. Split multi-baris/akad menunggu T-076.
6. **Worker** (`role=worker`) kini berjalan sebagai loop konsumen (sebelumnya placeholder `quit 3`,
   O-013). Batas operasional dari parameter: `ledger.posting.batch_size`, `max_attempts`,
   `retry_backoff_seconds`, `poll_interval_ms` — fail-fast bila belum tersemai.
7. Satu transaksi **per event**: klaim batch di luar, lalu `claimInbox`+jurnal+`markDone` dalam satu
   transaksi; kegagalan → rollback event itu dan `markFailed` di koneksi terpisah sehingga event
   lain dalam batch tetap diproses.

**Konsekuensi.** Belum ada API/UI pengelolaan rule — perubahan mapping masih lewat migrasi
(**O-080**). Worker yang dahulu keluar dengan status 3 sekarang long-running; unit container tetap
sama, dan `RestartPreventExitStatus=3` tidak lagi relevan untuk worker (tidak berbahaya). Bila
akun tujuan rule dinonaktifkan, event terkait gagal terlihat (DEAD) sampai rule diperbaiki.

**Konsekuensi lanjutan (review putaran 1).**
- Klaim batch memakai **lease** (`ledger.posting.lease_seconds`, default 300): event `IN_FLIGHT`
  yang lebih lama dari lease boleh direbut worker lain, sehingga worker yang mati tidak memarkir
  event selamanya. Identitas worker = `kran-worker:<pid>`.
- Konsumen **memancarkan `journal.posted`** dalam transaksi yang sama (tanpa header `accounting`,
  jadi tidak loop) — sebelumnya hanya endpoint pembalik yang memancarkannya.
- Header `accounting` yang ada tetapi **bukan boolean** = gagal terlihat (`DEAD`), bukan diabaikan.
- Baris jurnal hanya boleh masuk dalam **transaksi yang sama** dengan header (migrasi `0008`,
  dibandingkan lewat `xmin`); mencegah nominal jurnal final "ditambah" lewat INSERT berpasangan.
- **MINOR yang ditunda**: rule belum punya API/UI (O-080); worker belum masuk readiness (status
  `PENDING`/`DEAD`/`IN_FLIGHT`) dan belum di-enable saat boot (O-081).

**Bukti.** `tposting` (12 unit: containment, spesifisitas/priority/produk, ambigu, template,
nominal nol/negatif), `itposting` (8 integrasi: satu jurnal + `journal.posted`, redelivery tidak
menambah, non-akuntansi diabaikan, tanpa rule → PENDING lalu DEAD, periode tertutup, lease reclaim,
header salah tipe).

---

## D-074 — Trial balance dihitung dari jurnal; `balance_snapshot` hanya cache (T-075)

**Konteks.** Spec §9.1(4) menyebut `balance_snapshot`; §9 meminta saldo sebagai turunan yang bisa
direkonstruksi. Laporan tidak boleh bergantung pada cache yang basi.

**Keputusan.**
1. **Trial balance dihitung langsung dari `journal_line`** (join `journal` + `coa_account`) untuk
   rentang periode. Tidak ada jalur baca laporan yang memakai cache.
2. `ledger.balance_snapshot` disediakan sebagai **cache** per `(account_code, as_of)` dan hanya
   diisi oleh fungsi `ledger.rebuild_balance_snapshot(as_of)` yang menghitung ulang dari jurnal
   (DELETE + INSERT dalam satu pernyataan fungsi). Tidak ada API/consumer yang menulis saldo.
3. Akun tanpa pergerakan tidak muncul di TB; urutan menurut kode akun.
4. Izin: `ledger.journal.read` (tingkat institusi, dua gerbang seperti T-072/T-073). Tidak menambah
   izin baru untuk laporan sampai ada kebutuhan pemisahan auditor.

**Konsekuensi.** Biaya query TB tumbuh linear terhadap volume jurnal periode; bila itu menjadi
masalah, laporan boleh membaca `balance_snapshot` **setelah** rekonsiliasi day-close (Fase 5) —
bukan sebelum. Rekonstruksi cache adalah langkah eksplisit, bukan efek samping posting.

**Tambahan (review putaran 1).** `balance_snapshot` bersifat **kumulatif** sampai `as_of`, sedangkan
TB adalah **pergerakan periode**; keduanya hanya sama bila tidak ada periode sebelumnya — diuji
dengan jurnal bulan sebelumnya. Akun yang punya saldo awal tetapi tidak bergerak di periode ini
**tidak muncul** di TB (laporan saldo awal/neraca menunggu task laporan; **O-083**). "Tidak ada jalur
tulis saldo selain jurnal" dipertegas: posting jurnal tidak menulis cache sama sekali; satu-satunya
penulis cache adalah `rebuild_balance_snapshot`.

**Bukti.** `ittb` (TB seimbang dengan total independen, sama dengan agregasi SQL, snapshot kumulatif
vs TB periode, periode tidak ada = `none`) + `itapi_journal` (kontrak/total, batas periode inklusif,
400/404, 403).

---

## D-075 — Arah visual UI: "buku besar, kulit hangat" (20 Okt 2026)

**Konteks.** Fase 0 hanya punya shell (login, parameter, audit) dengan token netral `system-ui`.
Fase 2 akan membangun layar teller; tanpa arah tertulis, UI berisiko jadi template SaaS generik yang
tidak cocok untuk kerja 8 jam. Pemilik meminta UI "keren dan tidak AI-ish", dengan brainstorming SME.

**Keputusan.** `DESIGN.md` menjadi acuan wajib untuk layar baru:

1. **Arah**: basis data "buku besar" (near-monokrom, hairline, angka tabular, bidang datar) dengan
   kulit hangat (kertas tulang, hijau tua) hanya di header/navigasi/identitas — bukan di angka.
2. **Tipografi**: IBM Plex Sans + Plex Mono, self-host (OFL), angka tabular wajib; `system-ui` hanya
   fallback.
3. **Palet target** dengan kontras terverifikasi (teks ≥ 6.47:1; border kontrol ≥ 3.67:1) berlaku
   untuk migrasi token, **bukan** perubahan token produksi sekarang.
4. **Density & kontrol**: baris tabel 34 px; kontrol 32 px; aksi primer 44 px; target 1366×768 zoom
   125%; satu lapisan modal.
5. **Angka**: rata kanan, tabular, format `id-ID`, debit/kredit lewat posisi + label, bukan warna.
6. **Larangan**: gradien biru-ungu, shadow di semua kartu, pill, kartu statistik tanpa sumber,
   emoji/sparkle, hero/tur, count-up, skeleton palsu (daftar lengkap di `DESIGN.md` §11).

**Batas.** Fase 1 (T-070…T-077) tidak menyentuh UI. Migrasi token, komponen tabel/angka, font, dan
matriks kontras penuh = **T-079** (persiapan Fase 2), tidak dimulai sebelum T-077 selesai dan pemilik
meratifikasi arah ini. Bila pemilik memveto, cukup ganti §1–§3 `DESIGN.md`; aturan operasional (§4–§12)
tetap berlaku.

**Konsekuensi.** Menambah token/komponen UI tanpa memperbarui matriks kontras dan `DESIGN.md` =
temuan review. Font baru adalah aset self-host (bukan dependency runtime); lisensi OFL diverifikasi
saat T-079.

---

## D-076 — Bentuk tabel `product` & semantik versi (T-076)

**Konteks.** Spec hanya menyebut nama tabel (`product`, `product_version`,
`product_param_binding`) dan aturan effective-dated (§9.1(5)); tidak ada daftar kolom. T-076 harus
menurunkan bentuknya sendiri.

**Keputusan.**
1. **Identitas stabil di `product`** (`code` unik, `name`, `product_type`), hanya nama yang boleh
   diubah. Atribut bisnis tidak ada di sini.
2. **Versi di `product_version`**: `version_no` unik per produk, `effective_from`/`effective_to`
   dengan rentang **inklusif** `[from, to]` — konsisten dengan `ledger.period` (T-072) — dan
   `EXCLUDE USING gist (product_id WITH =, daterange(...) WITH &&)` menolak tumpang tindih, termasuk
   versi terbuka (`to` NULL).
3. **Versi immutable**: hanya `effective_to` yang boleh diisi, sekali (trigger). Versi baru menutup
   versi terbuka sehari sebelum tanggal mulai. Koreksi = versi baru, bukan edit.
4. **Atribut = binding parameter**: `product_param_binding(version_id, param_key, value jsonb)`,
   kunci wajib berawalan `product.`, minimal satu binding per versi (deferred), binding immutable.
   Binding adalah **snapshot penuh atribut versi itu**: atribut yang tidak disertakan di versi baru
   berarti tidak berlaku pada versi tersebut (bukan mewarisi versi sebelumnya).
   Tipe/enum/batas divalidasi composition root terhadap `platform.param_definition`; kunci tak
   terdaftar = 400.
5. **Izin** `product.catalog.read|manage` (migrasi platform `0017` + grant `0018`), aksi institusi
   dua gerbang.
6. **Event** `ProductPublished` per versi (payload productId/code/productType/versionNo/effectiveFrom),
   dedup per `versionId`.

**Tambahan (review putaran 1, 20 Okt 2026).** Empat perbaikan wajib:
1. `CREATE EXTENSION IF NOT EXISTS btree_gist` **di dalam `0002`** — urutan migrasi global menjalankan
   `product/0002` sebelum `platform/0004`, jadi DB kosong gagal tanpa ini (diverifikasi pada cluster
   PG kosong: 32 migrasi diterapkan, `btree_gist` + EXCLUDE ada).
2. CHECK jendela menjadi `effective_to >= effective_from` supaya versi baru H+1 (versi lama menjadi
   satu hari) sah; sebelumnya menghasilkan 500.
3. Binding **di-seal**: constraint trigger deferred memverifikasi minimal satu binding lalu
   `UPDATE product_version SET sealed = true`; trigger `BEFORE INSERT` menolak binding baru ke versi
   terbit. Guard versi hanya mengizinkan transisi `sealed` false→true.
4. Penutupan versi memakai `version_id` yang sudah dibaca (`closeVersion`), bukan "apa pun yang
   terbuka", sehingga balapan dua permintaan berakhir 409, bukan menutup versi lain.
Parser desimal memakai kernel (`moneyFromString`, `rateFromPercentString`) — checked, tanpa float;
batas schema non-integer ditolak fail-closed.

**Konsekuensi.** Belum ada maker-checker (**O-085**), belum ada status DRAFT/RETIRED, dan atribut
rate/day-count belum dimodelkan (**O-084**) karena butuh keputusan akad/produk. Perubahan bentuk
tabel setelah deploy harus lewat migrasi expand/contract, bukan edit migrasi lama.

---

## D-077 — Lane cepat untuk loop pengembangan (tanpa melemahkan gate)

**Konteks.** `./task ci` memakan waktu terutama karena `nim check` dijalankan **sekuensial** untuk
174 berkas; e2e Playwright hanya ~27 detik dan suite integrasi per modul hitungan detik. Loop
harian jadi lambat, sementara gate akhir task tetap harus utuh (AGENTS §6).

**Keputusan (disetujui pemilik, 20 Okt 2026).**
1. **`./task verify [filter]`** = `check-fast` + OpenAPI (sinkron + lint + typecheck klien) +
   `build` + (bila filter diberikan) test modul itu. Dipakai selama implementasi.
2. **`./task check-fast`** = format + archcheck + lint-nomagic + paramgen `--check` + i18n +
   shellcheck — **tanpa** `nim check` penuh.
3. **`./task check`** tetap seperti sekarang (termasuk `nim check` penuh) dan tetap menjadi bagian
   `./task ci`. **DoD tidak berubah**: `./task ci` hijau sebelum task ditandai `DONE`.
4. **`nim check` di-shard paralel** (`xargs -P`, default 4, bisa diatur `KRAN_LINT_JOBS`) dengan log
   per berkas; kegagalan tetap menampilkan log berkas yang gagal dan exit non-zero. Ini hanya
   mengubah cara menjalankan, bukan cakupan gate.
5. **Filter test** memakai kecocokan **nama berkas persis** lebih dulu (`tproduct` tidak lagi ikut
   menjalankan `itproduct`); bila tidak ada yang persis, baru jatuh ke substring seperti sebelumnya.

**Konsekuensi.** Loop harian tidak lagi menunggu lint penuh; regresi lint tetap tertangkap di
`task ci` sebelum `DONE`. `KRAN_LINT_JOBS` dinaikkan/diturunkan sesuai memori mesin (tiap `nim
check` memuat graf impor; 4 dipilih agar tidak menekan mesin 8–10 core).

---

## D-090 — Otorisasi pemilik untuk langkah produksi Fase 1 (override AGENTS §3)

**Konteks.** AGENTS §3 melarang agen merge ke `main` (push = deploy) dan menyentuh server/secret.
Pemilik secara eksplisit memilih "saya eksekusi (override §3)" pada 20 Okt 2026 untuk: merge
`feat/fase1-party` → `main`, seed parameter base di DB produksi, enable unit worker, dan
membuat/memasang KEK produksi.

**Keputusan.** Override berlaku **hanya** untuk rangkaian go-live Fase 1 ini, dengan pagar:
1. Tidak ada secret (nilai KEK, URL DB, password) masuk repo, log, atau pesan.
2. Sebelum merge: preflight read-only dicatat (DB `kran`, user `kran_app`, 13 migrasi, `btree_gist`
   + `pgcrypto` ada, `CREATE` privilege ada, kran-api sehat, SHA produksi `69dfca3`).
3. Deploy tetap lewat pipeline resmi (`push` → webhook → build → health gate `/readyz` →
   auto-rollback); tidak ada langkah manual yang melewati gate.
4. Seed parameter hanya berkas generated (`param_definitions` DO UPDATE metadata, `param_values`
   DO NOTHING) — tidak menimpa nilai yang sudah diubah pemilik; nilai base bertanda
   `NEEDS-COMPLIANCE-REVIEW`.
5. KEK dibuat di server, mode 0600, di luar repo/image; `sops`/`age` menyusul (D-046 butir 12).
6. Setiap langkah + hasilnya dicatat di `docs/PROGRESS.md`; kegagalan → rollback `:prev`, bukan
   memaksa ulang.

**Hasil (20 Okt 2026).** Deploy `36602a8` + `28168f7` sukses (33 migrasi, `/readyz` 200), parameter
base ter-seed, worker aktif, KEK v1 ter-mount. Dua kegagalan nyata saat proses: (a) API menolak
start karena berkas KEK tidak di-mount; (b) setelah mount, uid container 10001 tidak bisa membaca
berkas 600 → diperbaiki dengan `UserNS=keep-id:uid=10001,gid=10001`. Worker sempat exit 2 karena
deploy mendahului seed (**O-090**).

**Konsekuensi.** Tanggung jawab operasional atas deploy ini ada pada pemilik yang memberi override;
catatan ini yang membuat tindakan agen dapat diaudit. Aturan §3 tetap berlaku untuk task lain.

---

## D-091 — Tutup periode mengunci baris periode (`FOR SHARE`), bukan hanya membaca status

**Konteks.** O-089: trigger `ledger.assert_journal_period_open()` hanya membaca status periode.
Sesi A yang menutup periode (belum `COMMIT`) dan sesi B yang memposting jurnal pada tanggal itu
tidak saling melihat: B membaca versi lama `OPEN`, insert berhasil, lalu A commit — jurnal berada
di periode `CLOSED`. Invarian "tidak ada posting ke periode tertutup" bocor tanpa galat apa pun.

**Opsi.** (A) kunci baris periode di trigger; (B) dokumentasikan bahwa jaminan hanya untuk periode
yang sudah commit `CLOSED`; (C) A + B.

**Keputusan.** **A** (sekaligus B: sisa jendela operasional dicatat). Fungsi trigger diganti
`CREATE OR REPLACE` dengan `SELECT ... FOR SHARE` pada baris periode. `UPDATE` penutupan memakai
lock `FOR NO KEY UPDATE` yang berkonflik dengan `FOR SHARE`, sehingga:
- B menunggu sampai A selesai, lalu mengevaluasi versi **setelah** commit (`CLOSED`) → ditolak;
- bila B memegang lock lebih dulu, penutupan menunggu jurnal commit → jurnal tetap di periode OPEN.

**Ditolak.** B saja: membiarkan jalur posting normal (bukan hanya `daycloser`) menembus invarian
akuntansi; "didokumentasikan" tidak cukup untuk buku besar. `daycloser` (Fase 5) tetap menjadi
pemilik urutan EOD, tetapi penegakan tidak boleh bergantung padanya.

**Konsekuensi.** Lock baris periode dipegang sampai transaksi jurnal selesai (satu lock per jurnal);
penutupan periode menunggu jurnal yang sedang berjalan. Volume pilot kecil (D-072) sehingga
memadai; bila throughput jadi masalah, alternatifnya advisory lock per periode — bukan menurunkan
invarian. Migrasi `0011_ledger_period_lock.sql` expand-only.

**Urutan penguncian.** Jalur yang ada: tutup periode `period` → advisory `platform.audit_log`;
pembalik `period` (via `insertJournal`) → advisory; worker `inbox` → `period` → `outbox` (tanpa
audit). Tidak ada siklus hari ini. Konsekuensinya: penambahan lock baru di ledger harus sadar urutan
`period → audit`; jalur yang menulis audit **sebelum** posting berpotensi membuat siklus dengan
penutupan periode.

**Bukti.** Dua test `itjournal`: (1) dua koneksi, `lock_timeout` 200 ms — insert **gagal** karena
menunggu lock saat penutupan belum commit; (2) thread menahan penutupan 800 ms lalu COMMIT — insert
yang menunggu **ditolak** (`tidak ada periode OPEN`), bukan timeout, dan tidak ada baris jurnal.
Test (1) **FAILED** bila `FOR SHARE` dilepas (mutation check), lalu hijau setelah dipulihkan.
`./task verify ledger` hijau; `./task ci` hijau (lihat PROGRESS).

---

## D-092 — Seed parameter base dijalankan oleh jalur migrasi, sebelum unit di-restart

**Konteks.** O-090: `deploy-vps.sh` me-restart unit (termasuk worker) sebelum parameter posting
tersemai. Worker menolak start (exit 2) bila `ledger.posting.*` belum ada, dan deploy tidak pernah
menjalankan seed — deploy pertama setiap rilis yang menambah parameter meninggalkan worker mati
tanpa kegagalan deploy yang terlihat.

**Opsi.** (A) seed di jalur migrasi/deploy; (B) preflight gate yang menolak deploy bila parameter
wajib belum ada; (C) worker menunggu/retry sampai parameter muncul.

**Keputusan.** **A**: subperintah `kran-api --role=migrate --seed` menerapkan
`packs/*/generated/*.sql` memakai `dbtools/lib` (jalur yang sama dengan `dbtools seed`, sudah
diimpor aplikasi). Deploy memanggilnya **setelah** biner ditukar dan **sebelum** restart unit,
dengan `die` bila gagal. Berkas seed idempoten: `param_definitions` `DO UPDATE` metadata,
`param_values` `DO NOTHING`; `dev = false` sehingga seed dev/test tidak pernah ikut.

**Ditolak.** B saja: mendeteksi tetapi tetap menyisakan langkah manual yang mudah terlewat, dan
gate baru harus tahu daftar parameter wajib per rilis. C: menyembunyikan salah konfigurasi dan
membuat worker "hidup" tanpa posting yang benar.

**Konsekuensi.** Setiap deploy (termasuk docs-only) menerapkan dua berkas SQL generated — murah dan
aman. Bila kelak ada berkas generated yang tidak idempoten, deploy akan gagal keras; itu disengaja
(sumber kebenaran parameter = repo, bukan langkah manual).

**Risiko yang diterima.** Seed berjalan otomatis tiap deploy, jadi dua keadaan bisa membuat deploy
berhenti (fail-closed): (a) pack lain menyemai key yang sama dengan `param_value_id` berbeda, atau
(b) key sudah punya baris ACTIVE non-seed tanpa baris seed — keduanya melanggar `EXCLUDE` ACTIVE →
seed keluar 1 → deploy batal, bukan diam-diam menimpa. Seed juga **tidak** memverifikasi bahwa
parameter posting benar-benar resolvable; health gate hanya memeriksa API. Sampai ada gate worker,
pastikan log deploy memuat `==> seed parameter base` dan worker `active`.

**Bukti.** Test `itapi_roles` menghapus baris seed deterministik (`md5('ledger.posting.batch_size|base')`)
lalu membuktikan `--seed` mengembalikannya (`ACTIVE`, nilai `50`), tidak menggandakan baris ACTIVE,
dan tidak menyertakan berkas `packs/*/seed/` (dev). Mutation check: tanpa cabang `--seed` test
**FAILED**. Catatan urutan: `sync_script` memasang skrip deploy untuk deploy **berikutnya**, jadi
langkah seed baru aktif pada deploy setelah merge — bukan pada deploy yang membawa commit ini.

---

## D-093 — Biaya KDF di test: seed dev 1000 iterasi, parameter test diturunkan (bukan produksi)

**Konteks.** Seed pengguna dev memakai PBKDF2 600.000 iterasi (nilai parameter produksi). Setiap
login di test memverifikasi hash dengan iterasi tersimpan; ganti-password di satu test membuat hash
600k yang dipakai semua test berikutnya. Hasil ukur: `itapi_auth` **170 s**, `itapi_mfa` **49 s**
hanya untuk verifikasi login.

**Keputusan.** (1) Seed dev/test memakai **1000** iterasi (tetap PBKDF2-HMAC-SHA256, salt sama);
(2) test yang mengganti password (`itapi_auth`, `itapi_mfa`) menurunkan nilai parameter
`platform.security.password_pbkdf2_iterations` ke 1000 **di DB test saja**; (3) nilai produksi
(seed pack `600000`) tidak berubah; biaya KDF diuji terpisah di `tpassword`/`itpassword` dan
`./task bench-password`.

**Ditolak.** Menurunkan nilai di pack (produksi ikut lemah); caching binari test berdasarkan
mtime (risiko test lulus dengan kode lama — lebih buruk daripada panas). Kompilasi ulang setiap
run dipertahankan.

**Konsekuensi.** `itapi_auth` 170→30 s, `itapi_mfa` 49→20 s, `./task test` 368 s (819 `[OK]`).
Loop harian: `./task verify <modul>` atau `./task test <nama-suite>`; `./task ci` untuk pra-merge.

---

## D-094 — O-084: bentuk parameter akrual simpanan, tanpa nilai

**Keputusan.** Tambah lima kunci di `modules/product/seeds/params.yaml` **tanpa `default_pack`**:
`product.savings.{interest_rate, day_count_basis, rounding_mode, rounding_scale, interest_posting}`.
Nilai (rate/basis/pembulatan) menunggu compliance (`NEEDS-COMPLIANCE-REVIEW`); parameter tanpa nilai
membuat pembacaan gagal-cepat, bukan memakai default tak disetujui (spec §10.6).

**Ditolak.** Menunda bentuk (versi produk immutable + binding sealed → menambah kunci nanti =
versi produk baru); JSON blob (mematikan validasi, maker-checker, paramgen).

**Batas.** Frekuensi akrual = sifat day-close (Fase 3), cut-off = milik business date institusi,
nisbah syariah bukan `interest_rate`. Akrual bukan atribut produk.

---

## D-095 — O-066: klasifikasi seed base (teknis / kebijakan / menunggu compliance)

**Keputusan.** Seed base dipakai untuk pilot dengan kelas eksplisit:
- **Teknis** (aman): `ledger.posting.*`, `ledger.coa.code_pattern`, `platform.security.mfa.*`,
  `pbkdf2_iterations=600000` (tetap `HUMAN-REVIEW-REQUIRED` untuk kripto).
- **Kebijakan internal** (aman dipakai, wajib ditandai): password min length/classes/history,
  max failed logins, lockout, session idle/absolute.
- **Komersial** (konservatif): `product.savings.min_balance=0`, `admin_fee=0` — tidak menagih;
  angka final menunggu pemilik.
- **Belum punya semantik**: `product.savings.grace_period_days` — tidak ada konsumen; definisikan
  atau keluarkan sebelum dipakai.
- **Penerimaan risiko**: `mfa.enabled=false` untuk pilot hanya sebagai keputusan pemilik tertulis
  (spec §18.2 meminta MFA; jangan disebut "patuh").
- **Regulasi**: rate/nisbah/pajak/PPAP/LPS **tidak** disemai — pertahankan.

---

## D-096 — O-083: saldo GL sebagai laporan terpisah, TB tetap mutasi

**Keputusan.** TB tidak diberi kolom saldo. Endpoint baru `GET /api/v1/ledger/balances?periodId=`
mengembalikan opening/period/closing **debit & kredit terpisah** per akun dalam **satu query**;
baris = akun bergerak atau bersaldo awal ≠ 0; `source: ledger|snapshot` + `computedAt` wajib.
Snapshot hanya dipakai bila periode sudah CLOSED dan terekonsiliasi; default hitung dari jurnal.
Izin tetap `ledger.journal.read` (institusi). Saldo teller = modul deposit (per cabang), bukan GL.

**Ditolak.** Kolom saldo di TB (mencampur mutasi & posisi, akun tanpa mutasi tetap hilang);
snapshot sebagai default "cepat" (basi tanpa galat, granularitas harian, tanpa cabang).

---

## D-097 — O-082: 4 desimal di tabel, 2 desimal untuk tunai

**Keputusan.** Penyimpanan tetap `Money` 10⁻⁴. Tampilan: **4 desimal** untuk nilai yang
dijumlahkan (jurnal, TB, neraca), **2 desimal** untuk nilai tunai tunggal (input/konfirmasi teller,
struk). Satu pintu `formatMoney(decimal, {decimals})` di `apps/web/src/lib/app/format.ts`, parsing
string tanpa `Number()`/float, pembulatan sama dengan `Money`. `DESIGN.md` §6 diperbarui.

**Ditolak.** 2 desimal di tabel (jumlah baris tampak ≠ total → "TB tidak seimbang"); parameter
per institusi (presisi bukan kebijakan; dua orang melihat presisi berbeda).

---

## D-098 — O-072: idempotency bertahap pada endpoint pembuat objek (bukan middleware semua POST)

**Keputusan.** `Idempotency-Key` wajib pada POST pembuat objek bisnis, dimulai dari yang berisiko
duplikat nyata: `POST /parties`, risk-rating, param submit; lalu endpoint finansial teller.
Tabel `platform.idempotency_key` PK `(principal_id, key)` + `operation_id`, `request_hash`,
`response_status`, `response_body`, `expires_at`; baris ditulis **dalam transaksi bisnis**. Aturan:
kunci+hash sama → 200 replay + `Idempotent-Replayed: true`; hash/operasi beda → 409; baris ada tapi
belum selesai → 409 + `Retry-After`; 5xx di-rollback. TTL = parameter, pembersihan lewat daycloser.
Outbox key + `journal.idempotency_key` tetap lapisan dalam.

**Ditolak.** Middleware generik (tidak bisa membedakan login/MFA/logout; menyimpan respons error).

---

## D-099 — O-085: maker-checker versi produk (DRAFT → ACTIVE)

**Keputusan.** `product_version` mendapat status `DRAFT|ACTIVE`, `maker`, `checker`, timestamp;
binding tetap di-seal saat approve; `ProductPublished` terbit saat **approve**, bukan submit;
self-approval ditolak CHECK DB; izin baru `product.catalog.approve`. Versi lama tetap immutable.

**Konsekuensi.** Pilot satu operator akan terblokir sampai ada penyetuju kedua — konsekuensi
kebijakan, bukan bug. Sampai D-099 diimplementasi, perubahan produk produksi dibekukan (dicatat di
`ACCEPTED-LIMITS.md`).

---

## D-100 — Reset kata sandi lewat `ctl reset-password`, bukan SQL manual

**Konteks.** `bootstrap-admin` mencetak kata sandi awal **sekali**, tidak disimpan; akun `admin`
produksi masih `must_change_password = true` dan kata sandi awalnya hilang. Tidak ada jalur reset,
dan mengubah `password_hash` langsung lewat SQL akan melewati audit, pencabutan sesi, dan policy
check — persis area `HUMAN-REVIEW-REQUIRED` (AGENTS §8).

**Keputusan.** Tambah `kran-api --role=ctl reset-password --username=<nama>`:
- kata sandi acak CSPRNG, panjang mengikuti `password_min_length` + margin, kelas karakter dijamin;
- hash dengan `platform.security.password_pbkdf2_iterations` (nilai produksi, bukan konstanta);
- `must_change_password = true`, `failed_attempts = 0`, `locked_until = NULL`;
- **semua sesi pengguna dicabut**;
- audit `user.password_reset` (username, flag wajib-ganti, jumlah sesi dicabut) ditulis dalam
  transaksi yang sama lewat trigger rantai audit;
- kata sandi hanya di memori + stdout sekali; kode keluar 0/1/2/3 mengikuti kontrak `ctl`.

Perilaku yang dituntut dan diuji: akun berstatus `LOCKED` dikembalikan ke `ACTIVE` (tanpa
menyentuh `INACTIVE`/`SUSPENDED`) — `setPassword` hanya mengosongkan `locked_until`, sehingga tanpa
ini akun terkunci permanen; hash lama tetap masuk `user_password_history` supaya kebijakan "tidak
boleh pakai ulang" berlaku setelah reset.

**Ditolak.** UPDATE SQL manual (tanpa audit/sesi/policy); menyimpan kata sandi awal di disk
(melanggar desain bootstrap).

**Konsekuensi.** Operator dengan akses server bisa mereset siapa pun yang namanya diketahui;
tindakan tercatat di audit dengan aktor sistem (`actor_user_id` kosong) dan alasan eksplisit.
Perintah ini **tidak** menggantikan maker-checker untuk hal lain; ia jalur pemulihan darurat.

---

## D-101 — Monitoring worker konsumen lewat denyut, bukan panjang backlog

**Konteks.** `/readyz` sudah mengukur lag pump realtime (`pumpLagProbe`, O-019), tetapi itu
**bukan** konsumen posting: pump realtime membaca outbox dengan kursor sendiri, sedangkan jurnal
diposting worker (`ledger-postings`). Worker yang mati tidak terlihat — lag pump tetap kecil,
`DEAD` hanya muncul lewat query manual (O-081).

**Keputusan.** Worker menulis denyut `platform.worker_heartbeat` (satu baris per worker, maksimal
satu tulisan tiap 15 dtk lewat `INSERT ... ON CONFLICT DO UPDATE ... WHERE last_seen_at`). Denyut
ditulis **di awal putaran dan di antara event di dalam batch**, karena satu batch (maks. 500 event)
bisa berjalan lebih lama dari ambang dan worker yang sedang bekerja tidak boleh terlihat mati.
`/readyz` menambah dua check:
- `worker`: gagal bila denyut terakhir > **180 dtk** (`12 × 15 dtk`, memberi ruang
  `poll_interval_ms` maksimum 60 dtk), atau worker **belum pernah** melapor setelah **masa tenggang
  180 dtk** sejak proses API start. Denyut yang sudah basi **tidak** mendapat masa tenggang: worker
  sehat menulis paling lambat tiap 60 dtk, jadi basi berarti worker tidak jalan. Masa tenggang hanya
  menutup start pertama (API dan worker menyala bersamaan; gate deploy mengulang).
- `outbox-dead`: jumlah event `DEAD` muncul di `detail`, status tetap `ok`. **Alasan:** `DEAD`
  butuh re-drive operator; deploy ulang tidak menghidupkannya, dan readiness yang gagal hanya
  membuat gate deploy berputar rollback.

**Ditolak.** Menyimpulkan kesehatan worker dari panjang/usia backlog: backlog bisa kosong walau
worker mati, dan bisa besar walau worker sehat (impor massal). Ambang denyut sebagai parameter DB:
`/readyz` adalah gate deploy dan harus tetap berjalan walau parameter belum tersedia — sama seperti
`pumpLagSeconds`/`pumpReadyGraceSeconds`.

**Konsekuensi.** Worker yang pernah hidup lalu mati terlihat dari `/readyz` paling lambat ~3 menit
(usia denyut melewati 180 dtk); worker yang tidak pernah start terlihat setelah masa tenggang 180 dtk. Monitoring eksternal yang memberi alarm masih **belum ada**
(O-092); `DEAD` harus dipantau dari `detail` atau `ctl outbox-status`, bukan dari status HTTP.
**Limitasi yang diketahui:** worker yang crash-loop cepat (start → tulis denyut → mati) tetap
menyegarkan denyut dan bisa lolos sebagai `ok`; sinyal usia `IN_FLIGHT`/`PENDING` sengaja tidak
dipakai karena rawan alarm palsu saat impor massal — pantau `platform.outbox` untuk kasus itu.

---

## D-102 — Anggaran tunggu test stress pool mengikuti tujuan test, bukan SLA latensi

**Konteks.** `shared/platform-lib/tests/itpool.nim` menekan pool (8 thread, pool 3, 200 iterasi).
Di satu run `./task ci` (T-072) 4 iterasi gagal `PoolError: timeout menunggu koneksi` pada
15 dtk, sementara run lain hijau dan tanpa indikasi kebocoran (O-074). Penyebab paling mungkin
latensi tunnel SSH ke DB dev + penjadwalan thread, bukan invarian pool.

**Keputusan.** Anggaran tunggu test stress dinaikkan ke **60 dtk** lewat konstanta
`stressAcquireTimeoutMs` dengan komentar yang menyebut tujuan test. Tidak ada assertion yang
dilonggarkan: galat tetap harus 0, `inUse` kembali 0, `created <= poolSize`, jumlah iterasi tetap.
Yang berubah hanya berapa lama satu pinjaman boleh menunggu sebelum dinyatakan gagal.

**Ditolak.** Menurunkan iterasi/thread (mengurangi daya uji kebocoran); menaikkan `poolSize`
(menguji kontensi yang berbeda); menandai test `skip` saat lambat (menyembunyikan kebocoran nyata).

**Konsekuensi.** Test stress tidak lagi menjadi alarm latensi DB dev — itu memang bukan tujuannya.
Bila `timeout` muncul lagi, penyebabnya harus diselidiki sebagai kebocoran/koneksi mati, bukan
dinaikkan ambangnya lagi tanpa bukti.

---

## D-103 — Id cabang: UUID untuk identitas, `text` hanya untuk kolom scope

**Keputusan.** Semua id cabang yang **dibuat** aplikasi adalah UUID. Kolom `platform.*.scope_id`
tetap `text` karena spec §10.2 mendefinisikan scope sebagai pasangan `scope_type`/`scope_id` yang
generik (bukan FK), dan parameter dapat ber-scope selain cabang. Tidak ada migrasi tipe.

**Konsekuensi.** Data uji lama yang memakai id non-UUID (mis. `cabang-uji`) tetap sah sebagai
**fixture**, bukan contoh produksi. Handler yang menulis `branch_id` wajib mem-parse UUID
(`parseId`) sebelum menulis; audit sudah memaksa `uuid`. O-017 ditutup sebagai konvensi, bukan
perubahan skema.

## D-104 — Pembalik jurnal pada periode yang sudah CLOSED tetap ditolak

**Keputusan.** Koreksi lintas periode **tidak** dilakukan dengan membalik jurnal di periode lama
(itu menembus immutability dan mengubah laporan yang sudah ditutup). Jalur resmi: buat jurnal
pembalik/penyesuaian di **periode berjalan** dengan referensi ke jurnal asal, alasan, dan audit —
disetujui operator berwenang. Sistem tetap menolak `POST .../reversal` bila periode tanggal asal
CLOSED (409).

**Konsekuensi.** Koreksi lintas periode adalah prosedur manual yang tercatat, bukan fitur tersembunyi.
Bila kelak dibutuhkan otomasi, tambahkan use case eksplisit (izin + alasan + audit), bukan
melonggarkan guard.

## D-105 — Pembalik ditolak bila akun GL asal `INACTIVE`

**Keputusan.** Pertahankan fail-closed: trigger menuntut akun `postable AND ACTIVE`, termasuk untuk
baris pembalik. Aturan operasional: **jangan menonaktifkan akun GL yang masih dirujuk jurnal**;
koreksi dilakukan selagi akun aktif, atau akun diaktifkan sementara dengan alasan + audit lalu
dinonaktifkan lagi.

**Konsekuensi.** Tidak ada jalur "pembalik ke akun mati". Bila kebutuhan akun kontra/laporan muncul,
itu keputusan COA (D-106), bukan pelonggaran trigger.

## D-106 — Akun kontra (CKPN, akumulasi penyusutan) ditunda ke Fase 2

**Keputusan.** COA Fase 1 memakai invarian `normal_side` menurut tipe akun (D-070). Akun kontra
belum dimodelkan; jangan memaksanya menjadi LIABILITY. Perluasan (penanda `contra` atau
`normal_side` eksplisit) menunggu kebutuhan produk/akuntansi nyata dan keputusan REG-011.

**Konsekuensi.** Laporan Fase 1 tidak memuat akun kontra. Bila pilot membutuhkannya, itu task COA
baru dengan property test yang menjaga neraca tetap seimbang.

## D-107 — Perubahan posting rule lewat migrasi sampai ada API (Fase 2)

**Keputusan.** Fase 1 menyediakan tabel + resolver + konsumen; perubahan mapping oleh institusi
masih lewat migrasi/seed yang di-review. CRUD rule (maker-checker, effective-dated) ditunda ke
Fase 2 (O-080), karena belum ada kebutuhan multi-produk di pilot.

**Konsekuensi.** Setiap perubahan rule = perubahan repo + deploy + audit review. Jangan menambah
endpoint tulis rule diam-diam tanpa desain maker-checker.

## D-108 — Anchor audit harian lewat `ctl audit-anchor`

**Keputusan.** Rantai audit punya **anchor** yang disimpan di luar database: `kran-api --role=ctl
audit-anchor [--out=<berkas>]` mencetak `waktu seq hash` kepala rantai dan (bila `--out`) menambah
baris ke berkas append-only. Verifikasi: `ctl verify-audit` menyatakan rantai utuh **dan** hash/seq
terakhir pada anchor cocok dengan baris DB pada seq itu. Berkas anchor disimpan di host terpisah/
backup terpisah, bukan di DB yang sama.

**Alasan tidak menunggu daycloser.** Framework daycloser (Fase 3) boleh menjadwalkan anchor nanti;
kemampuan mencatatnya tidak bergantung pada daycloser, dan tanpa anchor penulisan ulang seluruh ekor
rantai tidak terdeteksi.

**Konsekuensi.** Penjadwalan harian (cron/systemd timer) dan penyimpanan salinan di luar server
tetap tindakan host/pemilik (O-009 sisa operasional). Command ini tidak mengubah audit.

## D-109 — Penolakan pengajuan parameter lewat endpoint `reject`

**Keputusan.** `POST /api/v1/params/changes/{paramValueId}/reject` (izin checker) mengubah
`PENDING` → `REJECTED`, alasan wajib (maks. 500 karakter), menulis audit `param.reject` + event
`param.changed` (status REJECTED) dalam satu transaksi; nilai `ACTIVE` tidak disentuh. Penolakan
kedua → 409 `not_pending`.

**Konsekuensi.** Pengajuan salah tidak lagi perlu dibiarkan menumpuk atau diubah lewat SQL; semua
jalur penolakan punya jejak audit yang sama dengan persetujuan.

## D-110 — Pemisahan role DB: prosedur siap, penerapan butuh pemilik

**Keputusan.** Append-only audit harus punya dua lapis: trigger (sudah ada) dan role aplikasi tanpa
`UPDATE/DELETE` pada `platform.audit_log`. Prosedur lengkap ada di `docs/runbooks/db-roles.md`.
Penerapannya **belum** dilakukan karena (a) `kran_app` saat ini pemilik schema, (b) deploy memakai
satu URL untuk migrasi dan runtime sehingga memindahkan ownership tanpa memisahkan URL akan
mematikan migrasi berikutnya.

**Konsekuensi.** O-010 tetap terbuka sampai pemilik menyetujui jendela perubahan dan env migrasi
dipisah. Jangan menjalankan separuh prosedur.

## D-111 — Rotasi KEK dilarang selama blind index identitas ada

**Keputusan.** Sampai ada perintah reindex blind index, rotasi KEK atas data identitas **dilarang**
(O-073). Prosedur darurat (re-enkripsi + hitung ulang `number_bidx` manual + verifikasi duplikat)
tercatat di `docs/runbooks/field-encryption.md`; itu operasi berisiko dengan snapshot DB, bukan
prosedur rutin.

**Konsekuensi.** Rotasi kunci untuk data non-identitas boleh mengikuti runbook; kunci lama tidak
dihapus sampai verifikasi baca selesai.

---

## D-112 — T-078 (detail PII party) adalah fitur tersendiri, bukan syarat penutupan Fase 0/1

**Keputusan.** Fase 1 berhenti pada `party` CIF + identitas dasar + KYC profile + risk rating
(T-070/T-071), sesuai §23 "CIF+KYC dasar". T-078 (nama resmi, tanggal lahir, jenis kelamin,
pekerjaan, alamat; tabel `party_person`/`party_org`/`address` dengan crypto per kolom) adalah
**fitur baru** yang menyentuh PII + enkripsi, wajib reviewer manusia (`HUMAN-REVIEW-REQUIRED`),
kontrak OpenAPI, dan test at-rest. Mengerjakannya sebagai tambahan cepat di akhir batch berisiko
menghasilkan skema/crypto setengah matang.

**Konsekuensi.** T-078 tetap `TODO` di backlog sebagai kandidat Fase 2; penutupan Fase 0/1 tidak
menunggunya. Bila pilot membutuhkan alamat/tanggal lahir, jadwalkan T-078 sebagai task tersendiri
dengan reviewer.

---

## D-113 — SoD ditegakkan sekarang hanya untuk `param_maker` vs `param_checker`

**Keputusan.** Migrasi `0020_platform_sod_param_conflict.sql` menyemai satu pasangan
`platform.role_conflict`: `param_checker` / `param_maker` (`sod.param.maker_checker`).

**Alasan.** Ini satu-satunya pasangan yang (a) sudah punya peran nyata di `0008`, (b) izinnya
saling melengkapi (`submit` vs `approve`), dan (c) hanya dijaga separuh oleh CHECK
`param_value_no_self_approval_chk` (yang memblokir approver = maker pada satu baris, bukan
kepemilikan dua peran). Pasangan lain — terutama yang menyertakan `platform_admin` — adalah
kebijakan institusi, tidak disemai.

**Konsekuensi.** `grantRole` menolak pemberian peran kedua; data lama yang memegang keduanya akan
ditolak saat `authorize` (`arRoleConflict`). Di produksi saat migrasi dijalankan tidak ada pengguna
yang memegang kedua peran. Test memakai kode peran nyata (`itauth.nim`), bukan peran sintetis.

---

## D-114 — Default parameter pilot diterima pemilik (jalur 1); validasi per institusi jadi gate komersial

**Keputusan.** Nilai parameter yang sekarang disemai (`party.kyc.review_months`, `doc_types`,
`doc_lengths`, `risk_levels`, `ledger.coa.code_pattern`) diterima pemilik **untuk pilot internal**,
tanpa klaim sesuai regulasi. Penanda `NEEDS-COMPLIANCE-REVIEW` tetap ada. Tidak ada kode yang
berubah dan tidak ada nilai regulasi baru yang disemai.

**Gate go-live komersial (wajib, tidak boleh dilewati).** Sebelum anggota nyata pertama dilayani
atau klien BPR/koperasi pertama menandatangani, nilai pada scope **institusi klien itu** harus
divalidasi oleh compliance klien/konsultan, dengan `reason` pengajuan parameter memuat nomor aturan
+ tanggal akses. Penanda `NEEDS-COMPLIANCE-REVIEW` dicabut **per institusi**, bukan global. Default
repo tidak pernah menjadi angka sah untuk klien.

**Konsekuensi.** Pilot boleh berjalan sekarang. Bila gate ini dilanggar, risikonya bukan teknis
(sistem tetap jalan) melainkan kepatuhan: angka default bisa berbeda dari ketentuan yang berlaku
untuk institusi tersebut.

---

## D-115 — Arah visual D-075 diratifikasi; T-079 dimulai

**Keputusan.** Pemilik menyetujui arah `DESIGN.md` ("buku besar, kulit hangat") dan memerintahkan
Fase 2 dimulai dengan syarat UI/UX bermutu, bukan hasil default AI. Ratifikasi ini yang ditunggu
D-075 sebelum token dipakai.

**Konsekuensi.** Token lama (biru) diganti palette D-075; IBM Plex Sans/Mono di-self-host (OFL,
tanpa CDN); angka uang memakai Plex Mono + `tabular-nums`; radius/ elevasi mengikuti DESIGN.
Pekerjaan UI wajib melewati antislop mode `during` + Delivery Gate, dan `DESIGN.md` menjadi sumber
arah, bukan selera agen.


---

## D-116 — Region tabel buku besar tetap fokusabel meski `role="region"`

**Keputusan.** Wadah tabel saldo (`/app/ledger`) memakai `role="region"` + `tabindex="0"` supaya
pengguna keyboard bisa menggulir tabel lebar dengan tombol panah (WCAG 2.1.1). `svelte-check`
memperingatkan `a11y_no_noninteractive_tabindex` untuk pola ini; peringatan ditekan dengan
`svelte-ignore` beralasan, bukan dengan melonggarkan gate.

**Konsekuensi.** Gate svelte-check kembali 0 warning. Kalau nanti wadah itu berisi kontrol
interaktif langsung, `tabindex` harus ditinjau ulang agar tidak menambah tab stop ganda.

---

## D-117 — Amandemen D-098: duplikat konkuren menunggu lalu replay; `Retry-After` dibatasi

**Keputusan.**
1. Baris klaim tetap ditulis di transaksi bisnis. Duplikat yang datang **saat transaksi pemenang
   masih berjalan** akan menunggu unique index `(principal_id, key)`, lalu setelah pemenang
   COMMIT membaca baris yang sudah selesai dan dijawab **replay 200** — bukan 409.
2. Karena klaim dan `completeIdempotency` terjadi dalam **satu** transaksi, baris in-flight yang
   ter-COMMIT **tidak mungkin muncul**: proses yang mati di tengah me-rollback klaimnya. Cabang
   `idemInFlight` (409 + `Retry-After`) karena itu **defensif** — hanya tercapai dari baris hasil
   INSERT manual/seeder, baris yang disapu setelah TTL di antara INSERT dan SELECT (fallback
   1 detik), atau bila kelak klaim dipisah ke transaksi sendiri. Kontrak endpoint dan
   runbook tidak boleh menjanjikan `Retry-After` sebagai respons normal.
3. `Retry-After` untuk klaim in-flight dibatasi **60 detik** (konstanta protokol di kode, bukan
   parameter bisnis); menunggu sisa TTL penuh (bisa sehari) tidak berguna bagi klien.
4. `created_at`, `expires_at`, dan `completed_at` memakai jam aplikasi yang sama (dikirim
   pemanggil), dengan CHECK `expires_at > created_at` dan `completed_at >= created_at`.

**Konsekuensi.** Duplikat konkuren menahan satu koneksi pool selama transaksi pemenang; bila
melewati deadline query, pemanggil menerima 500/PoolError. Ini batas yang diterima untuk pilot
(operasi pembuat objek pendek). Bila kelak ada operasi panjang, klaim harus dipisah ke transaksi
sendiri atau memakai advisory lock — perubahan itu butuh ADR baru.


---

## D-118 — `response_body` idempotensi menyimpan respons apa adanya (penerimaan risiko pilot)

**Keputusan (pemilik, 22 Okt 2026).** Kolom `platform.idempotency_key.response_body` menyimpan
respons sukses apa adanya, termasuk `displayName` pada `POST /parties`. Tidak ditulis ke log;
akses hanya lewat role aplikasi; retensi mengikuti `expires_at` (TTL parameter, base 24 jam) dan
sapuan **T-089** saat `daycloser` tersedia. Replay mengembalikan body tersimpan tanpa membaca ulang
objek.

**Batas.** Ini **bukan** penutupan O-093. Sebelum endpoint ini dipakai dengan data anggota nyata
(produksi penuh), wajib diputuskan masking/field allowlist **atau** enkripsi kolom plus retensi
formal; perubahan itu ditandai `HUMAN-REVIEW-REQUIRED` dan butuh ADR. Pilot dev/demo boleh dengan
penerimaan ini.

---

## D-119 — Amandemen D-099: status `REJECTED`, seal saat keputusan, `maker` rolling deploy

**Keputusan (pemilik, 22 Okt 2026).**
1. Status versi produk: `DRAFT | ACTIVE | REJECTED`. Reject wajib menyimpan `reject_reason`; draft
   yang ditolak tidak dihapus (trigger lama melarang DELETE). D-099 diamandemen.
2. `sealed` diisi saat **approve/reject**, bukan saat binding pertama masuk. Binding hanya boleh
   masuk ke versi `DRAFT`; versi `ACTIVE`/`REJECTED` selalu `sealed = true` (CHECK).
3. `maker` diisi saat insert (`published_by` untuk baris lama, aktor pengaju untuk versi baru).
   Selama jendela rolling deploy, trigger `BEFORE INSERT` mengisi `maker = coalesce(maker,
   published_by)` supaya binary lama tidak gagal; trigger dihapus di migrasi contract setelah
   deploy (T-090).
4. `docs/ACCEPTED-LIMITS.md` mencatat freeze katalog produk sebelum T-086 dan konsekuensinya
   (pilot satu operator terblokir oleh `checker <> maker`).

**Asumsi yang diratifikasi.** `maker` = pengaju, `checker` = penyetuju/penolak, `checker <> maker`
berlaku juga untuk reject. `published_at` tetap berarti waktu pencatatan versi (nama historis;
utang nama dicatat di `MODULE.md`). Event `ProductPublished` hanya terbit saat approve; reject
hanya audit.

---

## D-120 — Contract auto-apply lewat allowlist (deviasi terkontrol dari spec §21.4)

**Konteks.** Spec §21.4 menyatakan migrasi contract "hanya dijalankan manual". Kenyataannya push ke
`main` = deploy otomatis lewat webhook, sehingga contract yang menunggu manual akan membuat setiap
deploy berikutnya merah (fail-closed) sampai operator turun tangan — termasuk deploy yang hanya
mengubah dokumen. Keputusan pemilik pada T-086: contract dipecah expand (`product/0003`) + contract
(`product/0004`) dan deploy boleh menjalankan contract **hanya** untuk id yang tercantum di
`ops/migrations/contract-auto.txt`.

**Keputusan.** (1) Allowlist adalah daftar putih yang di-review lewat PR; tidak ada flag di server.
(2) `deploy-vps.sh` memeriksa contract pada **setiap** deploy (T-092), bukan hanya saat repo
mengubah migrasi, karena skema bisa tertinggal akibat restore dump/`--down` manual. (3) Id di luar
allowlist = deploy berhenti; operator menjalankan `--contract` manual. (4) Sebelum contract
dijalankan, dump pra-deploy wajib ada; deploy mengambil dump `pre-contract` bila belum ada. (5) Bila
contract dibatalkan dengan `--down`, id harus dikeluarkan dari allowlist sebelum push berikutnya,
kalau tidak deploy akan memasangnya lagi.

**Konsekuensi.** Deviasi dari spec tercatat di sini dan di runbook; allowlist menambah satu langkah
review saat contract baru dipakai. Rollback layanan tetap tidak mengembalikan skema
(ACCEPTED-LIMITS).

---

## D-121 — T-087: asal-usul nilai seed sebagai artefak generate, bukan tabel DB

**Konteks.** O-066 meminta nilai seed dipakai pilot dengan kelas eksplisit (D-095). "Nilai darimana"
sebelumnya hanya komentar prosa di `params.yaml` — tidak bisa diverifikasi mesin — dan
`product.savings.grace_period_days` (kelas "belum punya semantik") masih disemai tanpa konsumen.

**Keputusan.** (1) Tiap definisi di `modules/*/seeds/params.yaml` **wajib** punya `provenance`:
`class` (taksonomi D-095: `teknis`, `kebijakan`, `komersial-konservatif`, `belum-bermakna`,
`regulasi-tidak-disemai`), `compliance` opsional (`NEEDS-COMPLIANCE-REVIEW`/`HUMAN-REVIEW-REQUIRED`),
`note` opsional. (2) `paramgen` menegakkan aturan: kelas `regulasi-tidak-disemai`/`belum-bermakna`
**dilarang** punya `default_pack`; kelas `komersial-konservatif`/`regulasi-tidak-disemai` wajib
`NEEDS-COMPLIANCE-REVIEW`. (3) Tabel asal-usulnya `packs/base/generated/param_provenance.md`,
dihasilkan `paramgen` dan diverifikasi `./task check` byte-per-byte — **bukan** tabel DB. (4)
`product.savings.grace_period_days` dikeluarkan dari katalog seed; baris katalog lama ditandai
`deprecated = true` lewat migrasi expand-only `product/0005` (DB kosong: no-op).

**Ditolak.** Tabel `platform.seed_provenance` (kolom `deprecated` di `param_definition` sudah ada,
dan artefak generate + `paramgen --check` cukup untuk verifikasi mesin tanpa skema/migrasi baru).
Mengarang semantik `grace_period_days` (D-095). Mengubah/menghapus `param_value` yang pernah
tersemai (riwayat effective-dated; definisinya sudah deprecated sehingga nilainya inert).

**Konsekuensi.** Menambah parameter tanpa kelas = `paramgen` gagal. Kelas `belum-bermakna` saat ini
kosong (0 definisi) — disediakan untuk parameter yang didefinisikan tetapi belum bermakna. Kelas
`regulasi-tidak-disemai` memuat lima kunci akrual produk (O-084). Guard drift hanya membandingkan
definisi **hidup**: `dbDefinitions` mengabaikan baris `deprecated` supaya definisi pensiun tidak
dilaporkan sebagai "key yatim".

---

## D-122 — Nomor migrasi modul baru: seq harus > seq tabel yang di-FK (urutan `(seq, modul, berkas)`)

**Konteks.** Urutan migrasi global adalah `(seq, nama modul, nama berkas)` (`tools/dbtools/lib.nim`),
jadi pada **seq yang sama** modul yang abjadnya lebih dulu berjalan lebih dulu. Rencana T-088
menaruh `deposit.account` di `deposit/0002`, padahal tabel itu mem-FK `product.product` /
`product.product_version` yang dibuat `product/0002`. Karena `deposit` < `product` menurut abjad,
`deposit/0002` berjalan sebelum `product/0002` dan migrasi gagal di DB kosong (jalur `db-tests` CI +
`resetTestSchemas` harness). Rencana yang sama sudah menyadari bahaya ini untuk `ledger.journal`
(mendasari "tabel ber-FK `ledger.journal` wajib seq ≥ 4") tetapi melewatkannya untuk `product`.

**Keputusan.** Migrasi modul baru yang mem-FK tabel modul lain **wajib** memakai seq lebih besar
daripada seq migrasi yang membuat tabel itu. Untuk `deposit`: schema+sequence di `deposit/0001`,
tabel akun di `deposit/0003` (setelah `product/0002`); nomor `0002` sengaja dilewati. Diverifikasi
`./task dbtools validate` (urutan tercetak tanpa DB) dan `itaccount` (migrasi dari skema kosong).

**Alternatif yang ditolak.** Menaruh FK di migrasi terpisah (memecah pembuatan tabel dari
invariannya) dan menunda tabel akun sampai 0004 (memaksa nomor transaksi T-088b naik). Keduanya
menambah berkas/kerumitan tanpa manfaat.

**Konsekuensi.** Nomor berkas modul bisa berlubang (mis. `deposit/0002` tidak ada) — itu
disengaja dan dijelaskan di `MODULE.md`. Aturan ini juga mengikat T-088b (`deposit/0004` +
`ledger/0012`) dan modul Fase 2+ lainnya.


---

## D-123 — Nomor rekening simpanan provisoris (10 digit, tanpa check digit)

**Konteks.** Spec §9.1(8) dan §10.5 mewajibkan format nomor bisnis dari parameter DB plus check
digit. T-088a memakai sequence + zero-pad 10 digit di domain, tanpa parameter dan tanpa check digit,
agar 088b (transaksi) tidak tertahan. Ini **deviasi sadar**, bukan bentuk final.

**Keputusan.** (1) Bentuk sementara ditandai `NEEDS-COMPLIANCE-REVIEW` di kode dan `MODULE.md`.
(2) Tidak ada kode lain (validasi input, PB, cetak, UI teller) yang boleh mengasumsikan lebar atau
isi nomor sampai O-095 ditutup. (3) Sebelum data anggota nyata atau UI teller (088d), pemilik/
compliance menetapkan format final; implementasinya memakai parameter
`deposit.account.number_format` dengan token `{seq:N}`/`{check}` (pola `party.cif.format`, Luhn yang
sudah ada di `party/domain/cif.nim`) plus migrasi data bila rekening sudah tercipta.
(4) `account_no` tetap `UNIQUE` dan nomor tidak dipakai ulang.

**Status persetujuan.** Ini keputusan rekayasa untuk menjaga 088a tetap maju, **bukan** persetujuan
pemilik/compliance atas format final. 088b/088d wajib berhenti untuk keputusan pemilik sebelum
memakai bentuk nomor di UI/cetak; O-095 tetap terbuka.

**Konsekuensi.** Nomor bisa berubah sebelum keputusan final; jangan mengukirnya di template cetak,
dokumen, atau asumsi validasi. `maxAccountNoLength` di domain hanya backstop, bukan kontrak. Test boleh mengunci bentuk
sementara (mis. panjang 10) sebagai karakterisasi, bukan kontrak bisnis.

---

## D-124 — PB memakai tabel `deposit.transfer`, bukan `transaction` + `counter_account_id`

**Konteks.** Rencana T-088 menaruh PB di `deposit.transaction` dengan `tx_type='TRANSFER'` dan
`counter_account_id`. Tabel itu sudah live (`deposit/0004`) dengan CHECK yang hanya mengizinkan
`CASH_DEPOSIT`/`CASH_WITHDRAWAL`; menambah tipe berarti `DROP CONSTRAINT` + CHECK baru, yang
dikategorikan destruktif oleh `dbtools` dan butuh jalur contract. Rencana juga mengasumsikan
jurnal bisa merepresentasikan perpindahan per rekening.

**Keputusan.** (1) PB punya tabel sendiri `deposit.transfer` (migrasi expand-only `0007`) dengan
`source_account_id`, `destination_account_id`, `amount`, `journal_id` UNIQUE, dan trigger
immutability. (2) Jurnal `DepositTransferred` memakai D 201 / K 201; di GL keduanya akun yang sama,
jadi jurnal **net-nol** — perpindahan per rekening hanya tercatat di `deposit.transfer`.
(3) Audit, jurnal, dan event `TransferPosted` diatribusikan ke cabang **sumber**; cabang tujuan
tidak menerima baris jurnal sendiri (batas dicatat di `ACCEPTED-LIMITS.md`).

**Konsekuensi.** Rekonsiliasi per rekening (T-101) wajib membaca `deposit.transfer`, bukan hanya
`journal_line`. Lintas cabang hanya boleh bila pemanggil memegang izin di kedua cabang; atribusi
cabang tujuan menunggu kebutuhan audit viewer (088d/audit).


---

## D-125 — Sesi kas teller: gerbang transaksi tunai, cash_movement, dan batas tanpa jurnal

**Konteks.** T-088b menulis transaksi tunai langsung (saldo + jurnal sinkron) tanpa konsep sesi.
Spec §11.6 menuntut gate EOD "semua sesi teller tutup & kas seimbang", dan `expected_cash` tidak
punya arti tanpa sesi + arus laci. T-093 menambahkan itu di modul baru `teller`.

**Keputusan.**
1. **Transaksi tunai wajib sesi `OPEN`** milik pemanggil di cabang rekening pada `business_date`
   yang sama; tanpanya 409 `no_open_session`. Bila sesi OPEN ada tetapi tanggal bisnisnya lain →
   409 `session_business_date_mismatch` (sesi lama harus ditutup dulu; `GET current` sengaja
   menampilkannya dan menyertakan `businessDate`). **PB tidak wajib sesi** (tidak menggerakkan uang fisik).
2. **Gerbang berada di dalam blok `withIdempotency`**: replay yang sah setelah sesi ditutup harus
   mengembalikan respons tersimpan, bukan 409 palsu. Gerbang membaca sesi `FOR KEY SHARE` supaya
   penutupan (`FOR UPDATE`) menunggu transaksi in-flight dan movement tidak hilang dari `expected_cash`.
3. **`cash_movement` hanya 2 tipe** (`CASH_IN`/`CASH_OUT`); opening float & counted cash adalah kolom
   sesi (D-095: tidak ada tipe tanpa pemakai). Satu transaksi tunai = satu baris movement
   (`transaction_id` UNIQUE FK `deposit.transaction`), ditulis dalam satu `withDbTx` dengan transaksi.
4. **`note` sesi dipersist** saat buka dan tutup (kolom 200 karakter); respons buka/current/tutup
   menyertakan `businessDate` dan `note`. Tutup memeriksa kepemilikan **sebelum** status, supaya
   `session_not_owned` deterministik untuk non-pemilik.
4. **Satu sesi `OPEN` per (cabang, teller)** dijaga partial unique index; jalur repo memakai
   `INSERT ... ON CONFLICT ... WHERE status='OPEN' DO NOTHING` agar balapan dua buka → 409, bukan 500.
5. **Vault `FOR UPDATE` implisit** (`UPDATE ... WHERE balance >= ?`, satu baris per cabang), tidak
   boleh negatif; tutup menambah vault sebesar `counted_cash` (uang fisik), bukan `expected_cash`.
6. **Tanpa jurnal GL** untuk kas teller/variance: COA baru adalah keputusan akuntansi (batas di
   `ACCEPTED-LIMITS.md`, item O-097). Top-up vault di luar scope (T-107).
7. `GET /teller/sessions/current` tanpa sesi memilih **404** `session_not_open` (bukan 200 `null`).

**Alternatif yang ditolak.** Kolom `session_id` di `deposit.transaction` (menambah konsep teller ke
modul `deposit`, melanggar pemisahan D-124) dan menghitung sesi dari waktu transaksi (tidak bisa
membedakan sesi pagi/siang, tanpa audit arus laci). Menaruh gate sesi di luar `withIdempotency`
(ditolak karena replay sah jadi 409).

**Konsekuensi.** `expected_cash` hanya benar bila **setiap** transaksi tunai menulis movement →
dijaga satu `withDbTx` + test paritas. Rollback binary setelah 093b memerlukan tutup-sesi dahulu
(batas dicatat). Deploy 093a/093b harus satu rilis bila belum ada klien teller; di repo ini memang
belum ada.
