# Runbook — migrasi skema (expand → contract → rollback)

Untuk operator. Yang rutin hanya `--check`/`--up` (dan itu dipanggil `ops/scripts/deploy-vps.sh`);
`--contract` dan `--down` **manual, opt-in, dan bukan jalur rutin**. Implementasi:
`tools/dbtools/lib.nim`; peran CLI-nya `--role=migrate` (lihat `ops-cli.md`).

## Bentuk berkas

`modules/<modul>/migrations/<NNNN>_<slug>.sql` — terurut `(NNNN, modul, nama)`, dijalankan sekali,
idempoten (yang sudah tercatat dilewati; isinya tidak boleh berubah setelah diterapkan).

- **Expand (bawaan)**: menambah tanpa merusak versi yang sedang berjalan.
- `-- dbtools:destructive <alasan>`: berkas memuat DDL merusak. Alasan wajib. Jalur `--up` **tidak**
  menjalankannya (kode 3) — hanya `--contract`.
- `-- dbtools:contract <alasan>`: berkas dua tahap. `--up` melewatinya; `--contract` yang menjalankan,
  dan hanya bila seluruh migrasi expand sudah diterapkan. Bila berkasnya juga merusak, **kedua** penanda
  wajib ada — tidak ada pengecualian.
- `<NNNN>_<slug>.down.sql`: pasangan rollback. Bukan migrasi (tidak ikut dihitung/diurutkan), diperiksa
  seperti migrasi: tidak boleh `BEGIN`/`COMMIT`/`ROLLBACK`, tidak boleh kosong.

## Perintah

| Perintah | Arti |
|---|---|
| `migrate.sh --check` | read-only; keluar 1 bila ada migrasi **expand** tertunda atau isi migrasi yang sudah diterapkan berubah |
| `migrate.sh --up` | terapkan migrasi expand tertunda (idempoten) |
| `migrate.sh --contract --yes` | terapkan berkas bertanda contract; menolak bila expand masih tertunda |
| `migrate.sh --down --yes N` | batalkan N migrasi **terakhir diterapkan** |

Kode keluar: **0** berhasil · **1** salah data · **2** salah pakai · **3** dikenali tetapi ditolak pada
keadaan itu. Skrip ops membaca bedanya; jangan "merapikan" kode keluar tanpa memperbarui skrip.

Catatan `--check`: migrasi contract yang belum dijalankan **tidak** dihitung sebagai tertunda (berkas
contract memang menunggu keputusan operator, spec §21.4) — jadi merilis berkas contract tidak membuat
gate deploy merah selamanya. Yang tetap masuk hitungan: expand tertunda dan checksum yang berubah.

## Urutan expand → contract

1. Rilis migrasi expand, deploy biasa; versi lama dan baru hidup bersama.
2. Setelah rilis stabil dan tidak ada lagi proses yang memakai bentuk lama, tambahkan berkas contract
   berpenanda (lewat PR, di-review), lalu jalankan manual di jendela pemeliharaan:
   `migrate.sh --contract --yes`.
3. Bila ternyata salah: `migrate.sh --down --yes 1` — hanya bila berkas pasangannya ada.

## Rollback: batasnya, supaya tidak dikira lebih kuat daripada kenyataannya

- Hanya **N migrasi terakhir yang diterapkan**, berurutan. Tidak ada pemilihan per nama.
- Butuh berkas pasangan `.down.sql` yang **sudah di-review sebelumnya** — dibuat lewat PR, bukan
  ditulis di server saat panik. Tanpa pasangan: ditolak (kode 3) tanpa efek samping apa pun.
- Baris di `platform.schema_migration` **dihapus** setelah pembatalan berhasil, supaya `--check`/`status`
  menggambarkan DB dan bukan niat. Akibatnya `--up` sesudahnya akan menerapkannya lagi (dan itu benar).
- **Tidak tahu apa-apa soal data.** Membatalkan migrasi yang sudah dipakai aplikasi bisa menghilangkan
  kolom yang masih dibaca. Backup pra-deploy tetap jalur utama; `--down` bukan penggantinya.
- Tidak ada pembatalan otomatis saat deploy gagal — deploy hanya memanggil `--check`/`--up`.
- Tidak ada riwayat "pernah diterapkan lalu dibatalkan" di DB; jejaknya ada di log operator dan di
  kontrol versi berkas pasangannya (D-040).

## Kalau ditolak

| Pesan | Artinya |
|---|---|
| `migrasi expand masih tertunda (...)` | jalankan `--up` lebih dulu; contract selalu setelah expand |
| `tidak ada berkas pasangan ...` | pasangannya belum dibuat/di-merge |
| `diminta membatalkan N migrasi, tetapi hanya M yang diterapkan` | N salah; cek jumlah yang benar dulu |
| `DDL merusak ditolak oleh mode expand-only` | berkas belum berpenanda; itu penjagaan, bukan gangguan |
| `berkas pasangan rollback tidak boleh memuat 'COMMIT'` | pasangan mengelola transaksinya sendiri; runner yang mengelola |

## Status

Belum pernah dijalankan di server: skripnya bagian dari latihan deploy (T-013). Diuji di DB dev —
`itapi_roles` (kontrak kode keluar) + `itplatform` (efeknya di DB: DDL benar dijalankan/dikembalikan,
baris ikut terhapus, kegagalan di tengah tidak meninggalkan keadaan setengah). Bukti mutasi: 13
penjagaan, masing-masing dilepas dan ada uji yang gagal — `docs/tasks/T-035.md`.
