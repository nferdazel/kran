# DESIGN.md — arah visual & aturan UI KRAN

Status: **arah v2 ditetapkan 31 Okt 2026 (D-160)**, menggantikan D-075 dan ratifikasi D-115.
Berlaku untuk setiap layar dan komponen baru sejak sekarang. Implementasi berjalan bertahap
(§12); layar yang belum dimigrasi masih memakai token v1, dan itu **keadaan transisi yang
diketahui**, bukan izin menambah penyimpangan baru.

Input: `docs/proposals/design-v2-direction.md` (arah yang dipilih pemilik), `docs/design/SME-NOTES.md`
(operasional teller, information design, a11y). Angka kontras di bawah dihitung dengan contrast
checker, bukan taksiran.

Reading this as: back-office core banking untuk staf koperasi/BPR non-teknis, bahasa visual
netral-dingin dengan satu aksen, dial **ENERGY 2 / RHYTHM 2 / MOTION 2**.

## 1. Arah: alat kerja yang tenang

Basis datanya **netral dan dingin**: permukaan bersih, garis rambut, angka tabular, bidang datar.
Satu aksen **plum** dipakai hemat, hanya di titik yang butuh perhatian. Karakternya datang dari
ketenangan dan ketepatan, bukan dari ornamen.

| Diterima | Ditolak |
|---|---|
| Tabel & angka sebagai bintang utama | Dashboard kartu metrik, grafik dekoratif |
| Netral dingin + satu aksen plum | Gradien, glow, glassmorphism, pelangi status |
| Hairline 1px, elevasi hanya untuk overlay | Shadow di semua kartu, radius pill |
| Angka tabular, rata kanan, kolom tetap | Angka proporsional, rata kiri, count-up |
| Satu bidang kerja dan satu titik fokus per layar | Hero, tur onboarding, modal berlapis |
| Status = teks + bentuk + warna | Status hanya warna, animasi pulse abadi |
| Komponen bersama dengan state lengkap | CSS per halaman yang menyalin aturan |

Tidak ada ilustrasi, maskot, emoji, atau "sparkle". Tidak ada logo karangan: nama produk ditulis
sebagai teks, bukan digambar.

## 2. Tipografi

- **Satu keluarga: IBM Plex Sans** (OFL, self-host, tanpa CDN). Alasan: angka tabular tersedia,
  x-height tinggi, dirancang untuk dokumen — bukan font display, dan bukan pilihan default pasar.
- **IBM Plex Mono tidak dipakai lagi**, termasuk untuk uang, kolom jurnal, dan struk. Angka uang
  memakai Plex Sans dengan `font-variant-numeric: tabular-nums slashed-zero`.
- **Fallback:** `system-ui` hanya sampai font termuat; jangan mengandalkan tabular dari font sistem.
- Skala: `11 / 12 / 13 / 14 (base) / 16 / 20 / 28 px`; line-height 1.45 teks, 1.2 judul.
- Bobot: 400 teks, 500 label, 600 angka yang mengubah saldo. Tidak ada 800/900, tidak ada uppercase
  ber-letter-spacing.

## 3. Warna

Token semantik, bukan nama warna. Nilai dan bukti (dihitung 31 Okt 2026):

### Terang

| Peran | Nilai | Bukti |
|---|---|---|
| canvas | `#F6F7F9` | teks 16.78:1 |
| surface (panel/tabel) | `#FFFFFF` | teks 17.99:1 |
| teks | `#14171A` | 17.99:1 di surface |
| teks-2 | `#565D66` | 6.66:1 di surface, 6.21:1 di canvas |
| hairline | `#E3E7EC` | pemisah, bukan teks |
| border kontrol | `#7C848F` | 3.53:1 di canvas (non-teks ≥3:1) |
| aksen / focus ring | `#5B2A5E` | 10.84:1 di surface |
| positif (kredit) | `#17603F` | 7.55:1 |
| negatif (debet) | `#A02B31` | 7.28:1 |
| peringatan | `#8A5A00` | 5.93:1 |
| info | `#23557F` | 7.84:1 |
| baris terpilih | `#EDF0F4` | teks 15.74:1, teks-2 5.83:1 |

