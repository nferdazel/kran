# Validasi register regulasi (§4) - O-001

Dokumen kerja untuk **compliance owner**. Kode/seed tidak boleh memakai nilai regulasi final
sebelum baris terkait ditandai tervalidasi di sini.

## Status per 21 Okt 2026

Klasifikasi **live vs deferred** di bawah berasal dari penelusuran pembaca parameter di kode
(bukan tebakan): item "live" punya konsumen di jalur pilot, item "deferred" tidak dibaca kode mana
pun sehingga tidak butuh nilai sekarang.

### Live (dipakai kode; nilainya sudah disemai, tetapi masih `NEEDS-COMPLIANCE-REVIEW`)

| ID | Parameter yang dibaca | Konsumen | Status |
|---|---|---|---|
| REG-003/004 | `party.kyc.risk_levels`, `party.kyc.default_risk_level`, `party.kyc.review_months` | `handlers_kyc.nim` (onboarding/re-KYC) | `NEEDS-COMPLIANCE-REVIEW` |
| REG-010 | `party.identity.doc_types`, `party.identity.doc_lengths` | `handlers_kyc.nim` (validasi identitas) | `NEEDS-COMPLIANCE-REVIEW` |
| REG-011 | `ledger.coa.code_pattern` | teknis (pola kode COA), bukan kebijakan akuntansi | `NEEDS-COMPLIANCE-REVIEW` |

Pilot boleh berjalan dengan nilai ini, tetapi **jangan diklaim sesuai regulasi** sampai
ditandatangani.

### Deferred (tidak ada pembaca di kode; nilai tidak disemai)

| ID | Alasan fungsional |
|---|---|
| REG-008 (pajak) | modul `tax` belum ada; nilai PPh final sudah dicatat di §Riset 2 Nov 2026 untuk dipakai nanti |
| REG-009 (LPS) | belum ada konsumen rate/flag penjaminan |
| REG-305 (bagi hasil syariah) | modul `sharia` belum ada |

> **Koreksi 2 Nov 2026:** baris REG-203/204 tidak lagi *deferred* - modul `lending` sudah membaca
> `lending.collectibility.dpd_bounds` dan `lending.ppap.rates`. Statusnya pindah ke §Riset di bawah.

## Riset 2 Nov 2026 (O-001, O-100, O-123)

Sumber dibaca langsung dari salinan resmi; kutipan di bawah **bukan** tafsir bebas. Tetap butuh
tanda tangan compliance owner sebelum diklaim patuh.

### REG-101/REG-011 - simpanan pokok & wajib adalah ekuitas

**Sumber:** Permenkop UKM No. 2 Tahun 2024 tentang Kebijakan Akuntansi Koperasi (ditetapkan 10 Jan
2024, diundangkan 16 Jan 2024, BN 2024 No. 35; mencabut Permenkop 12/2015, 13/2015, 14/2015).
Salinan: <https://peraturan.bpk.go.id/Details/308465>. Materi IAI: <https://web.iaiglobal.or.id/assets/files/file_publikasi/Materi_Permenkop_2%20thn%202024_IAI.pdf>.

- Pasal 4 ayat (1): KSP wajib menggunakan **SAK Indonesia untuk Entitas Privat (SAK EP)**.
- Pasal 13: penerapan SAK EP paling lambat **tahun buku 2025**.
- Lampiran I, kebijakan akuntansi ekuitas 5.1: "**Simpanan pokok dan wajib disajikan di ekuitas.**"
- Format laporan posisi keuangan KSP: liabilitas memuat "Simpanan anggota", "Simpanan koperasi
  lain", "Utang pinjaman"; ekuitas memuat "Simpanan pokok/modal tetap", "Simpanan wajib/modal
  tambahan", "Cadangan umum", "Cadangan risiko", "Sisa hasil usaha", "Ekuitas lain".

**Konsekuensi untuk KRAN.** COA `301.1`/`301.2` sebagai ekuitas **sudah benar**; mengubahnya menjadi
liabilitas akan bertentangan dengan Permenkop 2/2024. Yang masuk liabilitas adalah **simpanan
anggota** (tabungan/sukarela/berjangka), bukan simpanan pokok/wajib.

**Masih terbuka:** aturan **iuran** anggota (jenis, besaran, klasifikasi pendapatan). Tidak ditemukan
tarif nasional; ditetapkan AD/ART + keputusan RAT, jadi bentuknya parameter per koperasi.

### REG-204 - kualitas aset & penyisihan (jalur BPR)

