-- Skema katalog `product` (spec §9: Product Factory parametrik, effective-dated).
--
-- Dipisah dari `0001_product_init.sql` (yang hanya membuat schema) karena 0001 sudah terlanjur
-- diterapkan di DB dev oleh harness test; mengubah berkas yang sudah diterapkan akan gagal checksum.
--
-- Spec hanya menyebut nama tabel (`product`, `product_version`, `product_param_binding`) dan
-- aturan bitemporal/effective-dated (§9.1(5)); kolom diturunkan di sini dan dicatat di MODULE.md.
--
-- Invarian yang ditegakkan DB, bukan konvensi:
--   * Versi produk tidak tumpang tindih per produk (`EXCLUDE` pada `daterange(...,'[)')`),
--     termasuk versi tanpa `effective_to` (terbuka ke atas).
--   * Versi **immutable**: hanya `effective_to` yang boleh diisi, sekali, untuk menutup versi saat
--     versi baru mulai. Binding juga immutable (versi baru = baris baru).
--   * Setiap versi wajib punya minimal satu binding parameter (constraint trigger deferred, karena
--     binding disisipkan setelah header dalam transaksi yang sama).
--   * Atribut produk **hanya** dari parameter: binding menyimpan `param_key` + nilai yang dipakai
--     versi itu; tidak ada angka bisnis di DDL.

CREATE SCHEMA IF NOT EXISTS product;

CREATE TABLE product.product (
  product_id   uuid PRIMARY KEY,
  code         text NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9][A-Z0-9._-]{1,31}$'),
  name         text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  product_type text NOT NULL CHECK (product_type IN ('SAVINGS', 'TIME_DEPOSIT', 'LOAN', 'FINANCING')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid NOT NULL
);

COMMENT ON TABLE product.product IS
  'Katalog produk (T-076). Identitas produk stabil; atribut berubah lewat versi baru, bukan edit.';

CREATE TABLE product.product_version (
  version_id     uuid PRIMARY KEY,
  product_id     uuid NOT NULL REFERENCES product.product(product_id),
  version_no     int NOT NULL CHECK (version_no >= 1),
  effective_from date NOT NULL,
  effective_to   date,
  published_at   timestamptz NOT NULL DEFAULT now(),
  published_by   uuid NOT NULL,
  CONSTRAINT product_version_no_uq UNIQUE (product_id, version_no),
  CONSTRAINT product_version_window_chk CHECK (
    effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT product_version_no_overlap EXCLUDE USING gist (
    product_id WITH =,
    daterange(effective_from, effective_to, '[]') WITH &&)
);

CREATE INDEX product_version_current_idx
  ON product.product_version (product_id, effective_from DESC);

COMMENT ON TABLE product.product_version IS
  'Versi produk effective-dated (T-076). Rentang inklusif [from, to]; EXCLUDE menolak '
  'tumpang tindih. Versi immutable kecuali effective_to (diisi sekali saat versi baru terbit).';

CREATE TABLE product.product_param_binding (
  version_id uuid NOT NULL REFERENCES product.product_version(version_id),
  param_key  text NOT NULL CHECK (length(btrim(param_key)) BETWEEN 1 AND 120),
  value      jsonb NOT NULL,
  PRIMARY KEY (version_id, param_key)
);

COMMENT ON TABLE product.product_param_binding IS
  'Nilai atribut produk per versi (T-076). Kunci harus parameter terdaftar; tipenya divalidasi '
  'composition root terhadap definisi parameter.';

CREATE FUNCTION product.guard_product_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'product: produk tidak boleh dihapus (pakai versi/status, bukan hapus)';
  END IF;
  IF NEW.product_id <> OLD.product_id OR NEW.code <> OLD.code
     OR NEW.product_type <> OLD.product_type OR NEW.created_at <> OLD.created_at
     OR NEW.created_by <> OLD.created_by THEN
    RAISE EXCEPTION 'product: hanya nama yang boleh diubah; kode/tipe/identitas tetap';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER product_guard_update
  BEFORE UPDATE OR DELETE ON product.product
  FOR EACH ROW EXECUTE FUNCTION product.guard_product_update();

CREATE FUNCTION product.guard_version_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'product: versi produk tidak boleh dihapus';
  END IF;
  IF NEW.version_id <> OLD.version_id OR NEW.product_id <> OLD.product_id
     OR NEW.version_no <> OLD.version_no OR NEW.effective_from <> OLD.effective_from
     OR NEW.published_at <> OLD.published_at OR NEW.published_by <> OLD.published_by THEN
    RAISE EXCEPTION 'product: versi immutable; hanya effective_to yang boleh diisi';
  END IF;
  IF OLD.effective_to IS NOT NULL AND NEW.effective_to IS DISTINCT FROM OLD.effective_to THEN
    RAISE EXCEPTION 'product: effective_to sudah pernah diisi (tidak boleh diubah lagi)';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER product_version_guard_update
  BEFORE UPDATE OR DELETE ON product.product_version
  FOR EACH ROW EXECUTE FUNCTION product.guard_version_update();

CREATE FUNCTION product.reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'product: % pada % ditolak (data versi immutable)', TG_OP, TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER product_param_binding_immutable
  BEFORE UPDATE OR DELETE ON product.product_param_binding
  FOR EACH ROW EXECUTE FUNCTION product.reject_mutation();

CREATE TRIGGER product_param_binding_no_truncate
  BEFORE TRUNCATE ON product.product_param_binding
  FOR EACH STATEMENT EXECUTE FUNCTION product.reject_mutation();

CREATE FUNCTION product.assert_version_has_bindings() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM product.product_param_binding b WHERE b.version_id = NEW.version_id) THEN
    RAISE EXCEPTION 'product: versi % wajib punya minimal satu binding parameter', NEW.version_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE CONSTRAINT TRIGGER product_version_has_bindings
  AFTER INSERT ON product.product_version
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION product.assert_version_has_bindings();
