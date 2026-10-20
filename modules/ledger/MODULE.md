# Modul `ledger`

## Tujuan & Bounded Context

`ledger` memiliki **buku besar**: Chart of Accounts, periode akuntansi, dan (menyusul) jurnal
double-entry, posting rule, saldo, serta trial balance. Modul bisnis **tidak** menulis jurnal
langsung — mereka memancarkan accounting event dan `ledger` memetakannya lewat posting rule
(spec §8.1). Bounded context lain hanya berbicara lewat `api.nim` dan event (spec §6.3).

Yang **bukan** milik modul ini: perhitungan bunga/PPAP/produk (modul bisnis), laporan keuangan
(`reporting`), dan orkestrasi tutup hari/bulan (`daycloser`).

## Aggregate & Aturan Bisnis Utama

- `CoaAccount` (`domain/coa.nim`): `code` unik, nama, `accountType`, `normalSide`, `postable`,
  status. Sisi normal adalah **invarian akuntansi** yang diturunkan dari tipe:
  ASSET/EXPENSE = DEBIT, LIABILITY/EQUITY/REVENUE = CREDIT (dijaga CHECK DB).
  `postable = false` menandai akun header/induk yang tidak boleh dipakai posting (T-073).
- Format kode akun = **parameter** `ledger.coa.code_pattern` (regex, dicocokkan seluruh string);
  bukan konstanta di kode (spec §10.5).
- `Period` (`domain/period.nim`): rentang tanggal **inklusif**, status OPEN/CLOSED. Tumpang tindih
  ditolak `EXCLUDE USING gist (daterange(...) WITH &&)`, bukan pemeriksaan aplikasi.
  Penutupan mengisi `closed_at`/`closed_by`; **alasan wajib** dan masuk audit.
- Urutan penutupan (tidak menutup periode lebih awal saat sebelumnya masih terbuka) **belum**
  ditegakkan di sini — itu tugas `daycloser` (Fase 5). Lihat `docs/tasks/T-072.md`.

## Public API (`api.nim`)

- `coa` — `AccountType`, `NormalSide`, `AccountStatus`, `CoaAccount`, `parseAccountType`,
  `parseAccountStatus`, `normalSideOf`, `compileCodePattern`, `validateCode`, `validateName`.
- `period` — `PeriodStatus`, `Period`, `parsePeriodStatus`, `parseIsoDate`, `validateRange`,
  `validateCloseReason`.

## Event dipublish / dikonsumsi (versi)

- Publish: `period.closed` v1, aggregate `period`, payload `{periodId, startsOn, endsOn}`.
- Konsumsi: belum ada (event bisnis via posting rule menyusul di T-074).

## Parameter key (+ sensitivitas, regulatory_refs)

| Key | Tipe | Scope | Default seed | Sensitivitas |
|---|---|---|---|---|
| `ledger.coa.code_pattern` | string (regex) | GLOBAL, INSTITUTION | `^[0-9]{1,3}(\.[0-9]{1,3})*$` | NORMAL |

## Tabel & schema (migrasi `0001`, `0002`)

- `ledger.coa_account` — kode unik, tipe, sisi normal (CHECK konsisten), `postable`, status.
  Tidak ber-cabang: GL milik institusi (spec §9).
- `ledger.period` — rentang inklusif, status, `closed_at`/`closed_by`, EXCLUDE tumpang tindih.
- COA awal (`0002_ledger_coa_base.sql`) adalah **contoh struktur** untuk pilot, bertanda
  `NEEDS-COMPLIANCE-REVIEW` (REG-011 `V!`): jangan dijadikan dasar laporan final sebelum review
  compliance. Ditaruh di migrasi (bukan `packs/*/seed/`) karena seed pack hanya untuk `--dev`.

## Task day-close yang didaftarkan

Belum ada. Penutupan periode **tidak** memakai cron/batch sendiri (AGENTS §1.7); integrasi
`daycloser` menyusul di Fase 5.

## Permission

| Permission | Resource | platform_admin |
|---|---|---|
| `ledger.coa.read` | `coa` | ya |
| `ledger.coa.manage` | `coa` | ya |
| `ledger.period.read` | `period` | ya |
| `ledger.period.manage` | `period` | ya |

Katalog: `modules/platform/migrations/0015_platform_rbac_ledger.sql`.

Aksi COA/periode adalah **aksi institusi**: selain `requirePermission`, handler memanggil
`authorizedAtBranch(db, principal, "", permission)` di dalam transaksi, sehingga grant yang
dibatasi satu cabang ditolak **403 `branch_not_allowed`** (D-062).

## Namespace i18n

Belum ada teks UI modul ini; nanti memakai prefix `ledger.`.

## Requirement regulasi terkait (REG-xxx → test)

REG-011 (standar akuntansi, SAK EP/PSAK) bertanda `V!` — **belum diverifikasi**. COA awal dan
aturan pengakuan belum diklaim patuh; lihat `NEEDS-COMPLIANCE-REVIEW` di migrasi COA.

## Batas yang belum ditegakkan (disengaja, tercatat)

- `postable=false` baru konvensi sampai T-073; belum ada yang menolak posting ke akun header/non-
  `ACTIVE` karena tabel jurnal belum ada.
- Akun kontra (CKPN/akumulasi penyusutan) belum bisa dimodelkan — **O-075**, menunggu keputusan
  accounting/compliance (REG-011 `V!`).
- Daftar COA/periode dibatasi 200 baris; paginasi menyusul bila perlu.
- Penutupan periode bersamaan: `UPDATE` 0 baris → 409 tanpa audit/event kedua.

## Keputusan & trade-off (link ADR)

- D-070: COA & periode T-072 — format kode = parameter, sisi normal = invarian kode, periode
  inklusif + EXCLUDE, COA awal lewat migrasi idempoten (bukan seed pack dev-only).

## Menjalankan test

- `./task test tledger` — unit tipe akun, pola kode, rentang periode.
- `./task test itledger` — seed COA, kode unik, CHECK sisi normal, EXCLUDE tumpang tindih.
- `./task test itapi_ledger` — jalur HTTP penuh + kontrak + audit/event.
