-- Rentang uang di DB = rentang `Money` (T-129/DB-5).
--
-- **Konteks.** `Money` adalah int64 minor units (`shared/kernel/money.nim`), jadi nilai terbesar
-- yang bisa diwakili adalah 92.233.720.368.547.758,07. Kolom uang di DB memakai `numeric(24,2)`/
-- `numeric(24,4)`, yang menampung 22 digit — jauh lebih besar. Sebelum ini, satu baris dengan nilai
-- raksasa (impor salah, bug aritmetika SQL) membuat pembacaan `moneyOf` membungkus diam-diam dan
-- saldo tampil negatif tanpa satu pun galat. Parser sudah diperbaiki memakai aritmetika terperiksa
-- (T-129/DB-5, `journal_repo.moneyOf`); CHECK ini adalah lapis kedua di sisi data: nilai di luar
-- rentang tidak bisa masuk sejak awal.
--
-- **Kenapa semua tabel, bukan hanya jurnal.** Aturannya milik kernel (`Money`), bukan milik modul;
-- menaruhnya di satu tabel saja membuat tabel uang berikutnya kembali tanpa penjagaan.
--
-- **Expand-only.** `NOT VALID` lalu `VALIDATE` per kolom: penambahan tidak memindai tabel. Produksi
-- diperiksa 24 Okt 2026: 0 baris di luar rentang pada semua kolom di bawah.
--
-- Idempoten: constraint dilewati bila sudah ada.

DO $$
DECLARE
  money_limit constant numeric := 92233720368547758.07;
  target record;
  constraint_name text;
BEGIN
  FOR target IN
    SELECT * FROM (VALUES
      ('deposit', 'account_balance',       'balance'),
      ('deposit', 'transaction',           'amount'),
      ('deposit', 'transfer',              'amount'),
      ('ledger',  'journal_line',          'debit'),
      ('ledger',  'journal_line',          'credit'),
      ('ledger',  'balance_snapshot',      'debit_total'),
      ('ledger',  'balance_snapshot',      'credit_total'),
      ('teller',  'vault',                 'balance'),
      ('teller',  'teller_session',        'opening_float'),
      ('teller',  'teller_session',        'expected_cash'),
      ('teller',  'teller_session',        'counted_cash'),
      ('teller',  'teller_session',        'variance'),
      ('teller',  'cash_movement',         'amount'),
      ('teller',  'vault_topup_request',   'amount')
    ) AS t(schema_name, table_name, column_name)
  LOOP
    constraint_name := target.table_name || '_' || target.column_name || '_money_range_chk';
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = constraint_name
           AND conrelid = format('%I.%I', target.schema_name, target.table_name)::regclass) THEN
      EXECUTE format(
        'ALTER TABLE %I.%I ADD CONSTRAINT %I CHECK (%I BETWEEN %L::numeric AND %L::numeric) NOT VALID',
        target.schema_name, target.table_name, constraint_name, target.column_name,
        -money_limit, money_limit);
    END IF;
    EXECUTE format('ALTER TABLE %I.%I VALIDATE CONSTRAINT %I',
      target.schema_name, target.table_name, constraint_name);
  END LOOP;
END
$$;
