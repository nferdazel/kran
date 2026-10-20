-- Katalog izin modul `product` (T-076).
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'product.catalog.read', 'product', 'catalog', 'read', 'perm.product.catalog.read'),
  (gen_random_uuid(), 'product.catalog.manage', 'product', 'catalog', 'manage', 'perm.product.catalog.manage')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('product.read', 'product.manage')
ON CONFLICT DO NOTHING;
