# .github/workflows/ci.yml — job dan kontrak runner

Job ditambahkan **bersamaan dengan komponennya**, bukan di awal sebagai gate kosong:
job kosong yang selalu hijau adalah "hijau palsu". Per tanggal T-001 hanya ada
`nim-check` + `security`; sisa job dari spec §21.3 masuk di task masing-masing:

| Job | Masuk di task |
|---|---|
| `nim-check` | T-001 |
| `security` (gitleaks) | T-001 |
| `db-tests` (services: postgres:18) | T-050 — **ada** (17 Okt 2026) |
| `traceability` (requirement ↔ kontrol/test) | T-005 |
| `contract` (OpenAPI ↔ implementasi) | T-008 — digabung ke job `web-e2e` (`./task openapi`) dan ke `./task test` (test Nim `tcontract`/`tapi`/`itapi`) |
| `web` (svelte-check/vitest/i18n) | T-010 — job `web-e2e` |
| `web-lint` (eslint: typescript-eslint + `svelte/*` non-a11y) | T-057 — dalam job `web-e2e` (`./task lint-web`, D-139) |
| `web-unit` (vitest fungsi murni `apps/web`) | T-126 — dalam `./task e2e` |
| `web-e2e` ber-DB (Postgres + migrate/seed) | T-126 — job `web-e2e` |
| `e2e-a11y` (Playwright + axe ×2 tema ×2 locale) | T-010 — dalam job `web-e2e` |
| `traceability` | **belum** dibuat — jangan dianggap ada (lihat O-027) |
| `release.yml` (tag ↔ `VERSION`, GitHub Release) | D-178 — **ada** (2 Nov 2026) |
| `visual-baseline.yml` (baseline Linux `visual.spec.ts`) | T-156/D-177 — **ada** (31 Okt 2026) |
| `secret-scan.yml` (gitleaks seluruh riwayat, mingguan) | D-190 — **ada** (2 Nov 2026) |

Catatan status (17 Okt 2026, T-050): job yang benar-benar ada di `ci.yml` sekarang `nim-check`,
`db-tests`, `web-e2e`, dan `security`. Yang masih selisih dari spec §21.3: `traceability`
(requirement ↔ kontrol/test) — dicatat sebagai item terbuka (`O-027`) supaya tidak terlihat
seperti sudah lengkap.

## Pemicu manual (2 Nov 2026)

`ci.yml` kini juga punya `workflow_dispatch`. Alasannya konkret: setelah riwayat git ditulis ulang
dan di-force-push, GitHub **tidak membuat run sama sekali** untuk push `main` maupun push tag
(`gh run list` kosong, padahal webhook deploy menerima event-nya). Gerbang CI di
`ops/scripts/deploy-vps.sh` menunggu 30 menit lalu menolak deploy. Dengan `workflow_dispatch`,
run bisa dibuat manual (`gh workflow run CI --ref main`) tanpa memalsukan commit.


## Runner yang dipin, timeout, dan install browser Playwright (23 Okt 2026)

Tiga hal di bawah berlaku untuk **semua** job, bukan saran:

- **Runner dipin ke `ubuntu-24.04`, bukan `ubuntu-latest`.** Migrasi label `latest` bisa diam-diam
  mengganti set lib sistem yang dibutuhkan Playwright Chromium, tanpa perubahan di repo. Karena itu
  runner ditulis eksplisit di setiap job.
- **`timeout-minutes: 15` adalah kontrak (AGENTS §2), bukan sekadar anggaran.** Job tanpa timeout
  dilarang, dan job yang menembus 15 menit dianggap jebol — bukan "cuma lambat".
- **Browser Playwright: hanya browser dari cache, tanpa `apt-get`.** Langkahnya
  `pnpm --filter @kran/web exec playwright install chromium`, **tanpa `--with-deps`**.
  `--with-deps` menjalankan `apt-get update/install` di setiap run dan pernah menghabiskan
  **14m47s** sampai job 15 menit dibatalkan (run `39962254127`), padahal browser sudah ada di cache
  `~/.cache/ms-playwright`. Lib sistem Chromium sudah tersedia di image `ubuntu-24.04`; runner dipin
  justru supaya set lib itu tidak berubah di bawah kaki.

## Job `db-tests` (T-050, 17 Okt 2026)

`services: postgres:18` + `KRAN_DATABASE_URL` menunjuk basis data `kran_test`; langkahnya
`./task dbtools migrate`, `./task dbtools seed --dev`, lalu `./task test` dengan
`KRAN_TEST_SCOPE=integration`.

