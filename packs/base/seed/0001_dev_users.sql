-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2, docs/OPEN_ITEMS.md).
--
-- Pengguna sintetis untuk pengembangan, uji integrasi, dan e2e Playwright. Password ketiganya
-- `rahasia-panjang-123` (PBKDF2-HMAC-SHA256, 600.000 iterasi, sesuai parameter pack `base`).
-- Nilainya bukan rahasia: berkas ini terbuka di repo, dan siapa pun yang bisa menyentuh DB dev
-- memang sudah boleh masuk.
--
-- Katalog izin dan role **tidak** lagi di sini: ia milik migrasi `0008_platform_rbac_catalogue.sql`,
-- karena hanya migrasi yang ikut terpasang di produksi. Berkas ini hanya menjaga user dan
-- pemberian rolenya.
--
-- Diterapkan hanya oleh `./task dbtools seed --dev`. Idempotent, dan **menyetel ulang** password
-- serta `must_change_password` ketiga user (bukan `DO NOTHING`): e2e mengubah password
-- `dev.firstlogin` saat menguji alur wajib-ganti, jadi seed harus bisa mengembalikannya.

INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                               must_change_password)
VALUES
  (md5('dev|dev.maker')::uuid, 'dev.maker', 'Uji Maker (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$600000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$reBXlbgbT/2dqhhgelI8Gn697hjWLDrHDCPU5cNKQzo=',
   false),
  (md5('dev|dev.checker')::uuid, 'dev.checker', 'Uji Checker (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$600000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$reBXlbgbT/2dqhhgelI8Gn697hjWLDrHDCPU5cNKQzo=',
   false),
  -- Dipakai e2e alur wajib-ganti: login pertama harus mengganti password sebelum bisa bekerja.
  (md5('dev|dev.firstlogin')::uuid, 'dev.firstlogin', 'Uji Login Pertama (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$600000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$reBXlbgbT/2dqhhgelI8Gn697hjWLDrHDCPU5cNKQzo=',
   true)
ON CONFLICT (username) DO UPDATE
  SET password_algo = EXCLUDED.password_algo,
      password_hash = EXCLUDED.password_hash,
      must_change_password = EXCLUDED.must_change_password,
      status = 'ACTIVE',
      failed_attempts = 0,
      locked_until = NULL,
      updated_at = now();

-- Grant tanpa cabang (NULL) = berlaku di semua cabang, termasuk aksi tingkat institusi
-- (`authorize` dengan `targetBranch = ""`).
INSERT INTO platform.user_role (user_id, role_id, branch_id)
SELECT u.user_id, r.role_id, NULL
  FROM platform.app_user u, platform.role r
 WHERE (u.username = 'dev.maker' AND r.code = 'param_maker')
    OR (u.username = 'dev.checker' AND r.code = 'param_checker')
    OR (u.username = 'dev.firstlogin' AND r.code = 'param_maker')
ON CONFLICT DO NOTHING;
