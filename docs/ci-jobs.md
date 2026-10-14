# .github/workflows/ci.yml — Fase 0 (bertahap)

Job ditambahkan **bersamaan dengan komponennya**, bukan di awal sebagai gate kosong:
job kosong yang selalu hijau adalah "hijau palsu". Per tanggal T-001 hanya ada
`nim-check` + `security`; sisa job dari spec §21.3 masuk di task masing-masing:

| Job | Masuk di task |
|---|---|
| `nim-check` | T-001 |
| `security` (gitleaks) | T-001 |
| `db-tests` (services: postgres:18) | T-004 |
| `traceability` (requirement ↔ kontrol/test) | T-005 |
| `contract` (OpenAPI ↔ implementasi) | T-008 — digabung ke job `web-e2e` (`./task openapi`) dan ke `./task test` (test Nim `tcontract`/`tapi`/`itapi`) |
| `web` (svelte-check/vitest/i18n) | T-010 — job `web-e2e` |
| `e2e-a11y` (Playwright + axe ×2 tema ×2 locale) | T-010 — dalam job `web-e2e` |
| `traceability`, `db-tests` | **belum** dibuat — jangan dianggap ada (lihat O-027) |

Catatan status (2026-10-14): job yang benar-benar ada di `ci.yml` baru `nim-check`, `web-e2e`,
dan `security`. Baris di atas adalah rencana spec §21.3, bukan kenyataan; selisihnya dicatat
sebagai item terbuka supaya tidak terlihat seperti sudah lengkap.
