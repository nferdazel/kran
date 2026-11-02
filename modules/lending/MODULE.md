# Modul `lending` — pinjaman anggota

Pinjaman (spec §9.2, §23 Fase 4): produk pinjaman berversi, akad/fasilitas, jadwal angsuran, lalu
kolektibilitas/PPAP di fase yang sama. Status: **T-161** (model + skema) + **T-162** (mesin jadwal) + **T-163** (pengajuan &
persetujuan) + **T-164** (pencairan) + **T-165** (pembayaran angsuran) + **T-166**
(kolektibilitas) + **T-167** (PPAP/CKPN) + **T-168** (restrukturisasi & hapus buku) + **T-169**
(baca & daftar dengan scoping cabang).
pengajuan/pencairan T-163/T-164; task day-close T-166/T-167; API/UI T-169/T-170.

Keputusan angka & aturan: **D-180**. Rencana fase: `docs/proposals/fase4-lending.md`.

## Batas modul

- `lending` **tidak** menyimpan data anggota (itu `party`) dan tidak memposting jurnal sendiri
  (itu `ledger` lewat posting rule). Yang ia punya: syarat pinjaman, jadwal, dan saldo pinjaman.
- Metode jadwal, tenor, suku bunga/margin, dan urutan alokasi datang dari **versi produk** yang
  di-pin pinjaman + parameter (spec §10, AGENTS.md §1.2). Tidak ada angka bisnis di `domain/`.

## Tabel (migrasi `0076` schema, `0077` produk+versi, `0078` pinjaman+saldo, `0079` jadwal, `0080` grant)

| Tabel | Isi |
|---|---|
| `lending.loan_product` | Identitas produk: `code` unik, nama. Atribut bisnis ada di versi, bukan di sini. |
| `lending.loan_product_version` | `product_id`, `version_no`, `status` (`DRAFT`/`ACTIVE`), `schedule_method` (`FLAT`/`EFFECTIVE`/`ANNUITY`), `tenor_months`, `annual_rate` (skala micro `Rate`), `allocation_order` (teks `PRINCIPAL,INTEREST,PENALTY` divalidasi domain), pembuat + penyetuju. Versi `ACTIVE` immutable. |
| `lending.loan` | Akad/fasilitas: `party_id`, `product_version_id` (di-pin, bukan produk), `branch_id`, `principal`, `status` (`APPLIED`/`APPROVED`/`ACTIVE`/`CLOSED`/`WRITTEN_OFF`), `disbursed_on`/`maturity_on` (NULL sebelum cair), `applied_by`, `approved_by`. CHECK: penyetuju ≠ pembuat saat status melewati `APPLIED`. |
| `lending.loan_balance` | Satu baris per pinjaman: `principal_outstanding`, `interest_overdue`, `penalty_outstanding` dengan CHECK `>= 0`. Cache; sumber kebenaran tetap `lending.installment` + jurnal ledger. |
| `lending.installment` | Satu baris per jatuh tempo: `no`, `due_on`, `principal_due`, `interest_due`, `penalty_due`, `paid_principal`, `paid_interest`, `paid_penalty`, `paid_on`. UNIQUE `(loan_id, no)`. CHECK: setiap `paid_*` ≤ `*_due` dan ≥ 0. |

**Jadwal disimpan per baris** (D-180 butir 1): membentuk ulang jadwal dengan metode lain setelah
pencairan berarti mengubah angka yang sudah disepakati anggota, jadi itu bukan operasi baca.

## Kalkulasi jadwal (`domain/schedule.nim`, T-162)

| Metode | Pokok per baris | Bunga per baris |
|---|---|---|
| `FLAT` | rata (`pokok/tenor`), sisa di baris terakhir | rata (`pokok × rate × tenor/12`, satu pembulatan), sisa di baris terakhir |
| `EFFECTIVE` | rata, sisa di baris terakhir | `saldo pokok tersisa × rate/12`, dibulatkan per baris (menurun) |
| `ANNUITY` | `angsuran − bunga` | `saldo pokok tersisa × rate/12`, dibulatkan per baris |

