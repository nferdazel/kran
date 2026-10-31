-- 0062: alasan task di-skip disimpan di DB (T-139a).
--
-- Orkestrator sudah menuntut alasan pada `skipOutcome` (spec §11.7: skip tanpa alasan tidak bisa
-- diaudit), tetapi alasannya hanya ditulis ke log. Monitor day-close membaca DB, jadi tanpa kolom
-- ini layar operator menampilkan `SKIPPED` tanpa sebab dan jejaknya hilang saat log bergulir.
--
-- Expand-only: satu kolom nullable, tanpa backfill. Baris lama tetap `NULL` (tidak ada alasan
-- tercatat), bukan diisi tebakan.
ALTER TABLE daycloser.task ADD COLUMN reason text;

COMMENT ON COLUMN daycloser.task.reason IS
  'Alasan task SKIPPED (dari skipOutcome). NULL untuk state lain dan untuk baris sebelum 0062.';
