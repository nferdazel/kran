-- Hapus `deposit.account.last_activity` yang tidak pernah dipakai (O-111, D-157, D-170).
--
-- dbtools:contract berkas ini memuat `DROP COLUMN`: PostgreSQL tidak punya cara menghapus kolom
--   selain itu, dan biner lama masih bisa jalan karena tidak ada kode yang membaca/menulis kolom ini.
-- dbtools:destructive satu `DROP COLUMN` (`last_activity`). Kolomnya **selalu NULL**: ditambahkan
--   `0064` untuk dasar deteksi dormant, tetapi `D-157` memutuskan aktivitas dibaca dari baris
--   subledger (`deposit.transaction` + `deposit.transfer`) supaya tidak ada dua sumber kebenaran.
--   Karena tidak ada data yang hilang dan tidak ada konsumen (kode, laporan, atau query) yang
--   membacanya, kolom yang tidak terpelihara lebih berbahaya daripada ketiadaannya: pembaca skema
--   berikutnya akan mengira kolom itu dasar deteksi dan menyimpulkan semua rekening tidak aktif.
--
-- Kalau kelak "aktivitas terakhir" perlu dibaca dari kolom (bukan agregasi subledger), tambahkan
-- kolom baru + jalur tulis **dan** penjaga agar jalur mutasi baru tidak lupa mengisinya (O-111
-- opsi b), bukan menghidupkan lagi kolom yang sudah dibuang.

ALTER TABLE deposit.account DROP COLUMN last_activity;
