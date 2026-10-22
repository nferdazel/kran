-- Maker-checker versi produk — tahap CONTRACT (T-086, D-099 + D-119).
--
-- dbtools:contract menyelesaikan expand `product/0003`: menghapus deferred trigger yang dulu
--             membekukan versi saat binding pertama masuk, lalu mengganti EXCLUDE semua-versi
--             dengan EXCLUDE hanya untuk ACTIVE (DRAFT boleh bertumpang tindih).
-- dbtools:destructive memuat DROP TRIGGER/FUNCTION dan DROP CONSTRAINT. Dijalankan lewat
--             `migrate --contract` setelah `--up`, sebelum binary baru menerima trafik. Deploy
--             hanya mengizinkannya lewat allowlist `ops/migrations/contract-auto.txt` (fail-closed
--             bila ada contract lain yang tertunda).
DROP TRIGGER product_version_has_bindings ON product.product_version;
DROP FUNCTION product.assert_version_has_bindings();

ALTER TABLE product.product_version
  DROP CONSTRAINT product_version_no_overlap,
  ADD CONSTRAINT product_version_active_no_overlap EXCLUDE USING gist (
    product_id WITH =,
    daterange(effective_from, effective_to, '[]') WITH &&
  ) WHERE (status = 'ACTIVE');

