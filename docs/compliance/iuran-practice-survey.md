# Survei praktik: pengelolaan iuran anggota KSP

**Status:** bahan riset meja untuk O-100. Bukan keputusan, bukan nasihat hukum/pajak.
**Tanggal riset:** 3 November 2026. **Metode:** penelusuran web + pembacaan PDF resmi.
**Batasan:** tidak ada wawancara koperasi; teks final SAK EP berbayar tidak diakses; dua dokumen
JDIH Kemenkop menolak diunduh (lihat §7).

## 0. Cara membaca

Setiap temuan diberi label:

- **(a) Regulasi mengikat** — peraturan berlaku, dengan pasal + URL.
- **(b) Praktik umum** — contoh AD/ART, laporan RAT, atau panduan; **bukan** kewajiban hukum.
  Contoh institusi tidak boleh diperlakukan sebagai norma.
- **(c) Usulan default pilot** — usulan untuk didiskusikan, dengan alasan dan konsekuensi.
  Bukan keputusan, bukan angka resmi.

Angka yang muncul di dokumen ini **hanya** contoh dari sumber (dikutip apa adanya) atau usulan
yang ditandai. Tidak ada satu pun yang ditetapkan sebagai nilai resmi KRAN.

## 1. Ringkasan

1. Tidak ada regulasi yang mengatur besaran, kadens, jatuh tempo, atau denda iuran anggota. UU
   25/1992 hanya menyebut simpanan pokok/wajib sebagai modal sendiri (Pasal 41) dan pembagian SHU
   (Pasal 45); Lampiran I Permenkop 2/2024 tidak memuat kata "iuran" untuk konteks ini (§7).
2. Istilah "iuran" dipakai campur-aduk: beberapa AD/ART menyebut simpanan pokok/wajib sebagai
   "iuran pokok"/"iuran wajib", dan juklak Kemenkop 2025 (belum terverifikasi penuh) mendefinisikan
   simpanan wajib sebagai "iuran anggota yang dibayar secara periodik".
3. Praktik yang paling sering terlihat pada dokumen yang bisa dibuka: **nominal tetap**, bukan
   persentase; simpanan wajib bulanan; iuran keanggotaan terpisah relatif jarang dan biasanya tahunan.
4. **Denda keterlambatan iuran: tidak ditemukan** contoh AD/ART yang dapat dibuka. Yang ditemukan
   hanya denda pada pinjaman, bukan pada iuran.
5. Pos akuntansi: praktik dominan menempatkan pemasukan non-operasional (termasuk iuran dan biaya
   administrasi) di **"Pendapatan lain-lain"**; tidak ada panduan yang mewajibkan pos tersendiri
   kecuali ambang materialitas 5% dari total pendapatan.
6. **Pemecahan iuran** ke dana sosial/pendidikan **tidak ditemukan**. Yang lazim adalah dana
   sosial/pendidikan sebagai **alokasi SHU**, bukan pemecahan pendapatan iuran.
7. Saat anggota keluar, praktik bervariasi: pengembalian penuh; pengembalian dipotong "bagian
   tanggungan" atau biaya administrasi; sampai simpanan pokok menjadi kekayaan koperasi bila
   anggota dipecat.
8. Pajak: aturan khusus hanya ada untuk **bunga simpanan** (PP 15/2009: 0% sampai Rp240.000/bulan,
   10% di atasnya). Tidak ada aturan khusus untuk iuran.
9. Sumber saling bertentangan pada detail: ambang Rp240.000 (PP) vs Rp244.000 (artikel DJP); tarif
   15% (pedoman dinas, warisan aturan lama) vs 0%/10% (PP 15/2009).
10. Yang benar-benar keputusan lokal: jenis iuran yang dipungut, ada/tidaknya denda, status
    tunggakan (piutang vs memo), potong-tidaknya dari SHU, dan penyajiannya di laporan.

## 2. Pertanyaan pemilik

Penomoran mengikuti `iuran-sme-brief.md` §3 (1–10). Empat pertanyaan akuntansi ada di §3.