- Bunga dibulatkan **sekali per baris** (half-to-even, sama seperti akrual simpanan). `Σ pokok`
  selalu **tepat** sama dengan pokok pinjaman; sisa pembulatan berakhir di baris terakhir, tidak
  disebar.
- Angsuran anuitas dicari dengan pencarian biner atas amortisasi bilangan bulat (angsuran terkecil
  yang menutup tenor), bukan `float`: rumus `A = P·i/(1−(1+i)^−n)` butuh pangkat pecahan yang tidak
  bisa dijamin tepat dalam sen.
- Tanggal jatuh tempo = tanggal kalender bulanan, hari dijepit ke akhir bulan (31 Jan + 1 bulan =
  28/29 Feb). Bukan penambahan 30 hari.
- Tidak ada kalender hari libur; penggeseran tanggal jatuh tempo karena libur belum ada (Fase 5).

## Invarian

- Baris jadwal yang sudah menerima pembayaran **immutable** (trigger memakai
  `ledger.reject_mutation()` seperti `deposit.transaction`); koreksi lewat jurnal pembalik + baris
  baru, bukan `UPDATE`.
- Tidak ada saldo negatif (`CHECK`), tidak ada `paid` melebihi `due`.
- Versi produk yang sudah `ACTIVE` tidak boleh diubah; perubahan = versi baru (pola `product`/T-086).

## Parameter (seed `lending/seeds/params.yaml`)

| Key | Isi | Status nilai |
|---|---|---|
| `lending.allocation_order` | urutan alokasi pembayaran (daftar terurut) | diputuskan pemilik: **parameter**, bukan kode (D-180 butir 4) |
| `lending.collectibility.dpd_bounds` | batas DPD per golongan 1–5 | `NEEDS-COMPLIANCE-REVIEW` (REG-204 `V!`; D-180 butir 2) |
| `lending.ppap.rates` | persentase penyisihan per golongan | `0,5/3/10/50/100` mengadopsi POJK 1/2024 Pasal 19 (D-196); tetap `NEEDS-COMPLIANCE-REVIEW` |
| `lending.restructure.clean_periods` | periode pembayaran bersih sebelum batas golongan pasca-restrukturisasi dilepas | `NEEDS-COMPLIANCE-REVIEW` (D-197, POJK 1/2024: 3 periode) |
| `lending.loan.max_principal` | plafon pengajuan pinjaman | `komersial-konservatif` + `NEEDS-COMPLIANCE-REVIEW` (Rp100 juta, T-163) |

Nilai di atas **bukan** angka final untuk pilot data nyata; lihat O-001.

## Pengajuan & persetujuan (T-163)

| Rute | Izin | Keluaran |
|---|---|---|
| `POST /api/v1/lending/loans` | `lending.loan.submit` (di cabang anggota) | `201` pinjaman `APPLIED`, audit `lending.loan.submit`, event `LoanSubmitted` |
| `POST /api/v1/lending/loans/{loanId}/approve` | `lending.loan.approve` (di cabang pinjaman) | `200` pinjaman `APPROVED`, audit `lending.loan.approve`, event `LoanApproved` |

- **Cabang** pinjaman diambil dari data anggota, bukan dari badan permintaan: parameter `BRANCH`
  yang diambil dari klien bisa dipakai untuk menaruh pinjaman di cabang lain.
- **Empat mata** ditegakkan tiga kali: `assertDistinctActors` (domain), `409 self_approval`
  (handler, dengan alasan yang dibaca operator), dan CHECK `approved_by <> applied_by` (DB).
- **Plafon** `lending.loan.max_principal` dibaca dari parameter institusi; tepat di plafon diterima,
  di atasnya `409 limit_exceeded`. Parameter yang hilang/rusak = 500, bukan plafon tak terbatas.
- **Balapan** dua penyetuju diselesaikan `SELECT … FOR UPDATE` + `UPDATE … WHERE status='APPLIED'`;
  yang kalah menerima `409 not_applied`.
- **Belum ada**: penolakan pengajuan (`REJECTED`) dan penomoran pinjaman bisnis. Persetujuan tidak
  memindahkan uang dan tidak membentuk jadwal — itu pencairan (di bawah).

## Pencairan (T-164, D-182)

