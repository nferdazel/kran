-- dbtools:destructive melonggarkan CHECK periode (tidak menghapus data) dan melepas NOT NULL updated_by
-- dbtools:contract DDL merusak (DROP CONSTRAINT) untuk penutupan periode oleh proses sistem; dijalankan lewat `--contract` setelah expand bersih
-- Penutupan periode oleh kerangka day-close (T-137) tidak punya pengguna: `ctl` berjalan tanpa
-- sesi, dan mencatat id pengguna palsu berarti mengarang pelaku. Jejak yang bisa dipertanggung-
-- jawabkan ada di audit (`device = kran-api ctl`, `reason`), bukan di kolom ini.
--
-- Perubahan bersifat melonggarkan (tidak menulis ulang data):
--   * `updated_by` NOT NULL dilepas; `closed_by` memang sudah nullable sejak `0001`.
--   * CHECK `period_closed_chk` tidak lagi mewajibkan `closed_by`/`updated_by` terisi saat CLOSED.
--     `closed_at` tetap wajib saat CLOSED — waktu tutup adalah bukti, pelaku sistem bukan.
--
-- Aman dijalankan sebelum biner baru menerima trafik: biner lama tetap menulis `closed_by` dan
-- `updated_by` berisi pengguna, yang memenuhi kedua cabang CHECK.

ALTER TABLE ledger.period DROP CONSTRAINT period_closed_chk;

ALTER TABLE ledger.period ALTER COLUMN updated_by DROP NOT NULL;

ALTER TABLE ledger.period ADD CONSTRAINT period_closed_chk CHECK (
  (status = 'CLOSED' AND closed_at IS NOT NULL)
  OR (status = 'OPEN' AND closed_at IS NULL AND closed_by IS NULL));

COMMENT ON COLUMN ledger.period.closed_by IS
  'NULL = ditutup proses sistem (day-close); pelakunya tercatat di audit, bukan sebagai id pengguna palsu.';
COMMENT ON COLUMN ledger.period.updated_by IS
  'NULL = perubahan terakhir oleh proses sistem (day-close); pelakunya tercatat di audit.';
