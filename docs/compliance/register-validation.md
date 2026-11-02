# Validasi register regulasi (§4) — O-001

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

> **Koreksi 2 Nov 2026:** baris REG-203/204 tidak lagi *deferred* — modul `lending` sudah membaca
> `lending.collectibility.dpd_bounds` dan `lending.ppap.rates`. Statusnya pindah ke §Riset di bawah.

## Riset 2 Nov 2026 (O-001, O-100, O-123)

Sumber dibaca langsung dari salinan resmi; kutipan di bawah **bukan** tafsir bebas. Tetap butuh
tanda tangan compliance owner sebelum diklaim patuh.

### REG-101/REG-011 — simpanan pokok & wajib adalah ekuitas

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

### REG-204 — kualitas aset & penyisihan (jalur BPR)

**Sumber:** POJK No. 1 Tahun 2024 tentang Kualitas Aset Bank Perekonomian Rakyat (menggantikan
POJK 33/POJK.03/2018, lihat Pasal 52). Salinan:
<https://www.ojk.go.id/id/regulasi/Documents/Pages/Kualitas-Aset-Bank-Perekonomian-Rakyat/POJK%201%20Tahun%202024%20Kualitas%20Aset%20Bank%20Perekonomian%20Rakyat.pdf>.

- Pasal 19 ayat (2): PPKA umum paling sedikit **0,5%** dari aset produktif kualitas lancar.
- Pasal 19 ayat (3): PPKA khusus paling sedikit **3%** (dalam perhatian khusus), **10%** (kurang
  lancar), **50%** (diragukan), **100%** (macet) — setelah dikurangi nilai agunan.
- Restrukturisasi kredit: kualitas **paling tinggi kurang lancar** bila sebelumnya diragukan/macet;
  **tidak berubah** bila sebelumnya lancar/DPK/kurang lancar; dapat menjadi **lancar** hanya bila
  tidak ada tunggakan selama **3 kali periode pembayaran berturut-turut**.

**Selisih dengan seed sekarang** (`lending.ppap.rates` = `0 / 0.5 / 10 / 50 / 100`):

| Golongan | Seed KRAN | POJK 1/2024 | Catatan |
|---|---|---|---|
| Lancar | 0% | **0,5%** (PPKA umum) | seed tidak membentuk penyisihan umum |
| Dalam perhatian khusus | 0,5% | **3%** | seed terlalu rendah |
| Kurang lancar | 10% | 10% | cocok |
| Diragukan | 50% | 50% | cocok |
| Macet | 100% | 100% | cocok |

Untuk **KSP** (segmen pilot), Permenkop 2/2024 tidak memberi tabel persentase: penyisihan pinjaman
ditentukan dari **bukti objektif** (incurred loss), individual dan kolektif. Jadi tabel di atas
adalah acuan **pack BPR** (Fase 7) dan pilihan konservatif untuk pilot.

### REG-008 — PPh final bunga simpanan anggota koperasi

**Sumber:** PP No. 15 Tahun 2009 jo. PMK 112/PMK.03/2010; ringkasan DJP:
<https://pajak.go.id/id/artikel/pembukuan-dan-aspek-perpajakan-koperasi>.

- Objek: bunga simpanan yang dibayarkan koperasi kepada **anggota orang pribadi** (bukan bagian SHU).
- Tarif: **0%** untuk bunga sampai **Rp240.000/bulan**; **10%** dari bruto di atasnya.
- Pemotong: koperasi, saat pembayaran; setor paling lambat tanggal 10, lapor tanggal 20 bulan berikut.
- Bunga simpanan **bukan** objek PPh 23 (sudah final).

Catatan: satu artikel DJP menulis ambang Rp244.000; angka pada PP 15/2009 adalah **Rp240.000** —
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

## Checklist sign-off

- [ ] Baris **live** diverifikasi ke sumber resmi (nomor + pasal + tanggal akses); alasan
      pengajuan parameter memuat sumber.
- [ ] Baris **deferred** disetujui tetap kosong sampai modulnya ada.
- [ ] `NEEDS-COMPLIANCE-REVIEW` dihapus hanya untuk baris yang sudah ditandatangani.

## Status: jalur 1 (D-114)

Pemilik menerima nilai default di atas **untuk pilot internal** — bukan klaim sesuai regulasi.
Penanda `NEEDS-COMPLIANCE-REVIEW` sengaja dipertahankan.

**Gate go-live komersial:** sebelum anggota nyata pertama atau klien BPR/koperasi pertama, nilai
pada scope institusi klien itu wajib divalidasi compliance klien/konsultan; `reason` pengajuan
parameter memuat nomor aturan + tanggal akses; penanda dicabut per institusi, bukan global.