**Sumber:** POJK No. 1 Tahun 2024 tentang Kualitas Aset Bank Perekonomian Rakyat (menggantikan
POJK 33/POJK.03/2018, lihat Pasal 52). Salinan:
<https://www.ojk.go.id/id/regulasi/Documents/Pages/Kualitas-Aset-Bank-Perekonomian-Rakyat/POJK%201%20Tahun%202024%20Kualitas%20Aset%20Bank%20Perekonomian%20Rakyat.pdf>.

- Pasal 19 ayat (2): PPKA umum paling sedikit **0,5%** dari aset produktif kualitas lancar.
- Pasal 19 ayat (3): PPKA khusus paling sedikit **3%** (dalam perhatian khusus), **10%** (kurang
  lancar), **50%** (diragukan), **100%** (macet) - setelah dikurangi nilai agunan.
- Restrukturisasi kredit: kualitas **paling tinggi kurang lancar** bila sebelumnya diragukan/macet;
  **tidak berubah** bila sebelumnya lancar/DPK/kurang lancar; dapat menjadi **lancar** hanya bila
  tidak ada tunggakan selama **3 kali periode pembayaran berturut-turut**.

**Seed sejak D-196** (`lending.ppap.rates` = `0.5 / 3 / 10 / 50 / 100`):

| Golongan | Seed KRAN | POJK 1/2024 | Catatan |
|---|---|---|---|
| Lancar | 0,5% | 0,5% (PPKA umum) | cocok |
| Dalam perhatian khusus | 3% | 3% | cocok |
| Kurang lancar | 10% | 10% | cocok |
| Diragukan | 50% | 50% | cocok |
| Macet | 100% | 100% | cocok |

**Dua catatan yang harus dibaca bersama angka ini.**

1. Dasar perhitungan KRAN = `principal_outstanding` **tanpa** mengurangi nilai agunan, sedangkan
   kutipan POJK khusus berbunyi "setelah dikurangi nilai agunan". Arahnya konservatif (penyisihan
   lebih besar), tetapi itu berarti KRAN **belum** menerapkan pengurangan agunan - jangan diklaim
   patuh penuh.
2. Untuk **KSP** (segmen pilot), Permenkop 2/2024 tidak memberi tabel persentase: penyisihan pinjaman
   ditentukan dari **bukti objektif** (incurred loss), individual dan kolektif. Angka di atas adalah
   sikap konservatif pack BPR, dipilih pemilik 2 Nov 2026 (D-196).

**Pembanding pajak:** PMK No. 74 Tahun 2024 (pembentukan cadangan piutang tak tertagih yang boleh
dikurangkan dari penghasilan). Lampirannya memuat beberapa tabel per jenis usaha; baris yang relevan
untuk KRAN berbunyi khusus **"Koperasi Simpan Pinjam yang … menyalurkan Kredit dan/atau Pembiayaan
Berdasarkan Prinsip Syariah"**: **0,5%** lancar, **10%** kurang lancar, **50%** diragukan, **100%**
macet, tanpa baris "dalam perhatian khusus". Frasa "setelah dikurangi nilai agunan" pada lampiran itu
menempel pada golongan 10/50/100%, **tidak** pada 0,5% lancar. Salinan:
<https://www.pajak.go.id/sites/default/files/LAMPIRAN%20PMK%2074%20TAHUN%202024.pdf>.
Golongan lancar dan kurang lancar karenanya punya dasar ganda (akuntansi + pajak); golongan DPK
hanya dari POJK.

### REG-008 - PPh final bunga simpanan anggota koperasi

**Sumber:** PP No. 15 Tahun 2009 jo. PMK 112/PMK.03/2010; ringkasan DJP:
<https://pajak.go.id/id/artikel/pembukuan-dan-aspek-perpajakan-koperasi>.

- Objek: bunga simpanan yang dibayarkan koperasi kepada **anggota orang pribadi** (bukan bagian SHU).
- Tarif: **0%** untuk bunga sampai **Rp240.000/bulan**; **10%** dari bruto di atasnya.
- Pemotong: koperasi, saat pembayaran; setor paling lambat tanggal 10, lapor tanggal 20 bulan berikut.
- Bunga simpanan **bukan** objek PPh 23 (sudah final).

Catatan: satu artikel DJP menulis ambang Rp244.000; angka pada PP 15/2009 adalah **Rp240.000** -
verifikasi ulang ke teks PP sebelum modul `tax` memakai nilai ini.

| REG-005/006/007 (e-sign, disclosure, retensi) | tidak ada parameter pembaca; retensi arsip belum diimplementasi |

Tandai deferred di `docs/OPEN_ITEMS.md`; jangan isi nilainya "supaya ada".

