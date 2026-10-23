-- Klasifikasi simpanan koperasi (T-111, memo SME) — tahap EXPAND, idempoten.
--
-- `savings_kind` hanya boleh diisi untuk `product_type = 'SAVINGS'` dan **immutable**: reklasifikasi
-- = produk baru (atau migrasi data eksplisit), bukan edit baris. `NULL` = belum terklasifikasi;
-- jangan menebak dari kode/nama produk dan jangan backfill (produk lama sengaja kosong).
--
-- Immutability dijaga trigger **baru** (`product_guard_savings_kind`); guard lama
-- (`product_guard_update` dari `0002`) tidak disentuh supaya binary lama tetap aman (rolling deploy).
--
-- Belum ada kolom baru di `deposit.account`: jenis dibaca lewat join produk yang di-pin rekening,
-- jadi klasifikasi tetap properti produk (spec §9). Tambah kolom = expand-only, aman di `--up`.

ALTER TABLE product.product
  ADD COLUMN savings_kind text;

ALTER TABLE product.product
  ADD CONSTRAINT product_savings_kind_chk CHECK (
    savings_kind IS NULL
    OR (product_type = 'SAVINGS'
        AND savings_kind IN ('POKOK', 'WAJIB', 'SUKARELA', 'TABUNGAN')));

COMMENT ON COLUMN product.product.savings_kind IS
  'Klasifikasi simpanan koperasi (T-111): POKOK/WAJIB/SUKARELA/TABUNGAN, hanya untuk produk '
  'SAVINGS. NULL = belum terklasifikasi. Immutable (reklasifikasi = produk baru).';

CREATE FUNCTION product.guard_savings_kind() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.savings_kind IS DISTINCT FROM OLD.savings_kind THEN
    RAISE EXCEPTION 'product: savings_kind immutable (reklasifikasi = produk baru)';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER product_guard_savings_kind
  BEFORE UPDATE ON product.product
  FOR EACH ROW EXECUTE FUNCTION product.guard_savings_kind();
