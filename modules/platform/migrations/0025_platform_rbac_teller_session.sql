-- Katalog izin modul `teller` sesi kas (T-093).
--
-- Sama alasannya dengan 0008/0023/0024: kode izin terikat kode program
-- (`apps/api/src/handlers_teller_sessions.nim` + gate di `handlers_teller.nim`), bukan nilai
-- bisnis yang bisa diubah institusi — jadi tempatnya di migrasi, ikut versi dan terpasang tanpa
-- langkah manual. Idempotent supaya aman dijalankan ulang.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'teller.session.open', 'teller', 'session', 'open',
   'perm.teller.session.open'),
  (gen_random_uuid(), 'teller.session.close', 'teller', 'session', 'close',
   'perm.teller.session.close'),
  (gen_random_uuid(), 'teller.session.read', 'teller', 'session', 'read',
   'perm.teller.session.read')
ON CONFLICT (code) DO NOTHING;

-- Grant eksplisit ke `platform_admin` (pola `0024_platform_rbac_teller.sql`). Daftar ditulis
-- eksplisit, bukan "semua baris permission": izin yang ditambahkan kemudian tidak boleh ikut
-- diam-diam.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('teller.session.open', 'teller.session.close', 'teller.session.read')
ON CONFLICT DO NOTHING;