`POST /api/v1/lending/loans/{loanId}/disburse` · izin `lending.loan.disburse` (migrasi
`platform/0084`; `lending_maker` + `platform_admin`) · **`Idempotency-Key` wajib**.

Satu transaksi DB: jadwal angsuran dibentuk dari atribut versi produk (metode/tenor/rate), jurnal
`D 110 Piutang Pembiayaan / K 201 Simpanan Anggota` dari rule `LoanDisbursed`, baris subledger
`LOAN_DISBURSEMENT` + saldo rekening anggota, status `APPROVED → ACTIVE`, audit
`lending.loan.disburse`, event `LoanDisbursed`.

| Ditolak | `params.reason` |
|---|---|
| Belum disetujui | `not_approved` |
| Sudah dicairkan | `already_disbursed` (kalah balapan / permintaan kedua) |
| Rekening bukan milik peminjam | `account_party_mismatch` |
| Rekening di cabang lain | `account_branch_mismatch` |
| Rekening tidak `ACTIVE` | `account_not_active` |
| Rekening tanpa baris saldo | `account_without_balance` |
| Jadwal tidak bisa dibentuk | `schedule_invalid` |

- **Uang tunai tidak keluar di sini.** Pencairan mengkredit rekening simpanan; anggota menarik tunai
  lewat teller (`CASH_WITHDRAWAL`) dari rekening itu. Alasannya di D-182: `teller.cash_movement`
  mewajibkan `deposit.transaction`, dan tabel itu mewajibkan rekening simpanan — jalur tunai khusus
  akan mengubah invarian `expected_cash` penutupan sesi.
- **Replay** dengan kunci + isi sama menjawab `200` + `Idempotent-Replayed` dengan isi respons asli;
  tidak ada jadwal/jurnal/transaksi kedua (dibuktikan test).
- **Koreksi** pencairan memakai jurnal pembalik (spec §9.1(3)), bukan status baru.

## Pembayaran angsuran (T-165, D-183)

`POST /api/v1/lending/loans/{loanId}/payments` · izin `lending.loan.pay` (migrasi `platform/0088`;
`lending_maker` + `platform_admin`) · **`Idempotency-Key` wajib**.

Jadwal dibaca `FOR UPDATE` (tertua lebih dulu), nominal dialokasikan menurut parameter
`lending.allocation_order`, lalu satu transaksi DB: `paid_*` bertambah, saldo rekening sumber
berkurang (tanpa menembus saldo minimum produk), **satu jurnal per komponen yang tidak nol**
(`LoanPrincipalPaid` D 201/K 110, `LoanInterestPaid` D 201/K 401, `LoanPenaltyPaid` D 201/K 403),
**satu baris subledger `LOAN_PAYMENT` per komponen** — masing-masing menunjuk jurnalnya sendiri,
karena satu baris `deposit.transaction` hanya bisa menunjuk satu jurnal — cache saldo pinjaman
turun, audit `lending.loan.pay`, event `LoanInstallmentPaid`.

| Ditolak | `params.reason` |
|---|---|
| Belum disetujui / belum dicairkan | `not_approved` / `not_disbursed` |
| Sudah tidak berjalan | `loan_inactive` |
| Nominal melebihi sisa kewajiban | `amount_exceeds_outstanding` |
| Saldo tidak cukup (atau menembus saldo minimum) | `insufficient_balance` |
| Rekening bukan milik peminjam / cabang lain / tidak aktif | `account_party_mismatch` / `account_branch_mismatch` / `account_not_active` |
| Jadwal berubah saat diproses | `allocation_conflict` |

- **Kelebihan bayar ditolak**, tidak dikreditkan ke pokok berikutnya: belum ada keputusan bisnis
  untuk uang muka (D-183).
- **Pelunasan tidak mengubah status** menjadi `CLOSED` — penutupan akad menyangkut pelepasan
  agunan/berkas. `principalOutstanding: "0.00"` adalah tandanya.
- **Trigger `0079` dilonggarkan `0089`**: baris yang sudah dibayar tetap tidak bisa dihapus dan
  kewajibannya beku, tetapi boleh menerima pembayaran berikutnya (`paid_*` hanya naik).

## Kolektibilitas (T-166, D-184)