### 2.1. (Brief #1) Iuran apa saja yang berlaku?

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| "Iuran pokok" dan "iuran wajib" dipakai sebagai **sinonim** simpanan pokok/wajib, bukan instrumen terpisah | ART Koperasi Karyawan Panca Sejahtera, Pasal 1 angka 1 ("membayar iuran pokok dan iuran wajib") — <https://koperasipancasejahtera.com/img/news/art18.pdf> | istilah "iuran" untuk simpanan vs "iuran" untuk dues | Jangan pernah memetakan "iuran" otomatis ke simpanan; dua entitas data berbeda |
| Iuran keanggotaan tahunan yang **dipotong dari SHU**, terpisah dari simpanan | Laporan RAT Kopdit Swastiastu 2025: "Iuran dari anggota sebesar Rp20.000/orang per tahun dipotong dari SHU" — <https://www.kopditswastiastu.co.id/wp-content/uploads/2025/02/RA-Kopdit-Swastiastu-2025.pdf> | bulanan / tahunan; tunai / potong SHU / potong gaji | Jenis iuran butuh atribut `cadence` + `collection_channel` |
| Iuran **peristiwa** (dana duka/solidaritas), bukan periodik | Kopdit Swastiastu: "Dana duka bersumber dari iuran anggota sebesar Rp2.000,00 per anggota meninggal" | per kejadian; per tahun | Butuh tipe tagihan "event-based", bukan hanya periodik |
| Biaya masuk/administrasi sekali bayar | ART Panca Sejahtera Pasal 45 angka 4 (administrasi 15% saat simpanan pokok dikembalikan); buku ajar Akuntansi untuk Koperasi FEB Unand memakai contoh "biaya administrasi Rp10.000" untuk anggota baru — <https://kampus2.feb.unand.ac.id/images/E-BOOK%20AKUNTANSI%20UNTUK%20KOPERASI.pdf> | sekali bayar; dipotong saat keluar | Tipe iuran "one-off" dengan akun sendiri |

**Variasi yang lazim:** satu jenis (hanya simpanan wajib) sampai tiga-empat jenis (dues + dana duka +
biaya masuk + iuran kegiatan). Tidak ada pola dominan yang bisa disebut "standar".

**Konsekuensi teknis.** Jika fitur iuran dibangun, ia harus berupa **katalog jenis iuran**
(`iuran_type`: kode, nama, basis, kadens, akun pendapatan, akun piutang opsional), bukan satu
parameter tunggal. Nama jenis tidak boleh dipakai sebagai pengganti semantik: simpanan wajib tetap
ekuitas (`301.2`), iuran tetap pendapatan.

**Usulan default pilot (c).** Aktifkan **satu** jenis: iuran anggota periodik. Alasan: contoh
terbuka menunjukkan iuran periodik sebagai bentuk paling sederhana; jenis lain menambah parameter
tanpa bukti kebutuhan pilot. Konsekuensi: koperasi yang memungut dana duka harus menunggu fase
berikutnya, atau memakai jenis "lainnya" dengan akun berbeda.

### 2.2. (Brief #2) Nominal tetap atau persentase? Persentase dari apa?

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| **Nominal tetap** per anggota | ART Panca Sejahtera Pasal 45 angka 5: simpanan wajib minimal Rp50.000/bulan; Kopdit Swastiastu: iuran Rp20.000/orang/tahun | tetap; bertingkat menurut wilayah/kelas anggota | Parameter `Money` + `effective_from`; tidak ada `%` |
| Persentase dari gaji (khusus koperasi karyawan dengan potong gaji) | Laporan PKL "Koperasi Kesehatan Karyawan dan Pensiunan Bank Mandiri": "Iuran Anggota sebesar 2% dari gaji yang dipotong" — <http://repository.fe.unj.ac.id/6455/1/PINGKY%20KANDY_8105150264_KOPERASI%20KESEHATAN%20KARYAWAN%20DAN%20PENSIUNAN%20BANK%20MANDIRI%20%28MANDIRI%20HEALTHCAR.pdf> (laporan akademik, bukan dokumen resmi koperasi) | % gaji; % simpanan; % pinjaman | Jika % dipakai: butuh basis perhitungan + aturan pembulatan + snapshot basis saat tagihan dibuat |
| Tidak ditemukan sumber yang menetapkan persentase dari SHU atau dari pinjaman sebagai praktik umum | — | — | Jangan bangun varian % sebelum ada keputusan |

**Konsekuensi teknis.** Tipe parameter harus dibedakan sejak awal: `fixed_amount` vs `percentage`
dengan `base` eksplisit. Menyimpan persentase sebagai float melanggar aturan repo (uang/rate hanya
`Money`); persentase harus skala tetap (basis poin) dan pembulatan ke rupiah dilakukan sekali, di
titik pembentukan tagihan, bukan di laporan.

**Usulan default pilot (c).** `fixed_amount` saja. Alasan: seluruh contoh terbuka yang bisa
diverifikasi memakai nominal tetap, dan varian % menambah basis yang harus di-snapshot. Konsekuensi:
koperasi dengan potong gaji harus menghitung sendiri nilai tetapnya sampai varian % dibuat.