> **Pembaruan 2 Nov 2026.** REG-203/204 sudah **tidak** deferred: modul `lending` ada dan membaca
> `lending.ppap.rates` + `lending.collectibility.dpd_bounds` (D-180); seed memakai angka provisional
> ber-`NEEDS-COMPLIANCE-REVIEW`, dan PPAP dilarang untuk data anggota nyata sampai angka/pasal
> diverifikasi. Baris tabel di atas adalah snapshot 21 Okt 2026. Sisa deferred: REG-008, REG-009,
> REG-305, REG-005/006/007.

## Risiko yang tersisa (dari SME compliance)

D-095 (tidak menyemai nilai regulasi) tetap benar dan gagal-cepat (`ParamNotFound`), bukan
nilai-salah-diam-diam. Risiko praktisnya: `platform.param_value` tidak menyimpan provenance review,
jadi setelah operator mengisi angka lewat maker-checker, angka tebakan tidak bisa dibedakan dari
yang sudah divalidasi.

**Mitigasi wajib:** `reason` pada pengajuan parameter harus memuat nomor sumber + tanggal akses,
atau nilai tetap ditandai `NEEDS-COMPLIANCE-REVIEW` di dokumentasi produk. Perbaikan skema
(kolom provenance) dicatat sebagai item Fase 2, bukan diubah diam-diam sekarang.

## Riset 2 Nov 2026 - tranche 2 (REG-002/003/004/009/103/104/205/207)

Sumber dibaca dari salinan resmi. Yang dicatat di sini adalah **teks aturan**, bukan tafsir bebas;
tetap butuh tanda tangan compliance owner sebelum diklaim patuh (`NEEDS-COMPLIANCE-REVIEW` bertahan).

### REG-002 - UU 27/2022 Pelindungan Data Pribadi

**Sumber:** UU No. 27 Tahun 2022 (LN 2022 No. 196), diundangkan 17 Okt 2022.
Salinan: <https://peraturan.bpk.go.id/Download/224884/UU%20Nomor%2027%20Tahun%2022.pdf>.
Masa transisi 2 (dua) tahun, sehingga kewajiban berlaku penuh sejak **17 Okt 2024**.

- Pasal 46 ayat (1): bila terjadi kegagalan pelindungan data pribadi, pengendali **wajib
  memberitahukan secara tertulis paling lambat 3 x 24 jam** kepada subjek data dan lembaga.
  Ayat (2) memuat isi minimum pemberitahuan; ayat (3) mewajibkan pengumuman kepada masyarakat
  dalam hal tertentu.
- Pasal 21 ayat (2) huruf d: saat meminta persetujuan, pengendali wajib menyampaikan informasi
  termasuk **jangka waktu retensi dokumen** yang memuat data pribadi.
- Pasal 32 ayat (1): subjek data berhak mengakses data pribadinya beserta rekam jejak pemrosesan.
- Pasal 45: pengendali wajib memberitahukan penghapusan/pemusnahan data pribadi kepada subjek data.

**Jarak ke KRAN (diperiksa dengan `ripgrep`, bukan dugaan).** Tidak ada modul/kolom untuk
**persetujuan (consent)**, **permintaan subjek data (akses/hapus)**, maupun **parameter retensi**;
tidak ada prosedur notifikasi kebocoran. Yang sudah ada: audit trail umum dan masking sebagian data
di lapisan API. Jadi ini **bukan nilai parameter yang salah**, melainkan fitur yang belum dibangun -
tidak boleh diklaim patuh pada pilot. Kandidat task: register consent + DSR + retensi per jenis data.

### REG-003/REG-004 - APU-PPT (LTKT/LTKM)

