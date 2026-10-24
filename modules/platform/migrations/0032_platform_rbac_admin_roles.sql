-- Peran admin sempit + pasangan SoD (T-118, keputusan pemilik K-1(b)/K-2(a)).
--
-- Sampai `0029` hanya `platform_admin` yang memegang seluruh izin (maker+checker parameter &
-- produk, kas/vault, buku besar, registrasi, dan administrasi pengguna) sehingga pemisahan tugas
-- (SoD) tidak bisa ditegakkan di produksi: memasangkan konflik ke `platform_admin` akan membuat
-- peran wildcard itu sendiri tidak bisa dipakai (memo T-118 §3). Jalan keluarnya adalah **memecah**
-- admin menjadi peran operasional sempit, lalu menyemai pasangan konflik antar peran sempit itu.
--
-- K-1(b): semai pasangan *wajib* **dan** *nice to have*. K-2(a): pecah admin dan hentikan pemakaian
-- harian `platform_admin`.
--
-- **`platform_admin` tetap ada sebagai break-glass**, bukan peran harian: jalur override
-- operasi-ganda (maker=checker) untuk operator cadangan dipakai hanya bila staf kurang dari yang
-- dibutuhkan SoD, wajib beralasan dan diaudit, dan dilaporkan ke pengurus (memo T-118 §3). Peran
-- ini sengaja **tidak** dipasangkan konflik: memasangkannya akan melumpuhkan break-glass itu
-- sendiri (proposal T-118 §3). Izinnya tidak diubah di sini.
--
-- Struktural (kode izin & matriks SoD terikat kode program), jadi tempatnya di migrasi seperti
-- 0008/0020/0022-0031, bukan parameter institusi. Idempotent: `ON CONFLICT DO NOTHING`.

INSERT INTO platform.role (role_id, code, name_key, is_system)
VALUES
  (gen_random_uuid(), 'ops_admin', 'role.ops_admin', false),
  (gen_random_uuid(), 'ledger_admin', 'role.ledger_admin', false),
  (gen_random_uuid(), 'cash_admin', 'role.cash_admin', false),
  (gen_random_uuid(), 'product_maker', 'role.product_maker', false)
ON CONFLICT (code) DO NOTHING;

-- Semua peran di atas INSTITUTION (default kolom `scope`, 0028): tugasnya lintas cabang, bukan laci
-- satu cabang. `teller` tetap satu-satunya peran BRANCH.

-- Grant eksplisit (pola 0008/0022-0031): daftar kode izin ditulis apa adanya, **bukan** "semua baris
-- `platform.permission`" — izin yang ditambahkan kemudian tidak boleh ikut diam-diam.
--
-- `ops_admin` = administrasi akun/anggota/rekening (pengganti harian `platform_admin` untuk
-- pengelolaan pengguna). Baca-only pada buku besar/vault: melihat tanpa membukukan.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'ops_admin'
   AND p.code IN ('platform.user.manage', 'platform.param.read', 'platform.audit.read',
                  'party.party.read', 'party.party.create', 'deposit.account.manage',
                  'deposit.account.read', 'product.catalog.read', 'ledger.coa.read',
                  'ledger.period.read', 'teller.vault.read')
ON CONFLICT DO NOTHING;

-- `ledger_admin` = pembukuan, periode, COA, dan pembalik jurnal. Tanpa hak kas/vault: yang
-- membukukan tidak boleh menjadi yang menyuntik kas (pasangan `ledger_admin`/`cash_admin` di bawah).
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'ledger_admin'
   AND p.code IN ('ledger.coa.manage', 'ledger.period.manage', 'ledger.journal.read',
                  'ledger.journal.reverse', 'product.catalog.manage', 'platform.param.read')
ON CONFLICT DO NOTHING;

-- `cash_admin` = penyediaan kas/vault cabang (injeksi operasional). Hanya itu — tidak menyentuh
-- buku besar maupun sesi laci (`teller`).
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'cash_admin'
   AND p.code IN ('teller.vault.topup', 'teller.vault.read')
ON CONFLICT DO NOTHING;

-- `product_maker` = pengaju katalog produk (pasangan checker-nya `product_checker`, 0027).
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'product_maker'
   AND p.code IN ('product.catalog.manage', 'product.catalog.read')
ON CONFLICT DO NOTHING;

-- Pasangan SoD (kanonik `role_code_a < role_code_b`, CHECK di 0006). Penugasan yang melahirkan
-- salah satu pasangan ini ditolak `grantRole`; bila konflik tetap ada di data, `authorize` menolak
-- semua aksi (fail-closed, spec §18.2).
--
-- Wajib: `product_checker`/`product_maker` (maker-checker katalog) dan `cash_admin`/`ledger_admin`
-- (yang membukukan tidak mengendalikan injeksi kas). Nice to have (K-1(b)): `ledger_admin`/`ops_admin`,
-- `ledger_admin`/`teller`, `cash_admin`/`teller` — efeknya hanya "satu orang tidak boleh memegang
-- keduanya", bukan larangan operasional.
INSERT INTO platform.role_conflict (role_code_a, role_code_b, reason_key)
VALUES
  ('product_checker', 'product_maker', 'sod.product.maker_checker'),
  ('cash_admin', 'ledger_admin', 'sod.cash.ledger'),
  ('ledger_admin', 'ops_admin', 'sod.ledger.ops'),
  ('ledger_admin', 'teller', 'sod.ledger.teller'),
  ('cash_admin', 'teller', 'sod.cash.teller')
ON CONFLICT (role_code_a, role_code_b) DO NOTHING;
