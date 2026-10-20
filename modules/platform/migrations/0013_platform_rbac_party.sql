-- Katalog izin modul `party` (T-070).
--
-- Sama alasannya dengan 0008: kode izin terikat kode program (`apps/api/src/handlers_party.nim`),
-- bukan nilai bisnis yang bisa diubah institusi — jadi tempatnya di migrasi, ikut versi dan
-- terpasang tanpa langkah manual. Idempotent supaya aman dijalankan ulang.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'party.party.create', 'party', 'party', 'create', 'perm.party.party.create'),
  (gen_random_uuid(), 'party.party.read', 'party', 'party', 'read', 'perm.party.party.read')
ON CONFLICT (code) DO NOTHING;

-- Admin platform mendapat izin baru secara eksplisit. Daftar ini sengaja tidak memakai
-- "semua baris permission": izin yang ditambahkan kemudian tidak boleh ikut diam-diam.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('party.party.create', 'party.party.read')
ON CONFLICT DO NOTHING;
