# Modul `lending`

Pinjaman anggota (spec §23 Fase 4): bentuk pinjaman, jadwal angsuran, kolektibilitas, PPAP.
Status: **T-161** (model) — kalkulasi jadwal T-162, pengajuan/pencairan T-163/T-164.

- Tujuan, aggregate, tabel, parameter, event, dan izin: `MODULE.md`.
- Permukaan publik modul: `api.nim`.
- Keputusan angka & aturan Fase 4: D-180 (`docs/DECISIONS.md`); rencana: `docs/proposals/fase4-lending.md`.

Test: `./task test tloan`, `./task test itlending`.
Gate: `./task check` (archcheck + lint-nomagic + paramgen).
