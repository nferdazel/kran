-- Katalog izin vault kas cabang (T-107).
--
-- Sama alasannya dengan 0008/0023/0024/0025: kode izin terikat kode program
-- (`apps/api/src/handlers_teller_vault.nim`), bukan nilai bisnis yang bisa diubah institusi —
-- jadi tempatnya di migrasi, ikut versi dan terpasang tanpa langkah manual. Idempotent supaya
-- aman dijalankan ulang.
--
-- `teller.vault.topup` = injeksi kas operasional ke vault cabang (operasi sensitif: menaikkan
-- saldo kas tanpa jurnal GL, lihat O-097/O-098). `teller.vault.read` = baca saldo vault, dipisah
-- dari `teller.session.read` supaya resource `vault` punya izin baca sendiri (pola
-- `resource.action` spec §13) — bukan menumpang izin sesi yang artinya berbeda.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'teller.vault.topup', 'teller', 'vault', 'topup',
   'perm.teller.vault.topup'),
  (gen_random_uuid(), 'teller.vault.read', 'teller', 'vault', 'read',
   'perm.teller.vault.read')
ON CONFLICT (code) DO NOTHING;

-- Grant eksplisit ke `platform_admin` (pola `0025_platform_rbac_teller_session.sql`). Daftar
-- ditulis eksplisit, bukan "semua baris permission": izin yang ditambahkan kemudian tidak boleh
-- ikut diam-diam.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('teller.vault.topup', 'teller.vault.read')
ON CONFLICT DO NOTHING;
