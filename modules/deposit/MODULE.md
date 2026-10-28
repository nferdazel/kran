# Modul `deposit` — rekening simpanan

Rekening simpanan anggota (spec §9.2, §23 Fase 2). Nomor rekening dibentuk dari sequence; saldo
disimpan satu baris per rekening sebagai cache untuk operasi teller.

Status: **T-088a** (skema + buka/baca rekening) + **T-088b** (transaksi tunai setor/tarik + posting
jurnal sinkron) + **T-088c** (pemindahbukuan/PB antar rekening). UI teller = T-088d.

## Tabel (migrasi `0001` schema+sequence, `0003` rekening, `0004` transaksi, `0005` immutability, `0006` grant runtime, `0007` transfer, `0008` grant transfer)

| Tabel | Isi |
|---|---|
| `deposit.account` | Identitas rekening: `account_no` (unik), `party_id`, `product_id`, `product_version_id`, `branch_id`, `account_type` (`SAVINGS`/`TIME_DEPOSIT`), `status` (`ACTIVE`/`CLOSED`), `opened_on`, plus `maturity_date`/`aro_instruction`/`last_activity` untuk deposito berjangka (nullable, T-138b). Satu cabang per rekening. |
| `deposit.account_balance` | Satu baris per rekening: `balance numeric(24,2)` dengan CHECK `balance >= 0`. Cache; sumber kebenaran tetap jurnal ledger (spec §9.1(4)). |
| `deposit.transaction` | Transaksi tunai (T-088b): `tx_type` (`CASH_DEPOSIT`/`CASH_WITHDRAWAL`), `account_id`, `amount numeric(24,2) > 0`, `business_date`, `narration`, `journal_id` (UNIQUE, FK `ledger.journal`). Satu baris = satu jurnal. |
| `deposit.transfer` | Pemindahbukuan/PB (T-088c): `source_account_id` + `destination_account_id` (FK `deposit.account`, CHECK berbeda), `amount numeric(24,2) > 0`, `business_date`, `narration`, `journal_id` (UNIQUE, FK `ledger.journal`). Satu baris = satu perpindahan = satu jurnal. |

`deposit.account_seq` memberi nomor urut rekening. **Nomor berkas tidak berurutan rapat**: tabel
akun ada di `0003`, bukan `0002`, karena urutan migrasi global `(seq, modul, berkas)` menjalankan
`deposit/*` **sebelum** `product/*` pada seq yang sama — sedangkan tabel ini mem-FK
`product.product`/`product.product_version` yang dibuat `product/0002`. `0002` sengaja dilewati
(diverifikasi `./task dbtools validate`). `deposit.transaction` ada di `0004` dan `deposit.transfer`
di `0007` karena mem-FK `ledger.journal` yang baru dibuat `ledger/0003` pada seq 3 (dan `deposit/0003`
berjalan **sebelum** `ledger/0003`). `deposit/0008` menambah grant runtime untuk tabel `0007`
(`0006` hanya mencakup tabel yang ada saat itu).

## Invarian

- **Saldo tidak boleh negatif** di DB (`CHECK balance >= 0`) — backstop; operation yang menolak
  saldo negatif ada di jalur tulis (T-088b).
- **Baris transaksi immutable** (`deposit/0005`): UPDATE/DELETE/TRUNCATE ditolak trigger yang
  memakai `ledger.reject_mutation()`; koreksi = jurnal pembalik + baris baru.
- **Uang tanpa float**: saldo `numeric(24,2)`; di kode lewat tipe `Money` (`kernel/money`), API
  selalu mengirim desimal string 2 desimal.
- **Tanpa kolom `currency`**: asumsi satu mata uang (spec §2.2; T-088 §8 butir 6).
- **`status` hanya `ACTIVE`/`CLOSED`**: `DORMANT`/`FROZEN` belum punya aturan (T-088 §8 butir 8).
- **Ordinary FK** ke `party.party`, `product.product`, `product.product_version`; `branch_id` tanpa
  FK (master cabang hidup di `platform.branch`, D-130) — kesamaan cabang party↔rekening ditegakkan
  use case (`branch_mismatch`), bukan DB.