**Kenapa hanya integrasi (2 Nov 2026).** Job ini dulu menjalankan `./task test` penuh, padahal job
`nim-check` sudah menjalankan unit + property test yang sama. Totalnya 13m18s (3m09s di antaranya
unit) dan satu run menembus `timeout-minutes: 15` → job dibatalkan, gerbang deploy gagal, padahal
kodenya hijau. Sisa anggaran sekarang ±4 menit untuk pertumbuhan test; bila itu habis, pecah per
modul — **jangan** menaikkan timeout (kontrak §21.3).

Dua batasan yang mudah menjatuhkannya:
- Nama basis data **harus** berakhiran `_test`/`_dev`: `dbtools seed --dev` fail-closed (O-062)
  karena seed dev memuat user contoh dengan kata sandi contoh.
- URL harus bentuk polos: `parseDatabaseUrl` menolak query string seperti `?sslmode=require`.

`resetTestSchemas` (`tools/dbtools`) menghapus schema **semua modul** di DB yang ditunjuk, bukan
hanya `platform`, jadi tiap run menyiapkan ulang dari nol — bukan mengandalkan keadaan DB yang
tersisa. Sejak T-127 fungsi itu menolak URL yang namanya bukan `_dev`/`_test`.

## Workflow lain: `release.yml` (D-178, 1 Nov 2026)

Dipicu **tag** `v*`, bukan push ke `main`. Tugasnya hanya memastikan tag menyebut versi yang benar
(`tag == "v$(cat VERSION)"`, plus `kran.nimble`, `package.json`, dan berkas generated), lalu membuat
GitHub Release. Ia **tidak** mendeploy: deploy tetap dari push ke `main` lewat webhook →
`ops/scripts/deploy-vps.sh`, yang menunggu check-run CI hijau untuk commit itu.

## Workflow lain: `visual-baseline.yml` (T-156/D-177, 31 Okt 2026)

`workflow_dispatch` saja, dengan input `update`. Screenshot Playwright bergantung pada OS dan font,
jadi baseline **harus** dibuat di runner Linux yang sama dengan job `web-e2e` — baseline macOS akan
gagal di sana. Alur: jalankan workflow → unduh artefak `visual-baseline-linux` → commit ke
`apps/web/tests/e2e/visual.spec.ts-snapshots/`. Gate-nya sendiri tetap di `ci.yml` job `web-e2e`
(`visual.spec.ts`, yang melewati diri sendiri di luar Linux).

Kedua workflow memakai `timeout-minutes: 15`, runner `ubuntu-24.04`, dan cache pnpm seperti job di
`ci.yml` (kontrak runner di atas).

## Gate kestabilan: `./task ci-repeat [N]` (T-031)

`./task ci` menjawab "kode ini lulus **sekarang**". Ia tidak menjawab "kode ini **stabil**": flake
hanya terlihat saat diulang. `./task ci-repeat 3` menjalankan gate penuh tiga kali berturut-turut dan
berhenti pada putaran pertama yang merah. Dipakai di akhir batch/task besar, bukan di setiap task
(satu putaran ≈ 8 menit). CI GitHub boleh menambahkannya sebagai jadwal malam bila nanti diinginkan;
itu perubahan `ci.yml`, dan belum dilakukan.

## Aturan isolasi test (pelajaran 15 Oktober 2026)

Dua kelas flake sudah benar-benar menggigit di repo ini, dan keduanya sudah pernah membuat CI merah
untuk kode yang benar:

1. **Batas waktu untuk aksi mahal.** Login memverifikasi PBKDF2 600.000 iterasi **sekali**. Ganti
   kata sandi menjalankan **N+3** derivasi: verifikasi kata sandi lama + kata sandi baru terhadap
   hash yang berlaku + N hash riwayat + hash kata sandi baru (N =
   `platform.security.password_history_count`, basis 5 → **8 derivasi**). Klaim lama "dua kali per
   permintaan" salah sejak O-052; angka + anggarannya di `docs/tasks/T-060.md` (T-060/O-068).
   DB dev ada di server lain lewat tunnel, dan 4 worker e2e berjalan serentak. Yang penting untuk
   suite ini: **biner e2e dibangun `./task build` = debug**, sehingga kriptonya ~20x lebih lambat
   daripada biner produksi (release, `apps/api/Dockerfile`) — itulah yang benar-benar diukur di
   sini, bukan biaya produksi. Karena itu: aksi mahal memakai batas waktu **eksplisit**
   (`password.spec.ts` → 20 s), dan `expect.timeout` bawaan e2e 10 s. Batas waktu dinaikkan
   **tanpa** melonggarkan assertion.
