# DESIGN.md — arah visual & aturan UI KRAN

Status: **arah ditetapkan (D-075) dan diratifikasi pemilik 21 Okt 2026 (D-115)**; token, komponen,
dan layar Fase 2 (teller, vault, ledger, cetak) sudah dibangun di atasnya (T-079 dan seterusnya).
Berlaku untuk setiap layar baru, termasuk Fase 3. Selama dokumen ini ada, pekerjaan UI tidak boleh
lagi "draft without direction".

Input: `docs/design/SME-NOTES.md` (operasional teller, information design, a11y). Angka kontras di
bawah dihitung ulang dengan contrast checker — bukan taksiran.

## 1. Arah: "buku besar, kulit hangat"

Basis datanya **buku besar**: near-monokrom, garis rambut, angka tabular, bidang datar. Kulitnya
**hangat**: kertas tulang, hijau tua bersahaja, sudut kecil — secukupnya di header, navigasi, dan
halaman identitas; **tidak** di permukaan angka.

Yang dipilih dan yang ditolak, eksplisit:

| Diterima | Ditolak |
|---|---|
| Tabel & angka sebagai bintang utama | Dashboard kartu metrik, grafik dekoratif |
| Latar kertas hangat, aksen hijau tua | Gradien biru-ungu, glow, glassmorphism |
| Hairline 1px, elevasi hanya untuk overlay | Shadow di semua kartu, radius pill |
| Angka tabular, rata kanan, kolom tetap | Angka proporsional, rata kiri, count-up |
| Satu bidang kerja per layar | Hero, tur onboarding, modal berlapis |
| Status = teks + bentuk + warna | Status hanya warna, animasi pulse abadi |

Identitasnya berasal dari **cara kerja** (kecepatan, ketenangan, akurasi), bukan dari ornamen.
Tidak ada ilustrasi, maskot, emoji, atau "sparkle".

## 2. Tipografi

- **UI:** IBM Plex Sans (OFL, self-host, tanpa CDN). Alasan: x-height tinggi, angka tabular, zero
  bertitik, dirancang untuk dokumen/mesin — bukan font display.
- **Angka uang, kolom jurnal, kode referensi:** IBM Plex Mono. Lebar digit tetap, desimal sejajar.
- **Fallback:** `system-ui` hanya sampai font termuat; jangan pernah mengandalkan tabular dari
  font sistem.
- Skala: `11 / 12 / 13 / 14 (base) / 16 / 20 / 28 px`; line-height 1.45 teks, 1.2 judul.
- Angka non-uang (tanggal, jumlah anggota) memakai Plex Sans + `font-variant-numeric:
  tabular-nums slashed-zero`.
- Bobot: 400 teks, 500 label, 600 angka yang mengubah saldo. Tidak ada 800/900, tidak ada
  uppercase ber-letter-spacing.

## 3. Warna

Token semantik, bukan nama warna. Nilai target (diverifikasi, lihat tabel bukti):

| Peran | Terang | Gelap |
|---|---|---|
| canvas | `#FAF8F5` | `#171614` |
| surface (panel/tabel) | `#FFFFFF` | `#1E1D1B` |
| teks | `#1C1B19` | `#EDEAE4` |
| teks-2 | `#5C5A55` | `#A8A49C` |
| hairline | `#E3DED6` | `#2A2926` |
| border kontrol | `#8A857C` | `#7C7770` |
| aksen / focus ring | `#1F4B43` | `#6FBFAA` |
| positif (kredit) | `#1A6B4A` | `#5FC08A` |
| negatif (debet) | `#9B2C2C` | `#E88B84` |
| peringatan | `#8A5A00` | `#D9A84E` |
| info | `#2A4C8F` | `#8FB3E8` |
| baris terpilih | `#EEF2EF` | `#23302C` |

Bukti (dihitung ulang 20 Okt 2026): teks 16.24:1 terang / 15.06:1 gelap; teks-2 6.89 / 6.78;
aksen 9.23 / 7.79; positif 6.47 / 7.53; negatif 7.53 / 6.78; peringatan 5.93 / 7.75; info 8.30 /
7.85; border kontrol 3.67 / 4.07 (non-teks ≥ 3:1). **Semua lolos AA** pada pasangan yang diuji.

