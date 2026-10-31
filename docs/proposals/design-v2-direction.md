# Arah Desain v2 — netral dingin, satu aksen, satu keluarga huruf

**Status:** diratifikasi pemilik 31 Okt 2026 sebagai **D-160**; arah ini sekarang mengikat lewat
`DESIGN.md` v2. Dokumen ini disimpan sebagai catatan asal-usul, bukan sumber aturan.
**Tanggal:** 31 Okt 2026. **Bukan kode, bukan migrasi.**

Reading this as: back-office core banking untuk staf koperasi/BPR non-teknis, bahasa visual
netral-dingin dengan satu aksen, dial **ENERGY 2 / RHYTHM 2 / MOTION 2**.

## 1. Apa yang berubah, dan apa yang tidak

| | v1 (berlaku) | v2 (usulan) |
|---|---|---|
| Metafora | buku besar berkulit hangat | alat kerja yang tenang |
| Dasar warna | kertas tulang + hijau tua | netral dingin + satu aksen plum |
| Huruf uang | IBM Plex Mono | IBM Plex Sans, angka tabular |
| Kepadatan | padat (34 px) | padat (34 px), tanpa perubahan |
| Angka | 2 desimal, rata kanan | 2 desimal, rata kanan, tanpa perubahan |

Yang **tidak** ikut berubah karena ini batasan bank, bukan selera: WCAG 2.2 AA di dua tema, target
1366×768 pada zoom 100–125%, tabel semantik, uang 2 desimal lewat `Money`, i18n id/en, cetak,
keyboard-only tanpa `outline:none`, status = teks + bentuk + warna.

## 2. Tipografi

Satu keluarga: **IBM Plex Sans** (OFL, self-host). Dipertahankan, bukan karena malas: angka
tabularnya sudah dipakai di sistem ini (DESIGN v1 §2 untuk tanggal dan jumlah), sehingga
`font-variant-numeric: tabular-nums slashed-zero` bisa diperluas ke kolom uang tanpa font baru.
Identitas v2 datang dari warna, komposisi, dan skala — bukan dari mengganti huruf.

- IBM Plex Mono **dihapus** dari antarmuka, termasuk sel uang dan struk. Tidak ada alasan
  fungsional yang tersisa begitu angka tabular tersedia di keluarga sans.
- Skala: `11 / 12 / 13 / 14 (base) / 16 / 20 / 28 px`; line-height 1.45 teks, 1.2 judul.
- Bobot: 400 teks, 500 label, 600 hanya untuk angka yang mengubah saldo. Tanpa 800/900.
- Angka: `tabular-nums slashed-zero` di **semua** angka, termasuk tanggal dan jumlah baris.
- Uppercase ber-letter-spacing tetap dilarang.

## 3. Warna

Token semantik. Nilai di bawah **sudah dihitung** dengan contrast checker, bukan taksiran.

### Terang

| Peran | Nilai | Bukti |
|---|---|---|
| canvas | `#F6F7F9` | teks 16.78:1 |
| surface | `#FFFFFF` | teks 17.99:1 |
| teks | `#14171A` | 17.99:1 di surface |
| teks-2 | `#565D66` | 6.66:1 di surface, 6.21:1 di canvas |
| hairline | `#E3E7EC` | pemisah, bukan teks |
| border kontrol | `#7C848F` | 3.53:1 di canvas (non-teks, ≥3:1) |
| aksen / focus ring | `#5B2A5E` | 10.84:1 di putih |
| positif | `#17603F` | 7.55:1 |
| negatif | `#A02B31` | 7.28:1 |
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

- **Aksen hanya satu**, yaitu plum. Alasan: plum tidak bertabrakan dengan empat warna status
  (hijau/merah/amber/biru) yang harus tetap terbaca sebagai status, dan tetap terbaca sebagai
  warna manusia, bukan warna mesin.
- Aksen dipakai untuk: fokus, aksi primer, tautan, penanda lokasi. **Tidak** untuk status, dan tidak
  untuk seluruh permukaan.
- Warna tidak pernah satu-satunya pembeda (spec §15.4). Status = teks + bentuk + warna.
- Pasangan baru wajib masuk matriks uji kontras **sebelum** token dipakai; menambah token tanpa uji
  = gagal review. Matriks `packages/ui/tests/tokens.contrast.test.ts` ikut diperluas, termasuk
  status di atas tint status dan `surface` raised.
- Di tema gelap, angka uang memakai `teks`, bukan `teks-2`.

## 4. Bentuk, spasi, density

