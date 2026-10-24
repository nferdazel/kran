# Audit codebase KRAN — 24 Oktober 2026

Audit menyeluruh sebelum Fase 3 (daycloser). Delapan reviewer bekerja paralel pada aspek berbeda
(keamanan/OWASP, ledger & uang, skema & migrasi, API & kontrak, frontend, ops/CI/supply chain,
arsitektur & performa, kualitas test & gate). Setiap temuan wajib punya lokasi dan bukti; yang tidak
bisa dibuktikan ditandai `HYPOTHESIS`. Orchestrator memverifikasi ulang semua kandidat
BLOCKER/MAJOR; yang gagal diverifikasi tidak masuk laporan ini.

- **Commit yang diaudit:** `2a3c101` (setelah T-057).
- **Sifat laporan:** temuan **belum diperbaiki**. Rencana remediasi ada di §6 dan di `BACKLOG.md`.
- **Bukan audit kepatuhan.** Tidak ada klaim bahwa sistem ini patuh regulasi; register regulasi
  tetap menunggu verifikasi compliance officer (O-001).

## 1. Ringkasan

| Severity | Jumlah | Inti |
|---|---|---|
| BLOCKER | 3 | gate CI yang tidak menguji apa pun; penghapus schema tanpa penjaga DB; eskalasi hak akses ke `platform_admin` |
| MAJOR | 15 | sesi kas bisa terkunci permanen; DoS login; 500 tanpa log; pool thread/koneksi tidak seimbang; N+1; XFF ke `inet`; PB tak bisa dipilih; 4 layar tanpa axe; image deploy menumpuk; versi pnpm berbeda; FK jurnal vault hilang; `ci` hijau tanpa DB; 121 unit test tak digerbang; spec mengklaim kontrol yang tidak ada |
| MINOR | 33 | lihat §4 |
| NIT | 8 | lihat §4 |

Tema yang berulang, dan ini yang paling penting:

1. **Beberapa kontrol yang diklaim dokumen tidak ada di kode.** Break-glass `platform_admin`
   (ACCEPTED-LIMITS §4c/O-102), "trigger + privilege" untuk imutabilitas jurnal (spec §9.1(3)),
   kompensasi deploy spec §21.7 (digest, tag `:<sha>`, `releases/<sha>/`), dan "e2e/a11y di CI"
   (ACCEPTED-LIMITS/M2). Semuanya berbunyi seperti sudah ada.
2. **Gate punya lubang senyap.** CI tidak memberi DB ke job web (9 dari 11 spec skip), unit test web
   tidak dijalankan gate mana pun, dan `./task ci` tetap mencetak hijau tanpa `KRAN_DATABASE_URL`.
3. **Batas kepercayaan tidak dijaga di tepi.** `X-Forwarded-For` dan `X-Request-Id` dari klien masuk
   audit (satu di antaranya lewat cast `inet` di dalam transaksi), `Content-Type` tidak diperiksa,
   tidak ada rate limit login.
4. **Kegagalan infrastruktur tampil sebagai 500 telanjang tanpa log**, karena `router.errorHandler`
   tidak pernah dipasang dan `PoolError` bukan `DbError`.
5. **Arsitektur bergeser tanpa penjaga**: `apps/` di-skip `archcheck` padahal di situ ~6,8k baris
   logika use-case; lima modul tidak punya lapisan `application/`.

## 2. BLOCKER

