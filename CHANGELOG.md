# Changelog

All notable changes to KRAN are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entri dihasilkan
`tools/gen-changelog.sh` dari Conventional Commits; jangan ditulis tangan.

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
