# Brief diskusi SME — aturan iuran anggota KSP (O-100)

Dokumen ini **bahan diskusi**, bukan keputusan. Tujuannya: satu sesi dengan SME/accounting owner
menghasilkan jawaban yang bisa langsung diterjemahkan menjadi parameter + posting rule + laporan,
tanpa ada angka yang dikarang di kode.

Siapa yang berhak menjawab: accounting owner / konsultan koperasi (bukan developer). Selama belum
dijawab, semua nilai terkait tetap bertanda `NEEDS-COMPLIANCE-REVIEW` dan fitur iuran **tidak**
diaktifkan.

---

## 1. Yang sudah final (jangan dibuka lagi)

| Hal | Dasar | Konsekuensi di KRAN |
|---|---|---|
| Simpanan pokok & wajib **disajikan di ekuitas** | Permenkop UKM No. 2/2024, Lampiran I kebijakan akuntansi ekuitas 5.1; Pasal 4 mewajibkan SAK EP | Akun `301.1`/`301.2` tetap ekuitas; **tidak** dipindah ke liabilitas (D-195) |
| Simpanan anggota (tabungan/sukarela/berjangka) = **liabilitas** | Format laporan posisi keuangan Permenkop 2/2024 | Akun `201`/`202` — sudah benar |
| Tidak ada tarif iuran nasional | Penelusuran regulasi 2 Nov 2026 (tidak ada angka di Permenkop 2/2024 maupun 8/2023) | Iuran **wajib** jadi parameter/keputusan per koperasi (AD/ART + RAT), bukan angka di kode |
| Simpanan pokok tidak dapat diambil kembali selama menjadi anggota | Definisi simpanan pokok (Permenkop 2/2024) | Perlu keputusan perlakuan saat anggota keluar (pertanyaan 6) |

## 2. Yang dibutuhkan KRAN dari keputusan ini

Empat hal, semuanya harus datang dari jawaban SME:

1. **Parameter** — jenis iuran, besaran, kadens, jatuh tempo, toleransi, denda (kalau ada).
2. **Posting rule** — akun debit/kredit saat iuran ditagih, dibayar, dan (bila ada) tunggakan.
3. **Perilaku** — apa yang terjadi bila anggota tidak membayar, dan saat anggota keluar.
4. **Laporan** — baris apa yang harus terlihat di laporan untuk pengurus/pengawas/RAT.

## 3. Pertanyaan untuk SME

Jawaban boleh "belum tahu" — itu lebih berguna daripada angka tebakan. Mohon sebutkan dasar
(AD/ART pasal berapa, keputusan RAT tahun berapa) bila ada.

| # | Pertanyaan | Opsi yang mungkin | Yang berubah di sistem |
|---|---|---|---|
| 1 | Iuran apa saja yang berlaku? (iuran anggota bulanan, iuran wajib khusus, iuran simpanan, lainnya) | satu jenis / beberapa jenis | jumlah parameter + jenis tagihan |
| 2 | Besarannya nominal tetap atau persentase? Persentase dari apa? | Rp tetap / % simpanan / % pinjaman / % SHU | tipe parameter + pembulatan |
| 3 | Kadens & jatuh tempo: bulanan? tanggal berapa? ada tenggang? | bulanan tgl 1–28 / lain | parameter kadens + tanggal |
| 4 | Apakah ada denda keterlambatan? Berapa dan bagaimana dihitung? | tidak ada / nominal / persentase | posting rule + parameter denda |
| 5 | Iuran diakui sebagai **pendapatan** apa? Ada porsi untuk dana cadangan / dana sosial / dana pendidikan? | pendapatan lain-lain 100% / dipecah beberapa pos | COA + posting rule (bisa >1 baris) |
| 6 | Saat anggota **keluar**: simpanan wajib dikembalikan? simpanan pokok? iuran yang sudah dibayar? tunggakan ditagih dulu? | dikembalikan penuh / dipotong tunggakan / hangus | alur keluar anggota + jurnal |
| 7 | Bila anggota tidak membayar: dicatat sebagai **piutang** atau hanya tunggakan administratif? | piutang (neraca) / catatan (memo) / potong SHU | perlu/tidak akun piutang iuran |
| 8 | Apakah iuran boleh dipotong dari SHU anggota saat RAT? | ya / tidak | alur SHU (Fase 5) |
| 9 | Perlakuan pajak: iuran anggota bukan bunga simpanan — apakah objek PPh badan biasa, atau ada perlakuan khusus? | penghasilan biasa / perlu konsultasi pajak | modul pajak (Fase 6) |
| 10 | Laporan apa yang harus memuat iuran (untuk pengurus/pengawas/RAT)? | baris tersendiri di PHU / rekap per anggota / keduanya | laporan + ekspor |

## 4. Format jawaban yang paling membantu

Untuk tiap nomor: **jawaban → dasar (AD/ART/RAT) → contoh angka bila ada**. Bila jawabannya
"tergantung koperasi", sebutkan minimal nilai default yang wajar untuk pilot dan tandai bahwa itu
kebijakan institusi (bukan regulasi).

## 5. Yang TIDAK akan dilakukan KRAN tanpa jawaban ini

- Tidak ada tarif iuran yang ditulis di kode atau di seed sebagai "angka pasti".
- Fitur penagihan iuran tidak diaktifkan pada pilot (tidak ada angka, tidak ada tagihan).
- Bila nanti diaktifkan, nilainya tetap kelas `kebijakan` + `NEEDS-COMPLIANCE-REVIEW` sampai
  accounting owner menandatangani, dan setiap perubahan lewat maker-checker dengan alasan tertulis.

## 6. Setelah jawaban masuk

Pekerjaan turunan (task terpisah, bukan sekarang): parameter iuran + seed + migrasi aturan posting +
alur keluar anggota + laporan rekap iuran; semuanya lewat gate dan review seperti biasa.
