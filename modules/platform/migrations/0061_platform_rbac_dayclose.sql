-- Katalog izin modul `daycloser` (T-139a).
--
-- Sama alasannya dengan 0008/0013/0015/0023: kode izin terikat kode program
-- (`apps/api/src/handlers_dayclose.nim`), bukan nilai bisnis yang bisa diubah institusi — jadi
-- tempatnya di migrasi. `module` harus `dayclose` karena CHECK `code = module || '.' || resource
-- || '.' || action`. Idempotent supaya aman dijalankan ulang.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'dayclose.run.read', 'dayclose', 'run', 'read',
   'perm.dayclose.run.read')
ON CONFLICT (code) DO NOTHING;

-- Grant eksplisit (pola 0008/0022-0032): daftar kode ditulis apa adanya, bukan "semua baris
-- permission", supaya izin yang ditambahkan kemudian tidak ikut diam-diam.
--
-- Baca saja, jadi aman diberikan ke tiga peran institusi yang sudah ada:
--   `platform_admin` — pemegang seluruh izin;
--   `ops_admin`      — pemantauan harian (sudah baca-only pada buku besar & vault);
--   `ledger_admin`   — yang menjalankan/mengawasi penutupan pembukuan.
-- Peran baru tidak dibuat di sini; izin tulis (`dayclose.run.manage`) menyusul bersama aksinya.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('platform_admin', 'ops_admin', 'ledger_admin')
   AND p.code = 'dayclose.run.read'
ON CONFLICT DO NOTHING;
