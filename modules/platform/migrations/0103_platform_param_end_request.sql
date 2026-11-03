-- Pengakhiran nilai parameter secara sengaja (O-064).
--
-- **Konteks.** D-056 butir 5 (O-043) mewajibkan `effective_to` punya penerus, sehingga nilai yang
-- memang harus berhenti tanpa pengganti — produk dihentikan, tarif dicabut — tidak punya jalur
-- resmi; satu-satunya jalan adalah SQL langsung, yang melewati audit, izin, dan penyetuju kedua.
--
-- **Bentuk.** Maker-checker seperti `teller.vault_topup_request` (T-118): pengajuan `PENDING`,
-- keputusan oleh akun **lain** (`param_end_request_self_approval_chk`), dan persetujuan menulis
-- `platform.param_value.effective_to` dalam transaksi yang sama dengan audit + event.
--
-- **Invarian O-043 tidak dilonggarkan.** Pengajuan nilai baru ber-`effective_to` tetap wajib punya
-- penerus (`effectiveToGapProblem`). Pengakhiran adalah operasi **terpisah** yang tujuannya memang
-- celah nilai, dan yang membuatnya aman adalah bukti dua orang + alasan + audit, bukan kelonggaran
-- pemeriksaan periode.
--
-- **Izin** memakai katalog yang sudah ada (`platform.param.submit` untuk pengaju,
-- `platform.param.approve` untuk pemutus), bukan izin baru: mengakhiri nilai adalah keputusan
-- tingkat penyetuju, bukan wewenang tambahan.
--
-- Idempoten: `CREATE TABLE/INDEX IF NOT EXISTS`.

CREATE TABLE IF NOT EXISTS platform.param_end_request (
  request_id     uuid PRIMARY KEY,
  param_value_id uuid NOT NULL REFERENCES platform.param_value(param_value_id),
  effective_to   date NOT NULL,
  status         text NOT NULL DEFAULT 'PENDING'
                 CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  requested_by   uuid NOT NULL,
  reason         text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  decided_by     uuid,
  decided_at     timestamptz,
  decision_note  text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT param_end_request_decision_chk CHECK (
    (status = 'PENDING' AND decided_by IS NULL AND decided_at IS NULL)
    OR (status IN ('APPROVED', 'REJECTED') AND decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CONSTRAINT param_end_request_self_approval_chk CHECK (
    decided_by IS NULL OR decided_by <> requested_by)
);

COMMENT ON TABLE platform.param_end_request IS
  'Pengajuan pengakhiran nilai parameter (O-064): PENDING → APPROVED/REJECTED oleh akun lain; '
  'persetujuan memangkas platform.param_value.effective_to tanpa menuntut nilai penerus.';

-- Satu pengajuan berjalan per nilai: dua pengajuan PENDING untuk baris yang sama hanya
-- membingungkan pemutus (mana tanggal yang disetujui?) tanpa menambah kemampuan apa pun.
CREATE UNIQUE INDEX IF NOT EXISTS param_end_request_pending_uq
  ON platform.param_end_request (param_value_id)
  WHERE status = 'PENDING';

CREATE INDEX IF NOT EXISTS param_end_request_status_idx
  ON platform.param_end_request (status, created_at DESC);

-- Hak role runtime untuk tabel baru ini (pola `lending/0102`, `deposit/0070`): `GRANT ... ON ALL
-- TABLES` hanya mencakup tabel yang ada saat migrasi grant berjalan, jadi setiap tabel baru butuh
-- grant sendiri — kalau tidak, produksi mendapat "permission denied" sementara seluruh test hijau
-- karena test berjalan sebagai role migrator (O-126).
--
-- Verba yang diberikan hanya yang dipakai kode: INSERT saat pengajuan, UPDATE saat keputusan,
-- SELECT saat daftar. Tidak ada DELETE: catatan keputusan adalah jejak audit, bukan data yang
-- boleh dihapus. No-op bila role belum ada (dev/CI).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT SELECT, INSERT, UPDATE ON platform.param_end_request TO kran_runtime;
  END IF;
END
$$;
