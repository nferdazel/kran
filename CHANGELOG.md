# Changelog

All notable changes to KRAN are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Entri dihasilkan
`tools/gen-changelog.sh` dari Conventional Commits; jangan ditulis tangan.

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