Task day-close `lending.dpd_regrade` (`apps/api/src/daycloser_lending.nim`) menilai setiap pinjaman
`ACTIVE` sekali per tanggal buku:

- **DPD** = hari sejak tanggal jatuh tempo angsuran **belum lunas tertua** (bukan tanggal cair, bukan
  pembayaran terakhir). Semua angsuran lunas → DPD 0, status tetap `ACTIVE` (D-183).
- **Golongan** dari ambang parameter `lending.collectibility.dpd_bounds` (seed `[90,120,180]`,
  `NEEDS-COMPLIANCE-REVIEW`): `0` lancar, `1–90` dalam perhatian khusus, `91–120` kurang lancar,
  `121–180` diragukan, `>180` macet. Parameter hilang/rusak → task gagal `DAY-372`.
- **Pasca-restrukturisasi** (O-123, D-197): pinjaman yang punya `grade_cap` tidak dinilai hanya dari
  DPD jadwal baru. Batasnya dari golongan **sebelum** restrukturisasi — diragukan/macet → paling
  tinggi kurang lancar, selain itu tidak berubah — dan dilepas setelah
  `lending.restructure.clean_periods` angsuran terakhir yang sudah jatuh tempo dibayar tepat waktu.
  Penurunan tetap boleh; yang ditahan hanya perbaikan.
- **Snapshot** `lending.collectibility_snapshot` ber-PK `(loan_id, business_date)` = idempotensi;
  kolom `lending.loan.collectibility` hanya nilai terkini. Run kedua pada tanggal yang sama
  melaporkan `skipped` dan tidak menerbitkan event kedua.
- **Tidak kritis**: tidak memindahkan uang. PPAP (T-167) yang membuat jurnal dan harus kritis.
- Audit satu per chunk berisi daftar pinjaman yang berubah; event `CollectibilityChanged` hanya saat
  golongan benar-benar berubah (termasuk dari `NULL`).

## PPAP/CKPN (T-167, D-185)

Task day-close `lending.ppap_provision`, **kritis** (menulis jurnal beban penyisihan), bergantung pada
`lending.dpd_regrade` lewat `dependsOn`. Satu chunk = satu halaman pinjaman ternilai:

- **Dasar** = `lending.loan_balance.principal_outstanding`; **tarif** dari parameter
  `lending.ppap.rates` (seed `["0.5","3","10","50","100"]` persen, urutan = urutan golongan,
  mengadopsi POJK 1/2024 Pasal 19 — D-196; parameter salah bentuk/jumlah → `DAY-380`, bukan tarif nol).
- **Snapshot** `lending.ppap_snapshot` ber-PK `(loan_id, business_date)` menyimpan `grade`,
  `base_amount`, `rate_micro`, `allowance`. Yang dijurnal adalah **selisih** terhadap penyisihan
  terakhir **sebelum** tanggal buku, bukan angka mutlak.
- **Jurnal** neto per cabang per chunk: `PpapProvisioned` (D 503 / K 111) bila bertambah,
  `PpapReleased` (D 111 / K 503) bila berkurang — jurnal pembalik, bukan nominal negatif.
- **Atomik**: snapshot + jurnal dalam satu `withTx`, jadi "Δ subledger == Δ GL" adalah konsekuensi,
  bukan harapan. Run ulang tanggal yang sama → `written: 0`, `skipped: n`, tanpa jurnal kedua.
- **Fail-closed**: pinjaman `ACTIVE` tanpa penilaian kolektibilitas tanggal itu → `DAY-383`;
  pinjaman tidak aktif yang masih menyimpan penyisihan → `DAY-384` (aturan pelepasan menunggu T-168).

Kode kegagalan: `DAY-380` tarif tidak terbaca/rusak, `DAY-381` halaman gagal dibaca, `DAY-382`
penyisihan/jurnal/audit gagal disimpan, `DAY-383` prasyarat regrading hilang, `DAY-384` penyisihan
menggantung pada pinjaman tidak aktif, `DAY-385` dasar/penyisihan tersimpan bukan nominal sah,
`DAY-386` konfigurasi posting rule penyisihan tidak sah.

## Baca & daftar (T-169)

