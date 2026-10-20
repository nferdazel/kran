# Modul `ledger`

Buku besar: Chart of Accounts + periode akuntansi (T-072). Jurnal, posting rule, saldo, dan trial
balance menyusul (T-073–T-075).

- Tujuan, aturan, tabel, parameter, izin, dan batas: `MODULE.md`.
- Permukaan publik modul: `api.nim`.

Test: `./task test tledger`, `./task test itledger`, `./task test itapi_ledger`.
Gate: `./task check` (archcheck + lint-nomagic + paramgen).