| ID | Lokasi | Temuan | Bukti | Perbaikan |
|---|---|---|---|---|
| BLK-1 | `.github/workflows/ci.yml:133-184`; `apps/web/tests/e2e/*.spec.ts:15-19` | Job `web-e2e` tidak punya Postgres/`KRAN_DATABASE_URL`, sementara 9 dari 11 spec memanggil `test.skip(!process.env.KRAN_DATABASE_URL, …)` di module level. Yang benar-benar berjalan di CI hanya `a11y.spec.ts` (halaman `/`) + `keyboard.spec.ts`. Login/maker-checker, teller, vault, ledger, print, zoom **tidak pernah digerbang**. | `grep -n 'services:\|KRAN_DATABASE_URL' ci.yml` → hanya job `db-tests`; `head -22 teller.spec.ts` → skip global | Beri `services: postgres:18` + migrate/seed ke job web (atau job `e2e-db`), dan gagalkan job bila jumlah test yang dieksekusi di bawah ambang. |
| BLK-2 | `tools/dbtools/lib.nim:463-480` | `resetTestSchemas` menjalankan `DROP SCHEMA … CASCADE` untuk semua modul **tanpa penjaga nama DB**, padahal `seed --dev` dijaga `devSeedDbAllowed` (`:605`, wajib `_dev`/`_test`). Satu `KRAN_DATABASE_URL` salah arah dari mesin developer = database pilot hilang. | Fungsi tidak menerima/memeriksa URL; 34 suite memanggilnya saat load | Pakai penjaga yang sama (`_dev`/`_test`) di `resetTestSchemas`, dan tolak dengan pesan jelas. |
| BLK-3 | `apps/api/src/handlers_users.nim:147-203` → `modules/platform/infrastructure/auth_service.nim:485-506` | `POST /users/{id}/roles` tidak melarang **self-grant** dan tidak memeriksa apakah pemberi izin memegang izin peran yang diberikan. `ops_admin` harian memegang `platform.user.manage` (`platform/0032:36-40`), dan `platform_admin` sengaja tidak dipasangkan SoD → satu sesi `ops_admin` dapat memberi dirinya `platform_admin` (semua izin: kas, ledger, param, baca PII) tanpa alasan dan tanpa approver. | `handleAssignRole` hanya `requirePermission(platform.user.manage)`; `grantUserRole` memeriksa role ada/scope/duplikat/SoD, bukan self-grant | Tolak `userId == principal`; syaratkan pemberi memegang semua izin peran itu, atau alur dua-orang dengan `reason` wajib untuk `platform_admin`. |

## 3. MAJOR

### 3.1 Data & akuntansi

| ID | Lokasi | Temuan | Perbaikan |
|---|---|---|---|
| LED-1 | `apps/api/src/handlers_ledger.nim:336-403`; `handlers_teller_sessions.nim:320-347` | Menutup periode saat ada sesi kas `OPEN` membuat sesi itu **tidak bisa ditutup selamanya**: jurnal penutupan sesi ber-`businessDate` sesi ditolak trigger periode, transaksi rollback, dan unique index `(branch_id, teller_user_id) WHERE status='OPEN'` menghalangi sesi baru. Kas laci/variance tidak pernah masuk GL, tanpa jalur reopen. | Tolak close periode bila ada sesi OPEN di rentangnya; pra-cek `periodOpenFor(session.businessDate)` di close sesi → 409, bukan 500. |
| DB-1 | `docs/runbooks/db-roles.md:51-56` | `kran_runtime` diberi `UPDATE, DELETE` di **semua** tabel; hanya `platform.audit_log` yang dicabut. Imutabilitas `ledger.journal`/`journal_line` bergantung pada trigger saja (spec §9.1(3) menulis "trigger **+ privilege**"), dan baris `SUPERSEDED` di `platform.param_value` (riwayat efektif-dated) bisa dihapus. | `REVOKE UPDATE, DELETE, TRUNCATE` pada tabel immutable + `REVOKE DELETE` pada `param_value`; kecualikan dari `ALTER DEFAULT PRIVILEGES`; terapkan lewat migrasi, bukan hanya runbook. |
| DB-2 | `modules/teller/migrations/0035:38` | `teller.vault_topup_request.journal_id` tanpa FK ke `ledger.journal` dan tanpa `UNIQUE`, padahal pola yang sama di `deposit/0004:24-27` dan `0007:27-30` punya keduanya. APPROVED bisa menunjuk jurnal yang tidak ada / dipakai dua request. | Migrasi expand: FK `NOT VALID` → `VALIDATE`, plus `UNIQUE (journal_id) WHERE journal_id IS NOT NULL`. |
| LED-2 | `apps/api/src/journal_ownership.nim:24-39`; `apps/api/src/main.nim` (`post-opening-balance`) | Jurnal saldo awal vault (`source_event='LedgerCashOpening'`, `D 101.1 / K 203`) tidak dikenali sebagai milik subledger → bisa dibalik lewat buku besar; GL `101.1` nol sementara `teller.vault` tetap. `ctl post-opening-balance` juga tidak menyesuaikan `teller.vault` sama sekali. | Tambahkan event itu ke deteksi kepemilikan; buat `post-opening-balance` memperbarui vault dalam transaksi yang sama. |
| DB-3 | `modules/platform/migrations/0012:21` | `platform.user_mfa.secret_enc text NOT NULL` tanpa `CHECK (… LIKE 'kran:enc:v1:%')`, tidak konsisten dengan semua kolom PII lain — rahasia TOTP bisa tersimpan plaintext tanpa protes DB (melanggar properti D-063/D-069). | CHECK `NOT VALID` → `VALIDATE`. |
| DB-4 | `modules/ledger/migrations/0001:43-63` | `ledger.period` sepenuhnya mutable: `CLOSED → OPEN` dan perubahan `starts_on/ends_on` tidak diblokir, sehingga penutupan periode bisa dibatalkan dan posting mundur diizinkan lagi. | Trigger `BEFORE UPDATE`: hanya `OPEN→CLOSED`; larang ubah rentang bila sudah ada jurnal di dalamnya. |
| DB-5 | `modules/ledger/infrastructure/journal_repo.nim:30-33` | `moneyOf` membaca `numeric(24,2)` dengan `parseBiggestInt` + aritmetika tanpa cek overflow. Kolom bisa memuat 22 digit, `Money` int64 ~19 digit → nilai besar membungkus diam-diam, bertentangan dengan kontrak kernel. | Pakai `moneyFromString`/`checkedInt`; tambah CHECK rentang uang di DB. |

