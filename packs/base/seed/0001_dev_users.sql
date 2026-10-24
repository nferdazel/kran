-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2, docs/OPEN_ITEMS.md).
--
-- Pengguna sintetis untuk pengembangan, uji integrasi, dan e2e Playwright. Password semuanya
-- `rahasia-panjang-123`. `dev.cashmaker`/`dev.cashchecker` adalah pasangan maker-checker untuk
-- top-up vault (T-121): dua orang berbeda dengan peran `cash_admin` yang sama (izin submit dan
-- approve memang dipegang peran itu). Sengaja **bukan** `ops_admin`: peran itu memegang
-- `platform.user.manage`, dan seed dev yang menambah pengelola aktif membuat uji "pengelola
-- terakhir" di `itapi_users` bergantung pada urutan seed.
--
-- **Iterasi sengaja 1000, bukan nilai parameter produksi (600.000)**: seed ini hanya untuk
-- DB dev/test, dan setiap login di test memverifikasi hash dengan iterasi yang tersimpan di baris.
-- Dengan 600.000, `itapi_auth` + `itapi_mfa` menghabiskan ~220 detik CPU hanya untuk verifikasi
-- login (laptop panas, CI lambat) tanpa menguji apa pun tentang biaya hashing — biaya KDF diuji
-- terpisah di `tpassword`/`itpassword` dan `./task bench-password`. Jalur produksi tetap memakai
-- parameter `platform.security.password_pbkdf2_iterations`.
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
   'pbkdf2-hmac-sha256$1000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$6jrvAXXnE41eOhdT8kzgnqjBuFG1J4EjRIeFquIawY0=',
   false),
  (md5('dev|dev.checker')::uuid, 'dev.checker', 'Uji Checker (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$1000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$6jrvAXXnE41eOhdT8kzgnqjBuFG1J4EjRIeFquIawY0=',
   false),
  -- Dipakai e2e alur wajib-ganti: login pertama harus mengganti password sebelum bisa bekerja.
  (md5('dev|dev.firstlogin')::uuid, 'dev.firstlogin', 'Uji Login Pertama (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$1000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$6jrvAXXnE41eOhdT8kzgnqjBuFG1J4EjRIeFquIawY0=',
   true),
  -- Pasangan top-up vault (T-121): pengaju `ops_admin`, penyetuju `cash_admin`. Dua akun berbeda
  -- supaya aturan maker-checker D-132 diuji dengan orang yang benar-benar berbeda.
  (md5('dev|dev.cashmaker')::uuid, 'dev.cashmaker', 'Uji Kas Pengaju (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$1000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$6jrvAXXnE41eOhdT8kzgnqjBuFG1J4EjRIeFquIawY0=',
   false),
  (md5('dev|dev.cashchecker')::uuid, 'dev.cashchecker', 'Uji Kas Penyetuju (dev)',
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

-- Koreksi idempoten: `dev.cashmaker` sempat memakai `ops_admin` (memegang
-- `platform.user.manage`) di iterasi seed awal T-121. Peran kas sudah cukup, dan pengelola aktif
-- tambahan menggeser hitungan uji "pengelola terakhir" di `itapi_users`.
DELETE FROM platform.user_role ur
 USING platform.app_user u, platform.role r
 WHERE ur.user_id = u.user_id
   AND ur.role_id = r.role_id
   AND u.username IN ('dev.cashmaker', 'dev.cashchecker')
   AND r.code = 'ops_admin';

-- Grant tanpa cabang (NULL) = berlaku di semua cabang, termasuk aksi tingkat institusi
-- (`authorize` dengan `targetBranch = ""`).
INSERT INTO platform.user_role (user_id, role_id, branch_id)
SELECT u.user_id, r.role_id, NULL
  FROM platform.app_user u, platform.role r
 WHERE (u.username = 'dev.maker' AND r.code = 'param_maker')
    OR (u.username = 'dev.checker' AND r.code = 'param_checker')
    OR (u.username = 'dev.firstlogin' AND r.code = 'param_maker')
    OR (u.username IN ('dev.cashmaker', 'dev.cashchecker') AND r.code = 'cash_admin')
ON CONFLICT DO NOTHING;

-- Determinisme e2e: suite integrasi berbagi DB dev yang sama dan sebagian (mis. `itapi_deposit`)
-- memberi `dev.maker` grant `platform_admin` untuk menguji jalur sukses. Grant itu tidak selalu
-- dikembalikan, sehingga maker bisa menyetujui dan seluruh menu tampil — gate e2e "maker tidak
-- boleh approve" lalu gagal karena sisa state, bukan karena kode. Buang **hanya** grant
-- `platform_admin` milik akun dev ini.
DELETE FROM platform.user_role ur
 USING platform.app_user u, platform.role r
 WHERE ur.user_id = u.user_id
   AND ur.role_id = r.role_id
   AND u.username IN ('dev.maker', 'dev.checker')
   AND r.code = 'platform_admin';
