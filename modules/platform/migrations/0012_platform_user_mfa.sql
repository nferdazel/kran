-- 0012: MFA TOTP per akun (T-046, spec §13/§18.2). Expand-only: hanya CREATE.
--
-- Bentuk & alasan (D-063):
--   * Satu baris per akun (`user_id` = PK). `secret_enc` = ciphertext field crypto T-054 dengan
--     AAD = nama tabel `user_mfa`; rahasia TOTP **tidak pernah** disimpan plaintext.
--   * `digits`/`period_seconds` disimpan per baris (pola `password_algo`/`password_hash`):
--     mengubah parameter hanya memengaruhi pendaftaran baru, tidak membatalkan rahasia yang
--     sudah terdaftar (kalau dibaca dari parameter saat verifikasi, kode lama diam-diam berhenti
--     cocok).
--   * `last_used_step` = langkah waktu terakhir yang berhasil dipakai (anti-replay RFC 6238 §5.2).
--   * `status`: PENDING = rahasia sudah dibuat, belum dikonfirmasi kode; ACTIVE = terkonfirmasi.
--     Tidak ada status DISABLED: penonaktifan/penghapusan belum punya alur (open item O-071).
--   * Tidak ada kolom kode pemulihan (belum ada alur aktivasi login, D-046 butir 9).
--
-- Tabel belum dipakai jalur login: alur login tidak berubah pada task ini.

CREATE TABLE platform.user_mfa (
  user_id        uuid PRIMARY KEY REFERENCES platform.app_user(user_id) ON DELETE CASCADE,
  method         text NOT NULL DEFAULT 'TOTP',
  status         text NOT NULL,
  secret_enc     text NOT NULL,
  digits         integer NOT NULL,
  period_seconds integer NOT NULL,
  last_used_step bigint,
  confirmed_at   timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_mfa_method_chk CHECK (method IN ('TOTP')),
  CONSTRAINT user_mfa_status_chk CHECK (status IN ('PENDING', 'ACTIVE')),
  CONSTRAINT user_mfa_digits_chk CHECK (digits BETWEEN 6 AND 10),
  CONSTRAINT user_mfa_period_chk CHECK (period_seconds BETWEEN 15 AND 300),
  CONSTRAINT user_mfa_active_confirmed_chk CHECK (status <> 'ACTIVE' OR confirmed_at IS NOT NULL)
);

COMMENT ON TABLE platform.user_mfa IS
  'Faktor kedua TOTP per akun (spec §13). secret_enc = ciphertext field crypto (AAD user_mfa); '
  'digits/period disimpan per baris supaya perubahan parameter tidak membatalkan rahasia lama.';

COMMENT ON COLUMN platform.user_mfa.last_used_step IS
  'Langkah waktu TOTP terakhir yang berhasil dipakai; kode dengan langkah <= nilai ini ditolak (anti-replay).';