### 3.2 Keamanan

| ID | Lokasi | Temuan | Perbaikan |
|---|---|---|---|
| SEC-1 | `apps/api/src/handlers_auth.nim:39-67`; `shared/platform-lib/db/config.nim:55` | Tidak ada rate limit di `POST /auth/login`. Setiap percobaan menjalankan PBKDF2 600k iterasi **sambil memegang satu koneksi pool** (default 8). Flood login murah = CPU habis + pool habis untuk semua rute; lockout hanya per akun, jadi spraying lintas akun bebas. | Token bucket per-IP + global, semaphore konkurensi login **sebelum** KDF, 429 + `Retry-After`. |
| SEC-2 | `apps/api/src/identity.nim:56-61`; `modules/platform/infrastructure/audit_repo.nim:48` | `X-Forwarded-For` diambil apa adanya lalu di-cast `::inet` **di dalam transaksi bisnis**. Header tidak sah → `DbError` → seluruh penulisan yang diaudit gagal 500; nilai spoof masuk rantai audit (tergantung Caddy). | Validasi dengan `parseIpAddress`, fallback `remoteAddress`, batasi panjang; percaya XFF hanya dari proxy tepercaya. |
| SEC-3 | `apps/api/src/handlers_mfa.nim:49` vs `handlers_auth.nim`/`handlers_detail.nim` | `Cache-Control: no-store` hanya di endpoint MFA. Login/sesi, unmask PII, slip, dan statement tidak punya direktif cache — browser cabang/kios dapat menyimpan NIK/alamat terdekripsi. | Set `no-store` di helper respons JSON untuk seluruh `/api/v1`. |
| SEC-4 | `apps/api/src/events.nim:389-406` | Upgrade WebSocket menerima koneksi mana pun yang cookie-nya sah, tanpa cek `Origin`/`Host`; satu-satunya penahan adalah `SameSite=Strict`. | Tolak upgrade bila `Origin` ≠ origin situs terkonfigurasi. |
| API-1 | `apps/api/src/server.nim:62-78`; `shared/platform-lib/db/pool.nim:35,265` | `router.errorHandler` tidak pernah dipasang dan handler hanya menangkap `DbError`/`ValueError`. `PoolError` (timeout ambil koneksi, deadline DB, koneksi mati) lolos → Mummy menjawab **500 tanpa body dan tanpa log**; klien `isProblem()` tidak mengenalinya. | Pasang `router.errorHandler` → `problem+json` + log; map `PoolError` → 503 + `Retry-After`; tambah test. |
| API-2 | `apps/api/src/handlers_auth.nim:76-77,193-195`; `apps/api/src/readiness.nim:110` | Beberapa respons 500 membocorkan teks exception internal (kebijakan keamanan, pesan libpq berisi host/port/user) — `detail` juga tidak sesuai komentar "tanpa kredensial". | `detail` tetap, `e.msg` ke log server. |

### 3.3 Operasional & rilis

