-- Izin pembayaran angsuran (T-165).
--
-- Dipisah dari `lending.loan.submit`/`approve`/`disburse`: menerima uang anggota adalah tugas
-- teller/kasir, bukan otomatis tugas pembuat akad. `lending_checker` (penyetuju) sengaja **tidak**
-- mendapat izin ini — yang menyetujui akad tidak harus yang menerima setoran angsuran.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'lending.loan.pay', 'lending', 'loan', 'pay', 'perm.lending.loan.pay')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('lending_maker', 'platform_admin')
   AND p.code = 'lending.loan.pay'
ON CONFLICT DO NOTHING;
