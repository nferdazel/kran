-- Grant izin `product.*` untuk `platform_admin` (T-076).
--
-- Dipisah dari `0017` karena 0017 sudah diterapkan dengan daftar kode lama (`product.read`);
-- migrasi yang sudah diterapkan tidak boleh diubah checksum-nya.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('product.catalog.read', 'product.catalog.manage')
ON CONFLICT DO NOTHING;
