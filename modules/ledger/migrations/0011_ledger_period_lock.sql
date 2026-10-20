-- O-089 / T-080: tutup periode vs posting jurnal tidak boleh balapan.
--
-- Trigger lama hanya MEMBACA status periode (MVCC). Bila sesi A menutup periode tetapi belum
-- COMMIT, sesi B melihat versi lama `OPEN` dan insert jurnal berhasil; setelah A commit, jurnal
-- itu berada di periode CLOSED. `FOR SHARE` membuat B menunggu lock baris yang dipegang UPDATE A,
-- lalu mengevaluasi versi SETELAH commit (CLOSED) dan menolak insert.
--
-- Arah sebaliknya aman dan diinginkan: bila jurnal memegang lock lebih dulu, penutupan periode
-- menunggu sampai jurnal commit, sehingga jurnal yang sudah berjalan tetap tercatat pada periode
-- OPEN. Lock dilepas saat transaksi jurnal selesai; biayanya satu lock baris per jurnal.
--
-- Expand-only: hanya CREATE OR REPLACE FUNCTION, tanpa perubahan tabel.

CREATE OR REPLACE FUNCTION ledger.assert_journal_period_open() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM ledger.period p
       WHERE p.status = 'OPEN'
         AND NEW.business_date BETWEEN p.starts_on AND p.ends_on
       FOR SHARE) THEN
    RAISE EXCEPTION 'ledger: tidak ada periode OPEN untuk tanggal %', NEW.business_date
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION ledger.assert_journal_period_open() IS
  'Jurnal hanya pada periode OPEN; FOR SHARE menutup balapan dengan penutupan periode (O-089).';
