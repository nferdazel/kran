# Modul `deposit`

Rekening simpanan anggota: buka + baca, saldo cache dengan CHECK tidak negatif.

- Tujuan, aggregate, tabel, parameter, event, dan izin: `MODULE.md`.
- Permukaan publik modul: `api.nim`.
- Setor/tarik/PB + posting jurnal belum ada (T-088b/T-088c).

Test: `./task test taccount`, `./task test itaccount`, `./task test itapi_deposit`.
Gate: `./task check` (archcheck + lint-nomagic + paramgen).
