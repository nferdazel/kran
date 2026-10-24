-- Presisi uang 2 desimal untuk buku besar (D-136). Expand-only: ALTER tipe kolom + ganti fungsi
-- trigger dengan deklarasi bertipe baru.
--
-- Pemeriksaan "berhenti, bukan membulatkan diam-diam" sama alasannya dengan `deposit/0038`:
-- `journal_line` immutable, jadi pembulatan nilai lama tidak bisa dikoreksi belakangan.
--
-- `balance_snapshot` adalah cache turunan (`ledger.rebuild_balance_snapshot`), sehingga barisnya
-- boleh dihitung ulang; setelah ALTER tipenya, snapshot dibangun ulang untuk hari ini supaya nilai
-- cache tidak terlihat "berbeda" dari jurnal yang sudah 2 desimal. Snapshot tanggal lain akan
-- dibangun ulang oleh pemanggilnya seperti biasa.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ledger.journal_line
              WHERE debit <> round(debit, 2) OR credit <> round(credit, 2)) THEN
    RAISE EXCEPTION 'ledger.journal_line punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
  IF EXISTS (SELECT 1 FROM ledger.balance_snapshot
              WHERE debit_total <> round(debit_total, 2)
                 OR credit_total <> round(credit_total, 2)) THEN
    RAISE EXCEPTION 'ledger.balance_snapshot punya nilai di bawah 0,01; putuskan dulu (D-136)'
      USING ERRCODE = 'data_exception';
  END IF;
END;
$$;

ALTER TABLE ledger.journal_line
  ALTER COLUMN debit TYPE numeric(24,2) USING round(debit, 2),
  ALTER COLUMN credit TYPE numeric(24,2) USING round(credit, 2);
ALTER TABLE ledger.balance_snapshot
  ALTER COLUMN debit_total TYPE numeric(24,2) USING round(debit_total, 2),
  ALTER COLUMN credit_total TYPE numeric(24,2) USING round(credit_total, 2);

-- Fungsi pemeriksa keseimbangan menyebut tipe kolomnya sendiri; samakan supaya tipe variabel lokal
-- tidak lebih lebar dari kolomnya (kalau tidak, selisih sub-sen bisa lolos dari pemeriksaan).
CREATE OR REPLACE FUNCTION ledger.assert_journal_header_complete() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  n bigint;
  diff numeric(24,2);
BEGIN
  SELECT count(*), coalesce(sum(l.debit), 0) - coalesce(sum(l.credit), 0)
    INTO n, diff
    FROM ledger.journal_line l
   WHERE l.journal_id = NEW.journal_id;
  IF n < 2 THEN
    RAISE EXCEPTION 'ledger: jurnal % harus punya minimal 2 baris', NEW.journal_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF diff <> 0 THEN
    RAISE EXCEPTION 'ledger: jurnal % tidak seimbang (selisih %)', NEW.journal_id, diff
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  d date;
BEGIN
  FOR d IN SELECT DISTINCT as_of FROM ledger.balance_snapshot LOOP
    PERFORM ledger.rebuild_balance_snapshot(d);
  END LOOP;
END;
$$;
