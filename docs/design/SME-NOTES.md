# Catatan SME untuk desain UI KRAN

Kumpulan memo SME (20 Okt 2026). Ini **input**, bukan keputusan. Arah final ada di `DESIGN.md`.
Aturan yang diadopsi harus bisa diuji (kontras, urutan fokus, dan satu layar penuh 1366×768).

## 1. Operasional koperasi/teller

Asumsi lapangan ditandai; bukan kutipan regulasi.

**Alur harian.** Buka teller = hitung kas awal per pecahan (salah di sini menggantung sepanjang
hari). Jam sibuk 08.00–11.00 dan tanggal gajian (asumsi). Kasus yang jarang ada di demo:

- Anggota lupa nomor → cari lewat nama/telepon/NIK; nama kembar butuh kolom pembeda (cabang,
  alamat, tanggal lahir).
- Setoran bendel: pokok + wajib + sukarela + angsuran/titipan dalam **satu slip**. Satu layar input,
  bukan empat.
- Titipan: penyetor ≠ pemilik rekening → dua kolom nama yang jelas terpisah.
- Salah input setelah uang diterima: koreksi = transaksi lawan berjejak, bukan hapus.
- Printer struk rusak/kertas habis: transaksi tunai tetap selesai; struk dicetak ulang dari nomor
  referensi.
- Listrik mati/PC lambat (asumsi): tombol simpan yang mengunci form sampai timeout, refresh yang
  menghapus ketikan, sesi terlalu pendek — semuanya pengalaman buruk.
- 1366×768: satu baris tabel + panel kanan sudah menghabiskan tinggi layar.
- Tutup teller: hitung fisik vs sistem, jelaskan selisih **per transaksi** (bukan satu angka
  global), serah terima, cetak rekap.

**Aturan yang diminta.** Satu form, satu tombol simpan, maksimum satu lapisan modal; nomor referensi
selalu tampil dan bisa disalin sebelum selesai; setiap aksi tunai punya rancangan "gagal separuh"
(uang masuk, sistem belum tersimpan).

**Yang membuat software dibenci.** Modal bertumpuk (anggota → setoran → konfirmasi → PIN); angka
tidak bisa diseleksi; tabel tidak bisa di-scan (baris terlalu tinggi, nominal rata kiri, tanpa garis
bantu baris); konfirmasi berlapis yang isinya sama; keyboard tidak jalan (fokus hilang, Tab keluar
form, Enter tidak submit); error buntu tanpa kode/transaksi/tombol ulangi.

**Aturan.** Enter = aksi utama, Esc = batal di semua layar; nominal pakai tabular figures; setiap
error menyebut transaksi dan aksi pemulihan; tidak ada jendela tanpa jalan keluar.

**Yang membuat percaya dan cepat.** Selalu terlihat: nama + nomor anggota, saldo, cabang, tanggal/
jam, saldo kas teller, referensi terakhir. Jangan pakai istilah akuntansi ke teller: "Setor (masuk)"
dan "Tarik (keluar)", dibedakan tanda (+/−), posisi kolom, **dan** warna (bukan warna saja). Setelah
simpan tampilkan saldo sebelum → sesudah. Shortcut (asumsi pola bank): F2 cari anggota, F4 setoran,
F5 penarikan, F9 pemindahbukuan, Enter simpan, Esc batal, Ctrl+P cetak ulang. Rupiah: pemisah ribuan,
desimal tetap, tanpa float, tanpa notasi eksponensial.

**Lima anti-pattern "dashboard bank modern".** (1) kartu metrik besar berikon sebagai isi utama;
(2) grafik donat/garis dekoratif tanpa aksi; (3) animasi transisi/skeleton/hover mewah (300 ms terasa
di jam sibuk); (4) hero/tur onboarding di aplikasi kerja; (5) modal konfirmasi layar penuh berilustrasi
untuk aksi rutin.

**Aturan.** Default halaman teller = tabel transaksi + panel aksi, bukan dashboard; animasi hanya
umpan balik < 100 ms; onboarding hanya hari pertama; konfirmasi hanya untuk pembatalan dan tutup kas.
1366×768 adalah target utama; uji tinggi 768 dan zoom 125% (asumsi). Mode keyboard bukan tambahan —
itu cara teller bekerja cepat.

## 2. Desain produk & information design

Tiga arah dibandingkan: **buku besar** (tipografi kuat, near-monokrom, hairline, angka tabular),
**terminal operasional** (sangat padat, mono, status bar), **koperasi hangat** (warna bumi, sudut
lembut). Rekomendasi: **buku besar dengan kulit hangat** — data near-monokrom, warna hangat hanya di
kulit (header, navigasi, halaman identitas), bukan di permukaan angka.

Alasan: tabel tanpa shadow terbaca sebagai dokumen akuntansi; salah baca turun; density 34 px +
kolom tetap mengurangi re-akuisisi baris; identitas Indonesia lewat kertas tulang + hijau tua, bukan
ornamen.

Usulan token (diverifikasi ulang dengan checker, lihat `DESIGN.md` §3): teks 16.24:1 terang /
15.06:1 gelap; teks-2 6.89 / 6.78; aksen 9.23 / 7.79; positif 6.47 / 7.53; negatif 7.53 / 6.78;
peringatan 5.93 / 7.75; info 8.30 / 7.85; border kontrol 3.67 / 4.07. Rentang font IBM Plex Sans +
Plex Mono (OFL, self-host); density 32/34/40; radius 2/4/6/8; shadow hanya overlay.

Aturan angka: rata kanan, tabular, kolom tetap, format `Intl.NumberFormat('id-ID')`, simbol mata
uang di header kolom, debit/kredit lewat kolom + label + posisi, selisih selalu disertai kata.

## 3. Aksesibilitas & craft front-end

Non-negotiable: kontrol **32 px**, aksi primer **44 px** (24 px hanya bila jarak ≥ 8 px); fokus 2 px
+ offset 2 px dan kontrasnya diuji terhadap `surface-raised`; DOM = urutan visual, tanpa
`tabindex > 0`; tabel ledger semantik (`caption`, `th scope`, `aria-sort`); error = ringkasan +
`aria-describedby` + fokus field pertama; `aria-live` polite untuk "tersimpan", assertive hanya
gagal transaksi; Enter submit, Esc tutup, label permanen.

Temuan terukur pada token lama: muted gelap `#AAB4C2` di raised `#1E2530` = 7.35:1 (aman); border
gelap di raised 3.34:1 (lulus non-teks, tapi jangan jadi satu-satunya pembatas); **terang
`surface` vs `bg` = 1.08:1** — panel nyaris tak terlihat, jadi grup wajib lewat border + elevasi.
Matriks uji kontras saat ini belum mencakup status di atas tint dan pasangan di `surface-raised`.

Zoom 200%: shell satu kolom; tabel ledger **tidak** diubah jadi kartu dan kolom tidak disembunyikan —
scroll horizontal dalam region berlabel, kolom kode/nominal sticky. Motion: dilarang animasi pada
baris/saldo, skeleton yang menggeser layout, toast yang menutupi toolbar. Cetak: `@page` 12mm,
`thead` berulang, `print-color-adjust` hanya untuk struk, status tetap berlabel.

Tiga risiko token lama: `system-ui` tidak menjamin angka tabular; minimum kontrol 24 px terlalu kecil
untuk shift panjang; radius 0.75rem + tiga shadow seragam menghilangkan ketajaman grid data.