| ID | Lokasi | Temuan | Perbaikan |
|---|---|---|---|
| OPS-1 | `ops/scripts/deploy-vps.sh:119-123` | `flock` gagal → `exit 0`. Webhook melihat sukses, deploy kedua tidak pernah jalan, produksi tertinggal dari `main` tanpa sinyal. Kontrak emas workspace §3.2 mewajibkan `exit 1`. | `exit 1` (dan/atau simpan rev tertunda untuk dijalankan setelah lock lepas). |
| OPS-2 | `ops/scripts/deploy-vps.sh:419-441` vs `:271-278` | `prune_images` hanya memangkas tag `^localhost/kran-api:[0-9a-f]{12}$`, padahal build tidak pernah membuat tag SHA (`:local`/`:prev` saja). Kode mati; setiap deploy meninggalkan satu image dangling tanpa pemangkasan. | Pangkas image dangling secara eksplisit (atau simpan image ID `:prev`), lalu hapus regex SHA. |
| OPS-3 | `deploy-vps.sh:397`; `package.json`; `pnpm-workspace.yaml:14-18` | Tidak ada `packageManager`; deploy memakai `corepack pnpm` tanpa versi, CI memakai pnpm 11. Image produksi bisa dibangun pnpm berbeda — dan pnpm lama mengabaikan `minimumReleaseAge`/`allowBuilds`, mem-bypass cooldown supply chain. | Tambah `"packageManager": "pnpm@11.x.y"`, hapus `version:` dari action, pakai versi yang sama saat deploy. |
| OPS-4 | `deploy-vps.sh:449-478` | Auto-rollback tidak memeriksa `/readyz` setelah rollback; kegagalan rollback dilaporkan sebagai rollback selesai. | Ulangi poll setelah rollback, catat dua keadaan, `exit 1` bila tetap tidak sehat. |
| OPS-5 | `deploy-vps.sh:223` (unit dipasang sebelum gate FREEZE/MIGRATION) | `die` setelah `sync_units` meninggalkan unit baru di disk; `daemon-reload`/reboot berikutnya bisa mengaktifkannya pada image lama. | Pasang unit setelah gate, atau `trap` pemulihan. |
| OPS-6 | `ops/env/kran-prod.env.example:38` | Contoh memberi path **host** (`/srv/qouver/apps/kran/env/kran-kek.key`), padahal unit me-mount ke `/run/secrets/kran-kek.key`. Nilai dokumentasi ini membuat container exit 2. | Dokumentasikan dua konteks; nilai untuk container = path mount. |
| OPS-7 | `ops/scripts/backup-pre-deploy.sh:15-22` | Dump pra-deploy dan pra-contract tanpa retensi — tumbuh selamanya. | `find … -mtime +N -delete` (mis. simpan 10) + log. |
| OPS-8 | `docs/spec/kran-prd-techspec.md:1074` | Spec mengklaim kompensasi "base image dipin (digest), tag `:<sha>`, hash binary di `releases/<sha>/`"; kenyataannya base image `debian:bookworm-slim` (tag mutable), tidak ada tag SHA, tidak ada `releases/`. | Implementasikan, atau koreksi spec + catat deviasi di `DECISIONS.md`/`ACCEPTED-LIMITS.md`. |
| OPS-9 | `apps/api/Dockerfile:19,29-32,48` | Base image tidak dipin digest; tarball Nim diunduh tanpa verifikasi checksum. | `FROM …@sha256:…`; verifikasi `sha256sum` tarball. |
| OPS-10 | `ops/webhook/hook.kran.json.example:6-24` | HMAC hanya menutup body; tidak ada filter event/repository, tidak ada perlindungan replay. | `trigger-rule` untuk `X-GitHub-Event: push` + nama repo yang diharapkan; tolak delivery basi. |

### 3.4 Arsitektur, performa, frontend, test

