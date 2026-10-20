-- Katalog izin modul `ledger` (T-072).
--
-- Sama alasannya dengan 0008/0013: kode izin terikat kode program, bukan nilai bisnis yang bisa
-- diubah institusi — jadi tempatnya di migrasi (ikut versi), bukan setelan.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'ledger.coa.read', 'ledger', 'coa', 'read', 'perm.ledger.coa.read'),
  (gen_random_uuid(), 'ledger.coa.manage', 'ledger', 'coa', 'manage', 'perm.ledger.coa.manage'),
  (gen_random_uuid(), 'ledger.period.read', 'ledger', 'period', 'read', 'perm.ledger.period.read'),
  (gen_random_uuid(), 'ledger.period.manage', 'ledger', 'period', 'manage',
   'perm.ledger.period.manage')
ON CONFLICT (code) DO NOTHING;

-- Daftar eksplisit: izin yang ditambahkan kemudian tidak ikut diam-diam.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('ledger.coa.read', 'ledger.coa.manage', 'ledger.period.read',
                  'ledger.period.manage')
ON CONFLICT DO NOTHING;