`GET /api/v1/lending/loans?partyId=&status=&limit=` · `GET /api/v1/lending/loans/{loanId}` · izin
`lending.loan.read`.

- Daftar disaring **per baris** menurut cabang yang izinnya dipegang (pola D-062,
  `loadBranchAuthz` sekali per permintaan), bukan 403 seluruh daftar.
- Detail memuat saldo (`principal_outstanding`, `interest_overdue`, `penalty_outstanding`),
  golongan terkini, **jadwal aktif saja**, dan riwayat versi jadwal.
- Pinjaman di cabang lain dijawab **404**, sama seperti id yang tidak ada: 403 akan membocorkan
  keberadaan akad di cabang lain.
- `status`/`limit` divalidasi (nilai salah → 400), `limit` dipotong ke batas atas respons.
- Layar operator `/app/loans` dan `/app/loans/{loanId}` (T-170/T-173) membaca data ini dan
  menjalankan empat aksi tulis dengan pratinjau sebelum uang bergerak: pencairan, pembayaran
  angsuran, restrukturisasi, dan hapus buku. Rekening sumber dipilih dari
  `GET /deposit/accounts?partyId=` (hanya `ACTIVE` yang ditawarkan, server tetap memvalidasi);
  `Idempotency-Key` dibuat saat dialog konfirmasi dibuka; tidak ada aritmetika uang di peramban —
  nominal dikirim apa adanya dan `params.reason` dipetakan ke pesan yang menyebut sebabnya.

## Laporan (T-171)

`GET /api/v1/lending/reports/arrears?asOf=` · `GET .../allowance?asOf=` · `GET .../reconciliation` ·
izin `lending.loan.read`.

- **Tunggakan/aging**: potret per tanggal buku dari `lending.installment` jadwal aktif (bukan cache
  `loan_balance`). `items` hanya pinjaman yang punya angsuran lewat jatuh tempo bersisa; `aging`
  adalah agregatnya per golongan — keranjang aging = golongan karena ambangnya sama (D-180).
  Golongan diambil dari snapshot tanggal itu; bila regrading belum berjalan, DPD dihitung dengan
  ambang yang berlaku pada `asOf`.
- **Penyisihan**: `ppap_snapshot` tanggal itu apa adanya; `mixedRates` menandai golongan yang
  tarifnya berubah di tengah hari.
- **Rekonsiliasi**: GL `110`/`111` dari **jurnal** versus subledger saat ini. Identitas:
  `GL 110 = Σ sisa pokok` dan `GL 111 = Σ penyisihan terakhir − Σ allowance_applied` (hapus buku).
  Selisih dilaporkan bertanda.
- Ketiganya menuntut izin pada **tingkat institusi**: laporan agregat lintas cabang bukan hak
  pemegang izin satu cabang (403), berbeda dari daftar pinjaman yang disaring per baris.
- Tidak ada UI laporan; angka tersedia lewat API dan diverifikasi `itapi_lending_reports`.

## Restrukturisasi (T-168, D-186)

`POST /api/v1/lending/loans/{loanId}/restructure` · izin `lending.loan.restructure` (migrasi
`platform/0096`; `lending_maker` + `platform_admin`) · **`Idempotency-Key` wajib**.

Jadwal lama **diarsipkan** (`installment.superseded_on`), jadwal **versi baru** ditulis dengan
`schedule_version = 2…` dan nomor angsuran **berlanjut** (`firstInstallmentNo`), karena
`payment_allocation` menunjuk nomor tanpa versi. Versi dicatat di `lending.loan_schedule` (versi 1
dibuat saat pencairan).

- **Dasar jadwal baru = sisa pokok**; tunggakan bunga/denda jadwal lama **dilepas** (D-186).
- **Tarif & metode** diambil dari versi produk — restrukturisasi tidak mengubah harga.
- **Kolektibilitas kembali lancar** karena DPD dibaca dari jadwal aktif (O-123,
  `NEEDS-COMPLIANCE-REVIEW`).
- Pembayaran setelah restrukturisasi hanya menyentuh baris aktif; baris arsip tidak bisa dibayar
  (`installmentsForUpdate` menyaring `superseded_on`).
