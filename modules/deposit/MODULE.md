# Modul `deposit` — rekening simpanan

Rekening simpanan anggota (spec §9.2, §23 Fase 2). Nomor rekening dibentuk dari sequence; saldo
disimpan satu baris per rekening sebagai cache untuk operasi teller.

Status: **T-088a** (skema + buka/baca rekening) + **T-088b** (transaksi tunai setor/tarik + posting
jurnal sinkron) + **T-088c** (pemindahbukuan/PB antar rekening) + **T-138c/d** (akrual bunga harian,
jatuh tempo/ARO deposito berjangka). UI teller = T-088d.

## Tabel (migrasi `0001` schema+sequence, `0003` rekening, `0004` transaksi, `0005` immutability, `0006` grant runtime, `0007` transfer, `0008` grant transfer)

| Tabel | Isi |
|---|---|
| `deposit.account` | Identitas rekening: `account_no` (unik), `party_id`, `product_id`, `product_version_id`, `branch_id`, `account_type` (`SAVINGS`/`TIME_DEPOSIT`), `status` (`ACTIVE`/`CLOSED`/`DORMANT` — `0071`), `opened_on`, plus `maturity_date`/`aro_instruction`/`last_activity` untuk deposito berjangka (nullable, T-138b). Satu cabang per rekening. |
| `deposit.account_balance` | Satu baris per rekening: `balance numeric(24,2)` dengan CHECK `balance >= 0`. Cache; sumber kebenaran tetap jurnal ledger (spec §9.1(4)). |
| `deposit.transaction` | Subledger rekening: `tx_type` (`CASH_DEPOSIT`/`CASH_WITHDRAWAL` dari teller, `MATURITY_OUT`/`MATURITY_IN`/`INTEREST_CREDIT` dari jatuh tempo deposito — `0068`, `INTEREST_PAID_EARLY`/`PENALTY_CHARGE` dari PB pencairan dini — `0074`), `account_id`, `amount numeric(24,2) > 0`, `business_date`, `narration`, `journal_id` (FK `ledger.journal`, UNIQUE **`(journal_id, account_id)`**). Satu baris = satu jurnal per rekening; satu jurnal boleh mencatat dua rekening untuk perpindahan jatuh tempo (`NONE`). |
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
- **Nominal bunga**: `domain/interest.nim` (`interestForRange`, T-138c) — `pokok × rate × hari /
  basis`, dibulatkan **sekali** ke sen dengan HALF_EVEN. `HUMAN-REVIEW-REQUIRED` (AGENTS.md §8):
  rumus bunga adalah area kritis.

## Deposito berjangka (T-138b, D-152)

Deposito berjangka adalah **rekening yang sama** dengan `account_type = TIME_DEPOSIT`, bukan tabel
terpisah. Migrasi `deposit/0064_deposit_time_deposit` (bertanda `-- dbtools:contract` karena
mengganti CHECK `account_type` bawaan `0003`; `DROP CONSTRAINT` adalah DDL merusak yang dilarang
jalur expand) menambah `maturity_date`, `aro_instruction`
(`NONE`/`PRINCIPAL`/`PRINCIPAL_AND_INTEREST`), dan `last_activity` — semuanya **nullable**, tanpa
backfill: rekening tabungan tidak punya jatuh tempo. Domain hanya mengenal tipe barunya
(`AccountType.atTimeDeposit`); perilaku jatuh tempo/ARO ada di T-138d, akrual di T-138c, dan dormant
di T-138e (lihat bagian masing-masing).

`status` menerima `DORMANT` sejak `deposit/0071` (contract) bersama aturannya di D-157. Akun/rule GL
bunga ada di `ledger/0065` dengan **`204` BUNGA AKRUAL** — bukan `203`, yang sudah dipakai
`TITIPAN PENGURUS` sejak `ledger/0036` (amendemen D-152). Pokok deposito sendiri masuk
`202 SIMPANAN BERJANGKA` lewat rule berkondisi `accountType = TIME_DEPOSIT` (`ledger/0067`:
`DepositPosted` D 101.2/K 202, `DepositWithdrawn` D 202/K 101.2). Jatuh tempo/ARO ada di T-138d.
Deposito berjangka **belum boleh** dibuka untuk anggota nyata: siklus ARO kedua belum benar
(O-109), penarikan dini diblokir tanpa jalur koreksi (D-156/O-108), dan belum ada endpoint buka
deposito. Nilai parameter akrual **wajib diikat versi produk** (D-152 amendemen kedua) dan tetap
**NEEDS-COMPLIANCE-REVIEW**.

