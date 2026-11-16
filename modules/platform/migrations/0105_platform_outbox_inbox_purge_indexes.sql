-- 0105: dasar purge retensi `platform.outbox` + `platform.inbox` (T-282, D-206, spec §5.6).
--
-- Keputusan D-206: outbox dan inbox dipangkas 30 hari. Untuk outbox jamnya dihitung dari saat
-- baris mencapai `DONE`/`DEAD`, **bukan** dari `occurred_at`. Bedanya bukan gaya: baris yang
-- lahir lama tapi baru mati kemarin masih bukti pengiriman dan masih bisa di-*re-drive*
-- operator, dan memakai `occurred_at` akan memangkasnya lebih awal dari 30 hari. Kolom penanda
-- itu belum ada di skema, jadi migrasi ini yang menambahkannya.
--
-- `completed_at` nullable tanpa default: expand-only, tidak menulis ulang tabel. Dispatcher
-- mengisinya sejak `markDone`/`markFailed` (T-282). Baris yang sudah selesai sebelum migrasi ini
-- tidak punya jejak waktu transisi, jadi jamnya dimulai saat migrasi berjalan — arah yang aman,
-- tidak pernah memangkas lebih awal dari seharusnya.
--
-- Dua index sengaja dibuat sekarang, sebelum purge-nya ada: purge tanpa index memindai seluruh
-- tabel, dan `outbox_dispatch_idx` `(status, available_at, seq)` tidak membantu karena tidak
-- memuat kolom waktu selesai. Index outbox parsial supaya baris `PENDING`/`IN_FLIGHT` yang
-- mayoritas tidak ikut membesarkannya.
--
-- `CONCURRENTLY` sengaja tidak dipakai: migrasi berjalan di dalam satu transaksi (runner), dan
-- `CREATE INDEX CONCURRENTLY` tidak boleh di dalam blok transaksi. Ukuran tabel pilot masih
-- kecil; bila kelak besar, index dibuat manual di luar runner.
--
-- Biaya kunci yang perlu diketahui operator: `UPDATE` backfill di bawah menulis **setiap** baris
-- `DONE`/`DEAD` yang belum punya `completed_at`, dalam satu transaksi. Ia memegang `ROW EXCLUSIVE`
-- pada `platform.outbox` sampai migrasi commit, sehingga dispatcher yang menandai baris selesai
-- (`markDone`/`markFailed`) menunggu, dan `CREATE INDEX` sesudahnya ikut memindai tabel penuh.
-- Pada pilot ini hitungannya detik; pada tabel besar, jalankan migrasi di jendela sepi. Backfill
-- tidak bisa dipecah per batch di sini karena runner menjalankan satu berkas sebagai satu
-- transaksi — memecahnya butuh migrasi terpisah dengan loop di luar runner.
--
-- Idempoten: `IF NOT EXISTS` di semua objek, dan backfill hanya menyentuh baris yang
-- `completed_at`-nya masih NULL.

ALTER TABLE platform.outbox
  ADD COLUMN IF NOT EXISTS completed_at timestamptz;

COMMENT ON COLUMN platform.outbox.completed_at IS
  'Waktu baris mencapai DONE/DEAD; dasar purge retensi 30 hari (D-206). NULL hanya untuk baris yang selesai sebelum migrasi 0105.';

UPDATE platform.outbox
   SET completed_at = now()
 WHERE status IN ('DONE', 'DEAD')
   AND completed_at IS NULL;

CREATE INDEX IF NOT EXISTS outbox_purge_idx
  ON platform.outbox (completed_at)
  WHERE status IN ('DONE', 'DEAD');

CREATE INDEX IF NOT EXISTS inbox_received_at_idx
  ON platform.inbox (received_at);
