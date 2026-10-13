# Modul `hello`

> Kerangka hasil `./task scaffold hello` (spec §5.5). Ganti isi placeholder ini saat modul
> diisi; jangan biarkan tetap seperti ini di modul yang sudah dipakai.

## Tujuan & Bounded Context

TODO: satu paragraf — apa yang dimiliki modul ini dan (tak kalah penting) yang bukan.
Bounded context lain hanya berbicara lewat `api.nim` dan kontrak event (spec §6.3).

## Aggregate & Aturan Bisnis Utama

- Belum ada aggregate; `domain/core.nim` masih contoh fungsi murni.
- Aturan bisnis wajib param-driven, bukan konstanta di kode (spec §10, AGENTS.md §1.2).

## Public API (api.nim)

- `greet(who: string): string` — contoh; ganti dengan permukaan publik sesungguhnya.
- `greetUser(who: string): string` — contoh use case.

## Event dipublish / dikonsumsi (versi)

- Belum ada. Nama event `PascalCase` lampau, versi `v1`, kontrak di
  `packages/contracts/events` (spec §12.4).

## Parameter key (+ sensitivitas, regulatory_refs)

- Belum ada; `seeds/params.yaml` masih daftar kosong.
- Pola key: `hello.kategori.nama` (spec §27.A). Nilai default pack lewat `paramgen`
  (spec §10.3); nilai bisnis tidak boleh di kode.

## Tabel & schema

- Schema Postgres `hello` dibuat `migrations/0001_hello_init.sql`.
- Tabel: belum ada.

## Task day-close yang didaftarkan

- Belum ada. Day-close hanya lewat framework `daycloser` (AGENTS.md §1.7); modul tidak
  membuat batch/cron sendiri.

## Permission

- Belum ada. Pola: `hello.<resource>.<action>` (spec §27.A).

## Namespace i18n

- Belum ada. Pakai prefix `hello.` saat katalog i18n dibangun (T-010, spec §5.5).

## Requirement regulasi terkait (REG-xxx → test)

- Tidak ada. Jangan mengarang nomor pasal (spec §1.8); tambahkan setelah diverifikasi
  compliance owner, lengkap dengan test-nya.

## Keputusan & trade-off (link ADR)

- Belum ada.

## Menjalankan test

- `./task test thello` — unit test modul ini (tanpa DB).
- `./task check` — archcheck + lint-nomagic + paramgen --check.
- `./task dbtools validate` — validasi migrasi (expand-only).
