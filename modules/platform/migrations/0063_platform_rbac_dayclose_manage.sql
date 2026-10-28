-- Izin aksi day-close (T-139a/actions).
--
-- Dipisah dari `dayclose.run.read` (0061): memantau penutupan dan menghentikannya adalah dua
-- kewenangan berbeda. `module` harus `dayclose` karena CHECK pada `platform.permission` menuntut
-- `code = module || '.' || resource || '.' || action`.
--
-- Pemberian ke peran: `platform_admin` (pemegang seluruh izin) dan `ledger_admin` (yang memang
-- menjalankan penutupan pembukuan). `ops_admin` sengaja hanya memegang izin baca dari 0061.
-- Izin ini **tidak** cukup sendirian: handler menuntut grant tanpa batas cabang karena penutupan
-- adalah urusan institusi (D-062).
--
-- Idempotent supaya aman dijalankan ulang.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'dayclose.run.manage', 'dayclose', 'run', 'manage',
   'perm.dayclose.run.manage')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('platform_admin', 'ledger_admin')
   AND p.code = 'dayclose.run.manage'
ON CONFLICT DO NOTHING;
