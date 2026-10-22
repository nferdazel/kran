-- Transaksi tunai simpanan (T-088b, spec §9.2/§9.3). Expand-only: hanya CREATE.
--
-- **Nomor berkas `0004` (bukan `0003`).** Urutan migrasi global adalah `(seq, nama modul, nama
-- berkas)` (`tools/dbtools/lib.nim:migrationsOf`); pada seq yang sama modul `deposit` berjalan
-- **sebelum** `ledger`. Tabel ini mem-FK `ledger.journal`, yang baru dibuat `ledger/0003` pada seq 3.
-- Karena `deposit/0003` berjalan **sebelum** `ledger/0003`, FK ke jurnal wajib menunggu seq berikutnya
-- (`0004`). Diverifikasi lewat `ittransaction` yang menjalankan migrasi dari skema kosong.
--
-- Cakupan T-088b hanya tunai setor/tarik. Pemindahbukuan (PB, `TRANSFER`) = T-088c dengan migrasi
-- tersendiri: kolom `counter_account_id` **belum** dibuat di sini (jangan mengarang semantik tanpa
-- pemakai, D-095).
--
-- Setiap baris transaksi menunjuk tepat satu jurnal (`journal_id UNIQUE`). Posting jurnal dilakukan
-- **sinkron** di transaksi DB yang sama dengan mutasi saldo (bukan lewat outbox), jadi baris ini
-- tidak pernah ada tanpa jurnal — dan sebaliknya (FK + satu `withDbTx`).

CREATE TABLE deposit.transaction (
  transaction_id uuid PRIMARY KEY,
  tx_type        text NOT NULL CHECK (tx_type IN ('CASH_DEPOSIT', 'CASH_WITHDRAWAL')),
  account_id     uuid NOT NULL REFERENCES deposit.account(account_id),
  amount         numeric(24,4) NOT NULL CHECK (amount > 0),
  business_date  date NOT NULL,
  narration      text CHECK (narration IS NULL OR length(narration) <= 200),
  journal_id     uuid NOT NULL REFERENCES ledger.journal(journal_id),
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL,
  CONSTRAINT deposit_transaction_journal_uq UNIQUE (journal_id)
);

COMMENT ON TABLE deposit.transaction IS
  'Transaksi tunai simpanan (T-088b): setor/tarik, satu jurnal per baris (sinkron, bukan outbox). '
  'Nominal numeric(24,4) > 0; tanpa float. Koreksi = jurnal pembalik, bukan ubah/hapus baris.';

CREATE INDEX deposit_transaction_account_idx
  ON deposit.transaction (account_id, business_date DESC);
