-- Deprecate `product.savings.grace_period_days` (T-087, D-095).
--
-- Parameter ini **dikeluarkan** dari katalog seed (`modules/product/seeds/params.yaml`): tidak ada
-- konsumen dan D-095 melarang mengarang semantik bisnisnya. Karena baris katalog `platform.param_definition`
-- yang sudah tersemai oleh `packs/base/generated/param_definitions.sql` (deployment lama) tidak ikut
-- hilang hanya dengan menghapus definisinya, migrasi ini menandai baris lama `deprecated` supaya
-- binding produk ke kunci itu ditolak `handlers_products` (fail-closed), bukan tetap hidup.
--
-- DB yang dibuat dari nol: kunci ini tidak ada lagi, jadi `UPDATE` di bawah no-op.
--
-- Expand-only (hanya UPDATE baris, tanpa DDL destruktif), tidak butuh `-- dbtools:contract`.
-- Nilai `platform.param_value` yang pernah tersemai sengaja **dibiarkan**: definisinya sudah
-- deprecated sehingga tidak bisa di-bind, tidak ada konsumen, dan mengubah riwayat effective-dated
-- bukan urusan migrasi expand.
UPDATE platform.param_definition
   SET deprecated = true
 WHERE key = 'product.savings.grace_period_days'
   AND NOT deprecated;
