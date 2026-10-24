-- Master cabang (O-101 tindak lanjut, D-135): setiap cabang punya **kode 3 digit** yang dipakai
-- sebagai prefiks nomor rekening, supaya nomor rekening langsung memperlihatkan cabang pembukanya.
--
-- Sampai sekarang `branch_id` hanya UUID yang tidak punya nama/kode manusiawi (O-101); ledger,
-- party, vault, dan sesi teller menyimpan UUID itu apa adanya. Tabel ini memberi satu tempat untuk
-- kode + nama, tanpa memaksa FK retrofit ke semua modul (expand-only; modul lain tetap menyimpan
-- `branch_id`). Penggunaan pertama: `formatAccountNo` (deposit) dan `GET /api/v1/deposit/accounts`
-- yang membuka rekening hanya bila cabangnya terdaftar.
--
-- Data pilot: produksi sudah memakai `b0000000-0000-4000-8000-000000000001` (D-129) tanpa nama.
-- Migrasi ini mendaftarkannya sebagai kode `001` / `Cabang Pilot`. Di dev/CI baris ini tidak
-- mengganggu (UUID tetap, `ON CONFLICT DO NOTHING`).
--
-- Ubah kode cabang = **tidak boleh** mengubah arti nomor rekening yang sudah terbit (nomor adalah
-- identitas bisnis). Karena itu `code` sengaja tidak punya jalur UPDATE di aplikasi; perbaikan kode
-- hanya lewat migrasi + analisis data (lihat O-104).

CREATE TABLE IF NOT EXISTS platform.branch (
  branch_id  uuid PRIMARY KEY,
  code       text NOT NULL,
  name       text NOT NULL,
  status     text NOT NULL DEFAULT 'ACTIVE',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT platform_branch_code_fmt CHECK (code ~ '^[0-9]{3}$'),
  CONSTRAINT platform_branch_name_not_blank CHECK (length(btrim(name)) > 0),
  CONSTRAINT platform_branch_status_ck CHECK (status IN ('ACTIVE', 'INACTIVE')),
  CONSTRAINT platform_branch_code_uq UNIQUE (code)
);

COMMENT ON TABLE platform.branch IS
  'Master cabang (D-135): kode 3 digit = prefiks nomor rekening. Modul lain tetap menyimpan '
  'branch_id tanpa FK (expand-only).';
COMMENT ON COLUMN platform.branch.code IS
  'Kode cabang 3 digit; dipakai sebagai prefiks nomor rekening. Mengubahnya mengubah identitas '
  'nomor yang sudah terbit, jadi hanya lewat migrasi + analisis data.';

INSERT INTO platform.branch (branch_id, code, name)
VALUES ('b0000000-0000-4000-8000-000000000001', '001', 'Cabang Pilot')
ON CONFLICT DO NOTHING;

-- Hak akses role runtime (pola `deposit/0006`): baca untuk pembukaan rekening, tulis untuk
-- `ctl create-branch`. No-op bila role belum ada (dev/CI).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT SELECT, INSERT, UPDATE ON platform.branch TO kran_runtime;
  END IF;
END
$$;