## Akrual bunga harian (T-138c, D-152)

Task day-close `deposit.interest_accrual` (EOD, fase proses, **kritis**, `psByChunkCount`) berjalan
di composition root (`apps/api/src/daycloser_deposit.nim`) karena satu transaksi per chunk menulis
tiga hal sekaligus: baris `deposit.interest_accrual`, jurnal `InterestAccrued`, dan event outbox.

| Aspek | Aturan |
|---|---|
| Rekening | `account_type = TIME_DEPOSIT` dan `status <> 'CLOSED'` (ACTIVE + DORMANT — dormant membatasi transaksi, bukan perjanjian bunga) |
| Atribut | binding versi produk yang dipin rekening: `product.savings.interest_rate`, `day_count_basis`, `rounding_scale`. Tidak ada → **DAY-331**, penutupan ditahan |
| Rentang | dari `opened_on` (atau hari setelah akrual terakhir) sampai tanggal buku, inklusif — dibatasi `maturity_date − 1` bila rekening punya jatuh tempo (D-155) |
| Pembulatan | **sekali per rentang**: `cumulative` = bunga dari `opened_on` dibulatkan ke skala produk; `amount` = `cumulative` − `cumulative` baris terakhir |
| Jurnal | D `501 BEBAN BUNGA` / K `204 BUNGA AKRUAL`, ditulis **sinkron** di transaksi yang sama; event `InterestAccrued` **tanpa** header `accounting` (jurnal sudah ada) |
| Nol | pokok/rate nol atau bagian hari itu nol → baris tercatat (`amount = 0.00`, `journal_id` NULL), **tanpa** jurnal nol |
| Idempoten | PK `(account_id, business_date)` + kunci jurnal `interest.accrual:<akun>:<tanggal>`; tanggal yang sudah punya baris dilewati |

Konsekuensi yang disengaja: `SUM(amount)` per rekening selalu sama dengan satu pembulatan bunga
rentang penuh, jadi tidak ada drift beberapa sen terhadap bunga yang dijanjikan di akhir tenor.
Basis 30/360 bisa menghasilkan 0 hari untuk rentang pendek di akhir bulan; hari itu tidak mencatat
baris dan ketinggalannya ikut pada hari berikutnya (kumulatif dihitung dari `opened_on`).

Kode kegagalan `DAY-330`…`DAY-337` ada di `docs/runbooks/dayclose.md`; semuanya kritis, jadi run
berhenti `FAILED` dan dapat dilanjutkan (`resume`) setelah penyebabnya diperbaiki.

## Jatuh tempo & ARO (T-138d, D-155)

Task day-close `deposit.maturity_aro` (EOD, fase proses, **kritis**, `psByChunkCount`) berjalan
**sesudah** `deposit.interest_accrual` (`dependsOn`) karena bunga hari terakhir tenor harus sudah
tercatat sebelum dipindahkan. Semua langkah satu rekening berada dalam **satu `withTx` per chunk**.

Keputusan per `aro_instruction` (D-155):

| ARO | Pokok | Bunga | Baris subledger | Jurnal |
|---|---|---|---|---|
| `NONE` | pindah ke rekening simpanan, deposito `CLOSED` | bayar ke rekening simpanan | `MATURITY_OUT` (deposito) + `MATURITY_IN` (simpanan, jurnal yang sama) + `INTEREST_CREDIT` (simpanan) | `DepositMatured` D 202/K 201, `InterestPosted` D 204/K 201 |
| `PRINCIPAL` | tetap, `maturity_date` maju satu tenor | bayar ke rekening simpanan | `INTEREST_CREDIT` (simpanan) | `InterestPosted` D 204/K 201 (bunga 0 → tanpa jurnal) |
| `PRINCIPAL_AND_INTEREST` | tetap + bunga dikapitalisasi, `maturity_date` maju | jadi pokok | `INTEREST_CREDIT` (deposito) | `InterestCapitalized` D 204/K 202 |

- **Bunga yang dipindahkan** = `cumulative` akrual terakhir **dikurangi**
  `deposit.account.interest_paid_cumulative` (baseline siklus, D-165). Siklus pertama baseline `0`
  sehingga perilakunya sama dengan sebelumnya; siklus berikutnya hanya membayar selisihnya. Setelah
  membayar/mengapitalisasi, baseline dinaikkan ke `cumulative` di transaksi chunk yang sama. Baris
  `deposit.interest_accrual` tidak diubah (ledger tetap immutable).
