-- 0100: penanda "sesi belum melewati faktor kedua" (O-071, spec §13). Expand-only: ADD COLUMN.
--
-- Alasan: saat `platform.security.mfa.require_login` aktif, login akun yang punya faktor TOTP
-- `ACTIVE` hanya boleh menghasilkan sesi **setengah**. Cookie tetap terbit (supaya rute
-- verifikasi bisa dipanggil dengan sesi itu), tetapi `requirePrincipal` menolak semua rute lain
-- sampai kode benar. Tanpa penanda di DB, "sesi penuh" dan "sesi menunggu faktor kedua" tidak
-- bisa dibedakan setelah login — dan membedakannya di memori proses berarti hilang saat restart.
--
-- Default `false` = sesi yang lahir saat kebijakan mati (dan sesi lama dari sebelum kolom ini
-- ada) tetap sesi penuh. Baris sesi tidak pernah "naik" status kecuali lewat verifikasi kode.

ALTER TABLE platform.session ADD COLUMN mfa_pending boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN platform.session.mfa_pending IS
  'true = kata sandi benar tetapi faktor kedua belum diverifikasi; sesi hanya boleh dipakai untuk '
  'memverifikasi kode (POST /api/v1/auth/mfa/challenge).';