### 2.3. (Brief #3) Kadens dan jatuh tempo

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| Bulanan, melekat pada simpanan wajib | ART Panca Sejahtera Pasal 45 angka 5 ("wajib dibayarkan setiap bulannya") | tanggal 1–28; ikut siklus gaji | `cadence=monthly` + `due_day` (1–28) sebagai parameter |
| Tahunan, sering dipotong dari SHU saat RAT | Kopdit Swastiastu (Rp20.000/orang/tahun, dipotong dari SHU) | awal tahun; saat RAT | `cadence=annual` + titik potong (`shu_offset`) |
| Tidak ditemukan contoh yang menetapkan **tenggang (grace period)** secara tertulis | — | 0 hari; 7 hari; akhir bulan | `grace_days` default 0, dapat diubah |
| Tidak ditemukan aturan regulasi soal tanggal jatuh tempo | — | — | Jangan hardcode tanggal; parameter per koperasi |

**Konsekuensi teknis.** Penagihan harus idempoten per `(anggota, jenis iuran, periode)`. Bila
kadens diubah di tengah tahun, periode yang sudah ditagih tidak boleh dihitung ulang (perubahan
berlaku untuk periode berikutnya), agar ledger tetap immutable.

**Usulan default pilot (c).** Bulanan, `due_day` = tanggal 1, `grace_days` = 0, dengan periode
terbuka sampai akhir bulan. Alasan: paling sederhana dan paling mudah diuji; tidak mengklaim
praktik. Konsekuensi: koperasi yang menagih tahunan memakai `cadence=annual`; koperasi yang
memakai potong gaji tetap harus menyetor manual pada pilot.

### 2.4. (Brief #4) Denda keterlambatan

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| **Tidak ditemukan** contoh AD/ART koperasi yang dapat dibuka dengan klausul denda atas iuran/simpanan wajib | — | tidak ada denda; nominal; persentase | Bila ada: akun pendapatan denda terpisah + parameter tarif |
| Denda yang lazim terdokumentasi adalah denda **pinjaman**, bukan iuran | Tidak ditelusuri sistematis dalam riset ini (di luar scope) | — | Jangan menyamakan mesin denda pinjaman dengan denda iuran |

**Konsekuensi teknis.** Jika denda diaktifkan: perlu `penalty_type`, `penalty_rate`, `penalty_cap`,
`penalty_basis` (tagihan tertunggak vs hari terlambat), dan akun pendapatan denda sendiri
(materialitas 5% menentukan apakah ia baris terpisah). Denda juga memunculkan pertanyaan
pajak/keadilan yang tidak dijawab sumber mana pun.

**Usulan default pilot (c).** Tidak ada denda; tunggakan hanya tercatat dan dilaporkan. Alasan:
tidak ada dasar tertulis yang ditemukan, dan denda menimbulkan konsekuensi hukum/relasi anggota
yang tidak boleh diputuskan sepihak oleh sistem. Konsekuensi: tidak ada insentif pembayaran tepat
waktu; koperasi yang ingin denda harus menambahkannya lewat parameter + lampiran AD/ART.

### 2.5. (Brief #6) Saat anggota keluar

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| Simpanan pokok dikembalikan saat mengundurkan diri, **dipotong biaya administrasi** | ART Panca Sejahtera Pasal 45 angka 3–4 (SP Rp15.000 lama / Rp200.000 baru; "dikenakan biaya administrasi 15% sebagai penambahan modal koperasi") | potongan %; potongan nominal; tanpa potongan | Alur keluar butuh `settlement_statement`: bruto − potongan = neto, tiap potongan punya jurnal sendiri |
| Simpanan pokok + wajib dikembalikan **setelah dipotong "bagian tanggungan yang ditetapkan"**; waktu pengembalian berbeda untuk mengundurkan diri vs dipecat | ART Paguyuban PKB, Pasal 32: mengundurkan diri → "selambat-lambatnya 1 (satu) bulan"; dipecat → "1 (satu) bulan sesudah Rapat Anggota Tahunan yang akan datang" — <https://paguyubanpkb.wordpress.com/adart/bab-i-organisasi/> | segera; 1 bulan; setelah RAT | Parameter `exit_payout_timing`; jurnal liabilitas antara ("utang pengembalian simpanan") bila tidak dibayar tunai |
| Pada kasus pemecatan, **simpanan pokok dapat menjadi kekayaan koperasi** dan pengembalian simpanan wajib diserahkan ke RAT | ART Paguyuban PKB, Pasal 32 (kasus "dipecat dan meminta pertimbangan RA") | hangus total; hangus sebagian; tetap dikembalikan | Perlu flag `forfeit_allowed` + otorisasi RAT, bukan default sistem |
| Iuran yang sudah dibayar: **tidak ditemukan** klausul pengembalian | — | tidak dikembalikan (paling umum secara implisit); dikembalikan prorata (tidak ditemukan) | Jangan membuat fitur refund iuran sebelum ada keputusan |

