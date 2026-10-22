-- Izin maker-checker katalog produk (T-086, D-099).
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'product.catalog.approve', 'product', 'catalog', 'approve',
   'perm.product.catalog.approve')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code = 'product.catalog.approve'
ON CONFLICT DO NOTHING;