- **Tenor perpanjangan** = atribut produk `product.savings.rollover_tenor_days` (hari), dihitung dari
  jatuh tempo lama (D-165). `maturity_date − opened_on` **tidak** dipakai: setelah satu perpanjangan
  nilainya dua kali tenor semula. Tanpa binding, task menahan chunk dengan `DAY-354`.
- **Prasyarat**: rekening simpanan `ACTIVE` **atau `DORMANT`** milik party yang sama di cabang yang
  sama (`activeSavingsAccount`, urut `account_no`), **tanpa** simpanan POKOK/WAJIB — GL-nya ekuitas
  `301.x` sedangkan perpindahan ini mengkredit `201`, dan penarikan POKOK/WAJIB diblokir. Tidak ada
  yang memenuhi → `DAY-343` (pola `DAY-301`), bukan "tidak berlaku". Rekening `DORMANT` direaktivasi
  task `deposit.dormant` pada penutupan yang sama (D-157 amendemen 1). Bila anggota punya beberapa
  tabungan, yang dipakai adalah yang nomornya paling kecil (paling awal dibuka).
- **Idempoten**: keadaan berubah di transaksi yang sama (`CLOSED` atau `maturity_date` maju), jadi
  rekening yang sudah diproses tidak lagi masuk halaman; kunci jurnal `maturity:<akun>:<tanggal>` dan
  `interest.post:<akun>:<tanggal>` adalah lapis kedua.
- **`aro_instruction` kosong = `DAY-341`**, nilai asing = `DAY-346`. Task **tidak menebak** ARO.
- **Paginasi** memakai jendela `row_number()` di atas **seluruh** rekening `TIME_DEPOSIT`, bukan
  `LIMIT/OFFSET` pada himpunan "jatuh tempo": task mengubah `status`/`maturity_date`, dan offset pada
  himpunan yang menyusut akan melewati rekening (akrual aman karena ia tidak mengubah populasi).
- **Keterlambatan** proses tidak menambah bunga (akrual berhenti di `maturity_date − 1`); perpindahan
  diposting pada tanggal buku saat prosesnya berjalan.
- Migrasi tipe baris: `deposit/0068` (contract + destructive, terdaftar di
  `ops/migrations/contract-auto.txt`). Rule GL: `ledger/0069`.
- **Cache saldo hilang bukan saldo nol**: rekening tanpa baris `deposit.account_balance` menahan
  task dengan `DAY-348` sebelum ada mutasi — menutup deposito tanpa memindahkan pokok tidak boleh
  terjadi diam-diam.
- **Proses terlambat lebih dari satu tenor** menahan task dengan `DAY-349`: tanggal jatuh tempo baru
  sudah lewat lagi, dan melanjutkan berarti membayar bunga siklus yang sama dua kali.
- Kode kegagalan `DAY-340`…`DAY-349` serta `DAY-354` ada di runbook + katalog i18n (id+en).
- **Pencairan dini** ada di `handlers_teller` (D-164/D-168): penuh, sebelum jatuh tempo, penalti
  persen dari pokok dari atribut produk, bunga dibayar sampai tanggal cair, rekening `CLOSED`, dan
  `min_balance` produk tidak berlaku karena rekening berakhir di nol.
  - **Tarik tunai**: `DepositWithdrawn` 202/101.2, `InterestPaidEarly` 204/101.2,
    `EarlyWithdrawalPenalty` 101.2/403; kas laci = `pokok + bunga − penalti`.
  - **PB keluar**: `deposit.transfer.amount` = pokok (jurnal `DepositWithdrawnViaTransfer` 202/201),
    bunga dan penalti menjadi baris subledger bertanda di rekening tujuan
    (`INTEREST_PAID_EARLY` +, `PENALTY_CHARGE −`) dengan jurnal `InterestPaidEarlyViaTransfer` (204/201)
    dan `EarlyWithdrawalPenaltyViaTransfer` (201/403). Rekening koran memakai `kind`
    `EARLY_WITHDRAWAL` untuk kedua baris itu.
- **Batas yang belum tertutup**: belum ada endpoint untuk membuka deposito berjangka; setoran tunai
  di tengah tenor masih membuat akrual menilai ulang hari sebelumnya pada pokok baru.
