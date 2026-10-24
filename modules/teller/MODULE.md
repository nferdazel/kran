# Modul `teller` — sesi kas teller + vault

Sesi kas teller, vault per cabang, dan arus kas laci (spec §9.2, §11.6, §13, §23 Fase 2).
Menjawab pertanyaan "berapa kas yang seharusnya ada di laci teller X di cabang Y hari ini", dan
menggerbang transaksi tunai supaya angka itu punya arti.

Status: **T-093** (skema + API sesi + gerbang transaksi tunai) + **T-107** (top-up vault) +
**T-118** (jurnal kas, top-up maker-checker). UI kas/top-up = T-088d/T-121; rekonsiliasi kas penuh
(selisih fisik vs GL) = Fase 3 (`daycloser`); gate EOD "semua sesi tutup & kas seimbang" = Fase 3.

## Tabel (migrasi `0001` schema, `0006` tabel, `0007` grant runtime, `0035` pengajuan top-up)

| Tabel | Isi |
|---|---|
| `teller.vault` | Satu vault per cabang: `balance numeric(24,4)` dengan CHECK `>= 0`. Berkurang saat sesi dibuka (opening float), bertambah saat ditutup (counted cash) dan saat top-up disetujui (T-118). Vault adalah representasi operasional saldo akun GL `teller.vault.cash_account` (parameter), bukan sumber kebenaran akuntansi. |
| `teller.teller_session` | Sesi kas: `branch_id`, `teller_user_id`, `business_date`, `status` (`OPEN`/`CLOSED`), `opening_float`, `opened_at/by`, `expected_cash`/`counted_cash`/`variance`/`note`/`closed_at/by` (terisi hanya saat `CLOSED`). |
| `teller.cash_movement` | Arus laci per sesi: `CASH_IN`/`CASH_OUT`, `amount > 0`, `transaction_id` **UNIQUE** (FK `deposit.transaction`). Satu transaksi tunai = tepat satu baris movement. |
| `teller.vault_topup_request` | Pengajuan top-up (T-118): `amount`, `source_account` (COA ASSET), `note` wajib, `status` `PENDING`/`APPROVED`/`REJECTED`, `requested_by`, `decided_by/at`, `decision_note`, `journal_id`. CHECK menolak self-approval dan mewajibkan `journal_id` hanya saat `APPROVED`. |

**Nomor berkas tidak rapat**: `0001` hanya schema; tabel di `0006` karena mem-FK `platform.app_user`
(`platform/0006`) dan `deposit.transaction` (`deposit/0004`) — urutan migrasi global `(seq, modul,
berkas)` menjalankan `platform` sebelum `teller` pada seq yang sama (D-122). `0007` memberi grant
runtime (pola `deposit/0006`/`0008`: `ON ALL TABLES` hanya mencakup tabel yang ada saat itu).

## Invarian

- **Satu sesi `OPEN` per (cabang, teller)**: partial unique index `teller_session_one_open_uq`
  (`WHERE status = 'OPEN'`). Jalur repo memakai `INSERT ... ON CONFLICT ... DO NOTHING` supaya
  balapan dua buka menjadi 409, bukan error DB.
- **Vault tidak boleh negatif**: CHECK DB + debit bersyarat `UPDATE ... WHERE balance >= ?` (satu
  baris per cabang, sehingga tidak ada celah read-then-write).
- **Top-up vault = maker-checker (T-118)**. `POST /teller/vault/topups` hanya menulis pengajuan
  `PENDING` (nominal, akun sumber, alasan/bukti wajib); saldo belum berubah. Persetujuan akun
  **lain** mengunci baris pengajuan `FOR UPDATE`, lalu `UPDATE teller.vault SET balance = balance + ?`
  (increment atomik) + jurnal + audit + event dalam satu transaksi. Vault **harus sudah ada**
  (seed/runbook): top-up tidak membuat baris vault baru diam-diam.
- **`expected_cash = opening_float + Σ CASH_IN − Σ CASH_OUT`**, dihitung saat tutup dari agregat
  `cash_movement` sesi itu (setelah baris sesi dikunci `FOR UPDATE`).
- **`variance = counted_cash − expected_cash`** (positif = kas lebih) ditegakkan CHECK tabel.
  Selisih **bukan** 409: dicatat + diaudit, bukan menolak penutupan.
- **Tutup menambah vault sebesar `counted_cash`** (uang fisik yang masuk vault), bukan `expected_cash`.
- **Jurnal kas (T-118, D-132)**: buka `D 101.2 KAS DI TELLER / K 101.1 KAS DI VAULT` sebesar float;
  tutup `D 101.1 / K 101.2` sebesar counted; selisih lebih `D 101.2 / K 101.9 SELISIH KAS`, kurang
  `D 101.9 / K 101.2` sebesar |variance|. **Deviasi sadar dari memo T-118 §5**: kaki selisih memakai
  akun laci (`101.2`), bukan vault — setelah kas kembali ke vault saldo laci = −variance, jadi hanya
  akun laci yang bisa dinolkan jurnal selisih. Nominal nol tidak dijurnal (domain menolak nominal
  nol). Jurnal ditulis **sinkron** di transaksi yang sama dengan mutasi vault, bukan lewat outbox.
