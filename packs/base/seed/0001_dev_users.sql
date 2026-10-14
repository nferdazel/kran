-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2, docs/OPEN_ITEMS.md).
--
-- Pengguna & role sintetis untuk pengembangan dan e2e Playwright. Password keduanya
-- `rahasia-panjang-123` (PBKDF2-HMAC-SHA256, 600.000 iterasi, sesuai parameter pack `base`).
-- Nilainya bukan rahasia: berkas ini terbuka di repo, dan siapa pun yang bisa menyentuh DB dev
-- memang sudah boleh masuk. Bootstrap user produksi (admin pertama, password awal, wajib ganti)
-- BELUM diputuskan — lihat OPEN_ITEMS "bootstrap user produksi".
--
-- Diterapkan hanya oleh `./task dbtools seed --dev`. Idempotent (ON CONFLICT DO NOTHING).

INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (md5('dev|platform.param.read')::uuid, 'platform.param.read', 'platform', 'param', 'read', 'perm.platform.param.read'),
  (md5('dev|platform.param.submit')::uuid, 'platform.param.submit', 'platform', 'param', 'submit', 'perm.platform.param.submit'),
  (md5('dev|platform.param.approve')::uuid, 'platform.param.approve', 'platform', 'param', 'approve', 'perm.platform.param.approve'),
  (md5('dev|platform.audit.read')::uuid, 'platform.audit.read', 'platform', 'audit', 'read', 'perm.platform.audit.read')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role (role_id, code, name_key, is_system)
VALUES
  (md5('dev|param_maker')::uuid, 'param_maker', 'role.param_maker', false),
  (md5('dev|param_checker')::uuid, 'param_checker', 'role.param_checker', false)
ON CONFLICT (code) DO NOTHING;

-- Maker: melihat parameter + mengajukan perubahan. Checker: melihat parameter + menyetujui.
-- Keduanya boleh membaca audit agar UI bisa menampilkan jejaknya. Tidak ada role_conflict antara
-- keduanya di sini: pemisahan tugas ditegakkan kolom `checker <> maker`, dan matriks SoD adalah
-- kebijakan institusi (tidak disemai di repo).
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE (r.code = 'param_maker' AND p.code IN ('platform.param.read', 'platform.param.submit', 'platform.audit.read'))
    OR (r.code = 'param_checker' AND p.code IN ('platform.param.read', 'platform.param.approve', 'platform.audit.read'))
ON CONFLICT DO NOTHING;

INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash)
VALUES
  (md5('dev|dev.maker')::uuid, 'dev.maker', 'Uji Maker (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$600000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$reBXlbgbT/2dqhhgelI8Gn697hjWLDrHDCPU5cNKQzo='),
  (md5('dev|dev.checker')::uuid, 'dev.checker', 'Uji Checker (dev)',
   'pbkdf2-hmac-sha256',
   'pbkdf2-hmac-sha256$600000$59q81bVw1VB6+/gqcNpKZjCSiHSKA7T77523I1MsHzE=$reBXlbgbT/2dqhhgelI8Gn697hjWLDrHDCPU5cNKQzo=')
ON CONFLICT (user_id) DO NOTHING;

-- Grant tanpa cabang (NULL) = berlaku di semua cabang, termasuk aksi tingkat institusi
-- (`authorize` dengan `targetBranch = ""`).
INSERT INTO platform.user_role (user_id, role_id, branch_id)
SELECT u.user_id, r.role_id, NULL
  FROM platform.app_user u, platform.role r
 WHERE (u.username = 'dev.maker' AND r.code = 'param_maker')
    OR (u.username = 'dev.checker' AND r.code = 'param_checker')
ON CONFLICT DO NOTHING;