**Sumber:** UU No. 8 Tahun 2010 Pasal 23 (kewajiban laporan PJK); Peraturan Kepala PPATK No. 1 Tahun
2021 Pasal 6 (<https://peraturan.bpk.go.id/Download/269244/peraturan-ppatk-nomor-1-tahun-2021.pdf>);
POJK No. 8 Tahun 2023 (mencabut POJK 12/POJK.01/2017).

- **LTKT (transaksi keuangan tunai)**: wajib dilaporkan bila nilainya **paling sedikit
  Rp500.000.000**, baik satu kali transaksi maupun **kumulatif beberapa kali dalam satu hari kerja**;
  disampaikan paling lambat **14 hari kerja** sejak tanggal transaksi.
- **LTKM**: tidak ada ambang nominal - dasarnya unsur kecurigaan (menyimpang dari profil, dsb.).
- **POJK 8/2023**: CDD/EDD, PEP, screening DTTOT/DPPSPM, Individual Risk Assessment, dan pelaporan
  ke PPATK. Ambang **Rp100.000.000** yang muncul di POJK itu adalah pemicu **CDD untuk walk-in
  customer/WIC**, **bukan** ambang LTKT - dua angka ini mudah tertukar, jangan disatukan.
- **KSP**: Permenkop 8/2023 Pasal 1 angka 66 mewajibkan KSP/KSPPS menerapkan **PMPJ** (mengenali
  anggota/koperasi lain, memantau transaksi, **termasuk pelaporan transaksi mencurigakan**). Aturan
  teknis pelaporan tetap merujuk ketentuan PPATK.

**Jarak ke KRAN.** Belum ada pemantauan/penandaan transaksi tunai kumulatif harian, belum ada
register laporan LTKT/LTKM. Untuk pilot KSP, yang paling dekat: agregasi transaksi tunai per hari per
anggota dan penanda "perlu laporan" - belum ada. Nilai ambang di atas boleh dijadikan parameter
`NEEDS-COMPLIANCE-REVIEW` saat fitur itu dibangun.

### REG-009 - LPS: **koperasi bukan peserta penjaminan**

**Sumber:** UU No. 24 Tahun 2004 tentang LPS; PP No. 66 Tahun 2008; Peraturan LPS No. 1 Tahun 2023
Pasal 2; halaman resmi LPS <https://lps.go.id/simpanan-yang-dijamin> dan FAQ LPS.

- Peserta penjaminan LPS adalah **bank** (bank umum dan BPR/BPRS). Nilai yang dijamin **Rp2 miliar
  per nasabah per bank** (PP 66/2008), dengan syarat 3T (tercatat di pembukuan bank, bunga tidak
  melebihi Tingkat Bunga Penjaminan, tidak merugikan bank).
- Tingkat Bunga Penjaminan yang berlaku (periode 1 Okt 2026 - 31 Jan 2027): **3,75%** bank umum,
  **6,25%** BPR, **2,00%** valas bank umum. Angka ini berubah tiap periode - kalau kelak dipakai,
  wajib parameter, bukan konstanta.
- **KSP/KSPPS bukan peserta LPS.** Permenkop 8/2023 Pasal 26 ayat (6)-(7) justru mewajibkan KSP/USP
  **menjamin keamanan simpanan anggota** dan **boleh mengasuransikannya ke perusahaan asuransi**.

**Konsekuensi produk.** Untuk segmen KSP, KRAN **tidak boleh** menampilkan klaim "simpanan dijamin
LPS" - itu salah dan berisiko. Parameter rate/flag penjaminan hanya bermakna untuk **pack BPR**
(Fase 7). Catatan transisi P2SK: KSP yang melayani non-anggota (open loop) harus beralih ke OJK;
KSP tertutup tetap di Kemenkop (lihat butir REG-103).

### REG-103/REG-104 - Permenkop 8/2023 & penilaian kesehatan KSP

**Sumber:** Permenkop UKM No. 8 Tahun 2023 tentang Usaha Simpan Pinjam oleh Koperasi (ditetapkan 16
Jun 2023, diundangkan 20 Jun 2023, BN 2023 No. 464).
Salinan: <https://peraturan.bpk.go.id/Download/317418/permenkop-kukm-no-8-tahun-2023.pdf>.

- **BMPP** (batas maksimum pemberian pinjaman): pihak **terkait paling tinggi 10%** dari Modal Sendiri
  (Pasal 44 ayat (1)) dan wajib disetujui Pengurus + Pengawas; pihak **tidak terkait paling tinggi
  15%** dari Modal Sendiri (Pasal 45). Dasar perhitungan = **saldo pokok pinjaman** (Pasal 42 ayat (1)).
  Pihak terkait = pengurus, pengawas, dan koperasi lain yang punya hubungan kepemilikan/kepengurusan.
- **Modal Sendiri** (Pasal 1 angka 23) = simpanan pokok + simpanan wajib + dana cadangan dari SHU +
  hibah + simpanan lain yang karakteristiknya sama dengan simpanan wajib. Ini **sejalan dengan
  D-195** (simpanan pokok/wajib di ekuitas) dan menegaskan definisi operasional yang harus dipakai
  kalau BMPP ditegakkan.
- Pasal 63 ayat (6): simpanan pokok + wajib + simpanan lain yang sama + modal penyertaan **per anggota
  paling tinggi 20%** dari modal sendiri. Pasal 68: modal penyertaan dari pemodal **paling tinggi 25%**
  dari aset.
- Pasal 6: usaha simpan pinjam ditetapkan sebagai kegiatan **berisiko tinggi** dan wajib punya Izin
  Usaha (perizinan berusaha berbasis risiko/OSS). Pasal 46: kegiatan boleh dilakukan sebagai
  **digital financial service**.
- **Penilaian kesehatan (REG-104)**: mengacu Permenkop No. 9 Tahun 2020 tentang Pengawasan Koperasi
  dan Petunjuk Teknis Deputi Bidang Perkoperasian No. 15 Tahun 2021; aspeknya **tata kelola, profil
  risiko, permodalan, dan kinerja keuangan**, dilakukan sebagai **penilaian mandiri elektronik** dan
  hasilnya ditetapkan pemerintah (Permenkop 8/2023 Pasal 107). Istilah resminya **LHPKK** (laporan
  hasil pemeriksaan kesehatan koperasi) + **BAPK** (berita acara).

**Jarak ke KRAN.** Belum ada penegakan BMPP, belum ada laporan rasio/skor kesehatan. Batas 10%/15%
dan basis "saldo pokok pinjaman" adalah nilai yang **sudah terverifikasi**, tetapi penegakannya
menunggu definisi operasional Modal Sendiri di COA (butuh accounting owner) - dicatat sebagai task
turunan, bukan dikerjakan diam-diam sekarang.

### REG-205/REG-207 - pack BPR (deferred, tapi nomor aturannya dikoreksi)

- **REG-205 (TI BPR)**: yang berlaku adalah **POJK No. 34 Tahun 2025** tentang Penyelenggaraan
  Teknologi Informasi oleh BPR dan BPR Syariah, dengan ketentuan pelaksanaan **PADK No.
  43/PADK.03/2025** (berlaku 1 tahun setelah ditetapkan, Des 2025 → efektif Des 2026) yang mencabut
  SEOJK 15/SEOJK.03/2017. Spec §4 menulis "kemungkinan POJK 19/2023" - **itu keliru** dan sudah
  diperbaiki di register.
- **REG-207 (pelaporan/SLIK)**: pelaporan debitur melalui **SLIK** diatur POJK 18/POJK.03/2017
  sebagaimana diubah POJK 64/POJK.03/2020 dan **POJK 11 Tahun 2024**. Pelaporan berkala BPR ke OJK
  diatur POJK pelaporan BPR (format & jadwal = parameter saat pack dibuat).
- Keduanya **tidak relevan untuk segmen KSP** dan tidak disemai; tetap deferred sampai pack BPR.

### Ringkasan status setelah tranche 2

| Baris | Status riset | Boleh dipakai? |
|---|---|---|
| REG-002 (PDP) | teks terverifikasi (3x24 jam, retensi, akses) | belum - fitur consent/DSR/retensi tidak ada |
| REG-003/004 (APU-PPT) | terverifikasi (LTKT ≥ Rp500 jt, 14 hari kerja; CDD Rp100 jt ≠ LTKT) | belum - pemantauan belum dibangun |
| REG-009 (LPS) | terverifikasi bahwa **KSP bukan peserta LPS** | ya, sebagai larangan klaim (bukan rate) |
| REG-103 (BMPP/izin) | terverifikasi (10% terkait / 15% tidak terkait, basis saldo pokok) | bentuk boleh; penegakan belum ada |
| REG-104 (kesehatan) | terverifikasi kerangka (Permenkop 9/2020 + Juknis 15/2021) | belum - modul laporan belum ada |
| REG-205 (TI BPR) | nomor aturan dikoreksi (POJK 34/2025 + PADK 43/2025) | deferred (pack BPR) |
| REG-207 (SLIK) | terverifikasi (POJK 18/2017 + 64/2020 + 11/2024) | deferred (pack BPR) |

## Checklist sign-off

- [ ] Baris **live** diverifikasi ke sumber resmi (nomor + pasal + tanggal akses); alasan
      pengajuan parameter memuat sumber.
- [ ] Baris **deferred** disetujui tetap kosong sampai modulnya ada.
- [ ] `NEEDS-COMPLIANCE-REVIEW` dihapus hanya untuk baris yang sudah ditandatangani.

## Status: jalur 1 (D-114)

Pemilik menerima nilai default di atas **untuk pilot internal** - bukan klaim sesuai regulasi.
Penanda `NEEDS-COMPLIANCE-REVIEW` sengaja dipertahankan.

**Gate go-live komersial:** sebelum anggota nyata pertama atau klien BPR/koperasi pertama, nilai
pada scope institusi klien itu wajib divalidasi compliance klien/konsultan; `reason` pengajuan
parameter memuat nomor aturan + tanggal akses; penanda dicabut per institusi, bukan global.
