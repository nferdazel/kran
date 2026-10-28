# Modul `daycloser`

Kerangka penutupan hari/bulan/tahun (spec §11). Modul lain mendaftarkan task lewat `api.nim`;
tidak ada batch/cron di luar framework ini.

- Rancangan, invarian, tabel, dan batas: `MODULE.md`.
- Titik masuk: `application/orchestrator.nim` (logika) + `infrastructure/run_repo.nim` (Postgres).
- Perintah operator: `kran-api --role=ctl daycloser-status|run|resume|pause|cancel`
  (composition root: `apps/api/src/daycloser_ctl.nim`).
