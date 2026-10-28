-- Deposito berjangka: tipe rekening baru + kolom jatuh tempo/ARO/aktivitas (T-138b, D-152).
--
-- dbtools:contract berkas ini memuat `DROP CONSTRAINT`: CHECK `account_type` dari `0003` hanya
--   menerima `SAVINGS`, dan PostgreSQL tidak punya cara melonggarkan CHECK selain menggantinya.
--   Karena itu seluruh berkas — termasuk kolom baru — diterapkan lewat `migrate --contract`
--   setelah jalur expand bersih, bukan sebagian-sebagian: skema setengah jadi (kolom ada, tipe
--   rekening masih ditolak) tidak pernah diuji siapa pun.
-- dbtools:destructive satu-satunya DDL merusak adalah `DROP CONSTRAINT account_account_type_check`.
--   Tidak ada tabel/kolom/baris yang dihapus, dan penggantinya lebih longgar; biner lama tetap
--   jalan karena ia hanya menulis `SAVINGS`, yang lolos CHECK baru.
--
-- Model data (D-152): deposito berjangka adalah `account_type = TIME_DEPOSIT` pada rekening yang
-- sama, bukan tabel terpisah — identitas, saldo, transaksi, dan PB tetap dipakai bersama. Tiga
-- kolom baru **nullable semua**: rekening tabungan tidak punya jatuh tempo/ARO, dan mengisi nilai
-- untuk rekening lama bukan tugas migrasi (tidak ada data yang bisa dipakai untuk menebaknya).
--
-- `account_account_type_check` adalah nama yang diberikan PostgreSQL untuk CHECK kolom tanpa nama
-- di `0003` (pola `<tabel>_<kolom>_check`). Berkas `0003` immutable (dijaga checksum), jadi namanya
-- stabil; bila kelak berbeda, migrasi ini gagal keras alih-alih diam-diam meninggalkan CHECK lama.
--
-- `status` **tidak** ditambah `DORMANT` di sini: nilainya ditetapkan bersama aturan deteksi dormant
-- (T-138e), dan domain `parseAccountStatus` belum mengenalinya. Menambah nilai yang belum bisa
-- dibaca kode berarti membuat baris yang membuat pembacaan rekening gagal.
--
-- **Tanpa backfill**: rekening lama dibiarkan `NULL` pada ketiga kolom. `last_activity` baru terisi
-- oleh transaksi setelah kode T-138e berjalan; mengisinya dari riwayat transaksi di migrasi berarti
-- menebak arti "aktivitas" (tunai saja? PB masuk juga?) sebelum aturannya diputuskan.
--
-- Urutan berkas: seq `64` > semua migrasi `deposit` lain; tidak bergantung pada modul mana pun.

ALTER TABLE deposit.account
  ADD COLUMN maturity_date   date,
  ADD COLUMN aro_instruction text,
  ADD COLUMN last_activity   date;

ALTER TABLE deposit.account
  DROP CONSTRAINT account_account_type_check,
  ADD CONSTRAINT deposit_account_type_chk
    CHECK (account_type IN ('SAVINGS', 'TIME_DEPOSIT')),
  ADD CONSTRAINT deposit_account_aro_instruction_chk CHECK (
    aro_instruction IS NULL
    OR aro_instruction IN ('NONE', 'PRINCIPAL', 'PRINCIPAL_AND_INTEREST'));

COMMENT ON COLUMN deposit.account.maturity_date IS
  'Tanggal jatuh tempo deposito berjangka; NULL untuk rekening tabungan (D-152).';
COMMENT ON COLUMN deposit.account.aro_instruction IS
  'Instruksi automatic roll-over saat jatuh tempo: NONE/PRINCIPAL/PRINCIPAL_AND_INTEREST; '
  'NULL = belum diatur (D-152).';
COMMENT ON COLUMN deposit.account.last_activity IS
  'Tanggal aktivitas terakhir (transaksi tunai/PB); dasar deteksi dormant T-138e (D-152). '
  'NULL = belum ada aktivitas.';
COMMENT ON COLUMN deposit.account.status IS
  'Status rekening: ACTIVE/CLOSED. Nilai DORMANT menyusul bersama aturan deteksi dormant (T-138e).';
