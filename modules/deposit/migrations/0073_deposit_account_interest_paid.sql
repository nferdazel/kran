-- Baseline akrual per siklus ARO (T-145, D-165).
--
-- dbtools:expand-only — satu kolom dengan DEFAULT, tanpa backfill dan tanpa DROP. Rekening lama
-- mendapat 0, artinya "belum ada bunga yang dibayar", yang memang benar untuk siklus pertama.
--
-- Kenapa kolom, bukan penanda di `deposit.interest_accrual`: `cumulative` di tabel akrual dihitung
-- dari `opened_on` dan barisnya immutable (D-152). Menandai baris terakhir sebagai "sudah dibayar"
-- berarti membedakan dua keadaan dalam satu kolom yang sama; kolom terpisah membuat baseline bisa
-- dibaca tanpa menafsirkan riwayat.
--
-- Nilai ini **bukan** saldo dan **bukan** akrual berjalan: ia hanya jumlah kumulatif yang sudah
-- dibayakan (ke rekening simpanan atau dikapitalisasi ke pokok). Task jatuh tempo membayar
-- `cumulative terakhir − interest_paid_cumulative`, lalu menaikkan kolom ini ke `cumulative`.

ALTER TABLE deposit.account
  ADD COLUMN interest_paid_cumulative numeric(24,2) NOT NULL DEFAULT 0,
  ADD CONSTRAINT deposit_account_interest_paid_nonneg_chk
    CHECK (interest_paid_cumulative >= 0);

COMMENT ON COLUMN deposit.account.interest_paid_cumulative IS
  'Bunga kumulatif yang sudah dibayar/dikapitalisasi (baseline siklus ARO, D-165). Task membayar '
  'selisihnya terhadap `deposit.interest_accrual.cumulative` terakhir. 0 = belum pernah dibayar.';
