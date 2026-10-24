-- Rahasia TOTP wajib berupa ciphertext field crypto (T-129/DB-3, D-063/D-069).
--
-- **Konteks.** `platform.user_mfa.secret_enc` (0012) hanya `text NOT NULL`; kolom PII lain dijaga
-- `CHECK` bentuk ciphertext, kolom ini tidak. Satu jalur tulis yang lupa memanggil enkripsi akan
-- menyimpan secret TOTP plaintext tanpa protes dari DB — dan itu berarti faktor kedua bisa dicuri
-- dengan satu `SELECT`.
--
-- **Bentuk.** `shared/platform-lib/crypto/fieldcrypto.nim` menulis `kran:enc:v1:<kid>:<nonce>:
-- <ciphertext||tag>`; prefiks `kran:enc:v1:` adalah yang bisa diperiksa SQL. Properti selebihnya
-- (kid ada di ring, tag valid) tetap urusan aplikasi saat dekripsi.
--
-- **Expand-only.** `NOT VALID` lalu `VALIDATE`: deploy tidak memindai tabel saat menambah
-- constraint. Produksi sudah diperiksa 24 Okt 2026 (0 baris `user_mfa`), jadi validasi tidak akan
-- menemukan baris lama.
--
-- Idempoten: constraint hanya ditambahkan bila belum ada.

DO $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
       WHERE conname = 'user_mfa_secret_enc_chk'
         AND conrelid = 'platform.user_mfa'::regclass) THEN
    ALTER TABLE platform.user_mfa
      ADD CONSTRAINT user_mfa_secret_enc_chk
      CHECK (secret_enc LIKE 'kran:enc:v1:%') NOT VALID;
  END IF;
END
$$;

ALTER TABLE platform.user_mfa VALIDATE CONSTRAINT user_mfa_secret_enc_chk;
