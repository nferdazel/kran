-- Komentar skema yang jujur untuk `deposit.account.last_activity` (T-138e, D-157, O-111).
--
-- `0064` menambahkan kolom ini dengan komentar "dasar deteksi dormant T-138e". Saat T-138e
-- dikerjakan, deteksi dormant **tidak** memakai kolom itu: tidak ada jalur transaksi yang
-- menulisnya, jadi membacanya akan membuat semua rekening terlihat tidak aktif sejak dibuka.
-- Aktivitas kini dibaca dari subledger (`deposit.transaction` + `deposit.transfer`) — lihat
-- `modules/deposit/infrastructure/dormant_repo.nim` dan D-157 butir 1.
--
-- Migrasi terpisah, bukan suntingan `0064`/`0071`: berkas yang sudah diterapkan dijaga checksum
-- (`platform.schema_migration`), jadi komentar yang menyesatkan diperbaiki lewat migrasi baru.
-- Hanya `COMMENT` (tanpa DDL merusak, tanpa perubahan data).
--
-- dbtools:contract kolom `last_activity` baru ada setelah `deposit/0064`, dan `0064` sendiri
--   bertanda contract (mengganti CHECK `account_type`). Jalur expand berjalan sebelum seluruh
--   berkas contract, jadi `COMMENT` di sini harus ikut fase contract — kalau tidak, ia gagal
--   `column does not exist` pada database yang dimigrasi dari kosong.

COMMENT ON COLUMN deposit.account.last_activity IS
  'TIDAK DIPAKAI (O-111). Kolom ini tidak pernah ditulis jalur transaksi mana pun, sehingga tidak '
  'boleh dipakai sebagai dasar deteksi dormant. Sumber aktivitas = baris deposit.transaction dan '
  'deposit.transfer (D-157).';
