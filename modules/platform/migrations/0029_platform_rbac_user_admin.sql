-- Izin administrasi pengguna (T-117).
--
-- Sampai sekarang hanya `ctl` yang bisa membuat/mengelola akun operator (bootstrap, create-user,
-- assign-role, disable, ...). Layar `/app/users` memberi jalur HTTP dengan aturan yang sama; ia
-- butuh satu izin tersendiri supaya pengelolaan pengguna tidak ikut terbuka bagi pemegang izin
-- lain (mis. `platform.audit.read`).
--
-- Struktural, jadi tempatnya di migrasi (pola 0008/0022-0028), bukan parameter institusi.
-- Idempotent: `ON CONFLICT DO NOTHING`, jadi aman dijalankan ulang.

INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'platform.user.manage', 'platform', 'user', 'manage',
   'perm.platform.user.manage')
ON CONFLICT (code) DO NOTHING;

-- Explicit grant, pattern of 0008/0022-0028: list the permission code, never "all rows".
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code = 'platform.user.manage'
ON CONFLICT DO NOTHING;