- **Tutup tidak bisa dua kali**: `UPDATE ... WHERE session_id = ? AND status = 'OPEN'`; 0 baris = 409.
- **Baris `cash_movement` immutable** (`0006`): UPDATE/DELETE/TRUNCATE ditolak
  `ledger.reject_mutation()`. Koreksi = transaksi tunai baru (jurnal pembalik di sisi `deposit`).
- **Uang tanpa float**: seluruh nominal `numeric(24,4)` / tipe `Money`; API mengirim desimal string.

## API

| Endpoint | Izin | Sukses | Error |
|---|---|---|---|
| `POST /api/v1/teller/sessions` | `teller.session.open` @cabang | 201 `TellerSession` | 400 body/nominal/note/kunci; 403 (cabang); 409 `session_already_open`/`insufficient_vault`/`vault_not_configured`; 409 idempotensi |
| `GET /api/v1/teller/sessions/current?branchId=` | `teller.session.read` @cabang | 200 `TellerSession` | 400 `branchId`; 403 (cabang); 404 `session_not_open` |
| `POST /api/v1/teller/sessions/{sessionId}/close` | `teller.session.close` @cabang sesi | 200 `TellerSessionClose` | 400 `countedCash`/note/kunci; 403 (cabang); 404 tak dikenal; 409 `session_not_open`/`session_not_owned`; 409 idempotensi |
| `POST /api/v1/teller/cash-transactions` | `teller.transaction.post` @cabang rekening | 201 `CashTransaction` | **409 `no_open_session`** bila tidak ada sesi `OPEN` hari itu, atau **409 `session_business_date_mismatch`** bila sesi `OPEN` ada tetapi untuk tanggal bisnis lain (tutup dulu); sisanya seperti T-088b |
| `GET /api/v1/teller/vault?branchId=` | `teller.vault.read` @cabang | 200 `TellerVault` (`{branchId,balance}`) | 400 `branchId`; 403 (cabang); **404 `vault_not_configured`** bila baris vault belum ada |
| `GET /api/v1/teller/vault/topups?branchId=&status=&limit=` | `teller.vault.read` @cabang | 200 `TellerVaultTopUpRequestList` | 400 `branchId`/`status`/`limit`; 403 (cabang) |
| `POST /api/v1/teller/vault/topups` | `teller.vault.submit` @cabang | 201 `TellerVaultTopUpRecord` (`status=PENDING`, saldo **tidak** berubah) | 400 `amount`≤0/bukan desimal/`branchId`/note kosong/akun sumber tidak sah/akun sumber = akun vault/kunci; 403 (cabang); 404 `vault_not_configured`; 409 idempotensi |
| `POST /api/v1/teller/vault/topups/{requestId}/approve` | `teller.vault.approve` @cabang pengajuan | 200 `TellerVaultTopUpApproval` (`{request,balanceAfter}`) + jurnal | 400 kunci; 403 (cabang); 404 `topup_request_not_found`/`vault_not_configured`; 409 `topup_request_not_pending`/`self_approval`/`source_account_invalid`; 500 konfigurasi akun vault |
| `POST /api/v1/teller/vault/topups/{requestId}/reject` | `teller.vault.approve` @cabang pengajuan | 200 `TellerVaultTopUpRejection` | 400 `reason` kosong; 403 (cabang); 404 tak dikenal; 409 `topup_request_not_pending`/`self_approval` |

- `Idempotency-Key` **wajib** pada buka, tutup, dan top-up vault (operasi kas, D-098): retry tidak
  boleh mendebit vault / menutup sesi / menambah vault dua kali. Replay = 200 + `Idempotent-Replayed`;
  isi beda = 409.
- `GET current` memilih **404** (`params.reason=session_not_open`) alih-alih 200 `{session:null}` —
  konsisten dengan konvensi repo (`params.reason` eksplisit).
- Audit: `teller.session.open`, `teller.session.close`, `teller.vault.topup.submit`,
  `teller.vault.topup.approve`, `teller.vault.topup.reject`. Event outbox (non-akuntansi, tanpa
  header `accounting`): `TellerSessionOpened`, `TellerSessionClosed` (payload memuat variance),
  `TellerVaultTopUpRequested`, `TellerVaultTopedUp` (payload memuat `amount`/`journalId`/
  `balanceAfter`) — untuk UI realtime 088d & gate EOD Fase 3. Jurnal kas **bukan** event: ditulis
  sinkron agar tidak ada saldo berubah tanpa jurnal.

