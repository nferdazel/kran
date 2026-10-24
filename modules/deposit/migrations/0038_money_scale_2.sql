-- Presisi uang 2 desimal untuk kolom simpanan (D-136). Expand-only: hanya ALTER tipe kolom.
--
-- **Kenapa berhenti, bukan membulatkan diam-diam.** `USING round(x, 2)` akan membuang nilai di
-- bawah 0,01 tanpa jejak. Untuk baris simpanan itu berarti saldo dan mutasi tidak lagi cocok
-- dengan yang tercatat di buku besar, dan buku besar sendiri immutable — tidak ada cara
-- "membatalkannya" setelah migrasi. Jadi tiap tabel diperiksa dulu: bila ada nilai yang tidak
-- sama dengan pembulatan 2 desimal, migrasi gagal dengan pesan yang menyebut tabelnya, dan
-- keputusan ada di manusia (D-136).
--
-- `CHECK (amount > 0)` / `CHECK (balance >= 0)` tidak berubah: perbandingan tetap sah pada skala
-- baru, dan 0,01 adalah unit terkecil yang masih bisa disimpan.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM deposit.transaction WHERE amount <> round(amount, 2)) THEN
    RAISE EXCEPTION 'deposit.transaction.amount punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
  IF EXISTS (SELECT 1 FROM deposit.transfer WHERE amount <> round(amount, 2)) THEN
    RAISE EXCEPTION 'deposit.transfer.amount punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
  IF EXISTS (SELECT 1 FROM deposit.account_balance WHERE balance <> round(balance, 2)) THEN
    RAISE EXCEPTION 'deposit.account_balance.balance punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
END;
$$;

ALTER TABLE deposit.transaction
  ALTER COLUMN amount TYPE numeric(24,2) USING round(amount, 2);
ALTER TABLE deposit.transfer
  ALTER COLUMN amount TYPE numeric(24,2) USING round(amount, 2);
ALTER TABLE deposit.account_balance
  ALTER COLUMN balance TYPE numeric(24,2) USING round(balance, 2);

COMMENT ON TABLE deposit.transaction IS
  'Transaksi tunai simpanan (T-088b): setor/tarik, satu jurnal per baris (sinkron, bukan outbox). '
  'Nominal numeric(24,2) > 0; tanpa float. Koreksi = jurnal pembalik, bukan ubah/hapus baris.';

COMMENT ON TABLE deposit.transfer IS
  'Pemindahbukuan antar rekening simpanan (T-088c): sumber & tujuan berbeda, satu jurnal per baris '
  '(sinkron, bukan outbox). Nominal numeric(24,2) > 0; tanpa float. Koreksi = jurnal pembalik, '
  'bukan ubah/hapus baris.';

COMMENT ON TABLE deposit.account_balance IS
  'Cache saldo satu baris per rekening (T-088a). CHECK balance >= 0 = backstop DB; operasi yang '
  'menolak saldo negatif ada di jalur tulis (T-088b). Angka disimpan numeric(24,2), tanpa float.';
