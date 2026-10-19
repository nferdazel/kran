# Modul `party`

## Tujuan & Bounded Context

`party` memiliki **identitas dasar** pihak (nasabah/anggota/lembaga): nomor CIF, jenis
(`PERSON`/`ORG`), nama tampil, status, dan cabang pemilik. Modul ini **bukan** tempat data KYC
(NIK, alamat, dokumen) — itu masuk T-071 bersama field crypto — dan bukan tempat rekening
(`ledger`/`account`). Bounded context lain hanya berbicara lewat `api.nim` dan event (spec §6.3).

## Aggregate & Aturan Bisnis Utama

- `Party` (`domain/party.nim`): `partyId`, `cif`, `kind`, `displayName`, `status`, `branchId`.
  Validasi: jenis dikenal, nama dinormalisasi (spasi dirapikan) dan 2–200 karakter tanpa karakter
  kontrol, status awal `ACTIVE`.
- CIF (`domain/cif.nim`): pola dari parameter `party.cif.format`; token `{seq:N}` (satu, wajib)
  dan `{check}` (Luhn mod 10, hanya di akhir). Panjang maksimum 32 (batas kolom), karakter aman
  `A-Z a-z 0-9 - _ . /`.
- Nomor urut dari sequence `party.cif_seq`; CIF **boleh berlubang** bila transaksi batal.
- Tidak ada nilai bisnis di kode: format/lebar/prefix = parameter DB (spec §10).

## Public API (`api.nim`)

- `cif` — `luhnCheckDigit`, `formatCif`, `maxCifLength`.
- `party` — `PartyKind`, `PartyStatus`, `Party`, `newParty`, `validateName`, `parsePartyKind`.

Orkestrasi transaksi (insert + audit + outbox) ada di composition root `apps/api`, bukan di modul,
karena modul `party` tidak boleh mengimpor internal `platform` (archcheck rule C).

## Event dipublish / dikonsumsi (versi)

- Publish: `party.onboarded` v1, aggregate `party`, payload `{partyId, cif, kind, branchId}`.
  **Nama tampil tidak ikut** (PII tidak meninggalkan modul tanpa kebutuhan).
- Konsumsi: belum ada.

## Parameter key (+ sensitivitas, regulatory_refs)

| Key | Tipe | Scope | Default seed | Sensitivitas |
|---|---|---|---|---|
| `party.cif.format` | string | GLOBAL, INSTITUTION | `{seq:6}{check}` | NORMAL |

## Tabel & schema

Schema Postgres `party` (`migrations/0001_party_init.sql`, expand-only):

- `party.cif_seq` — sequence nomor urut CIF.
- `party.party` — identitas dasar; `cif` unik, index `branch_id`.
- `party_person`/`party_org`, dokumen identitas: **T-071** (belum ada di migrasi ini).

## Task day-close yang didaftarkan

Belum ada. Day-close hanya lewat framework `daycloser` (AGENTS.md §1.7).

## Permission

| Permission | Resource | platform_admin |
|---|---|---|
| `party.party.create` | `party` | ya |
| `party.party.read` | `party` | ya |

Katalog di `modules/platform/migrations/0013_platform_rbac_party.sql`; role teller/CS menyusul.

## Namespace i18n

Belum ada teks UI modul ini; nanti memakai prefix `party.` (spec §5.5).

## Requirement regulasi terkait (REG-xxx → test)

Tidak ada nomor pasal yang diklaim. Aturan identitas nasabah yang belum terverifikasi tetap
bertanda `NEEDS-COMPLIANCE-REVIEW` di parameter/seed, bukan dikarang di kode (spec §1.8).

## Keputusan & trade-off (link ADR)

- D-046: pilot satu koperasi/satu cabang; `branchId` wajib, tanpa party lintas cabang.
- D-067: pola CIF (prefix/lebar/`{seq:N}`/`{check}`) = parameter `party.cif.format`; algoritme
  check digit Luhn mod 10 = kode (invarian matematis); salah konfigurasi → 500, bukan 400.
- T-070 menunda PII ke T-071 agar tidak ada kolom sensitif lahir plaintext; audit pembacaan PII
  ikut T-071 (T-070 baru mengaudit pembuatan).
- `Idempotency-Key` pada `POST` master data belum ada → O-072 (keputusan lingkup menyusul).

## Menjalankan test

- `./task test tparty` — unit CIF + validasi domain (tanpa DB).
- `./task test itparty` — repo, CIF unik, audit + outbox satu transaksi (butuh DB dev).
- `./task test itapi_party` — jalur HTTP penuh + kontrak OpenAPI (butuh DB dev).
- `./task check` — archcheck + lint-nomagic + paramgen --check.
