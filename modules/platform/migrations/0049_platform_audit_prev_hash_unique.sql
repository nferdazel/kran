-- Rantai audit tidak boleh bercabang (T-133/DB-8). Expand-only: hanya CREATE INDEX.
--
-- `platform.audit_log_chain` menyambung tiap baris ke hash baris terakhir di bawah advisory lock,
-- sehingga rantai selalu linear. Tanpa index unik, **percabangan** hanya ketahuan saat verifikasi
-- manual: dua baris bisa menunjuk `prev_hash` yang sama dan verifikasi rantai tetap "lulus" untuk
-- masing-masing cabang.
--
-- Dengan index ini, percabangan ditolak basis data saat INSERT: baris kedua yang menyambung ke
-- `prev_hash` yang sama melanggar keunikan. Genesis (`repeat('0', 64)`, migrasi 0002) juga hanya
-- boleh muncul sekali, jadi "dua rantai dalam satu tabel" tidak mungkin tanpa terlihat.
--
-- Tidak ada risiko blokir append normal: trigger mengambil `pg_advisory_xact_lock` sebelum membaca
-- baris terakhir, jadi penulisan bersamaan diserialkan dan `prev_hash` selalu berbeda.
--
-- Idempoten: `IF NOT EXISTS`. Bila tabel sudah bercabang, pembuatan index **gagal** — itu memang
-- tujuannya (deploy berhenti di migration gate daripada meneruskan data yang rantainya rusak).
-- Kedua basis data yang ada (produksi & dev) diperiksa 25 Okt 2026: 0 percabangan.

CREATE UNIQUE INDEX IF NOT EXISTS audit_log_prev_hash_unique_idx
  ON platform.audit_log (prev_hash);
