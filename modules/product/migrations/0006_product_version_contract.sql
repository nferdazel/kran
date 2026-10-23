-- Maker-checker versi produk — tahap CONTRACT kedua (T-090, D-119).
--
-- Menutup jaring rolling deploy yang dipasang `product/0003` setelah dipastikan tidak ada binary
-- lama. Berkas `0003` **tidak** disentuh (checksum-nya sudah tercatat di `platform.schema_migration`),
-- jadi pembersihan ini ada di berkas baru.
--
-- dbtools:contract melepas jaring rolling deploy versi produk: trigger `product_version_fill_maker`
--                  + DEFAULT `status = 'DRAFT'`.
-- dbtools:destructive memuat DROP TRIGGER/FUNCTION dan DROP DEFAULT. Dijalankan lewat
--                  `migrate --contract`; deploy hanya mengizinkannya lewat allowlist
--                  `ops/migrations/contract-auto.txt` (fail-closed bila ada contract lain tertunda).
--
-- Yang dilepas (memang hanya jaring rolling deploy, bukan invarian):
--   - DEFAULT `status = 'DRAFT'`: binary lama yang menulis tanpa kolom `status` akan gagal
--     NOT NULL setelah contract — justru itu tujuannya (tidak boleh ada binary lama lagi).
--   - trigger `product_version_fill_maker` + fungsi `product.fill_version_maker()` yang mengisi
--     `maker = coalesce(maker, published_by)`.
--
-- Yang dipertahankan: invarian "versi baru harus DRAFT, belum sealed, tanpa keputusan awal, dan
-- `maker = published_by`" dipindah ke trigger `product_version_guard_insert` (tanpa mengisi kolom),
-- supaya temuan MAJOR review T-086 r1 tetap tertutup setelah jaring dilepas.

DROP TRIGGER product_version_fill_maker ON product.product_version;
DROP FUNCTION product.fill_version_maker();

CREATE FUNCTION product.guard_version_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- Versi baru selalu DRAFT dan belum diputuskan; approve/reject hanya lewat transisi status
  -- (`guard_version_update`). Tanpa ini seed/import SQL bisa membuat ACTIVE/REJECTED tanpa binding
  -- yang tidak akan pernah bisa diberi binding (binding hanya untuk DRAFT).
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
  RETURN NEW;
END;
$$;

CREATE TRIGGER product_version_guard_insert
  BEFORE INSERT ON product.product_version
  FOR EACH ROW EXECUTE FUNCTION product.guard_version_insert();

ALTER TABLE product.product_version
  ALTER COLUMN status DROP DEFAULT;
