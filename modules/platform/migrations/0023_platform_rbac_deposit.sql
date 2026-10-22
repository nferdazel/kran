-- Katalog izin modul `deposit` (T-088a).
--
-- Sama alasannya dengan 0008/0013: kode izin terikat kode program
-- (`apps/api/src/handlers_deposit.nim`), bukan nilai bisnis yang bisa diubah institusi — jadi
-- tempatnya di migrasi, ikut versi dan terpasang tanpa langkah manual. Idempotent supaya aman
-- dijalankan ulang.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'deposit.account.manage', 'deposit', 'account', 'manage',
   'perm.deposit.account.manage'),
  (gen_random_uuid(), 'deposit.account.read', 'deposit', 'account', 'read',
   'perm.deposit.account.read')
ON CONFLICT (code) DO NOTHING;

-- Grant eksplisit ke `platform_admin` (pola `0022_platform_rbac_product_approve.sql`). Daftar
-- ditulis eksplisit, bukan "semua baris permission": izin yang ditambahkan kemudian tidak boleh
-- ikut diam-diam.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('deposit.account.manage', 'deposit.account.read')
ON CONFLICT DO NOTHING;