2. **Keadaan yang dibagi antar berkas test.** Test e2e berjalan paralel antar berkas (4 worker), jadi:
   - satu baris seed (`dev.maker`, `dev.checker`, `dev.firstlogin`, …) hanya boleh **diubah** oleh
     satu berkas test. Saat ini: `dev.firstlogin` (alur wajib-ganti kata sandi) hanya di
     `password.spec.ts`; berkas lain memakai `dev.maker`/`dev.checker` secara baca saja;
   - test tidak boleh mengandalkan keadaan awal yang bersih. Nilai yang menumpuk antar run (mis.
     nilai parameter) harus **diturunkan dari API** (lihat `nextEffectiveFrom` di `flow.spec.ts`),
     bukan diasumsikan;
   - proses yang dibunuh/di-restart oleh test harus memakai port dan instance sendiri
     (`shutdown.spec.ts` memakai port bebas, bukan 8099 milik `webServer`).

## Prasyarat pustaka runtime di runner (20 Okt 2026)

Kedua job yang menjalankan test Nim memasang `libpcre3`: `std/re` (validasi pola COA) membuka
`libpcre.so.3` lewat dynlib saat jalan. macOS membawanya, image runtime produksi juga
(`apps/api/Dockerfile`), tetapi runner `ubuntu-24.04` tidak — gejalanya
`could not load: libpcre.so(.3|.1|)` di awal binary test, bukan kegagalan assertion.

## Anggaran waktu test stress pool (O-074, D-102)

`itpool` menekan pool (8 thread, pool 3) untuk membuktikan **tidak ada kebocoran**. Di gate penuh,
latensi tunnel DB dev bisa membuat satu pinjaman menunggu > 15 dtk walau pool benar; karena itu
anggaran tunggunya 60 dtk (`stressAcquireTimeoutMs`). Assertion tidak berubah: galat harus 0,
`inUse` kembali 0, `created <= poolSize`. Timeout yang masih muncul = indikasi kebocoran/koneksi
mati, bukan alasan menaikkan ambang lagi.

## Job `secret-scan` (D-190, 2 Nov 2026)

Terpisah dari `ci.yml` karena `gitleaks-action` memindai **rentang commit** yang di-push (atau PR),
bukan seluruh riwayat. Job ini memindai `--log-opts=--all` dengan binary gitleaks versi terpin,
dijadwalkan Senin 03:17 UTC dan bisa dijalankan manual (`gh workflow run "Secret scan (riwayat penuh)"`).
Timeout tetap `timeout-minutes: 15`. Kalau hasilnya merah, jangan longgarkan `.gitleaks.toml`:
ganti nilainya, dan bila sudah terlanjur masuk riwayat, putuskan scrub bersama pemilik (riwayat
tidak bisa dibereskan dengan menghapus berkas).

## Nama job = kontrak dengan gerbang deploy (O-119, 2 Nov 2026)

`ops/scripts/deploy-vps.sh` mencocokkan **nama check-run** dengan daftar `CI_EXPECTED` sebelum
membangun apa pun; nama yang berubah tanpa memperbarui daftar itu membuat deploy menunggu 30 menit
lalu menolak. Aturannya:

- Nama job di `ci.yml` (`Nim (check + unit/property test)`, `DB (integrasi, Postgres 18)`,
  `Web (svelte-check + axe + Playwright)`, `Security (gitleaks)`) hanya boleh berubah **bersamaan**
  dengan `CI_EXPECTED` di `deploy-vps.sh`, dalam satu commit.
- Job baru tidak otomatis menjadi gerbang: masukkan ke `CI_EXPECTED` bila memang wajib hijau,
  atau biarkan di luar daftar bila sifatnya informatif (`secret-scan.yml` mingguan, `visual-baseline.yml`).
- `workflow_dispatch` pada `ci.yml` menjalankan job yang sama, jadi nama check-run-nya identik dan
  tetap memenuhi gerbang.

## Gate lokal vs gate CI (D-194, 2 Nov 2026)

Pembagian gate lokal **tidak** mengubah job CI: `./task ci-fast` (tanpa e2e) adalah loop harian,
sedangkan `./task ci` dan `./task release` menjalankan e2e. Job `Web (svelte-check + axe + Playwright)`
tetap dijalankan untuk setiap push dan tetap menjadi gerbang deploy, jadi commit yang lolos
`ci-fast` tetapi merah di e2e tetap tidak sampai ke produksi.