## Gerbang transaksi tunai (T-093b)

- Transaksi tunai (`POST /teller/cash-transactions`) **wajib** punya sesi `OPEN` milik pemanggil di
  cabang rekening **pada `business_date` yang sama**; kalau tidak → 409 `no_open_session` (atau
`session_business_date_mismatch` bila sesi OPEN bertanggal lain), dan
  saldo/jurnal tidak berubah.
- Gerbang berada **di dalam** blok `withIdempotency`: replay yang sah setelah sesi ditutup tetap
  mengembalikan respons tersimpan (bukan 409 palsu).
- Gerbang membaca sesi dengan `FOR KEY SHARE` (`lockOpenSession`): penutupan (`FOR UPDATE`) menunggu
  transaksi tunai in-flight, sehingga movement yang sedang ditulis tidak hilang dari `expected_cash`.
- Setiap transaksi tunai menulis satu baris `teller.cash_movement` (`CASH_IN` untuk setoran,
  `CASH_OUT` untuk penarikan) dengan `transaction_id`-nya, di transaksi DB yang sama.
- **PB (`POST /teller/transfers`) tidak wajib sesi**: pemindahbukuan tidak menggerakkan uang fisik.

## Batas (lihat `docs/ACCEPTED-LIMITS.md`)

- **Pemetaan akun kas adalah usulan pilot** (`101.1`/`101.2`/`101.9`, `ledger/0033`–`0034`):
  `NEEDS-COMPLIANCE-REVIEW` (REG-011), bukan kutipan SAK EP/PSAK. Mengubah pemetaan = migrasi rule
  baru + uji golden, bukan mengubah handler.
- **Sumber dana top-up** tidak diverifikasi ke rekening bank: bukti = alasan pengajuan + akun COA
  yang dipilih pengaju, dan checker menyetujui apa adanya. Penyesuaian **turun** (koreksi selisih
  vault) belum punya endpoint (O-098).
- **Batas nominal kas** (opening float, top-up, transaksi) belum ada — angkanya kebijakan pemilik
  (O-099/K-5). Saldo awal tetap bisa diisi seed/runbook (satu kali, ops).
- **Vault harus sudah ada** sebelum top-up: baris hilang bukan dibuat diam-diam (404
  `vault_not_configured`). Vault kosong juga membuat sesi tidak bisa dibuka — fail-closed, bukan bug.
- **Plafon nominal kas = parameter (D-133, O-099 tertutup)**: `teller.cash.limit_opening_float`
  (pilot 2.000.000), `teller.cash.limit_deposit` (10.000.000), `teller.cash.limit_withdrawal`
  (5.000.000), `teller.vault.limit_topup_per_request` (25.000.000). Dibaca `apps/api/src/cash_limit.nim`
  (scope institusi, tanggal bisnis) dan dicek **di handler** sebelum mutasi; pelanggaran = 409
  `cash_limit_exceeded`/`topup_exceeds_limit`, nominal tepat di plafon diterima, parameter hilang =
  500. Angka = kebijakan pilot (`NEEDS-COMPLIANCE-REVIEW`), bukan regulasi; ubah lewat nilai parameter.
- **Belum ada** akumulasi harian, plafon saldo vault, dan toleransi variance (usulan opsional SME,
  ditunda sampai ada kebutuhan pilot).
- **Rollback binary setelah 093b**: transaksi tunai kembali tanpa sesi sementara sesi masih `OPEN` →
  tutup semua sesi (atau rekonsiliasi manual) sebelum rollback.
- Tanpa rekap/daftar transaksi per sesi (088d/T-108) dan tanpa tutup otomatis sesi lama (T-093 R9).

**HUMAN-REVIEW-REQUIRED**: mutasi vault (opening float, counted cash, top-up T-118) + variance kas
+ jurnal GL kas (AGENTS.md §8).

## Operasional — saldo awal vault (satu kali, ops)

**T-118** mengganti top-up langsung dengan pengajuan + persetujuan (`POST /api/v1/teller/vault/topups`
= `teller.vault.submit`; `.../{requestId}/approve` = `teller.vault.approve`). Baris vault itu
sendiri tetap perlu ada lebih dulu: pengajuan tidak membuat baris baru (404
`vault_not_configured`). Membuat baris awal (satu kali, ops) lewat SQL (di produksi: role owner,
`kran-migrate.env`) atas permintaan pemilik:

```sql
INSERT INTO teller.vault (branch_id, balance) VALUES ('<branch-uuid>', '10000000.0000')
ON CONFLICT (branch_id) DO NOTHING;
```

Atau, bila baris sudah ada, cukup top-up lewat API. Tanpa baris vault, sesi tidak bisa dibuka
(`vault_not_configured`) — fail-closed, bukan bug.

