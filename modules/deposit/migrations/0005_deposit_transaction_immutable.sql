-- Baris transaksi teller **immutable** (T-088b, review m7). Koreksi transaksi tunai = jurnal
-- pembalik + baris transaksi baru, bukan UPDATE/DELETE; tanpa trigger, jejak teller bisa dihapus
-- sehingga jurnal menjadi yatim (`source_ref` tanpa baris).
--
-- Memakai fungsi yang sama dengan ledger: `ledger.reject_mutation()` sudah ada sejak
-- `ledger/0003` (seq 3) dan menolak UPDATE/DELETE/TRUNCATE dengan pesan yang jelas.
-- Expand-only: hanya CREATE TRIGGER.
CREATE TRIGGER deposit_transaction_immutable
  BEFORE UPDATE OR DELETE ON deposit.transaction
  FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();

CREATE TRIGGER deposit_transaction_no_truncate
  BEFORE TRUNCATE ON deposit.transaction
  FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
