-- Denyut worker konsumen (O-081).
--
-- Worker menulis `last_seen_at` secara berkala; `/readyz` membacanya untuk membedakan "worker hidup
-- tetapi tidak ada pekerjaan" dari "worker mati". Tanpa ini worker yang mati tidak terlihat: lag
-- outbox (`pumpLagProbe`) mengukur pump realtime, bukan konsumen posting.
--
-- Tabel teknis: tidak ada nilai bisnis, tidak diaudit (bukan data bisnis), dan boleh dihapus/ diisi
-- ulang kapan saja tanpa memengaruhi jurnal.
CREATE TABLE platform.worker_heartbeat (
  worker_name  text PRIMARY KEY,
  last_seen_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE platform.worker_heartbeat IS
  'Denyut proses worker (O-081). Satu baris per worker terakhir melapor; dibaca /readyz, bukan sumber kebenaran bisnis.';
