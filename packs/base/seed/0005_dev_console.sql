-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2).
--
-- Satu akun console untuk gate e2e layar administrasi (T-132/UI-4): `/app/users`,
-- `/app/products`, `/app/ledger/admin`, `/app/accounts/open`. Layar-layar itu butuh izin yang
-- berbeda-beda (`platform.user.manage`, `ledger.period.manage`, `deposit.account.manage`,
-- `product.catalog.read`); `ledger.period.manage` hanya dipegang `platform_admin`, jadi akun uji
-- ini memakai role itu.
--
-- **Kenapa berkas terpisah, bukan tambahan di `0001_dev_users.sql`.** `itapi_users` menjalankan
-- `0001` saja dan menegaskan "hanya satu pengelola aktif" (`platform.user.manage`) serta satu
-- pemegang `platform_admin`; pengelola aktif tambahan di berkas itu menggeser hitungannya (lihat
-- peringatan di kepala `0001`). Berkas terpisah dibaca `./task e2e` (seed `--dev` penuh) dan
-- `itapi_roles` (yang memarkir semua grant pengelola sebelum menguji, jadi tetap deterministik).
--
-- Password sama dengan akun dev lain (`rahasia-panjang-123`, iterasi 1000 — lihat alasannya di
-- `0001`). Idempoten: `ON CONFLICT` menyetel ulang hash & status, grant role `DO NOTHING`.

INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                               must_change_password)
VALUES
  (md5('dev|dev.console')::uuid, 'dev.console', 'Uji Console (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$1000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$6jrvAXXnE41eOhdT8kzgnqjBuFG1J4EjRIeFquIawY0=',
   false)
ON CONFLICT (username) DO UPDATE
  SET password_algo = EXCLUDED.password_algo,
      password_hash = EXCLUDED.password_hash,
      must_change_password = EXCLUDED.must_change_password,
      status = 'ACTIVE',
      failed_attempts = 0,
      locked_until = NULL,
      updated_at = now();

INSERT INTO platform.user_role (user_id, role_id, branch_id)
SELECT u.user_id, r.role_id, NULL
  FROM platform.app_user u, platform.role r
 WHERE u.username = 'dev.console'
   AND r.code = 'platform_admin'
ON CONFLICT DO NOTHING;
