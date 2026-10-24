-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2).
--
-- Fixture minimum untuk e2e teller (T-109): vault cabang uji + izin yang dibutuhkan alur
-- buka sesi → setor → tutup. Party/produk/rekening sengaja **tidak** di sini: e2e membuatnya
-- lewat API pada cabang `e2e00000-0000-4000-8000-000000000001` supaya setiap run memakai data
-- baru (tidak menumpuk rekening di seed).
--
-- Idempoten: grant `ON CONFLICT DO NOTHING`, vault `DO NOTHING` (jangan menimpa saldo yang sudah
-- dipakai run sebelumnya).
--
-- Pemisahan izin penting: `param_maker` hanya membuat (party/produk/rekening/transaksi), sedangkan
-- `product.catalog.approve` tetap milik `param_checker`. Memberi approve ke maker membuat uji e2e
-- "maker tidak boleh menyetujui" gagal, dan melanggar pemisahan tugas.

-- Bersihkan grant berlebih dari versi seed sebelumnya (dev saja), lalu beri ulang yang benar.
DELETE FROM platform.role_permission rp
 USING platform.role r, platform.permission p
 WHERE rp.role_id = r.role_id
   AND rp.permission_id = p.permission_id
   AND (
     (r.code IN ('param_maker', 'param_checker')
       AND p.code IN (
         'party.party.create', 'party.party.read',
         'product.catalog.read', 'product.catalog.manage', 'product.catalog.approve',
         'deposit.account.manage', 'deposit.account.read',
         'teller.transaction.post',
         'teller.session.open', 'teller.session.close', 'teller.session.read',
         'teller.vault.topup', 'teller.vault.read'
       ))
   );

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'param_maker'
   AND p.code IN (
     'party.party.create', 'party.party.read',
     'product.catalog.read', 'product.catalog.manage',
     'deposit.account.manage', 'deposit.account.read',
     'teller.transaction.post',
     'teller.session.open', 'teller.session.close', 'teller.session.read'
   )
ON CONFLICT DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'param_checker'
   AND p.code IN ('product.catalog.read', 'product.catalog.approve')
ON CONFLICT DO NOTHING;

-- Vault cabang e2e. Float awal e2e kecil (1000), jadi saldo ini cukup untuk ratusan run dan
-- tidak perlu top-up (T-107 belum ada).
INSERT INTO teller.vault (branch_id, balance)
VALUES ('e2e00000-0000-4000-8000-000000000001', '1000000.00')
ON CONFLICT (branch_id) DO NOTHING;
