-- Pemindahbukuan (PB) antar rekening simpanan (T-088c, spec §9.2/§9.3). Expand-only: hanya CREATE.
--
-- **Tabel baru, bukan kolom di `deposit.transaction`.** CHECK `tx_type` di `deposit/0004` hanya
-- menerima `CASH_DEPOSIT`/`CASH_WITHDRAWAL`; menambahkan `TRANSFER` ke sana berarti
-- `ALTER TABLE ... DROP CONSTRAINT` yang **destruktif** (butuh penanda `-- dbtools:destructive`)
-- dan ditolak aturan expand-only. Tabel terpisah juga memisahkan bentuk: transaksi tunai = satu
-- rekening + arah, PB = dua rekening (sumber & tujuan) dalam satu perpindahan.
--
-- **Nomor berkas `0007`**: tabel ini mem-FK `deposit.account` (dibuat `deposit/0003`) dan
-- `ledger.journal` (dibuat `ledger/0003`). Pada seq yang sama modul `deposit` berjalan **sebelum**
-- `ledger`, jadi FK ke jurnal wajib seq > 3 — sama alasannya dengan `deposit/0004`. Diverifikasi
-- `./task dbtools validate` + migrasi dari skema kosong lewat `ittransfer`.
--
-- Tanpa kolom `currency`: asumsi satu mata uang (spec §2.2; T-088 §8 butir 6).
--
-- Setiap baris PB menunjuk tepat satu jurnal (`journal_id UNIQUE`); jurnal diposting **sinkron** di
-- transaksi DB yang sama dengan mutasi kedua saldo (bukan lewat outbox), jadi baris ini tidak
-- pernah ada tanpa jurnal — dan sebaliknya (FK + satu `withDbTx`).

CREATE TABLE deposit.transfer (
  transfer_id            uuid PRIMARY KEY,
  source_account_id      uuid NOT NULL REFERENCES deposit.account(account_id),
  destination_account_id uuid NOT NULL REFERENCES deposit.account(account_id),
  amount                 numeric(24,4) NOT NULL CHECK (amount > 0),
  business_date          date NOT NULL,
  narration              text CHECK (narration IS NULL OR length(narration) <= 200),
  journal_id             uuid NOT NULL REFERENCES ledger.journal(journal_id),
  created_at             timestamptz NOT NULL DEFAULT now(),
  created_by             uuid NOT NULL,
  CONSTRAINT deposit_transfer_journal_uq UNIQUE (journal_id),
  CONSTRAINT deposit_transfer_accounts_differ_chk CHECK (source_account_id <> destination_account_id)
);

COMMENT ON TABLE deposit.transfer IS
  'Pemindahbukuan antar rekening simpanan (T-088c): sumber & tujuan berbeda, satu jurnal per baris '
  '(sinkron, bukan outbox). Nominal numeric(24,4) > 0; tanpa float. Koreksi = jurnal pembalik, '
  'bukan ubah/hapus baris.';

CREATE INDEX deposit_transfer_source_idx
  ON deposit.transfer (source_account_id, business_date DESC);

CREATE INDEX deposit_transfer_destination_idx
  ON deposit.transfer (destination_account_id, business_date DESC);

-- Baris PB **immutable** (sama alasannya dengan `deposit/0005`): koreksi PB = jurnal pembalik +
-- baris baru, bukan UPDATE/DELETE; tanpa trigger, jejak teller bisa dihapus sehingga jurnal menjadi
-- yatim (`source_ref` tanpa baris). Memakai fungsi `ledger.reject_mutation()` yang sudah ada sejak
-- `ledger/0003`.
CREATE TRIGGER deposit_transfer_immutable
  BEFORE UPDATE OR DELETE ON deposit.transfer
  FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();

CREATE TRIGGER deposit_transfer_no_truncate
  BEFORE TRUNCATE ON deposit.transfer
  FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