- **NEEDS-COMPLIANCE-REVIEW** (kode akun `202`/`204`/`501`) dan **HUMAN-REVIEW-REQUIRED** (pergerakan
  uang jatuh tempo, AGENTS.md §8) tetap berlaku.

Deposito berjangka kini punya alur jatuh tempo lengkap untuk banyak siklus (baseline akrual per
siklus, tenor dari atribut produk), tetapi belum boleh
dibuka untuk anggota nyata sebelum O-109 diputuskan, penalti penarikan dini (O-108) dan parameter
compliance (O-084) dikonfirmasi.

## Dormant (T-138e, D-152 butir 4, D-157)

Task day-close `deposit.dormant` (EOD, fase proses, **tidak kritis**, `psByChunkCount`, `dependsOn`
`deposit.interest_accrual` + `deposit.maturity_aro`) menandai rekening yang aktivitas terakhirnya
lebih lama dari parameter `deposit.dormant.after_months` (default 12) sebagai `DORMANT`, dan
mengembalikan `DORMANT` ke `ACTIVE` begitu ada aktivitas lagi.

- **Aktivitas** = `max(business_date)` dari `deposit.transaction` dan `deposit.transfer` (kedua
  sisi), dengan `opened_on` sebagai batas bawah. **Bukan** kolom `deposit.account.last_activity`:
  kolom itu tidak pernah ditulis jalur transaksi mana pun (O-111).
- **Batas** memakai `<` terhadap `tanggal buku − N bulan` (aritmetika kalender PostgreSQL).
- **Populasi yang dipaginasi** = `ACTIVE` + `DORMANT`, sehingga perpindahan status di antara
  keduanya tidak menggeser offset.
- **Tidak ada uang yang bergerak**: hanya `status`, `updated_by`, dan `updated_at` yang ditulis.
  Keputusan diulang **di dalam** `UPDATE` (`markDormantIfStale`/`reactivateIfActive`), jadi setoran
  yang commit setelah halaman dibaca tidak diabaikan. Audit per transisi belum ada (O-113), dan
  penutupan otomatis rekening dormant belum diputuskan (O-114).
- Rekening `DORMANT` **tetap diakrualkan** (akrual memakai `status <> 'CLOSED'`) dan **tetap menerima
  setoran tunai**; penarikan/PB ditolak `409 account_not_active` sampai aturan penolakan transaksi
  dormant diputuskan.
- Kode kegagalan: `DAY-350` daftar gagal dibaca (bisa diulang) · `DAY-351` parameter ambang tidak
  terbaca/bukan bulan ≥ 1 · `DAY-352` status rekening tidak dikenal · `DAY-353` status gagal
  disimpan (bisa diulang).

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
- Ambang dormant `deposit.dormant.after_months` (integer, `GLOBAL`/`INSTITUTION`, default pack
  **12**, T-138e/D-152 butir 4). Dibaca task `deposit.dormant` pada tanggal buku; nilai hilang atau
  bukan bulan ≥ 1 = `DAY-351` (fail-closed, bukan tebakan). Nilainya **NEEDS-COMPLIANCE-REVIEW**.
- Atribut akrual (`product.savings.interest_rate`, `day_count_basis`, `rounding_scale`) dibaca dari
  **binding versi produk**, bukan dari `default_pack`; versi produk tanpa ketiganya menahan
  penutupan dengan `DAY-331` (D-152 amendemen kedua).

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

`account_balance` adalah cache; baris di `deposit.transaction` (tunai + perpindahan jatuh tempo) dan
`deposit.transfer` (PB) adalah sumbernya. `kran-api --role=ctl reconcile-deposits [--branch=<uuid>]`
membandingkan
`expected = Σ masuk − Σ keluar` (tunai, perpindahan jatuh tempo, dan PB di kedua arah) dengan cache,
mencetak setiap rekening yang berbeda (termasuk cache yang hilang), dan keluar **1** bila ada selisih.
Baca saja: koreksi harus lewat penyelidikan, bukan ditulis ulang alat ini.

Tanda per jenis baris: `CASH_DEPOSIT`/`MATURITY_IN`/`INTEREST_CREDIT` menambah saldo,
`CASH_WITHDRAWAL`/`MATURITY_OUT` mengurangi. Baris dengan jenis yang tidak dikenal membuat `expected`
kosong (NULL) sehingga rekeningnya **dilaporkan** — bukan dihitung sebagai keluar (D-155).

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