| ID | Lokasi | Temuan | Perbaikan |
|---|---|---|---|
| ARC-1 | `apps/api/src/server.nim:89`; `mummy.nim:1476`; `config.nim:55` | Mummy default `workerThreads = countProcessors()*10` (40 di 4 vCPU), pool default 8. Lebih dari 8 permintaan ber-DB → tunggu 5 dtk lalu `PoolError` (lihat API-1). `databaseProbe` membuat pool **sendiri** (koneksi ~2×) dan `/readyz` bisa hijau walau pool request penuh. | Set `workerThreads ≤ poolSize`, hitung pool dari worker + pump, pakai `app.pool` di readiness. |
| ARC-2 | `apps/api/src/handlers_deposit.nim:320-325`; `handlers_users.nim:108` | N+1: `authorizedAtBranch` (2 query) per baris rekening (≤200 baris); `userJson` query role per pengguna. | Muat grant + pasangan konflik sekali per request; join role di `listUsers`. |
| ARC-3 | `tools/archcheck/lib.nim:63`; `modules/*` | `apps/` di-`catSkip` padahal ~6,8k baris logika use-case tinggal di sana; deposit/ledger/party/product/teller tidak punya `application/`. Penulisan jurnal terduplikasi di 4 tempat. | Pindahkan orkestrasi ke `application/` modul; tambah aturan archcheck untuk `apps/api/src` (larang SQL/`db_connector`). |
| UI-1 | `apps/web/src/routes/app/teller/+page.svelte:1539` | `fieldset disabled={postingBlocked}` membungkus radio mode; `postingBlocked = blocked && mode != "TRANSFER"`. Tanpa sesi kas, pengguna tidak bisa memilih PB lewat pointer/keyboard — hanya lewat F9. | Pindahkan `disabled` ke field nominal/narasi/submit, jangan ke pemilih mode. |
| UI-2 | `login/+page.svelte:45-47`; `app/password/+page.svelte:35-39` | `await api.POST` tanpa `try/catch/finally`: kegagalan jaringan membuat `submitting` tertahan `true` — tombol disabled permanen, tanpa pesan. | `try/catch/finally` seperti layar lain. |
| UI-3 | `apps/web/src/routes/app/{+page,password/+page}.svelte` | Logout hanya ada di `/app` (butuh `platform.param.read`) dan `/app/password`. Teller/kasir di `/app/teller` atau `/app/ledger` tidak bisa mengakhiri sesi di terminal bersama. | Taruh identitas + ubah sandi + logout di shell `/app`. |
| UI-4 | `apps/web/tests/e2e/` | `/app/users`, `/app/products`, `/app/ledger/admin`, `/app/accounts/open` (T-115…T-121) tidak punya spec Playwright/axe; axe baru mencakup login, ledger, teller, vault, palette, print, password, params. | Tambah axe ×2 tema ×2 locale + satu alur keyboard per layar. |
| TST-1 | `task:334-381,443` | `./task ci` tetap mencetak "CI green" walau integrasi dan e2e di-skip karena `KRAN_DATABASE_URL` kosong. | Dalam mode `ci`, gagal bila test ada tetapi DB tidak diset (flag opt-out untuk dry run). |
| TST-2 | `apps/web/tests/unit/*` (10 berkas, 121 test); `task:360` | Tidak ada gate yang menjalankan unit test `apps/web`; paket itu bahkan tidak punya dependensi/script vitest — selama ini dijalankan manual lewat binary `packages/ui`. | Tambah vitest di `apps/web` + jalankan dari `cmd_e2e`/`cmd_ci`. |
| API-3 | `tools/openapi/lib.nim:81-107` | Contract test hanya membandingkan method/path/operationId, tidak pernah respons. 45 dari 60 operasi ber-auth tidak mendeklarasikan `501`, 49 tidak mendeklarasikan `405`, padahal keduanya benar-benar dikembalikan. | Perluas pemeriksa + regenerate klien. |

## 4. MINOR & NIT (ringkas)

