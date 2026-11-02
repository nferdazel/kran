-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2).
--
-- Fixture e2e layar pinjaman (T-170): satu akun dev yang memegang peran `lending_maker`, dan satu
-- versi produk pinjaman `ACTIVE` yang bisa dipakai mengajukan akad.
--
-- Kenapa akun dan produk, bukan pinjaman jadi: pinjaman dibuat lewat API setiap run (submit →
-- approve → disburse) supaya layar diuji atas data yang benar-benar dilewatkan jalur tulis, bukan
-- baris yang dikarang untuk tampilan. Produk pinjaman **tidak** punya rute API (katalog pinjaman
-- belum ada), jadi versinya harus datang dari seed.
--
-- Akun terpisah (`dev.loans`), bukan menambah izin ke `param_maker`/`param_checker`: fixture itu
-- dipakai spec teller/palet, dan menambah tautan navigasi di sana akan mengubah asersi yang tidak
-- ada hubungannya dengan pinjaman.
--
-- Idempoten: user `ON CONFLICT DO UPDATE` (menyetel ulang sandi seperti `0001`), grant dan produk
-- `DO NOTHING`.

INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                               must_change_password)
SELECT md5('dev|dev.loans')::uuid, 'dev.loans', 'Uji Petugas Pinjaman (dev)',
       password_algo, password_hash, false
  FROM platform.app_user WHERE username = 'dev.maker'
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
 WHERE u.username = 'dev.loans'
   AND r.code = 'lending_maker'
ON CONFLICT DO NOTHING;

INSERT INTO lending.loan_product (product_id, code, name, created_by)
VALUES (md5('dev|lending-product')::uuid, 'LNE2E', 'Pinjaman E2E (dev)',
        md5('dev|dev.maker')::uuid)
ON CONFLICT DO NOTHING;

-- Versi langsung ACTIVE dengan penyetuju berbeda dari pembuat, memenuhi CHECK empat mata. Angka
-- rate/tenor adalah fixture uji, bukan nilai bisnis: nilai produksi datang dari versi produk yang
-- disusun operator lewat katalog (belum ada UI-nya).
INSERT INTO lending.loan_product_version
  (version_id, product_id, version_no, status, schedule_method, tenor_months, annual_rate,
   allocation_order, created_by, approved_at, approved_by)
VALUES
  (md5('dev|lending-product-version')::uuid, md5('dev|lending-product')::uuid, 1, 'ACTIVE',
   'ANNUITY', 12, 150000, 'INTEREST,PRINCIPAL,PENALTY', md5('dev|dev.maker')::uuid, now(),
   md5('dev|dev.checker')::uuid)
ON CONFLICT DO NOTHING;