- **Nomor rekening** (D-130, menggantikan D-123): **kode cabang 3 digit** (`platform.branch.code`) +
  **nomor urut 7 digit** (`deposit.account_seq`, global). Contoh `0010000006` = cabang `001`,
  rekening ke-6. Tanpa check digit; `POST /deposit/accounts` menolak cabang yang belum terdaftar
  (409 `branch_not_registered`). Format lain (mis. check digit) masih bisa diminta compliance
  (O-104) dan tidak boleh diasumsikan modul lain.

## API

| Endpoint | Izin | Sukses | Error |
|---|---|---|---|
| `POST /api/v1/deposit/accounts` | `deposit.account.manage` | 201 `DepositAccount` | 400 body; 403 (cabang); 409 `party_not_active`/`branch_mismatch`/`product_not_active`; 409 idempotensi |
| `GET /api/v1/deposit/accounts/{accountId}` | `deposit.account.read` | 200 `DepositAccount` | 403 (cabang), 404 |
| `GET /api/v1/deposit/accounts?partyId=` | `deposit.account.read` | 200 `{items:[]}` | 400 uuid, 403 |
| `POST /api/v1/teller/cash-transactions` | `teller.transaction.post` | 201 `CashTransaction` | 400 arah/nominal/narration; 403 (cabang); 404 akun; 409 `insufficient_funds`/`period_closed`/`account_not_active`/`cash_limit_exceeded`; 409 idempotensi |
| `POST /api/v1/teller/transfers` | `teller.transaction.post` (**kedua** cabang) | 201 `Transfer` | 400 akun sama/nominal/narration; 403 (cabang); 404 akun; 409 `insufficient_funds`/`period_closed`/`account_not_active`; 409 idempotensi |

- `Idempotency-Key` **wajib** di `POST` (pola T-085: `requireIdempotencyKey`/`withIdempotency`);
  replay 200 + `Idempotent-Replayed: true`, hash beda 409.
- Objek ber-cabang: izin dipegang di cabang rekening (`authorizedAtBranch`). Daftar disaring per
  baris (D-062), bukan 403 seluruh daftar.
- Validasi lintas-modul (party harus ACTIVE dan satu cabang, produk `SAVINGS` dengan versi `ACTIVE`
  berlaku) dilakukan composition root; repo tetap SQL murni.

## Transaksi tunai & posting jurnal (T-088b)

- **Satu transaksi DB** (`withDbTx` + `withIdempotency`): kunci/ubah saldo, posting jurnal **sinkron**
  (bukan outbox), baris `deposit.transaction`, audit, event. Gagal di tengah → rollback seluruhnya.
- **Saldo** dijaga `UPDATE ... WHERE balance - ? >= min_balance` (tarik) pada baris `account_balance`;
  0 baris = 409 `insufficient_funds`. Baris terkunci otomatis → dua koneksi bersamaan terserialisasi.
  `min_balance` dari binding versi produk (`product.savings.min_balance`); tidak ada binding → 0.
- **Jurnal** dari posting rule data (`ledger.posting_rule`): setor = `DepositPosted` (D 101/K 201),
  tarik = `DepositWithdrawn` (D 201/K 101, migrasi `ledger/0012`). `journal.idempotency_key =
  "teller:<principalId>:<Idempotency-Key>"` (≤200) = lapis kedua anti-jurnal-ganda.
- **Event outbox** (`CashTransactionPosted`, `journal.posted`) **tanpa** header `accounting` supaya
  konsumen `ledger` tidak memposting jurnal kedua.
- **HUMAN-REVIEW-REQUIRED**: mutasi saldo + jurnal double-entry (AGENTS.md §8).

## Pemindahbukuan / PB (T-088c)

- **Satu transaksi DB** (`withDbTx` + `withIdempotency`): kunci kedua baris saldo, kurangi sumber,
  tambah tujuan, jurnal sinkron, baris `deposit.transfer`, audit, event non-akuntansi.
