# Changelog

All notable changes to KRAN are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entri dihasilkan
`tools/gen-changelog.sh` dari Conventional Commits; jangan ditulis tangan.

## [0.3.2] - 2026-11-13

### Fixed
- **i18n:** Keep the read_all permission label inside the T-292 terminology rule
- **params:** Reject backdated effective dates on submit and approve (C-03)
- **teller:** Bind cash-session transaction read to the session owner (C-02)
- **realtime:** Filter param.changed with the params read-scope rule (C-01)

## [0.3.1] - 2026-11-13

### Fixed
- **authz:** Fail closed on the trusted proxy range (K-02, K-03, K-04)
- **authz:** Deny passwords the repo publishes and trust the proxy range for the audit IP
- **ops:** Keep a rollback target when :local and :prev share an image

## [0.3.0] - 2026-11-12

### Added
- Add shared MoneyInput and migrate the amount fields

### Fixed
- Announce field errors and tighten MoneyInput e2e selectors
- **i18n:** State IDR once on the loan amount label
- Stop the shell scrolling sideways at 200% zoom (T-294 part 1)
- **ops:** Stop the SPA fallback from answering missing hashed assets with HTML

## [0.2.0] - 2026-11-11

### Added
- Rebuild sign-in screen per approved direction (T-241)
- Drawer 520 with an honest focus trap (T-290)
- State IDR once in loans money headers (T-295)
- Tighten loans list density (T-293)
- Sweep list states and vault terminology (T-292)
- **lending:** Add partyName to the loans list item
- State money once per column and reserve cell width (T-289)
- Add DataTable density, totals, selection and two-line rows (T-288)
- Add button sizes and the quiet variant (T-287)
- Add v2 form controls and migrate app forms (T-286)
- Adopt design system v2 tokens
- Render the workspace shell from shared ui components

### Fixed
- Axe print routes at 1440 and 360 with a focusable statement region (T-291)
- Print routes use token colours, page sizes and header repeat (T-291)
- Keep drawer keys on window so scrim clicks cannot escape (T-290)
- Restore business date, panel landmark and print chrome in v2 shell
- **deploy:** Wait for the deploy lock instead of failing fast

### Operations
- **visual:** Always rewrite snapshots on regeneration
- Build dbtools through ./task in the visual baseline job
- Upload Playwright failure artifacts and add a visual baseline update job

## [0.1.21] - 2026-11-05

### Fixed
- **migrations:** Keep deployed migrations byte-identical

## [0.1.20] - 2026-11-05

### Changed
- Rebuild planning corpus around replanned roadmap
- **fase5:** Usulan breakdown Koperasi Pack sebelum fase dibuka
- Buktikan biner produksi v0.1.19 ber-atomicArc, catat celah log build (O-129)
- **open-items:** Catat keputusan pemilik 3 Nov 2026 (MFA ditunda, sign-off O-001 dibiarkan)

## [0.1.19] - 2026-11-03

### Changed
- **build:** Bangun API dan biner test dengan --mm:atomicArc (O-128/D-201)

## [0.1.18] - 2026-11-03

### Added
- **auth:** Require MFA second factor at login when policy enabled (O-071)
- **platform:** Let an operator end a parameter value without a successor (O-064)
- **i18n:** Translate role and permission catalogue keys (O-053)

### Fixed
- **platform:** Grant role runtime pada platform.param_end_request (O-064)
- **api:** Pin Mummy parser limits and classify e2e API crashes (T-044)

## [0.1.17] - 2026-11-03

### Fixed
- **daycloser:** Gate subledger ikut menghitung akun ekuitas simpanan (O-127)

## [0.1.16] - 2026-11-03

### Fixed
- **lending:** Grant role runtime untuk tujuh tabel transaksi (O-126)

## [0.1.15] - 2026-11-02

### Added
- **ci:** Gate traceability requirement <-> kontrol <-> test (O-027)
- **lending:** Batas golongan pasca-restrukturisasi + tarif PPAP POJK 1/2024

### Fixed
- **daycloser:** Penjadwal tidak menutup tanggal yang belum berjalan
- **lending:** Pembanding golongan pada tanggal buku + cap tidak melonggar saat restrukturisasi berulang

## [0.1.14] - 2026-11-02

### Added
- Aksi pemulihan pasca hapus buku di UI (T-177)

### Fixed
- Tutup temuan review T-177 (sidik, rekening wajib, axe 4 kombinasi)

## [0.1.13] - 2026-11-02

### Added
- **lending:** Pemulihan pasca hapus buku lewat API (T-176, O-122)

### Fixed
- **lending:** Kunci jurnal pemulihan memakai id pemulihan + tanda rekonsiliasi
- Simpan kunci idempotensi per sidik isian (T-175)

## [0.1.12] - 2026-11-02

### Added
- **security:** Guardrail kredensial tiga lapis (D-190)

## [0.1.11] - 2026-11-02

### Fixed
- **security:** Allowlist sempit untuk awalan kunci uji di riwayat (D-189)

### Operations
- Izinkan pemicu manual pada workflow CI

## [0.1.10] - 2026-11-02

### Fixed
- **ci:** Db-tests hanya menjalankan integrasi
- **ops:** Izinkan contract tx_type pinjaman ikut deploy

## [0.1.9] - 2026-11-02

### Added
- Aksi tulis pinjaman dengan pratinjau di layar detail
- **ops:** Ikutkan anchor audit ke backup harian, catat offsite yang belum ada
- **ops:** Jadwalkan anchor audit harian dan perbaiki unit day-close host

### Fixed
- Tutup celah kunci replay dan uji sisa aksi pinjaman (review T-173)

## [0.1.8] - 2026-11-02

### Added
- **dayclose:** Simulasi 12 bulan berpinjaman, benchmark EOD 100k+50k
- **lending:** Laporan tunggakan/aging, penyisihan, dan rekonsiliasi

## [0.1.7] - 2026-11-02

### Added
- **lending:** Baca & daftar pinjaman, dan layar operatornya

## [0.1.6] - 2026-11-02

### Added
- **lending:** Restrukturisasi jadwal versi baru dan hapus buku

## [0.1.5] - 2026-11-02

### Added
- **lending:** PPAP/CKPN dengan jurnal selisih harian
- **lending:** Penilaian kolektibilitas harian lewat day-close

## [0.1.4] - 2026-11-01

### Added
- **lending:** Pembayaran angsuran dengan alokasi per parameter

## [0.1.3] - 2026-11-01

### Added
- **lending:** Pencairan pinjaman ke rekening simpanan dengan jurnal piutang
- **lending:** Pengajuan dan persetujuan pinjaman dengan empat mata

## [0.1.2] - 2026-11-01

### Added
- **lending:** Modul pinjaman, skema, dan mesin jadwal angsuran

### Fixed
- **api:** Test pembatas login tidak bergantung pada jendela 60 detik
- **ops:** Gerbang deploy tidak lagi berbohong soal kuota, DB, dan e2e
- **ops:** Give the CI gate twice the CI duration we actually observed

## [0.1.1] - 2026-11-01

### Fixed
- **ops:** Poll the CI gate conditionally so waiting stays inside the rate limit
- **tools:** A release with only docs still says something, and an empty one refuses
