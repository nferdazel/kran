# .github/workflows/ci.yml — Fase 0 (bertahap)

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
| `e2e-a11y` (Playwright + axe ×2 tema ×2 locale) | T-010 — dalam job `web-e2e` |
| `traceability` | **belum** dibuat — jangan dianggap ada (lihat O-027) |

Catatan status (17 Okt 2026, T-050): job yang benar-benar ada di `ci.yml` sekarang `nim-check`,
`db-tests`, `web-e2e`, dan `security`. Yang masih selisih dari spec §21.3: `traceability`
(requirement ↔ kontrol/test) — dicatat sebagai item terbuka (`O-027`) supaya tidak terlihat
seperti sudah lengkap.

## Job `db-tests` (T-050, 17 Okt 2026)

`services: postgres:18` + `KRAN_DATABASE_URL` menunjuk basis data `kran_test`; langkahnya
`./task dbtools migrate`, `./task dbtools seed --dev`, lalu `./task test` (test integrasi ikut
berjalan karena URL terisi).

Dua batasan yang mudah menjatuhkannya:
- Nama basis data **harus** berakhiran `_test`/`_dev`: `dbtools seed --dev` fail-closed (O-062)
  karena seed dev memuat user contoh dengan kata sandi contoh.
- URL harus bentuk polos: `parseDatabaseUrl` menolak query string seperti `?sslmode=require`.

`itplatform` menghapus schema `platform` di DB yang ditunjuk, jadi tiap run menyiapkan ulang
dari nol — bukan mengandalkan keadaan DB yang tersisa.

## Gate kestabilan: `./task ci-repeat [N]` (T-031)

`./task ci` menjawab "kode ini lulus **sekarang**". Ia tidak menjawab "kode ini **stabil**": flake
hanya terlihat saat diulang. `./task ci-repeat 3` menjalankan gate penuh tiga kali berturut-turut dan
berhenti pada putaran pertama yang merah. Dipakai di akhir batch/task besar, bukan di setiap task
(satu putaran ≈ 8 menit). CI GitHub boleh menambahkannya sebagai jadwal malam bila nanti diinginkan;
itu perubahan `ci.yml`, dan belum dilakukan.

## Aturan isolasi test (pelajaran 15 Oktober 2026)

Dua kelas flake sudah benar-benar menggigit di repo ini, dan keduanya sudah pernah membuat CI merah
untuk kode yang benar:

1. **Batas waktu 5 s untuk aksi mahal.** Login/ganti kata sandi menjalankan PBKDF2 600.000 iterasi
   (parameter dev) sementara DB ada di server lain lewat tunnel, dan 4 worker e2e berjalan serentak.
   Karena itu: aksi mahal memakai batas waktu **eksplisit**, dan `expect.timeout` bawaan e2e kini
   10 s. Batas waktu dinaikkan **tanpa** melonggarkan assertion.
2. **Keadaan yang dibagi antar berkas test.** Test e2e berjalan paralel antar berkas (4 worker), jadi:
   - satu baris seed (`dev.maker`, `dev.checker`, `dev.firstlogin`, …) hanya boleh **diubah** oleh
     satu berkas test. Saat ini: `dev.firstlogin` (alur wajib-ganti kata sandi) hanya di
     `password.spec.ts`; berkas lain memakai `dev.maker`/`dev.checker` secara baca saja;
   - test tidak boleh mengandalkan keadaan awal yang bersih. Nilai yang menumpuk antar run (mis.
     nilai parameter) harus **diturunkan dari API** (lihat `nextEffectiveFrom` di `flow.spec.ts`),
     bukan diasumsikan;
   - proses yang dibunuh/di-restart oleh test harus memakai port dan instance sendiri
     (`shutdown.spec.ts` memakai port bebas, bukan 8099 milik `webServer`).
