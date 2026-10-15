-- Katalog izin + role sistem (T-027, D-035).
--
-- Sebelum ini katalog izin hanya ada di `packs/base/seed/0001_dev_users.sql`, yang **tidak pernah**
-- diterapkan di produksi: `dbtools seed` menerapkan `packs/*/generated/*.sql` selalu, dan
-- `packs/*/seed/*.sql` hanya dengan `--dev`. Akibatnya admin pertama (peran `ctl bootstrap-admin`)
-- akan dibuat tanpa satu pun izin dan RBAC tidak bisa dipakai di produksi sama sekali.
--
-- Katalog ini struktural: kode izin terikat kode program (`apps/api/src/access.nim`), bukan nilai
-- bisnis yang bisa diubah institusi. Karena itu tempatnya di migrasi: ikut versi, ikut jalur
-- expand-only, dan terpasang tanpa langkah manual di server.
--
-- Idempotent: `ON CONFLICT (code) DO NOTHING` supaya aman dijalankan ulang.

INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'platform.param.read', 'platform', 'param', 'read', 'perm.platform.param.read'),
  (gen_random_uuid(), 'platform.param.submit', 'platform', 'param', 'submit', 'perm.platform.param.submit'),
  (gen_random_uuid(), 'platform.param.approve', 'platform', 'param', 'approve', 'perm.platform.param.approve'),
  (gen_random_uuid(), 'platform.audit.read', 'platform', 'audit', 'read', 'perm.platform.audit.read')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role (role_id, code, name_key, is_system)
VALUES
  (gen_random_uuid(), 'platform_admin', 'role.platform_admin', true),
  (gen_random_uuid(), 'param_maker', 'role.param_maker', false),
  (gen_random_uuid(), 'param_checker', 'role.param_checker', false)
ON CONFLICT (code) DO NOTHING;

-- `platform_admin`: seluruh izin yang dikenal. Daftarnya ditulis eksplisit (bukan "semua baris
-- platform.permission"), supaya izin yang ditambahkan kemudian tidak diam-diam ikut diberikan hanya
-- karena ada di tabel.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('platform.param.read', 'platform.param.submit', 'platform.param.approve',
                  'platform.audit.read')
ON CONFLICT DO NOTHING;

-- Maker melihat parameter + mengajukan perubahan; checker melihat parameter + menyetujui. Keduanya
-- boleh membaca audit. Pemisahan tugasnya sendiri ditegakkan kolom `checker <> maker`, dan matriks
-- SoD per institusi bukan urusan repo.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE (r.code = 'param_maker' AND p.code IN ('platform.param.read', 'platform.param.submit',
                                              'platform.audit.read'))
    OR (r.code = 'param_checker' AND p.code IN ('platform.param.read', 'platform.param.approve',
                                                'platform.audit.read'))
ON CONFLICT DO NOTHING;
