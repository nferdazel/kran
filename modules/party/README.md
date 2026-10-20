# Modul `party`

Identitas dasar pihak: CIF (param-driven, Luhn) + jenis/nama/status/cabang.

- Tujuan, aggregate, tabel, parameter, event, dan izin: `MODULE.md`.
- Permukaan publik modul: `api.nim`.
- Data KYC/PII belum ada di sini — menyusul di T-071 bersama field crypto.

Test: `./task test tparty`, `./task test itparty`, `./task test itapi_party`.
Gate: `./task check` (archcheck + lint-nomagic + paramgen).
