-- Presisi uang 2 desimal untuk kas teller (D-136). Expand-only: ALTER tipe kolom + komentar.
--
-- Pemeriksaan "berhenti, bukan membulatkan diam-diam" sama alasannya dengan `deposit/0038`.
-- `teller.cash_movement` immutable (trigger `ledger.reject_mutation`), jadi nilai di bawah 0,01
-- tidak boleh hilang tanpa keputusan manusia. `teller_session` adalah baris penutup yang dipakai
-- untuk rekonsiliasi kas, jadi selisih sub-sen di sana juga harus terlihat, bukan dibulatkan.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM teller.vault WHERE balance <> round(balance, 2)) THEN
    RAISE EXCEPTION 'teller.vault.balance punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
  IF EXISTS (SELECT 1 FROM teller.cash_movement WHERE amount <> round(amount, 2)) THEN
    RAISE EXCEPTION 'teller.cash_movement.amount punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
  IF EXISTS (SELECT 1 FROM teller.teller_session
              WHERE opening_float <> round(opening_float, 2)
                 OR coalesce(expected_cash, 0) <> round(coalesce(expected_cash, 0), 2)
                 OR coalesce(counted_cash, 0) <> round(coalesce(counted_cash, 0), 2)
                 OR coalesce(variance, 0) <> round(coalesce(variance, 0), 2)) THEN
    RAISE EXCEPTION 'teller.teller_session punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
  IF EXISTS (SELECT 1 FROM teller.vault_topup_request WHERE amount <> round(amount, 2)) THEN
    RAISE EXCEPTION 'teller.vault_topup_request.amount punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
END;
$$;

ALTER TABLE teller.vault
  ALTER COLUMN balance TYPE numeric(24,2) USING round(balance, 2);
ALTER TABLE teller.cash_movement
  ALTER COLUMN amount TYPE numeric(24,2) USING round(amount, 2);
ALTER TABLE teller.teller_session
  ALTER COLUMN opening_float TYPE numeric(24,2) USING round(opening_float, 2),
  ALTER COLUMN expected_cash TYPE numeric(24,2) USING round(expected_cash, 2),
  ALTER COLUMN counted_cash TYPE numeric(24,2) USING round(counted_cash, 2),
  ALTER COLUMN variance TYPE numeric(24,2) USING round(variance, 2);
ALTER TABLE teller.vault_topup_request
  ALTER COLUMN amount TYPE numeric(24,2) USING round(amount, 2);

COMMENT ON TABLE teller.vault IS
  'Saldo kas fisik satu vault per cabang (T-093). Bertambah saat sesi ditutup (counted cash) dan '
  'berkurang saat sesi dibuka (opening float). CHECK balance >= 0 = backstop DB; operasi yang '
  'menolak saldo kurang ada di jalur tulis. Angka numeric(24,2), tanpa float.';
