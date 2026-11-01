-- Izin pencairan pinjaman (T-164).
--
-- Pencairan memindahkan uang, jadi izinnya dipisah dari `lending.loan.approve`: orang yang
-- menyetujui akad tidak otomatis boleh mencairkan. `lending_checker` mendapat approve saja;
-- pencairan dipegang `lending_maker` (petugas yang menjalankan akad) dan `platform_admin`.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'lending.loan.disburse', 'lending', 'loan', 'disburse',
   'perm.lending.loan.disburse')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('lending_maker', 'platform_admin')
   AND p.code = 'lending.loan.disburse'
ON CONFLICT DO NOTHING;