### Gelap

| Peran | Nilai | Bukti |
|---|---|---|
| canvas | `#101215` | teks 15.81:1 |
| surface | `#181B1F` | teks 14.56:1 |
| teks | `#E8ECF1` | 14.56:1 di surface |
| teks-2 | `#9AA3AE` | 6.77:1 di surface |
| hairline | `#272C32` | pemisah, bukan teks |
| border kontrol | `#6F7883` | 4.19:1 di canvas (non-teks) |
| aksen / focus ring | `#D9A0D4` | 8.17:1 di surface, 8.87:1 di canvas |
| positif | `#5FBF8D` | 7.67:1 |
| negatif | `#E88B84` | 6.96:1 |
| peringatan | `#D9A84E` | 7.95:1 |
| info | `#8FB3E8` | 8.05:1 |
| baris terpilih | `#1E2429` | teks 13.21:1, teks-2 6.14:1 |

Aturan yang mengikat:

- **Satu aksen saja.** Alasan: plum tidak bertabrakan dengan empat warna status yang harus tetap
  terbaca sebagai status, dan tetap terasa manusia, bukan mesin. Aksen dipakai untuk fokus, aksi
  primer, tautan, dan penanda lokasi. **Bukan** untuk status, **bukan** untuk seluruh permukaan.
- Warna hanya menguatkan makna; **tidak pernah satu-satunya pembeda** (spec §15.4).
- `surface` vs `canvas` hanya beda tipis: panel dan baris dipisahkan **garis + elevasi minimum**,
  bukan tint.
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
- Pemisah: hairline. Shadow hanya untuk overlay: dropdown `0 2px 4px rgb(20 23 26 / .10)`,
  dialog `0 8px 24px rgb(20 23 26 / .16)`. **Kartu flat.**
- Permukaan dipakai untuk bidang kerja (tabel, form, panel), bukan untuk membungkus setiap
  kelompok. Tabel: radius kiri-kanan `4`, tanpa shadow, tanpa zebra.

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
  desimal, layar 2 desimal.
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
- Setiap kontrol punya state `:disabled` yang terlihat dan kontrasnya terukur. Tombol yang tampak
  bisa ditekan padahal mati adalah cacat, bukan detail.
- Aksi tunai punya rancangan "gagal separuh": uang sudah diterima, sistem belum tersimpan —
  tampilkan status jelas + langkah rekonsiliasi, bukan toast lalu hilang.

## 8. Status & motion

- Status = teks + ikon garis + warna, dengan `role="status"`/`aria-live="polite"` untuk "tersimpan"
  dan saldo; `assertive` hanya untuk kegagalan transaksi. Jangan umumkan tiap ketikan.
- Durasi 150–200 ms untuk elemen non-angka (hover, expand, dialog); **0 ms untuk angka**. Tidak
  ada animasi pada baris/saldo yang berubah, count-up, skeleton yang menggeser layout, atau pulse
  abadi.
- `prefers-reduced-motion`: semua transisi 0 ms; state akhir tetap terbaca.
- Toast: punya live region + tombol tutup, tidak menutupi tombol simpan/cetak, error tidak
  auto-hilang.

## 9. Ikon & copy

- Satu keluarga ikon garis, stroke 1.5 px, grid 20 px, self-host. Tanpa emoji/sparkle. Tanpa
  glyph pengganti ikon (`✔`, `○`, `▲`) sebagai status.
- Copy Indonesia: kerja, bukan pemasaran. "Setor (masuk)" bukan "Debit"; "Tutup kas" bukan
  "Finalisasi sesi"; "Belum ada jurnal bertanggal ini. Posting jurnal (F2), atau ubah tanggal."
