-- Izin restrukturisasi dan hapus buku (T-168).
--
-- `lending.loan.restructure` → `lending_maker` + `platform_admin`: menyusun ulang jadwal adalah
-- pekerjaan pembuat akad, bukan penyetujunya.
--
-- `lending.loan.write_off` → `lending_checker` + `platform_admin`, **tanpa** `lending_maker`:
-- menghapusbukukan piutang tidak boleh dilakukan orang yang sama dengan yang mencairkan pinjaman.
-- Ini pemisahan tugas yang paling murah dan tidak menambah alur persetujuan baru.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'lending.loan.restructure', 'lending', 'loan', 'restructure',
   'perm.lending.loan.restructure'),
  (gen_random_uuid(), 'lending.loan.write_off', 'lending', 'loan', 'write_off',
   'perm.lending.loan.write_off')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('lending_maker', 'platform_admin')
   AND p.code = 'lending.loan.restructure'
ON CONFLICT DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('lending_checker', 'platform_admin')
   AND p.code = 'lending.loan.write_off'
ON CONFLICT DO NOTHING;