Aturan yang mengikat:

- Warna hanya menguatkan makna; **tidak pernah satu-satunya pembeda** (spec §15.4).
- Di terang, `surface` vs `canvas` hanya 1.08:1 (token lama): panel dan baris dipisahkan **garis +
  elevasi minimum**, bukan tint.
- Pasangan di atas **wajib masuk matriks uji kontras** (termasuk status di atas tint status dan
  `surface` raised) sebelum token dipakai; menambah token tanpa uji = gagal review.
- Dark mode: jangan pakai teks-2 untuk angka uang; angka memakai `teks`.

## 4. Spasi, density, kontrol

- Grid 4px. Skala: 4 / 8 / 12 / 16 / 24 / 32 / 48.
- Baris tabel: 32 px (padat), **34 px default**, 40 px untuk baris dua tingkat. Padding sel 8×12,
  kolom pertama 16.
- Kontrol: **32 px** untuk input/tombol/aksi baris tabel; **44 px** untuk aksi primer (simpan,
  posting, cetak, buka/tutup kas). 24 px hanya bila tiap target berjarak ≥ 8 px.
- Target utama: **1366×768 pada zoom 100–125%**. Layout maksimum 72rem; di bawah 1100 px panel
  kanan turun jadi bawah, bukan modal.
- Tinggi toolbar maksimum 48 px; header lengket 34 px dengan garis bawah saat "stuck".

## 5. Bentuk

- Radius: 2 chip, 4 kontrol, 6 kartu, 8 dialog. Tidak ada pill.
- Pemisah: hairline. Shadow hanya untuk overlay: dropdown `0 2px 4px rgb(28 27 25 / .10)`,
  dialog `0 8px 24px rgb(28 27 25 / .16)`. **Kartu flat.**
- Tabel: radius kiri-kanan `4`, tanpa shadow, tanpa zebra.

## 6. Tabel & angka uang

- Tabel memakai `<table>` semantik: `<caption>`, `<th scope>`, `aria-sort` untuk kolom terurut;
  pembungkus `overflow-x:auto` dengan `role="region"`, `tabindex="0"`, `aria-label`.
- Garis horizontal saja. Tanpa garis vertikal (vertikal hanya di ekspor kertas kerja). Baris
  terakhir tanpa garis. Header grup lebih tebal.
- Angka: rata kanan, digit tabular, padding kanan 12 px + 4 px optis, `white-space:nowrap`.
  Digit terakhir setiap baris jatuh di satu garis vertikal.
- Format `id-ID` / `en-US` lewat `Intl.NumberFormat`; simbol mata uang di header kolom
  ("Saldo (IDR)"), bukan di setiap sel. Singkatan angka (rb/jt) dilarang.
- **Presisi uang 2 desimal di semua tempat** (D-136): penyimpanan `numeric(24,2)`, API string 2
  desimal, layar 2 desimal. Tidak ada lagi dua presisi berbeda antara tabel dan layar tunai.
- Debit/kredit: kolom terpisah + label "D"/"K" + posisi, bukan warna saja. Untuk teller, bahasa
  yang dipakai "Setor (masuk)" / "Tarik (keluar)" dengan tanda + / −.
- Total: baris lengket, hairline 2 px di atas, latar surface. Selisih selalu disertai kata:
  "Tidak seimbang: selisih 250.000,00". Nol tampil `0,00`; negatif pakai minus di depan digit.
- Nilai angka bisa diseleksi dan disalin; jangan pakai `user-select:none` di sel data.

## 7. Form, alur, dan kegagalan

- Satu form, satu tombol simpan, **maksimum satu lapisan modal**. Tidak ada konfirmasi untuk aksi
  rutin; konfirmasi hanya untuk pembatalan dan tutup kas.
- Enter = aksi utama, Esc = batal/tutup. Label permanen (bukan placeholder). Field uang menolak
  karakter non-digit.
- Error: ringkasan di atas form, pesan teks + `aria-describedby`, fokus ke field salah pertama,
  kode/rujukan transaksi bila ada, dan jalan pulih ("Ulangi", "Salin rujukan"). Tidak ada
  "Terjadi kesalahan sistem" tanpa langkah berikutnya.
