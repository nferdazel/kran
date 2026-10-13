-- 0006: identitas, akses, dan sesi (spec §9.2, §13, §18.2).
--
-- Deviasi yang disengaja dari daftar nama tabel spec §9.2 (lihat docs/DECISIONS.md D-013):
--   * `user` adalah kata kunci SQL (reserved) → tabel dinamai `platform.app_user` supaya tidak
--     perlu dikutip di setiap query.
--   * `permission`/`role`/`session` aman dipakai apa adanya.
-- Nama kolom & bentuk tabel tidak ada di spec (spec hanya menyebut nama tabel), jadi dipilih
-- di sini dan dicatat di MODULE.md.
--
-- Catatan desain:
--   * id user/role/permission/session dibuat aplikasi (UUIDv7 lewat kernel IdGen), bukan
--     `gen_random_uuid()`, supaya urut waktu seperti tabel lain.
--   * `user_role.branch_id` NULL = berlaku untuk semua cabang; berisi = hanya cabang itu.
--   * `role_conflict` = matriks SoD (spec §18.2). Tabelnya **sengaja tidak diisi** di repo:
--     pasangan yang dilarang adalah kebijakan institusi/compliance (OPEN_ITEMS O-001), bukan
--     tebakan pengembang.
--   * `session.token_hash` menyimpan SHA-256 dari token acak 256-bit — bukan PBKDF2: token
--     berentropi tinggi, jadi hash cepat sudah cukup (PBKDF2 hanya untuk password).
--   * Expand-only: hanya CREATE.

CREATE TABLE platform.app_user (
  user_id              uuid PRIMARY KEY,
  username             text NOT NULL,
  full_name            text NOT NULL,
  status               text NOT NULL DEFAULT 'ACTIVE',
  password_algo        text NOT NULL,
  password_hash        text NOT NULL,
  password_updated_at  timestamptz NOT NULL DEFAULT now(),
  must_change_password boolean NOT NULL DEFAULT false,
  failed_attempts      integer NOT NULL DEFAULT 0,
  locked_until         timestamptz,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT app_user_status_chk CHECK (status IN ('ACTIVE', 'INACTIVE', 'LOCKED', 'SUSPENDED')),
  CONSTRAINT app_user_username_chk CHECK (username = lower(username) AND length(btrim(username)) > 0),
  CONSTRAINT app_user_failed_chk CHECK (failed_attempts >= 0)
);

COMMENT ON TABLE platform.app_user IS
  'Pengguna sistem (spec §9.2 `user`). Username wajib lower-case; lockout dijaga kolom status + locked_until.';

CREATE UNIQUE INDEX app_user_username_uq ON platform.app_user (username);

CREATE TABLE platform.role (
  role_id    uuid PRIMARY KEY,
  code       text NOT NULL,
  name_key   text NOT NULL,
  is_system  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT role_code_chk CHECK (code = lower(code) AND length(btrim(code)) > 0)
);

CREATE UNIQUE INDEX role_code_uq ON platform.role (code);

CREATE TABLE platform.permission (
  permission_id   uuid PRIMARY KEY,
  code            text NOT NULL,
  module          text NOT NULL,
  resource        text NOT NULL,
  action          text NOT NULL,
  description_key text NOT NULL,
  CONSTRAINT permission_code_chk CHECK (code = module || '.' || resource || '.' || action)
);

CREATE UNIQUE INDEX permission_code_uq ON platform.permission (code);

CREATE TABLE platform.role_permission (
  role_id       uuid NOT NULL REFERENCES platform.role(role_id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES platform.permission(permission_id) ON DELETE CASCADE,
  granted_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE platform.user_role (
  user_id    uuid NOT NULL REFERENCES platform.app_user(user_id) ON DELETE CASCADE,
  role_id    uuid NOT NULL REFERENCES platform.role(role_id) ON DELETE CASCADE,
  branch_id  text,
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by uuid
);

CREATE UNIQUE INDEX user_role_uq
  ON platform.user_role (user_id, role_id, COALESCE(branch_id, ''));

CREATE TABLE platform.role_conflict (
  role_code_a text NOT NULL REFERENCES platform.role(code) ON DELETE CASCADE,
  role_code_b text NOT NULL REFERENCES platform.role(code) ON DELETE CASCADE,
  reason_key  text NOT NULL,
  PRIMARY KEY (role_code_a, role_code_b),
  CONSTRAINT role_conflict_order_chk CHECK (role_code_a < role_code_b)
);

COMMENT ON TABLE platform.role_conflict IS
  'Matriks pemisahan tugas (SoD, spec §18.2): pasangan role yang tidak boleh dipegang satu orang. Pasangan kanonik satu arah (a < b). Isi matriks = kebijakan institusi, tidak disemai di repo.';

CREATE TABLE platform.session (
  session_id          uuid PRIMARY KEY,
  user_id             uuid NOT NULL REFERENCES platform.app_user(user_id) ON DELETE CASCADE,
  token_hash          text NOT NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  last_seen_at        timestamptz NOT NULL DEFAULT now(),
  expires_at          timestamptz NOT NULL,
  absolute_expires_at timestamptz NOT NULL,
  revoked_at          timestamptz,
  revoked_reason      text,
  ip                  text,
  device              text,
  correlation_id      text,
  CONSTRAINT session_expiry_chk CHECK (absolute_expires_at >= expires_at)
);

CREATE UNIQUE INDEX session_token_uq ON platform.session (token_hash);
CREATE INDEX session_user_active_idx ON platform.session (user_id) WHERE revoked_at IS NULL;
