-- Ujung rantai audit ditentukan oleh rantainya, bukan oleh `seq` terbesar (T-133/DB-8).
--
-- **Bug yang ditutup.** `seq` dialokasikan identity saat INSERT dimulai, sedangkan trigger rantai
-- mengambil advisory lock sesudahnya. Dua penulisan bersamaan karena itu bisa commit dengan urutan
-- `seq` terbalik: A (seq 6) menunggu lock, B (seq 7) menyelesaikan lebih dulu, lalu A merantai ke B.
-- Rantainya linear — B → A — tetapi baris dengan `seq` terbesar (B) **bukan** ujung rantai.
-- Trigger lama memilih `ORDER BY seq DESC LIMIT 1`, jadi append berikutnya merantai ke B: cabang,
-- bukan lanjutan. Tanpa index unik, cabang itu tidak terlihat sampai verifikasi manual; dengan
-- index unik (migrasi 0049), append berikutnya justru **ditolak** dan setiap operasi teraudit gagal
-- 500 — jadi perbaikan ujung rantai adalah syarat, bukan tambahan.
--
-- **Aturan baru.** Ujung rantai = baris yang `hash`-nya tidak dipakai sebagai `prev_hash` baris lain.
-- Pada rantai linear hanya ada satu baris seperti itu. Index unik `audit_log_prev_hash_unique_idx`
-- membuat pemeriksaan `NOT EXISTS` ini murah (lookup index, bukan pemindaian tabel).
--
-- Sisa `seq` tetap dipakai untuk memilih di antara beberapa kandidat (hanya mungkin bila data lama
-- sudah bercabang): append baru menempel ke cabang terbaru, bukan gagal diam-diam.
--
-- Trigger lama didefinisikan di `0002_platform_audit_log.sql`; berkas ini hanya mengganti fungsinya
-- (tidak menyentuh data, tidak menambah kolom). Idempoten: `CREATE OR REPLACE FUNCTION`.

CREATE OR REPLACE FUNCTION platform.audit_log_chain() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE
  prev_hash_value text;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'platform.audit_log hanya menerima INSERT (dapat %)', TG_OP;
  END IF;
  -- Serialkan append: hash harus merantai ke ujung rantai yang benar-benar commit.
  PERFORM pg_advisory_xact_lock(hashtext('platform.audit_log'));
  SELECT a.hash INTO prev_hash_value
  FROM platform.audit_log a
  WHERE NOT EXISTS (
    SELECT 1 FROM platform.audit_log b WHERE b.prev_hash = a.hash
  )
  ORDER BY a.seq DESC
  LIMIT 1;
  IF prev_hash_value IS NULL THEN
    prev_hash_value := repeat('0', 64);
  END IF;
  NEW.prev_hash := prev_hash_value;
  NEW.hash := encode(
    digest(prev_hash_value || '|' || platform.audit_log_payload(NEW), 'sha256'), 'hex');
  RETURN NEW;
END
$fn$;
