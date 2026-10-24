-- Periode akuntansi: tutup hanya maju, rentang tidak bisa diubah (T-129/DB-4, spec §9.1(5)).
--
-- **Konteks.** `ledger.period` (0001) sepenuhnya mutable: `CLOSED → OPEN` dan perubahan
-- `starts_on`/`ends_on` tidak diblokir. Satu `UPDATE` manual (atau bug handler di masa depan) bisa
-- membatalkan penutupan periode, lalu posting mundur ke periode yang sudah dilaporkan diizinkan
-- lagi — tanpa audit, karena perubahan itu bukan aksi aplikasi.
--
-- **Aturan yang ditegakkan.**
--   1. Satu-satunya transisi status yang sah: `OPEN → CLOSED`. `CLOSED → OPEN` dan
--      `OPEN → OPEN` (menulis ulang baris yang sudah tertutup) ditolak.
--   2. `starts_on`/`ends_on`/`period_id`/`created_at`/`created_by` tidak boleh berubah. Rentang
--      periode adalah dasar laporan yang sudah dibekukan.
--   3. Mengubah rentang periode yang **sudah punya jurnal** ditolak lebih tegas: jurnal itu
--      bertanggal di dalam rentang lama, dan memindahkan batas akan membuatnya "di luar periode"
--      secara retroaktif.
--
-- Handler tutup periode hanya mengubah `status`, `closed_at`, `closed_by`, `updated_*`, jadi aturan
-- ini tidak mengubah jalur aplikasi (dibuktikan `itapi_ledger`).
--
-- Trigger `BEFORE UPDATE` (bukan `INSTEAD OF`) supaya `RETURNING` pada `closePeriod` tetap bekerja.

CREATE OR REPLACE FUNCTION ledger.period_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'CLOSED' THEN
    RAISE EXCEPTION 'ledger: periode % sudah CLOSED dan tidak bisa diubah', OLD.period_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF NEW.period_id <> OLD.period_id
     OR NEW.created_at <> OLD.created_at
     OR NEW.created_by <> OLD.created_by THEN
    RAISE EXCEPTION 'ledger: identitas periode % tidak boleh berubah', OLD.period_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF NEW.starts_on <> OLD.starts_on OR NEW.ends_on <> OLD.ends_on THEN
    IF EXISTS (
        SELECT 1 FROM ledger.journal j
         WHERE j.business_date BETWEEN OLD.starts_on AND OLD.ends_on) THEN
      RAISE EXCEPTION
        'ledger: rentang periode % tidak boleh diubah — sudah ada jurnal di dalamnya',
        OLD.period_id
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  IF NEW.status <> 'CLOSED' THEN
    RAISE EXCEPTION 'ledger: periode % hanya boleh berubah dari OPEN ke CLOSED (bukan ke %)',
      OLD.period_id, NEW.status
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- Migrasi hanya berjalan sekali (ledger `schema_migration`), jadi trigger tidak perlu di-DROP.
CREATE TRIGGER period_guard
  BEFORE UPDATE ON ledger.period
  FOR EACH ROW EXECUTE FUNCTION ledger.period_guard();

COMMENT ON FUNCTION ledger.period_guard() IS
  'Penutupan periode hanya satu arah: OPEN→CLOSED, tanpa perubahan rentang bila sudah ada jurnal '
  '(T-129/DB-4). Pembatalan penutupan bukan jalur yang didukung; koreksi = jurnal pembalik.';