- **Anti-deadlock**: baris saldo kedua rekening dikunci `SELECT ... FOR UPDATE` dalam urutan
  `account_id` **naik**. Dua PB berlawanan arah (A→B dan B→A) selalu mengunci baris terkecil dulu,
  jadi tidak ada siklus tunggu. Syarat saldo (`UPDATE ... WHERE balance - ? >= min`) dievaluasi
  **setelah** kedua baris terkunci, jadi 0 baris = 409 `insufficient_funds` tanpa kredit nyangkut di
  tujuan. `min_balance` dari binding versi produk rekening **sumber**.
- **Jurnal** dari posting rule `DepositTransferred` (migrasi `ledger/0013`): D 201 / K 201. **Batas:**
  kedua sisi GL akun `201` yang sama, jadi jurnal PB **net-nol di buku besar**; perpindahan **per
  rekening** dicatat di `deposit.transfer` (sumber & tujuan). Rekonsiliasi cache = T-101 (selesai);
  **GL per pemilik** belum ada dan tetap Fase 3 (lihat `docs/ACCEPTED-LIMITS.md`).
- **Izin** `teller.transaction.post` diperiksa di **kedua** cabang rekening (sumber & tujuan).
- **HUMAN-REVIEW-REQUIRED**: mutasi dua saldo + jurnal (AGENTS.md §8).

## Hitung hari bunga (T-138a, D-152)

`domain/daycount.nim` — murni, tanpa uang dan tanpa I/O:

- `DayCountBasis` (`dcAct365`/`dcAct360`/`dcThirty360`, nilai string sama dengan parameter
  `product.savings.day_count_basis`), `parseDayCountBasis` (tanpa fallback; nilai tak dikenal
  `ValueError`), `basisDays` (365/360/360), `accrualDays(basis, startsOn, endsOn)`.
- `THIRTY_360` memakai konvensi **30/360 US (NASD)** dengan aturan tertulis di docstring; rentang
  pendek di akhir bulan bisa menghasilkan 0 hari (artefak konvensi). `NEEDS-COMPLIANCE-REVIEW`:
  konvensi ini perlu konfirmasi compliance, dan `ACT_365` adalah default institusi (D-152).
- **Nominal bunga belum ada di sini** (butuh `Money` × rate × hari, pembulatan skala 2, dan review
  manusia — AGENTS.md §8). `accrualDays` hanya menjawab berapa hari yang harus dikalikan.

## Deposito berjangka (T-138b, D-152)

Deposito berjangka adalah **rekening yang sama** dengan `account_type = TIME_DEPOSIT`, bukan tabel
terpisah. Migrasi `deposit/0064_deposit_time_deposit` (bertanda `-- dbtools:contract` karena
mengganti CHECK `account_type` bawaan `0003`; `DROP CONSTRAINT` adalah DDL merusak yang dilarang
jalur expand) menambah `maturity_date`, `aro_instruction`
(`NONE`/`PRINCIPAL`/`PRINCIPAL_AND_INTEREST`), dan `last_activity` — semuanya **nullable**, tanpa
backfill: rekening tabungan tidak punya jatuh tempo, dan arti "aktivitas" baru ditetapkan bersama
task dormant. Domain hanya mengenal tipe barunya (`AccountType.atTimeDeposit`); perilaku jatuh
tempo/ARO masih tugas T-138d, akrual T-138c, dan dormant T-138e.

`status` **belum** menerima `DORMANT`: nilainya ditetapkan T-138e bersama aturannya. Rule/akun GL
bunga (D-152: `203 BUNGA AKRUAL`) **belum** ada — kode `203` sudah dipakai `TITIPAN PENGURUS`
(`ledger/0036`), jadi penomoran akun akrual menunggu keputusan pemilik. Nilai parameter default
(2,5% p.a., `ACT_365`) tetap **NEEDS-COMPLIANCE-REVIEW** (D-152).

## Event