| ID | Sev | Lokasi | Temuan |
|---|---|---|---|
| DB-6 | MINOR | `tools/dbtools/lib.nim:76-190` | Penjaga expand-only hanya melihat kata pertama per statement; `UPDATE`/`DELETE` top-level dan DDL di dalam `DO $$ … $$` tak terlihat. |
| DB-7 | MINOR | `tools/dbtools/lib.nim:482-530` | Drift checksum dideteksi di dalam loop apply, setelah file sebelumnya ter-commit; `--dry-run` melewati drift sepenuhnya. |
| DB-8 | MINOR | `platform/0002:34-35`, `0011:26-27` | `audit_log.prev_hash` tidak `UNIQUE`; percabangan rantai hanya terdeteksi saat verifikasi manual. |
| DB-9 | MINOR | `ledger/0003:40` | `journal_line.gl_account` tanpa index, padahal FK dan join laporan memakainya. |
| DB-10 | MINOR | `product/0002:87,112`; `party/0002:80` | Trigger imutabilitas tanpa `BEFORE TRUNCATE` pada beberapa tabel (TRUNCATE melewati trigger baris). |
| DB-11 | NIT | `handlers_audit.nim:47-58` | Filter `action LIKE 'x%'` tanpa index; scan mundur seluruh tabel sebelum `LIMIT`. |
| DB-12 | NIT | — | Belum ada keputusan retensi/partisi untuk `platform.audit_log`, `inbox`, `outbox` (D-072 hanya journal). |
| SEC-5 | NIT | `packages/contracts/openapi/kran-api.yaml:2908` | Kontrak menulis cookie `SameSite=Lax`; implementasi `Strict` (baris 207/227 sudah Strict). |
| SEC-6 | NIT | `.github/workflows/ci.yml` | Action pihak ketiga dipin ke tag mayor mengambang (`@v4`, `@v2`), bukan commit SHA. |
| API-4 | MINOR | `apps/api/src/http_util.nim:36-46` | Body JSON diterima tanpa memeriksa `Content-Type`; tidak ada 415 (kontrak mendeklarasikan `application/json`). |
| API-5 | MINOR | `handlers_deposit.nim:213-218` | `Idempotency-Key` tidak sah → 500 (handler lain 400). |
| API-6 | MINOR | `main.nim:1146`; `server.nim:89` | Tidak ada access log per request (method, rute, status, ms, traceId); logger terstruktur hanya 3 baris startup. |
| API-7 | MINOR | `handlers_audit.nim:23-24` | `GET /audit` hanya `limit` (maks 200), tanpa cursor — baris lama tidak bisa ditinjau lewat API (spec §13 minta cursor; deviasi hanya terdaftar untuk COA/D-100). |
| API-8 | MINOR | `handlers_*` (detail party) | Upsert PII tanpa ETag/`If-Match` → dua editor back-office saling menimpa diam-diam (spec §13). |
| API-9 | NIT | `apps/api/src/idempotency.nim:47-62` | Fingerprint mem-hash string body apa adanya; retry dengan urutan key berbeda → 409, bukan replay. |
| API-10 | NIT | `apps/api/src/problem.nim:77-81` | `X-Request-Id` klien diterima verbatim (tanpa batas panjang/charset) → polusi `correlation_id`. |
| API-11 | MINOR | `modules/platform/domain/param.nim:107-112` | `minimum`/`maximum` tidak ditegakkan untuk parameter money/rate (nilai JSON string); `limit_withdrawal="-1.00"` lolos submit/approve. |
| LED-3 | MINOR | `modules/platform/infrastructure/idempotency_repo.nim:31-35` | Klaim kedaluwarsa dihapus lalu dianggap baru; top-up vault/`POST /deposit/accounts` tanpa kunci alami → duplikat setelah TTL. |
| LED-4 | MINOR | `itsession.nim:317`; `itapi_teller_sessions.nim:526` | Uji balapan tutup sesi tidak memaksa overlap (tanpa holder lock + `pg_blocking_pids`). |
| LED-5 | MINOR | `itauth.nim:199`; `itapi_auth.nim:800` | Lockout dibuktikan di repo dan `/auth/password`, bukan lewat N percobaan `POST /auth/login`. |
| LED-6 | MINOR | `tprop_money.nim:9`; `propgen.nim:19-21` | Properti memakai satu seed tetap, tanpa shrinking; batas `|v|≤1e12` membuat overflow penjumlahan Money tidak pernah diuji. |
| LED-7 | MINOR | `apps/web/tests/e2e/vault.spec.ts:276` | Hanya `/app/vault` diuji pada 390px; teller/ledger/print/open-account tidak. |
| ARC-4 | MINOR | `apps/api/src/events.nim:242-261` | Ghost subscriber: `subscribe` dipanggil walau socket sudah dibuang/`clientId == 0`, entri tak pernah dihapus. |
| ARC-5 | MINOR | `apps/api/src/posting.nim:149-163` | Semua `CatchableError` menghabiskan percobaan → `DEAD`; tidak ada `ctl outbox-redrive` (pemulihan lewat SQL manual). |
| ARC-6 | MINOR | `modules/deposit/infrastructure/account_repo.nim:65` | Modul membaca tabel modul lain (`JOIN product.product`); tidak terlihat archcheck. |
| ARC-7 | MINOR | `modules/platform/application/param_cache.nim` | Cache parameter lengkap hanya dipakai test; komentar menunjuk `param_watcher.nim` yang tidak ada. |
| ARC-8 | MINOR | `apps/api/src/posting.nim:200-205` | Worker `while true` tanpa handler SIGTERM/`pool.close()`; stop container memotong batch. |
| ARC-9 | MINOR | `modules/party/infrastructure/party_repo.nim:78` | `ILIKE '%…%'` tanpa index trigram (ekstensi `pg_trgm` terpasang tapi tak dipakai). |
| ARC-10 | MINOR | `modules/platform/migrations/0002:70-73` | Advisory lock di trigger audit menyerialkan **semua** transaksi teraudit sampai COMMIT. |
| ARC-11 | NIT | `realtime.nim:115`; `events.nim:190` | Komentar mengklaim resume memakai `lastSentId`, padahal hanya dipakai test. |
| ARC-12 | NIT | `db/config.nim:16` | Docstring bilang cek `PQstatus`; kenyataannya `select 1` per acquire. |
| UI-5 | MINOR | vault/users/products/accounts-open | Tidak ada penanganan `401 → /login`; sesi kedaluwarsa menyisakan UI interaktif yang mati. |
| UI-6 | MINOR | `lib/app/format.ts:45-47` | Tanggal bisnis dibangun tengah malam UTC lalu diformat zona browser → bergeser sehari di zona negatif. |
| UI-7 | MINOR | `app/ledger/+page.svelte:124` | "Hari ini" memakai tanggal browser UTC, bukan tanggal bisnis cabang. |
| UI-8 | MINOR | `+layout.svelte:178` | `{#key locale}` me-remount seluruh subtree: ganti bahasa membuang input form dan konteks. |
| UI-9 | MINOR | `app/+page.svelte`, `ledger/admin` | Tabel scroll horizontal tanpa `role="region" tabindex="0" aria-label"`, tidak terjangkau keyboard. |
| UI-10 | MINOR | `accounts/open/+page.svelte:79` | Pencarian debounce tanpa urutan request/`AbortController`; timer tidak dibersihkan saat unmount. |
| UI-11 | MINOR | `packages/ui/src/components.css` | `prefers-reduced-motion` hanya untuk satu aturan; transisi lain tetap jalan. |
| UI-12 | MINOR | `app/+page.svelte:179` | `Number(text)` tanpa cek finite → `NaN` menjadi `null` di body, 400 tanpa pesan field. |
| UI-13 | MINOR | `app/password/+page.svelte:81` | "Lanjut" menuju `/app` yang bisa 403 untuk teller. |
| OPS-11 | MINOR | `deploy-vps.sh:449-457` | Health gate hingga 75 dtk (spec 30-60) dan tidak memverifikasi revisi yang melayani. |
| OPS-12 | MINOR | `ops/scripts/backup-postgres.sh:45-79` | Dump tidak dienkripsi dan hanya di host yang sama; tidak tercatat sebagai batas. |
| OPS-13 | MINOR | `.github/workflows/ci.yml` | Tidak ada job yang membangun `Dockerfile` API; regresi image baru terlihat saat deploy produksi. |
| OPS-14 | MINOR | `ops/caddy/Caddyfile.kran.example:32-34` | Tanpa `request_body` limit dan timeout proxy. |
| OPS-15 | MINOR | `ops/systemd/*.container` | Tanpa `ProtectSystem`/`PrivateTmp`/`MemoryMax`/`HealthCmd`; API menggantung pasca-start tak terlihat systemd. |
| OPS-16 | NIT | `deploy-vps.sh:54-60` | Env file di-source tanpa memeriksa mode/owner 600; bukti rilis (`releases/<sha>/`, hash binary) tidak ada. |
| DOC-1 | MINOR | `docs/ci-jobs.md:51` | Menulis `itplatform` hanya menghapus schema `platform`; sekarang semua schema modul. |