- Istilah internal tidak tampil ke operator: kode task, nama tabel, `uuid`, "run", "vault".
  Operator melihat akibatnya ("Kas belum dibuka", "Selisih kas 12.000,00"), bukan mekanismenya.
- Tidak mengarang angka, nama, atau alasan. Empty state jujur, tanpa data dummy.

## 10. Aksesibilitas (non-negotiable)

- Fokus `:focus-visible` 2 px + offset 2 px, kontras ≥ 3:1 terhadap **surface raised** juga; tidak
  pernah `outline:none`.
- Urutan DOM = urutan visual; tanpa `tabindex > 0`; satu tab-stop per komponen komposit
  (combobox/tabel: Tab masuk, panah pindah item, `aria-activedescendant`).
- Satu `h1` per halaman, landmark lengkap, skip link ke `#main`.
- Pengaturan tampilan (tema, bahasa) **tidak boleh** menjadi tab-stop sebelum konten.
- Zoom 200%: shell satu kolom; **tabel ledger tidak boleh diubah jadi kartu** dan kolom tidak
  disembunyikan — pakai scroll horizontal dalam region berlabel, kolom kode/nominal sticky.
- Cetak: `@page { margin: 12mm }`, `thead` berulang, `break-inside: avoid` pada blok total/tanda
  tangan, sembunyikan nav/toolbar/toast, status tetap berlabel teks, angka tabular, tema terang.
- axe wajib hijau di dua tema; alur kritis diuji keyboard-only.

## 11. Struktur & navigasi

- **Satu titik fokus per layar.** Di layar transaksi titik fokusnya form dan angkanya; di layar
  daftar, tabelnya. Tidak ada strip kartu metrik.
- Navigasi dikelompokkan menurut pekerjaan (mis. Kas, Anggota, Simpanan, Buku besar, Pengaturan),
  bukan daftar datar. Setiap item menuju layar yang benar-benar ada.
- Layar kas adalah **stasiun kerja**: membuka kas tidak bergantung pada memuat rekening anggota,
  dan daftar transaksi sesi terlihat tanpa berpindah halaman.
- Aturan visual tinggal di token + komponen bersama (`packages/ui`), bukan disalin per halaman.
  Halaman boleh punya tata letak; halaman tidak boleh menulis ulang aturan.

## 12. Status implementasi

| Fase | Isi | Gerbang |
|---|---|---|
| 0 | Dokumen ini + D-160 | review pemilik (selesai) |
| 1 | token v2 + matriks kontras diperluas + komponen Svelte di `packages/ui` | vitest kontras 2 tema, svelte-check |
| 2 | shell + navigasi bergrup + pengaturan keluar dari alur Tab | axe 2 tema, keyboard, Playwright |
| 3 | layar kas sebagai stasiun kerja | axe, keyboard, e2e kas |
| 4 | migrasi layar lain ke komponen | axe per layar, e2e layar |
| 5 | copy operator, hapus istilah teknis | i18ncheck, review copy |
| 6 | zoom 125/200 + cetak | Playwright zoom, print |

Sampai sebuah fase selesai, penyimpangan yang **sudah ada sebelum D-160** dicatat di PR sebagai
utang migrasi, bukan temuan review. Penyimpangan **baru** tetap gagal review.

## 13. Daftar larangan (anti-slop)

1. Gradien dekoratif, glow, glassmorphism.
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
13. Tombol atau tautan tanpa perilaku, termasuk yang dinonaktifkan tanpa state terlihat.
14. Logo, avatar, atau foto yang digambar sendiri tanpa diminta.

## 14. Cara memverifikasi

- Matriks kontras penuh (dua tema, termasuk status di atas tint dan surface raised) hijau.
- axe dua tema + keyboard-only untuk alur kritis; e2e Playwright.
- Satu layar penuh pada 1366×768 dan zoom 125% tanpa scroll horizontal pada shell.
- Cetak struk + rekap: tidak terpotong, status tetap terbaca.
- Delivery Gate antislop (4 blok PASS/FAIL) + R-35: jalankan app, klik setiap elemen, cek console.