- **Buka rekening**: tanpa event outbox — hanya audit `deposit.account.open` (belum ada konsumen,
  prinsip: jangan buat semantik tanpa pemakai).
- **Transaksi tunai** (T-088b): `CashTransactionPosted` (payload transaksi) + `journal.posted`,
  keduanya **non-akuntansi** (tanpa header `accounting`) agar konsumen `ledger` tidak memposting
  jurnal kedua. Jurnal sudah ditulis sinkron di transaksi DB yang sama.
- **Pemindahbukuan** (T-088c): `TransferPosted` (payload sumber/tujuan) + `journal.posted`,
  keduanya **non-akuntansi** (alasan sama). Jurnal `DepositTransferred` ditulis sinkron.

## Parameter

Tidak ada parameter baru di seed/packs untuk T-088b:
- Saldo minimum dibaca dari **binding versi produk** `product.savings.min_balance` (sudah terdaftar
  di pack `base`); tidak ada binding → 0.
- Batas nominal transaksi tunai lewat **parameter teller** (T-093/D-133):
  `teller.cash.limit_deposit`/`limit_withdrawal` dicek di handler teller sebelum mutasi (409
  `cash_limit_exceeded`); limit harian kumulatif belum ada — **NEEDS-COMPLIANCE-REVIEW**.

## Batas

- PB (pemindahbukuan antar rekening) = T-088c: **stuktur** ada (tabel `deposit.transfer` + endpoint),
  tetapi **GL per pemilik belum terpisah** — kedua sisi jurnal akun `201` (net-nol); perpindahan
  per rekening ada di `deposit.transfer`. Pemodelan GL per pemilik tetap terbuka untuk Fase 3 (T-101 hanya menutup rekonsiliasi cache).
- Nomor rekening: kode cabang + nomor urut (D-130); check digit belum ada, dan modul lain tidak
  boleh mengasumsikan lebar/isi nomor.
- Satu cabang per rekening; pindah cabang belum dimodelkan.
- Batas nominal per transaksi tunai sudah ada (parameter teller, D-133); akumulasi/limit harian
  belum ada — **NEEDS-COMPLIANCE-REVIEW**.

## Rekonsiliasi cache (T-101)

`account_balance` adalah cache; baris di `deposit.transaction` (tunai) dan `deposit.transfer` (PB)
adalah sumbernya. `kran-api --role=ctl reconcile-deposits [--branch=<uuid>]` membandingkan
`expected = Σ tunai masuk − Σ tunai keluar + Σ PB masuk − Σ PB keluar` dengan cache, mencetak setiap
rekening yang berbeda (termasuk cache yang hilang), dan keluar **1** bila ada selisih. Baca saja:
koreksi harus lewat penyelidikan, bukan ditulis ulang alat ini.

Kenapa bukan `journal_line`: kedua kaki PB memakai akun `201` yang sama (net-nol), jadi jurnal tidak
bisa memisahkan saldo per rekening (D-124). Jurnal simpanan yang dibalik di ledger juga tidak
memutar baris simpanan (T-123).

## Jenis simpanan & cetak (T-111, T-094)

- `Account.savingsKind` dibaca lewat join `product.product` (bukan kolom rekening); `""` = belum
  terklasifikasi. Teller memberi label jujur: NULL bukan "Pokok".
- Setoran POKOK/WAJIB diposting ke ekuitas `301.1`/`301.2` lewat rule `DepositPosted` berkondisi
  `savingsKind`. Tarik dan PB yang menyentuh POKOK/WAJIB diblokir 409 `savings_kind_locked`; PB
  beda jenis (keduanya terisi) 409 `transfer_kind_mismatch`; NULL ↔ SUKARELA/TABUNGAN tetap boleh
  (keduanya liabilitas `201`).
- Cetak: `GET /teller/cash-transactions/{id}` (slip, cetak ulang) dan `GET /deposit/accounts/{id}/
  statement` (subledger A4, batas 500 baris, tanpa saldo berjalan). Halaman print di web memakai
  browser print; tidak ada PDF server (D-127, `ACCEPTED-LIMITS` §4b).