## 5. Yang diperiksa dan dinilai sehat

Ini bukan pujian kosong — semuanya diverifikasi di kode/test:

- **Jurnal**: tidak seimbang, satu baris, nol baris, dan nilai negatif ditolak DB; imutabilitas
  UPDATE/DELETE/TRUNCATE; posting ke akun non-postable/periode tertutup ditolak trigger; balapan
  tutup-periode vs posting ditutup `FOR SHARE`; satu pembalik per jurnal, pembalik-dari-pembalik
  ditolak, jurnal subledger ditolak 409.
- **Uang**: tidak ada float; `Money`/`Rate` checked; parser menolak sub-sen; properti round-trip,
  asosiatif, dan batas galat `applyRate` nyata.
- **Saldo & konkurensi**: cache dan jurnal selalu satu transaksi; penarikan memakai satu
  `UPDATE … WHERE balance - ? >= min`; PB mengunci dua baris dalam urutan `account_id`.
- **Password & sesi**: PBKDF2 600k + salt CSPRNG + perbandingan konstan; pesan seragam dan dummy
  hash untuk user tak dikenal; lockout per akun; token 256-bit, DB hanya menyimpan SHA-256;
  cookie `HttpOnly; Secure; SameSite=Strict`; `mustChangePassword` ditegakkan terpusat.
