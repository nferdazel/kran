-- Izin pemulihan pasca hapus buku (O-122, T-176).
--
-- `lending.loan.recovery` → `lending_checker` + `platform_admin`, **tanpa** `lending_maker`.
-- Alasannya sama dengan `lending.loan.write_off` (D-186): menerima uang atas piutang yang sudah
-- dibebankan mengubah laba rugi, jadi tidak boleh dipegang orang yang sama dengan pencair pinjaman.
-- Peran teller yang menerima setoran tetap memakai alur simpanan biasa; ini pencatatan pemulihan,
-- bukan transaksi kas.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'lending.loan.recovery', 'lending', 'loan', 'recovery',
   'perm.lending.loan.recovery')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('lending_checker', 'platform_admin')
   AND p.code = 'lending.loan.recovery'
ON CONFLICT DO NOTHING;
