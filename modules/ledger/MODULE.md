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

## Jurnal (T-073)

- `ledger.journal` + `ledger.journal_line`: double-entry. **Immutable** — trigger menolak
  `UPDATE`/`DELETE`/`TRUNCATE`; koreksi hanya lewat **jurnal pembalik** (`reversal_of`).
- Keseimbangan `SUM(debit) = SUM(credit)` (minimal 2 baris) ditegakkan **constraint trigger
  deferred** → diperiksa saat `COMMIT`. Karena itu header + baris **wajib satu transaksi**;
  menyisipkan baris dengan autocommit akan ditolak.
- Tanggal bisnis harus berada di periode **OPEN** (trigger). Belum ada periode = tidak bisa posting.
- Akun GL harus `postable` dan `ACTIVE` (trigger).
- `idempotency_key` unik; endpoint pembalik memakai header `Idempotency-Key` dan **idempoten**
  (permintaan ulang → 200 dengan jurnal yang sama). Jurnal yang sudah dibalik tidak bisa dibalik
  lagi; jurnal pembalik tidak bisa dibalik.
- Tanpa partisi pada Fase 1 — **D-072**.
- Immutability **bersandar pada trigger**, bukan pemisahan privilege: role aplikasi saat ini adalah
  pemilik tabel, sehingga `ALTER TABLE … DISABLE TRIGGER`/`session_replication_role` bisa
  membatalkannya. Pemisahan role produksi dicatat **O-010**; sampai itu ada, jaminan ini berlaku
  untuk jalur aplikasi, bukan terhadap superuser.
- Pembalik memakai akun dari jurnal asal; bila akun sudah dinonaktifkan, pembalik ditolak
  (fail-closed) — kebijakan alternatif dicatat **O-079**.

## Posting rule & konsumen outbox (T-074)

- `ledger.posting_rule` / `posting_rule_line`: mapping event → template jurnal, **data** bukan kode.
  Kondisi = subset payload; rule paling spesifik menang, tie-break `priority`, ambigu = gagal
  terlihat. Template Fase 1: tepat satu DEBIT + satu CREDIT, nominal `payload.amount`.
- Konsumen ada di composition root (`apps/api/src/posting.nim`) karena modul tidak boleh menyentuh
  outbox/inbox platform. Event akuntansi **wajib** membawa header outbox `{"accounting": true}`;
  tanpa itu event diabaikan.
- Idempotensi: `platform.inbox` (`consumer = "ledger-postings"`) + `journal.idempotency_key =
  "outbox:<eventId>"`. Event akuntansi tanpa rule → `markFailed`, setelah batas percobaan `DEAD`
  dengan `last_error` — tidak ada jurnal kosong.
- Worker `role=worker` menjalankan loop konsumen; batas dari parameter
  `ledger.posting.batch_size`, `max_attempts`, `retry_backoff_seconds`, `poll_interval_ms`.
- Pengelolaan rule lewat migrasi sampai ada API/UI (**O-080**).

## Saldo turunan & trial balance (T-075)

- `GET /api/v1/ledger/trial-balance?periodId=` — agregat debit/kredit per akun untuk rentang
  periode, **dihitung dari `journal_line`**, bukan cache. Total debit = total kredit (invarian DB).
- `ledger.balance_snapshot` adalah **cache kumulatif** `(account_code, as_of)`: berisi semua jurnal
  dengan `business_date <= as_of`. Satu-satunya penulisnya `ledger.rebuild_balance_snapshot(as_of)`;
  posting jurnal **tidak** menyentuhnya (**D-074**). Trial balance adalah **pergerakan periode**
  (bukan saldo kumulatif), jadi angka snapshot dan TB hanya sama bila tidak ada periode sebelumnya.
- Izin baca laporan memakai `ledger.journal.read` (tingkat institusi).

## Public API (`api.nim`)

- `coa` — `AccountType`, `NormalSide`, `AccountStatus`, `CoaAccount`, `parseAccountType`,
  `parseAccountStatus`, `normalSideOf`, `compileCodePattern`, `validateCode`, `validateName`.
- `period` — `PeriodStatus`, `Period`, `parsePeriodStatus`, `parseIsoDate`, `validateRange`,
  `validateCloseReason`.
- `report` — `TrialBalance`, `TrialBalanceLine`, `totalDebit`, `totalCredit`, `isBalanced`.
- `posting` — `PostingRule`, `PostingRuleLine`, `jsonContains`, `selectRule`,
  `validateTemplate`, `buildLines`.
- `journal` — `Journal`, `JournalLine`, `totalDebit`, `totalCredit`, `isBalanced`,
  `validateJournalLines`, `validateIdempotencyKey`, `validateSourceEvent`, `reversalLinesOf`,
  `validateReversalReason`.

## Event dipublish / dikonsumsi (versi)

- Publish: `period.closed` v1, aggregate `period`, payload `{periodId, startsOn, endsOn}`.
- Publish: `journal.posted` v1, aggregate `journal`, payload
  `{journalId, businessDate, reversalOf, totalDebit}` (dipakai untuk rekonsiliasi/real-time).
- Konsumsi: accounting event dari outbox (header `{"accounting": true}`) lewat konsumen
  `ledger-postings`, dipetakan posting rule → jurnal (T-074).

## Parameter key (+ sensitivitas, regulatory_refs)

| Key | Tipe | Scope | Default seed | Sensitivitas |
|---|---|---|---|---|
| `ledger.coa.code_pattern` | string (regex) | GLOBAL, INSTITUTION | `^[0-9]{1,3}(\.[0-9]{1,3})*$` | NORMAL |
| `ledger.posting.batch_size` | integer | GLOBAL, INSTITUTION | 50 | NORMAL |
| `ledger.posting.max_attempts` | integer | GLOBAL, INSTITUTION | 10 | NORMAL |
| `ledger.posting.retry_backoff_seconds` | integer | GLOBAL, INSTITUTION | 30 | NORMAL |
| `ledger.posting.poll_interval_ms` | integer | GLOBAL, INSTITUTION | 500 | NORMAL |

## Tabel & schema (migrasi `0001`–`0008`)

- `ledger.coa_account` — kode unik, tipe, sisi normal (CHECK konsisten), `postable`, status.
  Tidak ber-cabang: GL milik institusi (spec §9).
- `ledger.period` — rentang inklusif, status, `closed_at`/`closed_by`, EXCLUDE tumpang tindih.
- `ledger.journal` / `ledger.journal_line` — jurnal immutable + pembalik, trigger keseimbangan
  deferred, periode OPEN, akun postable/ACTIVE, dan baris hanya boleh masuk dalam **transaksi yang
  sama** dengan header (lihat bagian Jurnal di atas).
- `ledger.posting_rule` / `posting_rule_line` — mapping event → template jurnal (T-074).
- `ledger.balance_snapshot` — cache saldo per `(account_code, as_of)`; sumber kebenaran tetap jurnal
  (T-075).
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
| `ledger.journal.read` | `journal` | ya |
| `ledger.journal.reverse` | `journal` | ya |

Katalog: `modules/platform/migrations/0015_platform_rbac_ledger.sql` (COA/periode) dan
`0016_platform_rbac_ledger_journal.sql` (jurnal).

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