- Nomor referensi tampil dan bisa disalin **sebelum** transaksi selesai.
- Aksi tunai punya rancangan "gagal separuh": uang sudah diterima, sistem belum tersimpan — tampilkan
  status jelas + langkah rekonsiliasi, bukan toast lalu hilang.

## 8. Status & motion

- Status = teks + ikon garis + warna, dengan `role="status"`/`aria-live="polite"` untuk "tersimpan"
  dan saldo; `assertive` hanya untuk kegagalan transaksi. Jangan umumkan tiap ketikan.
- Durasi 120 ms (hover/focus), 180 ms (expand/dialog); **0 ms untuk angka**. Tidak ada animasi pada
  baris/saldo yang berubah, count-up, skeleton yang menggeser layout, atau pulse abadi.
- `prefers-reduced-motion`: semua transisi 0 ms; state akhir tetap terbaca.
- Toast: punya live region + tombol tutup, tidak menutupi tombol simpan/cetak, error tidak
  auto-hilang.

## 9. Ikon & copy

- Satu keluarga ikon garis, stroke 1.5 px, grid 20 px, self-host. Tanpa emoji/sparkle.
- Copy Indonesia: kerja, bukan pemasaran. "Setor (masuk)" bukan "Debit"; "Tutup kas" bukan
  "Finalisasi sesi"; "Belum ada jurnal bertanggal ini. Posting jurnal (F2), atau ubah tanggal."
- Tidak mengarang angka, nama, atau alasan. Empty state jujur, tanpa data dummy.

## 10. Aksesibilitas (non-negotiable)

- Fokus `:focus-visible` 2 px + offset 2 px, kontras ≥ 3:1 terhadap **surface raised** juga; tidak
  pernah `outline:none`.
- Urutan DOM = urutan visual; tanpa `tabindex > 0`; satu tab-stop per komponen komposit
  (combobox/tabel: Tab masuk, panah pindah item, `aria-activedescendant`).
- Satu `h1` per halaman, landmark lengkap, skip link ke `#main`.
- Zoom 200%: shell satu kolom; **tabel ledger tidak boleh diubah jadi kartu** dan kolom tidak
  disembunyikan — pakai scroll horizontal dalam region berlabel, kolom kode/nominal sticky.
- Cetak: `@page { margin: 12mm }`, `thead` berulang, `break-inside: avoid` pada blok total/tanda
  tangan, sembunyikan nav/toolbar/toast, status tetap berlabel teks, angka tabular, tema terang.
- axe wajib hijau di dua tema; alur kritis diuji keyboard-only.

## 11. Daftar larangan (anti-slop)

1. Gradien biru-ungu/ungu-pink, glow, glassmorphism.
2. Shadow di semua kartu; semua elemen mengapung.
3. Radius pill seragam di input/baris/chip.
4. Empat kartu statistik dengan delta tanpa sumber.
5. Emoji, sparkle, petir sebagai ikon status.
6. Setiap bagian dibungkus kartu (sidebar + topbar + 4 kartu + grafik + tabel).
7. Hero, tur onboarding, modal konfirmasi berilustrasi untuk aksi rutin.
8. Skeleton yang tak pernah terisi, data dummy, "John Doe".
9. Count-up pada angka, animasi pulse abadi.
10. Uppercase ber-letter-spacing lebar sebagai gaya default.
11. Label placeholder sebagai satu-satunya label.
12. Tabel `div` tanpa semantik, sort hanya ikon.

## 12. Cara memverifikasi (saat UI ada)

- Matriks kontras penuh (dua tema, termasuk status di atas tint dan surface raised) hijau.
- axe dua tema + keyboard-only untuk alur kritis; e2e Playwright.
- Satu layar penuh pada 1366×768 dan zoom 125% tanpa scroll horizontal pada shell.
- Cetak struk + rekap: tidak terpotong, status tetap terbaca.
- Delivery Gate antislop (4 blok PASS/FAIL) + R-35: jalankan app, klik setiap elemen, cek console.