- **Otorisasi rute**: semua rute mutasi/baca memanggil `requirePrincipal` + `requirePermission`;
  objek ber-cabang memeriksa `authorizedAtBranch` dengan cabang objek itu.
- **Tidak ada SQL injection** yang ditemukan: semua nilai di-bind; SQL dinamis hanya menyambung
  daftar kolom konstanta.
- **Kripto field**: AES-256-GCM, DEK per tabel, AAD nama tabel, nonce CSPRNG, KEK mode 600
  divalidasi saat start, unmask butuh izin + alasan + audit tanpa plaintext.
- **Rantai audit** dihitung di trigger di bawah advisory lock; UPDATE/DELETE/TRUNCATE ditolak.
- **Deploy**: ref guard fail-closed, `flock`, `git fetch`+`reset --hard`, urutan dump→migrasi→gate,
  tidak ada secret di argv/log, container non-root `DropCapability=ALL`.
- **Batas input**: Mummy 1 MB body / 8 KB header; `std/json` kedalaman 1000 (diuji dengan probe);
  daftar dibatasi 20–500 baris dan menolak permintaan terlalu lebar.
- **Gate yang benar-benar membandingkan**: `tcontract` membandingkan tabel rute dengan YAML dua arah;
  `tapi` menjalankan server Mummy nyata dan memvalidasi skema respons; `tdbtools` menguji penjaga
  expand-only, contract marker, dan atomicity.
- **Playwright**: `retries: 0`, `forbidOnly`, `workers: 1`, tanpa `waitForTimeout` di spec UI.

## 6. Rencana remediasi (usulan, belum dikerjakan)

Urutan berdasarkan risiko, bukan kemudahan. Setiap batch = satu task backlog.

| Batch | Task | Isi | Kenapa lebih dulu |
|---|---|---|---|
| A | T-126 | BLK-1, TST-1, TST-2, G-11: CI `web-e2e` ber-DB + ambang test + vitest web + `ci` gagal tanpa DB | Gate yang bohong membuat semua perbaikan lain tidak terbukti |
| A | T-127 | BLK-2: penjaga `_dev`/`_test` di `resetTestSchemas` | Satu salah URL = database pilot hilang |
| B | T-128 | BLK-3 + SEC-1..SEC-4 + API-2: self-grant, rate limit login, no-store, Origin WS, detail 500 | Kontrol akses & DoS |
| B | T-129 | LED-1, LED-2, DB-1..DB-5: sesi/periode, grant runtime, FK vault, CHECK MFA, periode immutable, `moneyOf` | Integritas kas & buku besar |
| C | T-130 | API-1, ARC-1, ARC-2, SEC-2, API-6: errorHandler+PoolError, worker/pool, N+1, XFF, access log | 500 tanpa jejak dan kelaparan pool |
| C | T-131 | OPS-1..OPS-10: kontrak deploy, retensi image/dump, pnpm pin, rollback gate, unit order, KEK doc, klaim spec §21.7 | Deploy yang gagal senyap |
| D | T-132 | UI-1..UI-4 + UI-5/UI-6/UI-11: PB terkunci, error jaringan, logout di shell, axe 4 layar, 401 terpusat, tanggal UTC, reduced motion | UX operator pilot |
| D | T-133 | API-3/4/5/7/8, DB-6..DB-12, ARC-3..ARC-12, LED-3..LED-7, UI-7..UI-13, OPS-11..OPS-16 | Sisa MINOR/NIT |

Batch A dan B wajib selesai sebelum Fase 3; C dan D boleh berjalan paralel dengan persiapan Fase 3,
tetapi OPS-1/OPS-3 sebaiknya ikut sebelum deploy berikutnya.

## 7. Tidak bisa diverifikasi dari repo

- Konfigurasi Caddy produksi (HSTS/CSP/`request_body`/`trusted_proxies`) — hanya contoh di repo.
- Mode/owner sebenarnya `/srv/qouver/apps/kran/env/*` dan `/srv/qouver/backups/*`.
- Grant `kran_runtime` yang benar-benar terpasang di produksi (runbook manual, bukan migrasi).
- Perilaku `webhook.service` dan apakah `KRAN_KEK_FILE` produksi memakai path container.
- Riwayat run CI (jumlah test yang benar-benar dieksekusi per run) — hanya bisa disimpulkan statis.
- Efektivitas `gitleaks-action` pada `pull_request` dengan `contents: read` saja.
