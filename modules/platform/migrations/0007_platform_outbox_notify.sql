-- 0007: NOTIFY saat event masuk outbox (spec §12.4, §19.1).
--
-- Mengapa trigger di INSERT (bukan NOTIFY dari dispatcher):
--   * UI perlu tahu peristiwa begitu peristiwa itu **durable** di outbox. Kalau NOTIFY digantungkan
--     pada dispatcher, layar akan "diam" saat dispatcher tertunda/pause — dan di Fase 0 role worker
--     belum ada (O-013), sehingga jalur UI akan bergantung pada komponen yang belum lahir.
--   * Dispatcher tetap punya tanggung jawabnya sendiri: subscriber in-proc + status
--     PENDING→DONE/DEAD (spec §12.4). Kanal NOTIFY ini bukan pengganti pipeline delivery.
--
-- Payload hanya `outbox_id`: NOTIFY adalah sinyal "ada yang baru", bukan pengangkut data. Isi
-- event dibaca dari tabel oleh pendengar (sehingga tidak ada batas 8000 byte dan tidak ada
-- duplikasi kebenaran).
--
-- Expand-only: hanya menambah fungsi + trigger. Nama kanal `cbs_outbox` dipakai bersama
-- `modules/platform/infrastructure/outbox_listener.nim`.

CREATE OR REPLACE FUNCTION platform.notify_outbox_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_notify('cbs_outbox', NEW.outbox_id::text);
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION platform.notify_outbox_insert() IS
  'Sinyal outbox baru ke kanal cbs_outbox (payload = outbox_id). Lihat migration 0007.';

CREATE TRIGGER outbox_notify_insert
AFTER INSERT ON platform.outbox
FOR EACH ROW
EXECUTE FUNCTION platform.notify_outbox_insert();
