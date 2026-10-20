-- Katalog izin PII/KYC modul `party` (T-071).
--
-- Dipisah dari `0013` supaya izin PII tidak ikut terpasang pada deploy yang belum memakai
-- fitur ini. Alasannya sama dengan 0008/0013: kode izin terikat kode program, jadi tempatnya
-- di migrasi (ikut versi), bukan nilai yang bisa diubah institusi.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'party.kyc.manage', 'party', 'kyc', 'manage', 'perm.party.kyc.manage'),
  (gen_random_uuid(), 'party.identity_doc.read', 'party', 'identity_doc', 'read', 'perm.party.identity_doc.read')
ON CONFLICT (code) DO NOTHING;

-- Daftar eksplisit, bukan "semua izin": izin yang ditambahkan kemudian tidak ikut diam-diam.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('party.kyc.manage', 'party.identity_doc.read')
ON CONFLICT DO NOTHING;
