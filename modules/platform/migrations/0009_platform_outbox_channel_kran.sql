-- 0009: kanal NOTIFY outbox berganti nama `cbs_outbox` -> `kran_outbox` (bagian dari rename
-- identifier teknis; lihat docs/DECISIONS.md D-039).
--
-- Mengapa migrasi baru, bukan menyunting 0007: 0007 **sudah diterapkan** di DB dev, dan `dbtools`
-- memverifikasi checksum berkas migrasi yang sudah diterapkan ("isi migrasi berubah" = kode keluar 1).
-- Mengubahnya akan merusak verifikasi migrasi. Jadi fungsi diganti di sini, cara yang sama
-- (CREATE OR REPLACE FUNCTION) seperti 0007 sendiri.
--
-- Non-destruktif: tidak ada DROP/TRUNCATE/RENAME; trigger lama tetap dipakai karena ia memanggil
-- fungsi ini berdasarkan nama, bukan berdasarkan isi.
--
-- Catatan urutan (jujur, ini jendela nyata): trigger menulis ke kanal baru segera setelah migrasi
-- diterapkan, sedangkan proses yang masih berjalan masih mendengarkan kanal lama sampai di-restart.
-- Pada `ops/scripts/deploy-vps.sh` urutannya migrasi lalu restart, jadi ada jendela kecil di mana
-- UI realtime belum menerima sinyal (isi outbox tetap ada; klien menyambung ulang seperti pada
-- T-029). Aman di Fase 0 karena belum ada proses produksi yang berjalan; kalau nanti ada, urutannya
-- harus: naikkan versi yang mendengarkan kanal baru, baru migrasinya.

CREATE OR REPLACE FUNCTION platform.notify_outbox_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_notify('kran_outbox', NEW.outbox_id::text);
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION platform.notify_outbox_insert() IS
  'Sinyal outbox baru ke kanal kran_outbox (payload = outbox_id). Lihat migrasi 0007 + 0009.';