Grid 4 px; skala 4 / 8 / 12 / 16 / 24 / 32 / 48. Radius 2 chip / 4 kontrol / 6 kartu / 8 dialog,
tetap. Baris tabel 34 px default (32 padat, 40 dua tingkat); padding sel 8×12; kolom pertama 16.
Kontrol 32 px, aksi primer 44 px. Toolbar maksimum 48 px.

Perubahan v2: **kartu berhenti jadi wadah default.** Permukaan dipakai untuk bidang kerja (tabel,
form, panel), bukan untuk setiap kelompok. Shadow tetap hanya untuk overlay.

## 5. Struktur (ringkas; detail menyusul di fase 2)

Arah ini menyentuh struktur, bukan cuma warna. Komitmen tingkat atas:

- **Satu titik fokus per layar.** Di layar transaksi, titik fokusnya adalah form dan angkanya; di
  layar daftar, tabelnya. Tidak ada strip kartu metrik.
- **Navigasi dikelompokkan** menurut pekerjaan (Kas, Anggota, Simpanan, Buku besar, Pengaturan),
  bukan daftar datar 9 item.
- **Pengaturan (tema, bahasa) pindah keluar dari alur Tab konten** ke menu akun di akhir shell.
- **Layar kas adalah stasiun kerja**: buka kas tidak boleh bergantung pada memuat rekening anggota,
  dan daftar transaksi sesi harus terlihat tanpa berpindah halaman.
- **Komponen, bukan CSS per halaman.** `packages/ui` mendapat komponen Svelte dengan state lengkap
  (default, hover, focus, disabled, invalid, loading). Tanpa ini, aturan v2 hanya jadi dekorasi.

## 6. Batasan anti-slop yang berlaku untuk v2

Dilarang: gradien dekoratif, glow, glassmorphism, radius pill, emoji/sparkle, kartu statistik
tanpa sumber, count-up pada angka, skeleton yang tak pernah terisi, data dummy, uppercase
ber-letter-spacing, label placeholder sebagai satu-satunya label, status hanya warna, tombol tanpa
perilaku, dan kontrol yang tampil tetapi tidak punya state `:disabled` (hazard yang sekarang ada:
37 tombol `:disabled` tanpa style).

Motion: transisi 150–200 ms hanya untuk elemen non-angka (hover, expand, dialog). Angka 0 ms.
`prefers-reduced-motion` mematikan semua transisi.

## 7. Inventaris komponen minimum (fase 1)

shell (header, nav bergrup, menu akun, skip link) · page header + toolbar · tabel (caption, `th
scope`, `aria-sort`, region berlabel, kolom uang sticky) · sel uang · field + label + pesan error ·
tombol (primer/sekunder/baris/destruktif, semua state) · badge status · alert inline · empty state ·
dialog · live region · palette · header cetak.

## 8. Fase, dan gerbang tiap fase

| Fase | Isi | Gerbang |
|---|---|---|
| 0 | Dokumen ini + entri D-160 + `DESIGN.md` diganti | review pemilik |
| 1 | Token v2 + matriks kontras diperluas + komponen Svelte (`packages/ui`) | vitest kontras 2 tema, svelte-check |
| 2 | Shell + IA baru (nav bergrup, pengaturan keluar dari alur Tab, `/app` = Hari ini) | axe 2 tema, keyboard, Playwright |
| 3 | Layar kas sebagai stasiun kerja | axe, keyboard, e2e kas |
| 4 | Migrasi 9 layar lain ke komponen | axe per layar, e2e layar |
| 5 | Copy: istilah operator, hapus kebocoran istilah teknis | i18ncheck, review copy |
| 6 | Zoom 125/200 + cetak | Playwright zoom, print |

`./task ci` hijau di akhir setiap fase. Fase 3 membutuhkan endpoint baru
`GET /teller/sessions/{id}/transactions` (belum ada di kontrak) — itu perubahan API, bukan UI, dan
harus lewat jalur biasa (OpenAPI + contract test).

## 9. Yang perlu diputuskan pemilik

1. **Aksen plum `#5B2A5E` / `#D9A0D4`** — atau indigo `#2F3E9E` / `#AEBBF5` (9.12:1 / 9.24:1).
2. **IBM Plex Sans dipertahankan** sebagai satu-satunya keluarga huruf (alasan di §2), atau ganti
   keluarga huruf — bila ganti, dukungan angka tabular wajib diverifikasi dulu, jangan diasumsikan.
3. Ratifikasi entri **D-160** dan penggantian `DESIGN.md`.
