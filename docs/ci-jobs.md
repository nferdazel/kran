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
| `contract` (OpenAPI ↔ implementasi) | T-008 |
| `web` (eslint/a11y/svelte-check/vitest/i18n) | T-010 |
| `e2e-a11y` (Playwright + axe ×2 tema ×2 locale) | T-010 |