- Ditolak: pinjaman belum cair (`not_disbursed`), sudah tidak berjalan (`loan_inactive`), bentuk
  permintaan salah (`tenorMonths < 1`, `reason` kosong → 400).

## Hapus buku (T-168, D-186)

`POST /api/v1/lending/loans/{loanId}/write-off` · izin `lending.loan.write_off` (migrasi
`platform/0096`; `lending_checker` + `platform_admin`, **bukan** `lending_maker`) ·
**`Idempotency-Key` wajib**.

Syarat: pinjaman `ACTIVE` dan golongan kolektibilitas terkini **`LOSS`**. Nilai yang dihapus =
**seluruh sisa kewajiban** jadwal aktif.

| Jurnal | Debit | Kredit | Kapan |
|---|---|---|---|
| `LoanWriteOffProvisioned` | `111` penyisihan | `110` piutang | bagian yang ditutup penyisihan |
| `LoanWriteOffExpense` | `504` beban hapus buku | `110` piutang | kekurangan yang menjadi beban |

Dua jurnal karena template memaksa satu debit + satu kredit; bagian nol tidak dijurnal. Setelahnya:
status `WRITTEN_OFF` + `written_off_on`/`written_off_by`/`written_off_reason` (CHECK DB memaksa
ketiganya), rincian nilai di `lending.writeoff`, dan `loan_balance` nol.

- **Penyisihan terpakai** — pemeriksaan `DAY-384` membandingkan penyisihan terakhir dengan
  `lending.writeoff.allowance_applied`, jadi hapus buku tidak menggagalkan penutupan buku.

## Pemulihan pasca hapus buku (T-176, D-191)

`POST /api/v1/lending/loans/{loanId}/recovery` · izin `lending.loan.recovery` (migrasi
`platform/0099`; `lending_checker` + `platform_admin`, **bukan** `lending_maker`) ·
**`Idempotency-Key` wajib**.

Pinjaman `WRITTEN_OFF` tidak punya piutang di neraca, jadi uang yang masuk belakangan dicatat sebagai
**pendapatan**, bukan pelunasan. Saldo rekening anggota berkurang (`D 201`), lawannya per komponen:

| Jurnal | Debit | Kredit | Komponen |
|---|---|---|---|
| `LoanRecoveryPrincipal` | `201` simpanan | `409` pendapatan lain-lain | pokok |
| `LoanRecoveryInterest` | `201` simpanan | `401` pendapatan bunga | bunga |
| `LoanRecoveryPenalty` | `201` simpanan | `403` pendapatan denda | denda |

Batas kumulatif per komponen: `Σ lending.recovery` tidak boleh melebihi nilai di
`lending.writeoff`. Permintaan berlebih ditolak `409 recovery_exceeds_written_off` (tidak dipotong
diam-diam), permintaan tanpa komponen positif ditolak `400`.

- `lending.recovery` menyimpan satu baris per penerimaan (bisa bertahap) + rekening sumber + alasan.
- Baris rekening koran memakai `tx_type = LOAN_RECOVERY` (migrasi contract `deposit/0100`).
- **NEEDS-COMPLIANCE-REVIEW** — akun `409` adalah usulan struktur pilot (REG-011 `V!`);
  **HUMAN-REVIEW-REQUIRED** (AGENTS.md §8).
- Aksi pemulihan ada di UI detail pinjaman (T-177): panel tiga komponen + rekening sumber +
  alasan, pratinjau dengan total dari `addMoney`, dialog native dengan axe 2 tema × 2 locale.
- **Prasyarat operasional (D-192):** `lending_maker` tidak memegang `deposit.account.read`, jadi
  aksi yang butuh rekening dipakai operator yang juga memegang `teller`/`platform_admin`.

## Event

| Event | Kapan | Dedup key |
|---|---|---|
| `LoanSubmitted` | pengajuan dibuat (T-163) | `lending.loan.submitted:<loanId>` |
| `LoanApproved` | pengajuan disetujui (T-163) | `lending.loan.approved:<loanId>` |
| `LoanDisbursed` | pinjaman dicairkan (T-164) | `lending.loan.disbursed:<loanId>` |
| `LoanInstallmentPaid` | angsuran dibayar (T-165) | `lending.loan.payment:<paymentId>` |
| `CollectibilityChanged` | golongan berubah pada regrading (T-166) | `lending.collectibility:<loanId>:<businessDate>` |
| `LoanRestructured` | jadwal versi baru dibuat (T-168) | `lending.loan.restructured:<loanId>:<scheduleVersion>` |
| `LoanWrittenOff` | piutang dihapusbukukan (T-168) | `lending.loan.written_off:<loanId>` |

