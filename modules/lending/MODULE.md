# Modul `lending` — pinjaman anggota

Pinjaman (spec §9.2, §23 Fase 4): produk pinjaman berversi, akad/fasilitas, jadwal angsuran, lalu
kolektibilitas/PPAP di fase yang sama. Status: **T-161** (model + skema) + **T-162** (mesin jadwal flat/efektif/anuitas).
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
| `lending.ppap.rates` | persentase penyisihan per golongan | `NEEDS-COMPLIANCE-REVIEW` (D-180 butir 3, angka sementara) |

Nilai di atas **bukan** angka final untuk pilot data nyata; lihat O-001.

## Event (direncanakan, belum ada)

`LoanSubmitted`, `LoanApproved`, `LoanDisbursed`, `InstallmentDue`, `CollectibilityChanged`
(spec §8). Tidak satu pun dipublikasikan pada T-161 — jangan menganggapnya sudah ada.

## Izin

Belum ada. Rute dan izin `lending.*` menyusul di T-169; sampai itu modul ini tidak punya permukaan
HTTP.

## Test

- `./task test tloan` — domain (urutan alokasi, total jadwal, penyelesaian baris).
- `./task test tschedule` — mesin jadwal: golden flat/efektif/anuitas + property (pokok total tepat,
  baris tanpa kewajiban, tanggal monoton) + kasus tepi (rate 0%, tenor 1, akhir bulan).
- `./task test itlending` — skema: produk/versi, pinjaman, jadwal, CHECK + trigger imutabilitas.
