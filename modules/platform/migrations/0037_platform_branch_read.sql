-- Master cabang bisa dibaca lewat API (T-121/O-101).
--
-- Sampai sekarang `platform.branch` hanya terbaca lewat `ctl`/SQL, sehingga layar operator harus
-- menebak UUID cabang. Layar vault kas (T-121) butuh memilih cabang, dan pemilih itu tidak boleh
-- menuntut operator menghafal id.
--
-- Izin baru ini **baca saja**: tidak ada jalur HTTP untuk membuat atau mengubah cabang; itu tetap
-- milik `ctl create-branch` (D-130) sampai ada task administrasi cabang tersendiri.
--
-- Pemberian ke peran operator harian yang bekerja per cabang. `product_maker`/`product_checker`
-- sengaja tidak: katalog produk tidak memilih cabang.

INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'platform.branch.read', 'platform', 'branch', 'read',
   'perm.platform.branch.read')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('ops_admin', 'cash_admin', 'teller', 'ledger_admin', 'platform_admin')
   AND p.code = 'platform.branch.read'
ON CONFLICT DO NOTHING;