`InstallmentDue` menyusul bila denda keterlambatan diputuskan (D-180 belum menetapkan rumusnya).

## Izin

`lending.loan.read`, `lending.loan.submit`, `lending.loan.approve` (migrasi `platform/0081`).
`lending.loan.disburse` ditambahkan migrasi `platform/0084`, `lending.loan.pay` migrasi
`platform/0088`, lalu `lending.loan.restructure` + `lending.loan.write_off` migrasi
`platform/0096`: memindahkan uang dan menerima uang tidak otomatis ikut izin approve. Peran sempit:
`lending_maker` (read+submit+disburse+pay+restructure) dan `lending_checker`
(read+approve+write_off), dengan baris `role_conflict` supaya satu orang tidak memegang keduanya.
Hapus buku sengaja **tidak** dipegang `lending_maker`. `platform_admin` memegang semuanya.

## Permukaan HTTP

T-163…T-169 memasang delapan rute (lihat bagian di atas): empat tulis dari T-163…T-165, dua dari
T-168, dan dua baca dari T-169.

## Test

- `./task test tloan` — domain (urutan alokasi, total jadwal, penyelesaian baris).
- `./task test itapi_lending` — HTTP: pengajuan/persetujuan/pencairan/pembayaran/restrukturisasi/
  hapus buku (jadwal & versi, jurnal per komponen dan per bagian hapus buku, subledger, saldo,
  replay idempoten, penolakan rekening bukan milik peminjam, saldo tidak cukup, kelebihan bayar,
  pelunasan, `not_loss`, `not_disbursed`), daftar & detail dengan scoping cabang (`404` untuk
  akad cabang lain), validasi `status`/`limit`.
- `./task test trestructure` — jadwal versi baru: sisa pokok terurai tepat, nomor angsuran
  berlanjut, jadwal mulai di masa depan, bentuk tidak sah ditolak.
- `./task test twriteoff` — pembagian penyisihan vs beban, penyisihan melebihi nilai, komponen
  negatif/total nol ditolak.
- `./task test tppap` — tarif parameter (lima golongan, bentuk rusak ditolak), penyisihan
  `dasar × tarif` dengan pembulatan half-to-even, selisih bertanda.
- `./task test tcollectibility` — hari tunggakan (termasuk lintas bulan/tahun), pemetaan ambang dua
  kebijakan berbeda, ambang tidak sah ditolak.
- `./task test itdaycloser_lending` — task day-close: DPD dari angsuran tertua, idempotensi run
  ulang, ambang dari parameter, event per perubahan, parameter hilang → `DAY-372`, paginasi chunk,
  PPAP (selisih vs tanggal sebelumnya, jurnal pembalik, Δ snapshot == Δ GL, run ulang, `DAY-380`,
  `DAY-383`), tunggakan jadwal arsip tidak dihitung sebagai DPD, `DAY-384` hilang setelah hapus
  buku.
- `./task test tpayment` — alokasi: golden dua urutan parameter, denda paling akhir, kelebihan bayar
  ditolak, pelunasan bertahap, property 200 kasus acak (`Σ alokasi == nominal`).
- `./task test tschedule` — mesin jadwal: golden flat/efektif/anuitas + property (pokok total tepat,
  baris tanpa kewajiban, tanggal monoton) + kasus tepi (rate 0%, tenor 1, akhir bulan).
- `./task test itlending` — skema + repositori: produk/versi, pinjaman, jadwal, CHECK + trigger
  imutabilitas, round-trip `loanById`, approve sekali, approve oleh pengaju ditolak.
- `./task test itapi_lending` — HTTP: 401/403, pengajuan 201 + audit + event, self-approval 409,
  approve 200 + audit + event, plafon, versi DRAFT, anggota suspended, 404.
