-- Produk pinjaman + versinya (T-161, pola `product`/T-086: versi, maker-checker, versi ACTIVE
-- tidak bisa diubah).
--
-- Atribut bisnis (metode jadwal, tenor, rate, urutan alokasi) ada di **versi**, bukan di produk:
-- mengubah produk yang sudah dipakai pinjaman berarti mengubah kontrak yang sudah disepakati.
-- `annual_rate` disimpan sebagai micro-unit `Rate` (1e6 = 100%), bukan float (AGENTS.md §1.3).
--
-- `allocation_order` disimpan sebagai teks `PRINCIPAL,INTEREST,PENALTY`; validasi bentuknya milik
-- domain (`domain/loan.nim:parseAllocationOrder`) karena urutan yang tidak lengkap berarti uang
-- tanpa tujuan. Nilai awalnya parameter (D-180 butir 4, `lending.allocation_order`).

CREATE TABLE lending.loan_product (
  product_id  uuid PRIMARY KEY,
  code        text NOT NULL CHECK (length(code) BETWEEN 1 AND 32),
  name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid NOT NULL,
  CONSTRAINT lending_loan_product_code_uq UNIQUE (code)
);

CREATE TABLE lending.loan_product_version (
  version_id       uuid PRIMARY KEY,
  product_id       uuid NOT NULL REFERENCES lending.loan_product(product_id),
  version_no       integer NOT NULL CHECK (version_no > 0),
  status           text NOT NULL CHECK (status IN ('DRAFT', 'ACTIVE')),
  schedule_method  text NOT NULL CHECK (schedule_method IN ('FLAT', 'EFFECTIVE', 'ANNUITY')),
  tenor_months     integer NOT NULL CHECK (tenor_months > 0),
  annual_rate      bigint NOT NULL CHECK (annual_rate >= 0),
  allocation_order text NOT NULL CHECK (length(allocation_order) BETWEEN 1 AND 64),
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid NOT NULL,
  approved_at      timestamptz,
  approved_by      uuid,
  CONSTRAINT lending_loan_product_version_no_uq UNIQUE (product_id, version_no),
  -- Empat mata: versi ACTIVE harus punya penyetuju, dan penyetuju bukan pembuatnya.
  CONSTRAINT lending_loan_product_version_approver_chk CHECK (
    status <> 'ACTIVE' OR (approved_by IS NOT NULL AND approved_by <> created_by)
  )
);

COMMENT ON COLUMN lending.loan_product_version.annual_rate IS
  'Rate tahunan dalam micro-unit (1e6 = 100%), mis. 125000 = 12,5%. Bukan money, bukan float.';
COMMENT ON COLUMN lending.loan_product_version.allocation_order IS
  'Urutan alokasi pembayaran, mis. INTEREST,PRINCIPAL,PENALTY. Divalidasi domain, bukan DB: '
  'komponen yang hilang/duplikat ditolak sebelum disimpan.';

CREATE INDEX lending_loan_product_version_product_idx
  ON lending.loan_product_version (product_id, version_no);

-- Versi yang sudah ACTIVE tidak boleh diubah: perubahan = versi baru. DRAFT masih boleh, karena
-- itu tempat penyusunan. `ledger.reject_mutation()` tidak dipakai di sini karena yang dilarang
-- hanya keadaan ACTIVE, bukan seluruh baris.
CREATE FUNCTION lending.reject_active_version_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'ACTIVE' THEN
    RAISE EXCEPTION 'versi produk pinjaman yang ACTIVE tidak boleh diubah atau dihapus; buat versi baru';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;

CREATE TRIGGER lending_loan_product_version_immutable
  BEFORE UPDATE OR DELETE ON lending.loan_product_version
  FOR EACH ROW EXECUTE FUNCTION lending.reject_active_version_mutation();
