-- Riwayat kata sandi (O-052, D-046 butir 8): menyimpan hash kata sandi yang **sudah digantikan**
-- supaya kata sandi baru tidak boleh memakai ulang N yang terakhir.
--
-- **HUMAN-REVIEW-REQUIRED**: tabel ini menyimpan bahan kredensial (hash kata sandi) — area kriptografi
-- (AGENTS.md §8). Lihat D-058.
--
-- Yang disimpan hanya hash, tidak pernah kata sandi mentah (invarian MODULE.md #12). Riwayat
-- **tidak** menyimpan hash yang sedang berlaku: itu tetap di `app_user.password_hash`, jadi satu
-- kata sandi tidak pernah punya dua tempat.
--
-- Tidak ada kolom kedaluwarsa dan tidak ada tugas yang menghapus berdasarkan umur: D-046 butir 8
-- memutuskan kata sandi tidak kedaluwarsa, jadi umur tidak pernah jadi alasan menolak.

CREATE TABLE platform.user_password_history (
  seq           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES platform.app_user(user_id) ON DELETE CASCADE,
  password_hash text NOT NULL,
  recorded_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE platform.user_password_history IS
  'Hash kata sandi yang sudah digantikan, urut `seq` (terbaru terbesar). Dipangkas ke N terakhir; N dari parameter platform.security.password_history_count.';

-- Urutan `seq` yang dipakai pemangkasan & pembacaan riwayat.
CREATE INDEX user_password_history_user_idx ON platform.user_password_history (user_id, seq DESC);
