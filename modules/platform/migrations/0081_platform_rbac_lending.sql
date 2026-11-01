-- Izin modul `lending` (T-163): pengajuan, persetujuan, dan pembacaan pinjaman.
--
-- Kode izin hidup di migrasi (bukan parameter institusi) karena yang memakainya adalah kode
-- (`handlers_lending.nim`), pola yang sama dengan `product.catalog.*` (0017/0022) dan `teller.*`
-- (0027). Idempoten.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'lending.loan.read', 'lending', 'loan', 'read',
   'perm.lending.loan.read'),
  (gen_random_uuid(), 'lending.loan.submit', 'lending', 'loan', 'submit',
   'perm.lending.loan.submit'),
  (gen_random_uuid(), 'lending.loan.approve', 'lending', 'loan', 'approve',
   'perm.lending.loan.approve')
ON CONFLICT (code) DO NOTHING;

-- Dua peran sempit: pembuat pengajuan dan penyetuju tidak dipegang satu orang (SoD di bawah).
-- Tanpa peran ini satu-satunya cara memakai modul adalah `platform_admin`, dan pemisahan tugas
-- hanya berlaku di atas kertas.
INSERT INTO platform.role (role_id, code, name_key, is_system)
VALUES
  (gen_random_uuid(), 'lending_maker', 'role.lending_maker', false),
  (gen_random_uuid(), 'lending_checker', 'role.lending_checker', false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('lending_maker', 'lending_checker')
   AND p.code = 'lending.loan.read'
ON CONFLICT DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'lending_maker'
   AND p.code = 'lending.loan.submit'
ON CONFLICT DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'lending_checker'
   AND p.code = 'lending.loan.approve'
ON CONFLICT DO NOTHING;

-- Admin institusi memegang ketiganya, sama seperti `product.catalog.*`: empat mata tetap ditegakkan
-- oleh aturan domain + CHECK DB (penyetuju ≠ pembuat), bukan oleh izin.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('lending.loan.read', 'lending.loan.submit', 'lending.loan.approve')
ON CONFLICT DO NOTHING;

-- Satu orang tidak boleh memegang kedua peran pinjaman.
INSERT INTO platform.role_conflict (role_code_a, role_code_b, reason_key)
VALUES ('lending_checker', 'lending_maker', 'sod.lending.maker_checker')
ON CONFLICT (role_code_a, role_code_b) DO NOTHING;
