# Dokumentasi KRAN — peta dan aturan kesegaran

Dokumen di `docs/` tidak semuanya berlaku sama. Sebagian adalah **keadaan sekarang**, sebagian
adalah **catatan bertanggal** yang sengaja tidak ditulis ulang. Membedakannya penting: menyalin
angka dari catatan lama ke kode adalah cara paling mudah membuat dokumen "benar" tapi sistemnya
salah.

## Keadaan sekarang (harus akurat hari ini)

| Dokumen | Isi |
| --- | --- |
| [`spec/kran-prd-techspec.md`](spec/kran-prd-techspec.md) | Sumber kebenaran produk + teknis (termasuk daftar fase §23) |
| [`BACKLOG.md`](BACKLOG.md) | Status task (`TODO`/`READY`/`IN_PROGRESS`/`DONE`/`BLOCKED`) |
| [`OPEN_ITEMS.md`](OPEN_ITEMS.md) | Hal yang belum bisa ditutup + pemilik tindakannya |
| [`ACCEPTED-LIMITS.md`](ACCEPTED-LIMITS.md) | Batas yang **diterima** beserta cara mendeteksi dan pemiliknya |
| [`DECISIONS.md`](DECISIONS.md) | Register keputusan (append-only; keputusan lama ditandai "diganti D-xxx", tidak dihapus) |
| [`runbooks/`](runbooks) | Prosedur operasional yang dijalankan hari ini |
| [`ci-jobs.md`](ci-jobs.md) | Job CI yang benar-benar ada |
| [`compliance/`](compliance) | Register kepatuhan dan status verifikasi |
| `modules/*/MODULE.md` | Batas, tabel, izin, dan invarian tiap modul |
| [`../DESIGN.md`](../DESIGN.md) | Arah visual dan aturan UI yang mengikat |
| [`../AGENTS.md`](../AGENTS.md) | Aturan kerja manusia & agen, termasuk protokol per task |

Kalau isi dokumen di tabel ini bertentangan dengan kode, **kode + test yang menang** sampai
diperbaiki; catat pertentangannya di `DECISIONS.md` (dan `OPEN_ITEMS.md` bila butuh keputusan).

## Catatan bertanggal (riwayat, tidak ditulis ulang)

| Lokasi | Kenapa tidak diubah |
| --- | --- |
| [`PROGRESS.md`](PROGRESS.md), `PROGRESS-T0*.md` | Log per tanggal: angka dan keadaan saat itu. Angka terkini dicari di bagian terakhir, bukan di tengah |
| [`tasks/`](tasks) | Rencana + bukti per task. Fakta di dalamnya benar **pada tanggal pengerjaan** |
| [`proposals/`](proposals) | Memo usulan sebelum keputusan; bisa memuat opsi yang akhirnya ditolak |
| [`milestones/`](milestones) | Laporan penutupan fase |
| [`spikes/`](spikes) | Eksperimen dengan hasil terukur saat itu |
| [`migration/`](migration) | Inventaris sistem lama (referensi, bukan target) |
| [`ESCALATIONS.md`](ESCALATIONS.md) | Titik STOP beserta jawabannya (status `TERJAWAB` + tanggal) |

Aturan untuk catatan bertanggal:

1. **Jangan sunting fakta lamanya.** Kalau sebuah fakta sudah tidak berlaku, tambahkan catatan
   bertanggal di tempat yang sama (contoh: memo T-118 diberi catatan D-136 di kepalanya).
2. **Jangan salin angka** dari catatan bertanggal ke dokumen keadaan sekarang tanpa memeriksa kode.
3. **Jangan hapus dokumen** hanya karena isinya sudah digantikan; riwayat alasannya yang membuat
   keputusan berikutnya bisa dinilai.

## Jebakan yang sudah pernah menggigit

- **Presisi uang.** Sebelum 24 Okt 2026 uang 4 desimal; sekarang **2 desimal di penyimpanan, API, dan
  tampilan** (D-136). Dokumen lama yang menulis `numeric(24,4)` atau `0.0000` adalah riwayat.
- **Jumlah test/berkas.** Angka seperti "1099 OK" adalah snapshot pada tanggal task itu, bukan janji.
  Selalu jalankan gate sendiri; hasilnya yang berlaku.
- **Status task.** `BACKLOG.md` adalah satu-satunya tempat status task. Dokumen task bisa bilang
  "IN PROGRESS" walau task sudah `DONE`; percayai backlog + commit.
- **Batas yang sudah ditutup.** `ACCEPTED-LIMITS.md` memakai coretan (`~~…~~`) untuk batas yang sudah
  tidak berlaku, supaya tidak dikutip ulang sebagai masalah yang masih ada.
