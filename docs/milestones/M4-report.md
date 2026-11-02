# M4 — Lending: laporan milestone

Status: **SELESAI, menunggu keputusan manusia** (2 Nov 2026). Fase 4 spec §23: "Pengajuan →
pencairan → angsuran, DPD, kolektibilitas, PPAP, restruk"; kriteria selesai: **siklus pinjaman
penuh + task day-close** dan **golden test vs spreadsheet akunting**.

Branch kerja: `main` (rilis v0.1.4…v0.1.7). Fase 5 **tidak** dimulai.

---

## 1. Yang selesai

| Task | Isi | Status |
|---|---|---|
| T-161 | Skeleton modul `lending`: produk berversi, akad, saldo, jadwal; migrasi expand-only | selesai |
| T-162 | Mesin jadwal flat/efektif/anuitas (`Money`), property + golden test | selesai |
| T-163 | Pengajuan & persetujuan (maker-checker, empat mata, plafon parameter) | selesai |
| T-164 | Pencairan ke rekening simpanan + jurnal `D 110 / K 201` | selesai |
| T-165 | Angsuran: alokasi pokok/bunga/denda dari parameter | selesai |
| T-166 | Task `lending.dpd_regrade` (kolektibilitas per tanggal buku) | selesai |
| T-167 | Task `lending.ppap_provision` (CKPN + jurnal selisih) | selesai |
| T-168 | Restrukturisasi (versi jadwal baru) & hapus buku (LOSS) | selesai |
| T-169 | API baca + daftar dengan scoping cabang + kontrak | selesai |
| T-170 | Layar operator `/app/loans` dan detail | selesai |
| T-171 | Laporan tunggakan/aging, penyisihan, rekonsiliasi GL↔subledger | selesai |
| T-172 | Simulasi 12 bulan berpinjaman, benchmark EOD 100k + 50k, laporan ini | selesai |

Pendukung: `modules/lending/MODULE.md`, `docs/DECISIONS.md` D-180…D-188,
`docs/runbooks/dayclose.md` (kode `DAY-37x`/`DAY-38x`).

## 2. Gate dan bukti

- `./task ci` **hijau** (2 Nov 2026): seluruh suite Nim (unit, property, integrasi), kontrak OpenAPI
  + klien TS sinkron, `paramgen --check`, `archcheck`, `lint-nomagic`, i18n id+en, vitest web,
  svelte-check 0 error/0 warning, Playwright **65** (axe dua tema × dua locale) — Nim **1565**
  `[OK]`, 0 `[FAILED]`.
- Suite paling relevan: `itapi_lending` **40**, `itapi_lending_reports` **7**,
  `itdaycloser_lending` **15**, `itdaycloser_sim` **6** (+1 pinjaman), `treport` **9**,
  `tcollectibility` **9**, `tppap` **8**, `trestructure` **4**, `twriteoff` **5**,
  `tschedule` (golden flat/efektif/anuitas).
- Rilis: v0.1.4 (T-161…T-164), v0.1.5 (T-165…T-167), v0.1.6 (T-168), v0.1.7 (T-169/T-170).
  Deploy produksi tetap lewat push `main` + gerbang CI hijau (`ops/scripts/deploy-vps.sh`).

## 3. Golden test vs spreadsheet akunting (kriteria §23)

Yang diuji sebagai "golden" bukan angka karangan: total jadwal **tepat** sama dengan pokok + bunga
untuk ketiga metode (`tschedule`), dan identitas akuntansi diperiksa silang dari dua arah:

- pencairan: Δ subledger pinjaman = Δ GL `110` (`itapi_lending`, subledger `LOAN_DISBURSEMENT`);
- angsuran: satu jurnal per komponen non-nol, satu baris subledger per komponen (`itapi_lending`);
- PPAP: Δ snapshot = Δ GL `111` di seluruh rangkaian (`itdaycloser_lending`), run ulang tidak
  menggandakan;
- hapus buku: penyisihan `111` dipakai lebih dulu, sisanya `504` (`twriteoff`, `itapi_lending`);
- laporan: `GL 110 = Σ sisa pokok`, `GL 111 = Σ penyisihan terakhir − Σ allowance_applied`
  (`itapi_lending_reports`, `itdaycloser_sim`).

**Batas jujur**: pembandingnya bukan spreadsheet milik koperasi nyata — belum ada data nyata
(O-121/O-122/O-123 tetap terbuka). Yang dibuktikan adalah konsistensi internal dan invarian
double-entry, bukan kesesuaian dengan kebijakan akuntansi institusi tertentu.

## 4. Simulasi 12 bulan dengan pinjaman (kriteria §23)

`apps/api/tests/itdaycloser_sim.nim` — 1 Januari…31 Desember 2026, setiap hari kerja ditutup lewat
`startRunAction`, kini dengan **dua pinjaman sintetis** yang dicairkan 1 Januari:

- satu pinjaman 12.000.000 anuitas dengan angsuran pertama 1 Februari (menunggak sepanjang tahun);
- satu pinjaman 6.000.000 dengan angsuran pertama 15 Januari 2027 (tidak pernah menunggak).

Invarian setelah 12 bulan:

- setiap penutupan `COMPLETED` — termasuk `lending.dpd_regrade` dan `lending.ppap_provision`;
- snapshot kolektibilitas = jumlah hari tutup × jumlah pinjaman (tidak ada hari terlewat, tidak ada
  baris ganda); sama untuk snapshot PPAP;
- golongan akhir: pinjaman menunggak = `LOSS`, pinjaman belum jatuh tempo = `COLLECTIBLE`;
- `GL 110 = 18.000.000,00 = Σ sisa pokok`, `GL 111 = 12.000.000,00 = Σ penyisihan terakhir`
  (100% × 12.000.000 untuk `LOSS`, 0% untuk `COLLECTIBLE`);
- laporan tunggakan/penyisihan pada tanggal tutup terakhir memakai snapshot **tanggal itu**.

**Bug nyata yang ditemukan simulasi ini**: prasyarat `DAY-383` diperiksa saat *perencanaan* chunk,
sebelum dependensi regrading berjalan, sehingga EOD dengan pinjaman selalu gagal pada hari pertama.
Diperbaiki dengan memindahkan prasyarat ke eksekusi chunk (D-188), perilaku fail-closed tetap.

## 5. Benchmark EOD (§23)

Alat: `./task bench-eod --accounts N --loans M` (seed sintetis, satu penutupan penuh lewat service
yang sama dengan `ctl`). Lingkungan: MacBook Apple Silicon, PostgreSQL 18 **lokal** (`kran_test`),
bukan VPS kelas bawah.

| Populasi | EOD | ms/unit | Status |
|---|---|---|---|
| 100.000 rekening | 153,5 s | 1,53 | `COMPLETED` |
| 1.000 rekening + 50.000 pinjaman | 27,3 s | 0,54 | `COMPLETED` |
| **100.000 rekening + 50.000 pinjaman** | **245,0 s** | **1,63** | `COMPLETED` |

Target spec §23: 100k simpanan + 50k pinjaman **< 30 menit** (1.800 s). Angka di atas memakai
**±13,6%** anggaran. Pinjaman menambah ±27 s pada 50k (regrading + PPAP + snapshot), sedangkan
gabungan mengukur 245 s — selisihnya berasal dari mesin yang sedang dipakai pengembangan, bukan dari
jalur kode yang berbeda; angka M3 untuk 100k rekening saja (133 s) dan pengukuran ulang hari ini
(153 s) menunjukkan variasi yang sama.

**Cakupan yang diukur jujur**: pinjaman bench disemai tanpa jurnal pencairan (alat mengukur biaya
task, bukan membuktikan identitas akuntansi — itu `itdaycloser_sim`/`itapi_lending_reports`), dan
tanpa pembayaran angsuran, jadi golongannya seragam `LOSS`. Jalur tulis pembayaran/restrukturisasi
diukur di suite integrasi, bukan pada skala 50k.

## 6. Deviasi dari spec dan batas yang diterima

- **Penutupan akad otomatis tidak ada** (D-183): pinjaman lunas tetap `ACTIVE`; belum ada aturan
  pelepasan penyisihan, sehingga gerbang `DAY-384` menahan buku bila ada pinjaman tidak aktif yang
  masih menyimpan penyisihan.
- **Pemulihan pasca hapus buku belum ada** (O-122): pembayaran setelah hapus buku tidak punya jalur.
- **Kolektibilitas pasca restrukturisasi kembali lancar** (D-186) dan **CKPN sebagai akun `111`
  yang dikredit** (D-185) ditandai `NEEDS-COMPLIANCE-REVIEW` + `HUMAN-REVIEW-REQUIRED`; keduanya
  menunggu verifikasi compliance.
- **Aksi tulis pinjaman belum ada di UI** (T-173): pencairan/pembayaran/restrukturisasi/hapus buku
  masih lewat API.
- **Katalog produk pinjaman belum punya API/UI**: versi produk pinjaman disemai lewat seed
  (`packs/base/seed/0006_dev_lending.sql` untuk e2e).
- **Bunga pinjaman diakui saat dibayar** (D-183), bukan akrual harian seperti simpanan; laporan
  pendapatan bunga karenanya mengikuti kas masuk, bukan waktu.

## 7. Open items dan risiko

- O-075/O-121 (tipe akun kontra; CKPN sementara dikredit di akun aset `111`), O-122 (pemulihan
  hapus buku), O-123 (kolektibilitas pasca restrukturisasi) — semua butuh keputusan
  pemilik/compliance. Tarif PPAP/ambang DPD bukan O-121: itu D-180/REG-204.
- Regulasi §4 spec masih bertanda `V?`/`V!`: ambang DPD dan tarif PPAP di seed adalah **provisional**
  (`NEEDS-COMPLIANCE-REVIEW`). Jangan dipakai pada data nyata sebelum diverifikasi.
- Benchmark belum dijalankan di VPS produksi; angka lokal adalah batas atas optimistis.

## 8. Saran langkah berikutnya

1. Verifikasi parameter DPD/PPAP dan perlakuan restrukturisasi dengan compliance owner (O-121…O-123).
2. T-173 (aksi tulis di UI) sebelum pilot: operator tidak seharusnya memakai API mentah untuk
   mencairkan atau menerima angsuran.
3. Fase 5 (Koperasi Pack) **menunggu keputusan manusia** — milestone ini berhenti di sini.
