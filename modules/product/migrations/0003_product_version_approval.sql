-- Maker-checker versi produk — tahap EXPAND (T-086, D-099 + D-119).
--
-- Aman untuk `migrate --up` (tanpa DROP/TRUNCATE): kolom baru, backfill, CHECK baru, index, dan
-- penggantian badan fungsi trigger (`CREATE OR REPLACE`). Perubahan constraint EXCLUDE yang
-- bersifat merusak dipisah ke `0004_product_version_contract.sql`.
--
-- Selama jendela antara expand dan contract, constraint lama (semua versi tidak boleh tumpang
-- tindih) masih berlaku, jadi dua DRAFT bertumpang tindih belum bisa dibuat; deploy menjalankan
-- contract segera setelah expand sebelum binary baru menerima trafik (lihat T-090).
--
-- Rolling deploy: `maker` diisi trigger BEFORE INSERT dan `status` tetap punya DEFAULT 'DRAFT',
-- supaya binary lama yang masih berjalan (menulis tanpa kolom baru) tidak gagal. Keduanya
-- dibersihkan di migrasi contract **T-090** setelah dipastikan tidak ada binary lama.

ALTER TABLE product.product_version
  ADD COLUMN status text NOT NULL DEFAULT 'DRAFT',
  ADD COLUMN maker uuid,
  ADD COLUMN checker uuid,
  ADD COLUMN approved_at timestamptz,
  ADD COLUMN reject_reason text;

-- Backfill baris lama: semuanya sudah terbit (tidak ada konsep DRAFT sebelumnya).
UPDATE product.product_version
   SET status = 'ACTIVE',
       maker = published_by,
       checker = '00000000-0000-0000-0000-000000000000',
       approved_at = published_at,
       sealed = true;

ALTER TABLE product.product_version
  ALTER COLUMN maker SET NOT NULL,
  ADD CONSTRAINT product_version_status_chk
    CHECK (status IN ('DRAFT', 'ACTIVE', 'REJECTED')),
  ADD CONSTRAINT product_version_self_approval_chk
    CHECK (checker IS NULL OR checker <> maker),
  ADD CONSTRAINT product_version_decision_chk CHECK (
    (status = 'DRAFT') = (checker IS NULL)
    AND (status = 'ACTIVE') = (approved_at IS NOT NULL)
    AND (status = 'REJECTED') = (reject_reason IS NOT NULL)
    AND (status <> 'DRAFT') = sealed);

COMMENT ON COLUMN product.product_version.status IS
  'DRAFT → ACTIVE (approve) atau REJECTED (reject). Tidak ada transisi lain (T-086).';
COMMENT ON COLUMN product.product_version.checker IS
  'Penyetuju/penolak; wajib berbeda dari maker. Backfill baris lama memakai UUID nol sebagai '
  'sentinel "pack reviewer" (tidak ada aktor nyata sebelum maker-checker).';

CREATE INDEX product_version_status_idx
  ON product.product_version (product_id, status, effective_from DESC);

-- Trigger lama membekukan versi begitu binding pertama masuk. Badan fungsinya dinetralkan di
-- expand; trigger-nya sendiri baru dihapus di contract (DROP = merusak).
CREATE OR REPLACE FUNCTION product.assert_version_has_bindings() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Seal kini terjadi saat approve/reject; invarian "ACTIVE wajib punya binding" ditegakkan
  -- `guard_version_update` pada transisi status.
  RETURN NEW;
END;
$$;

CREATE FUNCTION product.fill_version_maker() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Invarian yang dulu dijaga deferred trigger kini harus dijaga di INSERT: versi baru selalu
  -- DRAFT dan belum sealed. Tanpa ini seed/import SQL bisa membuat ACTIVE tanpa binding yang
  -- tidak akan pernah bisa diberi binding (binding hanya untuk DRAFT).
  IF NEW.status <> 'DRAFT' THEN
    RAISE EXCEPTION 'product: versi baru harus DRAFT (bukan %)', NEW.status;
  END IF;
  IF NEW.sealed THEN
    RAISE EXCEPTION 'product: versi baru tidak boleh langsung sealed';
  END IF;
  IF NEW.checker IS NOT NULL OR NEW.approved_at IS NOT NULL OR NEW.reject_reason IS NOT NULL THEN
    RAISE EXCEPTION 'product: keputusan approve/reject hanya lewat transisi status';
  END IF;
  IF NEW.maker IS NOT NULL AND NEW.maker <> NEW.published_by THEN
    RAISE EXCEPTION 'product: maker versi baru harus sama dengan published_by (pengaju)';
  END IF;
  NEW.maker := coalesce(NEW.maker, NEW.published_by);
  RETURN NEW;
END;
$$;

CREATE TRIGGER product_version_fill_maker
  BEFORE INSERT ON product.product_version
  FOR EACH ROW EXECUTE FUNCTION product.fill_version_maker();

CREATE OR REPLACE FUNCTION product.guard_version_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'product: versi produk tidak boleh dihapus';
  END IF;
  IF NEW.version_id <> OLD.version_id OR NEW.product_id <> OLD.product_id
     OR NEW.version_no <> OLD.version_no OR NEW.effective_from <> OLD.effective_from
     OR NEW.published_at <> OLD.published_at OR NEW.published_by <> OLD.published_by
     OR NEW.maker <> OLD.maker THEN
    RAISE EXCEPTION 'product: versi immutable; hanya status/effective_to yang boleh berubah';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (OLD.status = 'DRAFT' AND NEW.status IN ('ACTIVE', 'REJECTED')) THEN
      RAISE EXCEPTION 'product: transisi status % → % tidak diizinkan', OLD.status, NEW.status;
    END IF;
    IF NEW.status = 'ACTIVE' AND NOT EXISTS (
        SELECT 1 FROM product.product_param_binding b WHERE b.version_id = NEW.version_id) THEN
      RAISE EXCEPTION 'product: versi % wajib punya minimal satu binding parameter',
        NEW.version_id USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  IF OLD.checker IS NOT NULL AND NEW.checker IS DISTINCT FROM OLD.checker THEN
    RAISE EXCEPTION 'product: checker sudah tercatat (tidak boleh diubah)';
  END IF;
  IF OLD.approved_at IS NOT NULL AND NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
    RAISE EXCEPTION 'product: approved_at sudah tercatat (tidak boleh diubah)';
  END IF;
  IF OLD.reject_reason IS NOT NULL AND NEW.reject_reason IS DISTINCT FROM OLD.reject_reason THEN
    RAISE EXCEPTION 'product: reject_reason sudah tercatat (tidak boleh diubah)';
  END IF;

  IF OLD.sealed AND NOT NEW.sealed THEN
    RAISE EXCEPTION 'product: sealed tidak boleh dibuka kembali';
  END IF;
  IF OLD.effective_to IS NOT NULL AND NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN
    RAISE EXCEPTION 'product: effective_to sudah pernah diisi (tidak boleh diubah lagi)';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION product.assert_binding_open() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
      SELECT 1 FROM product.product_version v
       WHERE v.version_id = NEW.version_id
         AND (v.status <> 'DRAFT' OR v.sealed)) THEN
    RAISE EXCEPTION 'product: binding versi % sudah dibekukan (bukan DRAFT); pakai versi baru',
      NEW.version_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;