**Catatan (a).** Permenkop 2/2024 Lampiran I Bagian IV angka 4.1 menyatakan simpanan pokok/wajib
"tidak dapat diambil kembali selama yang bersangkutan masih menjadi anggota". Ini **menjelaskan
kapan tidak boleh**, bukan mengatur tata cara pengembalian saat berhenti. Tidak ada pasal yang
mengatur potongan, waktu, atau kehangusan.

**Konsekuensi teknis.** Keluar anggota = transaksi multi-jurnal: (i) tutup ekuitas simpanan,
(ii) akui utang pengembalian atau kas keluar, (iii) potong tunggakan (lihat #7), (iv) akui
pendapatan administrasi bila ada, (v) arsipkan kartu anggota. Tanpa `settlement_statement` yang
disetujui, jangan menutup keanggotaan.

**Usulan default pilot (c).** Pengembalian penuh SP + SW, dipotong tunggakan iuran yang tercatat,
tanpa biaya administrasi, dibayar tunai saat penutupan. Alasan: paling sedikit asumsi dan paling
mudah diaudit. Konsekuensi: koperasi yang memungut biaya administrasi harus mengaktifkannya sebagai
parameter; kehangusan simpanan pokok tidak didukung sampai ada keputusan tertulis.

### 2.6. (Brief #10) Laporan untuk pengurus/pengawas/RAT

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| Iuran **tidak** muncul sebagai baris tersendiri; masuk "Pendapatan Lainnya" bersama bunga bank dan lain-lain | Laporan RAT Kopdit Swastiastu 2025, catatan 5.25 "Pendapatan Lainnya" (Bunga Bank, Bunga Koperasi, Bunga Investasi, Lain-lain) | baris tersendiri; digabung; hanya di CALK | Baris terpisah wajib bila ≥5% total pendapatan (lihat #5) |
| Kebijakan iuran dilaporkan sebagai **kebijakan**, bukan angka pendapatan | Kopdit Swastiastu, "Pola Kebijakan Solidaritas 2025" (sumber & penggunaan dana sosial/duka) | narasi kebijakan; tabel realisasi | Laporan RAT butuh dua bagian: realisasi keuangan + kebijakan |
| Tidak ditemukan contoh **rekap iuran per anggota** yang dipublikasikan | — | ada; tidak ada | Jika diminta, bentuknya laporan operasional, bukan laporan keuangan |

**Catatan (a).** UU 25/1992 Pasal 35 mewajibkan laporan tahunan memuat perhitungan tahunan (neraca +
perhitungan hasil usaha + penjelasan) dan keadaan/usaha koperasi. Permenkop 2/2024 Pasal 6 ayat (2)
mewajibkan laporan keuangan tahunan dipertanggungjawabkan dan disahkan di RAT; Pasal 8 menetapkan
komponennya; Pasal 11 menetapkan batas waktu 30 April (koperasi primer). Lampiran I angka 1.11
angka 3: pos pendapatan ≥5% dari total pendapatan disajikan dalam pos tersendiri.

**Konsekuensi teknis.** Tiga keluaran berbeda: (i) baris PHU (kondisional materialitas), (ii) CALK
(kebijakan + rincian), (iii) rekap operasional per anggota + aging. Yang (iii) tidak boleh
dicampur ke laporan keuangan resmi.

**Usulan default pilot (c).** Sajikan sebagai satu baris "Pendapatan iuran anggota" di bawah
"Pendapatan lain" pada PHU, dengan rincian di CALK; rekap per anggota tersedia sebagai ekspor
terpisah. Alasan: memenuhi ambang materialitas tanpa memaksa struktur COA baru. Konsekuensi:
koperasi yang ingin iuran menjadi baris utama harus mengubah pemetaan akun.

## 3. Pertanyaan akuntansi

### 3.1. (Brief #5) Diakui sebagai pendapatan apa? Ada porsi dana cadangan/sosial/pendidikan?

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| Masuk **"Pendapatan lain-lain"** | Buku ajar Akuntansi untuk Koperasi FEB Unand, COA: 4.3 "Pendapatan lain-lain" — <https://kampus2.feb.unand.ac.id/images/E-BOOK%20AKUNTANSI%20UNTUK%20KOPERASI.pdf>; contoh COA koperasi dalam laporan akademik UIN Suska memuat akun "370 Iuran Anggota" — <https://repository.uin-suska.ac.id/76262/2/SKRIPSI%20LENGKAP%20KECUALI%20BAB%20IV.pdf> | baris sendiri; digabung "lain-lain" | Pemetaan akun per jenis iuran; baris PHU mengikuti materialitas |
| **Tidak ada** praktik pemecahan pendapatan iuran ke dana cadangan/sosial/pendidikan yang ditemukan | — | — | Jangan bangun split otomatis |
| Dana sosial/pendidikan lazimnya **alokasi SHU** | UU 25/1992 Pasal 45 ayat (2); AD/ART Kopkar Shinto: "Dana Cadangan 10%, Anggota 75%, Dana Sosial dan pendidikan 2,5%..." — <https://kopishinto.id/ad_art.pdf> | persentase berbeda per koperasi | Alokasi SHU = modul Fase 5, bukan modul iuran |

**Catatan (a).** Permenkop 2/2024 Pasal 4 ayat (1) mewajibkan KSP memakai SAK EP; Pasal 13
menetapkan penerapan paling lambat tahun buku 2025. Lampiran I Bagian IV angka 2 mendefinisikan
pendapatan sebagai "arus masuk bruto dari manfaat ekonomik yang timbul dari aktivitas normal
Koperasi...". Contoh PHU di Lampiran I memuat pos **"Pendapatan lain"**. Tidak ada pasal yang
menyebut iuran.

**Catatan SAK EP.** Bab 23 mengatur pendapatan: paragraf 23.3 (pengukuran pada nilai wajar
imbalan), 23.4 (hanya arus masuk bruto; pajak yang dipungut untuk pihak ketiga dikecualikan), dan
23.15 (jasa yang diberikan sepanjang periode diakui **garis lurus** selama periode, kecuali ada
metode lain yang lebih baik). Nomor paragraf di atas berasal dari **Draf Eksposur** SAK EP
(<https://web.iaiglobal.or.id/assets/files/file_berita/1%20DE%20SAK%20ENTITAS%20PRIVAT.pdf>);
penomoran pada standar final yang disahkan belum dapat diverifikasi dari sumber publik.

**Konsekuensi teknis.** Pengakuan harus mengikuti basis akrual: tagihan diterbitkan → pendapatan
diakui untuk periode berjalan; pembayaran diterima di muka → liabilitas "pendapatan diterima di
muka", bukan pendapatan. Posting rule minimal tiga (terbit tagihan, terima pembayaran, jurnal
penyesuaian periode). Akun pendapatan per jenis iuran; jangan satu akun untuk semua.

**Usulan default pilot (c).** Satu akun pendapatan "Iuran anggota" di kelompok pendapatan lain-lain;
tanpa pemecahan ke dana. Alasan: tidak ada sumber yang memecah pendapatan iuran, dan pemecahan
akan menciptakan ekuitas terikat tanpa dasar RAT. Konsekuensi: bila koperasi ingin dana
pendidikan bersumber dari iuran, itu keputusan RAT yang mengubah posting rule (bukan parameter).

### 3.2. (Brief #7) Tunggakan: piutang atau catatan administratif?

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| **Tidak ditemukan** dokumen yang menyatakan tunggakan iuran dicatat sebagai piutang di neraca | — | piutang (neraca); memo; potong SHU | Dua mode yang tidak boleh dicampur |
| Yang ditemukan: tunggakan dipakai sebagai **syarat** (mis. pelunasan tunggakan sebelum layanan tertentu) | Tidak ada contoh koperasi yang dapat dibuka; hanya praktik asosiasi/organisasi | blokir layanan; tanpa sanksi | Jika ada, perlu aturan eligibility, bukan jurnal |

**Catatan (a).** Tidak ada pasal. Secara prinsip, SAK EP mensyaratkan basis akrual, tetapi
pengakuan aset (piutang) menuntut hak tagih yang dapat ditegakkan; iuran yang tidak punya dasar
penagihan hukum sulit dipertahankan sebagai aset. Ini **penalaran**, bukan kutipan pasal.

**Konsekuensi teknis.** Mode "piutang" memerlukan akun piutang iuran, penyisihan tak tertagih,
dan dampak ke rasio/ekuitas. Mode "memo" hanya menyimpan status tagihan + aging, tanpa jurnal.
Perpindahan mode antar tahun bukan perubahan parameter biasa — perlu kebijakan dan persetujuan.

**Usulan default pilot (c).** Mode **memo**: tagihan tercatat, tidak membentuk piutang, tidak
mengakui pendapatan sampai dibayar. Alasan: paling konservatif; menghindari aset yang tidak dapat
ditagih secara hukum. Konsekuensi: pendapatan iuran menjadi mirip kas basis; RAT harus menjelaskan
kebijakan ini di CALK, dan laporan tunggakan tetap tersedia operasional.

### 3.3. (Brief #8) Boleh dipotong dari SHU?

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| **Ya** — iuran anggota dipotong dari SHU anggota | Kopdit Swastiastu 2025: "Iuran dari anggota sebesar Rp20.000/orang per tahun dipotong dari SHU" | potong penuh; potong sebagian; tidak potong | Modul SHU harus menerima komponen potongan per anggota |
| Tidak ditemukan contoh yang memotong **tunggakan** iuran dari SHU | — | — | Jangan gabungkan "iuran tahun berjalan" dan "tunggakan" dalam satu potongan tanpa keputusan |

**Catatan (a).** UU 25/1992 Pasal 45 ayat (2): SHU setelah dikurangi dana cadangan dibagikan
sebanding jasa usaha anggota dan digunakan untuk pendidikan perkoperasian/keperluan lain **sesuai
keputusan Rapat Anggota**. Pemotongan iuran dari SHU karena itu sah hanya bila diputuskan
RAT/AD-ART; bukan default sistem.

**Konsekuensi teknis.** Butuh `shu_deduction` per anggota dengan dasar (tahun iuran mana), urutan
potongan, dan jejak audit. SHU tidak boleh negatif tanpa keputusan eksplisit; bila potongan >
SHU, selisihnya menjadi tunggakan, bukan saldo negatif diam-diam.

**Usulan default pilot (c).** Tidak memotong dari SHU pada pilot; penagihan tunai/transfer.
Alasan: modul SHU baru ada di Fase 5. Konsekuensi: koperasi yang biasa memotong dari SHU harus
menagih manual sampai modul tersedia.

### 3.4. (Brief #9) Pajak

| Praktik umum | Sumber (contoh) | Variasi lazim | Konsekuensi teknis |
|---|---|---|---|
| Aturan khusus **hanya** untuk bunga simpanan anggota orang pribadi: final 0% ≤ Rp240.000/bulan, 10% di atasnya | PP 15/2009 Pasal 1–3 — <https://pajak.go.id/id/peraturan/pajak-penghasilan-atas-bunga-simpanan-yang-dibayarkan-oleh-koperasi-kepada-anggota> | — | Tidak berlaku untuk iuran |
| Iuran bukan bunga simpanan; tidak ada aturan pemotongan khusus yang ditemukan. Koperasi tetap badan usaha yang dikenai PPh badan | Artikel DJP "Pembukuan dan Aspek Perpajakan Koperasi" — <https://pajak.go.id/id/artikel/pembukuan-dan-aspek-perpajakan-koperasi> | PPh badan tarif umum 22%; opsi PP 23/2018 untuk omzet ≤ Rp4,8 M (dengan batasan waktu) | Iuran masuk penghasilan bruto; tidak ada withholding |
| Pedoman dinas lama masih mencantumkan tarif 15% untuk bunga simpanan | Pedoman Kebijakan Perpajakan bagi Koperasi, Dinkopukm Sleman — <https://dinkopukm.slemankab.go.id/wp-content/uploads/2023/06/Pedoman-Perpajakan-Koperasi.pdf> | — | Jangan pakai pedoman ini sebagai acuan tarif |

**Catatan (a).** PP 15/2009 Penjelasan Pasal 1 menegaskan yang dimaksud bunga simpanan adalah
imbalan dari dana yang disimpan anggota, dan **tidak termasuk** bunga simpanan yang merupakan
bagian dari SHU. Tidak ada pasal yang menyebut iuran anggota.

**Konsekuensi teknis.** Modul pajak (Fase 6) hanya perlu memotong PPh final atas bunga simpanan;
iuran tidak dipotong. Nilai iuran tetap menambah penghasilan kena pajak badan. Jangan menambahkan
baris potongan pajak pada tagihan iuran.

**Usulan default pilot (c).** Tidak ada perlakuan pajak khusus untuk iuran di sistem; serahkan ke
perhitungan PPh badan tahunan oleh akuntan. Alasan: tidak ada dasar pemotongan. Konsekuensi:
koperasi harus memisahkan iuran dari bunga simpanan di laporan fiskal, dan status PP 23/2018
(kelayakan, masa berlaku) harus dikonfirmasi akuntan.

## 4. Yang masih wajib diputuskan institusi

Daftar ini sengaja pendek dan tanpa rekomendasi terselubung.

1. Jenis iuran yang dipungut (dan namanya di AD/ART) — termasuk apakah simpanan wajib disebut "iuran".
2. Besaran dan apakah nominal tetap atau persentase; bila persentase, basisnya apa.
3. Kadens, tanggal jatuh tempo, dan tenggang.
4. Ada/tidaknya denda, besaran, dan dasar hitungnya.
5. Status tunggakan: piutang di neraca atau catatan administratif.
6. Potong/tidaknya iuran dari SHU, dan urutan potongannya.
7. Perlakuan saat keluar: potongan apa saja, waktu pembayaran, dan apakah simpanan pokok bisa hangus.
8. Penyajian: baris tersendiri atau digabung, serta isi rekap per anggota untuk RAT.
9. Dasar tertulis untuk semua di atas: pasal AD/ART dan nomor keputusan RAT.

## 5. Perbedaan dan ketegangan antar sumber

| Hal | Versi A | Versi B | Catatan |
|---|---|---|---|
| Ambang bunga simpanan | PP 15/2009: **Rp240.000**/bulan | Artikel DJP (2023): **Rp244.000**/bulan | PP adalah sumber hukum; angka DJP tampak salah ketik. Perlu konfirmasi sebelum dipakai di kode |
| Tarif bunga simpanan | PP 15/2009: 0% / 10% | Pedoman Dinkopukm Sleman: 15% (mengacu KMK 522/1998) | Pedoman dinas tampak belum diperbarui; jangan dijadikan acuan |
| Istilah "iuran" | AD/ART: iuran = simpanan pokok/wajib | Brief O-100: iuran = dues terpisah dari simpanan | Perbedaan konsep, bukan sekadar istilah; berisiko salah pemetaan akun |
| Sumber dana sosial | Kopdit Swastiastu: dari SHU **dan** iuran anggota | AD/ART Kopkar Shinto: dari alokasi SHU | Tidak ada aturan yang menyatukan; tiap koperasi berbeda |
| Perlakuan saat keluar | Panca Sejahtera: dikembalikan, dipotong administrasi | Paguyuban PKB: dipotong "bagian tanggungan"; bisa menjadi kekayaan koperasi | Tidak ada norma tunggal |

## 6. Yang tidak ditemukan

Ditulis eksplisit agar tidak diisi dengan tebakan:

- Tarif/ambang iuran nasional — tidak ada (konsisten dengan temuan sebelumnya).
- Contoh AD/ART dengan klausul **denda iuran** yang dapat dibuka — tidak ditemukan.
- Contoh **pengembalian iuran** yang sudah dibayar saat anggota keluar — tidak ditemukan.
- Contoh **tunggakan iuran sebagai piutang** di neraca — tidak ditemukan.
- Panduan resmi yang mengklasifikasikan iuran ke pos tertentu (selain "pendapatan lain") — tidak ditemukan.
- Praktik pemecahan pendapatan iuran ke dana cadangan/sosial/pendidikan — tidak ditemukan.
- Nomor paragraf final SAK EP Bab 23 — tidak dapat diverifikasi (teks final berbayar).

## 7. Catatan verifikasi (sumber yang tidak dapat dibuka penuh)

1. **Petunjuk Pelaksanaan SOM 2025** (Kemenkop, JDIH): kutipan "Simpanan Wajib: Iuran anggota yang
   dibayar secara periodik sesuai keputusan..." muncul di indeks mesin pencari, tetapi berkas
   <https://jdih.kop.go.id/doc/download/file/1770612160_Petunjuk%20Pelaksanaan%20SOM_2025%20(2).pdf/t/peraturan>
   menolak akses (403). **Jangan dikutip sebagai fakta sampai dibuka langsung.**
2. **ART DEKOPIN** (koperasi sekunder): menyebut "iuran wajib bulanan" bertingkat, tetapi PDF-nya
   hasil pindai tanpa teks; kutipan hanya dari cuplikan pencarian. Tidak dipakai di tabel.
3. **SAK EP final**: hanya Draf Eksposur yang dapat dibaca; nomor paragraf final belum terverifikasi.
4. Sumber Scribd/Academia tidak dipakai sebagai dasar klaim karena tidak dapat diverifikasi
   keasliannya; yang dipakai hanya PDF dari situs koperasi, situs resmi, atau repositori kampus
   yang menyebut institusi asalnya.

## 8. Sumber

**Regulasi**

- UU No. 25 Tahun 1992 tentang Perkoperasian — <https://peraturan.bpk.go.id/Download/35388/UU%20Nomor%2025%20Tahun%201992.pdf> (Pasal 35, 41, 45).
- Permenkop UKM No. 2 Tahun 2024 tentang Kebijakan Akuntansi Koperasi — <https://peraturan.bpk.go.id/Details/308465> ; PDF <https://peraturan.bpk.go.id/Download/368923/2%20th%202024.pdf> (Pasal 4, 6, 8, 11, 13; Lampiran I Bagian IV angka 2 & 4.1, angka 1.11, contoh PHU).
- Permenkop UKM No. 8 Tahun 2023 tentang Usaha Simpan Pinjam oleh Koperasi — <https://peraturan.bpk.go.id/Details/260414> (Pasal 1 angka 14–15: definisi simpanan pokok/wajib; tidak mengatur iuran).
- PP No. 15 Tahun 2009 tentang PPh atas Bunga Simpanan yang Dibayarkan Koperasi kepada Anggota Koperasi Orang Pribadi — <https://pajak.go.id/id/peraturan/pajak-penghasilan-atas-bunga-simpanan-yang-dibayarkan-oleh-koperasi-kepada-anggota>.

**Standar akuntansi**

- SAK Entitas Privat, daftar bab (Bab 23 Pendapatan) — <https://web.iaiglobal.or.id/SAK-EP-Efektif/SAK%20Entitas%20Privat%20Efektif%20Per%201%20Januari%202025>.
- Draf Eksposur SAK EP (paragraf 23.3, 23.4, 23.15) — <https://web.iaiglobal.or.id/assets/files/file_berita/1%20DE%20SAK%20ENTITAS%20PRIVAT.pdf>.

**Contoh AD/ART dan laporan koperasi**

- ART Koperasi Karyawan Panca Sejahtera, Pasal 1, 44, 45 — <https://koperasipancasejahtera.com/img/news/art18.pdf>.
- AD/ART Kopkar Shinto, Pasal 35 dan lampiran pembagian SHU — <https://kopishinto.id/ad_art.pdf>.
- AD/ART Paguyuban PKB, Pasal 32 (pengakhiran keanggotaan) — <https://paguyubanpkb.wordpress.com/adart/bab-i-organisasi/>.
- Laporan RAT Kopdit Swastiastu 2025 (catatan 5.25; Pola Kebijakan Solidaritas) — <https://www.kopditswastiastu.co.id/wp-content/uploads/2025/02/RA-Kopdit-Swastiastu-2025.pdf>.

**Panduan/rujukan praktik (bukan norma)**

- Buku ajar "Akuntansi untuk Koperasi", FEB Unand (COA 4.3 Pendapatan lain-lain; contoh biaya administrasi anggota baru) — <https://kampus2.feb.unand.ac.id/images/E-BOOK%20AKUNTANSI%20UNTUK%20KOPERASI.pdf>.
- Artikel DJP "Pembukuan dan Aspek Perpajakan Koperasi" (0%/10%, ambang Rp244.000, PPh badan) — <https://pajak.go.id/id/artikel/pembukuan-dan-aspek-perpajakan-koperasi>.
- Pedoman Kebijakan Perpajakan bagi Koperasi, Dinkopukm Sleman (tarif 15%, tampak kedaluwarsa) — <https://dinkopukm.slemankab.go.id/wp-content/uploads/2023/06/Pedoman-Perpajakan-Koperasi.pdf>.
- Laporan PKL Koperasi Kesehatan Karyawan dan Pensiunan Bank Mandiri (contoh iuran 2% gaji) — <http://repository.fe.unj.ac.id/6455/1/PINGKY%20KANDY_8105150264_KOPERASI%20KESEHATAN%20KARYAWAN%20DAN%20PENSIUNAN%20BANK%20MANDIRI%20%28MANDIRI%20HEALTHCAR.pdf>.
- Laporan akademik UIN Suska (contoh COA dengan akun "370 Iuran Anggota") — <https://repository.uin-suska.ac.id/76262/2/SKRIPSI%20LENGKAP%20KECUALI%20BAB%20IV.pdf>.
