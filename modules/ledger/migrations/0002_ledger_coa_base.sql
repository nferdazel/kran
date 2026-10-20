-- COA awal pack `base` untuk modul `ledger` (T-072, spec §4.3 "COA template").
--
-- NEEDS-COMPLIANCE-REVIEW: kode/nama akun di bawah adalah **contoh struktur** untuk pilot, bukan
-- kutipan SAK EP/PSAK (REG-011 bertanda V! di spec §4 — belum diverifikasi compliance owner).
-- Jangan jadikan dasar laporan keuangan final sebelum review itu.
--
-- Ditaruh di migrasi (bukan `packs/*/seed/`) karena direktori seed pack hanya diterapkan dengan
-- `--dev`; produksi harus mendapatkannya lewat jalur migrasi (lihat O-066 dan `docs/tasks/T-072.md`).
--
-- Idempoten: `ON CONFLICT (code) DO NOTHING` — aman bila migrasi dijalankan ulang pada DB uji yang
-- schema-nya dibuat ulang, dan tidak menimpa akun yang sudah diubah institusi.

INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|1')::uuid,   '1',   'ASET',                    'ASSET',     'DEBIT',  false, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|101')::uuid, '101', 'KAS',                     'ASSET',     'DEBIT',  true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|102')::uuid, '102', 'BANK',                    'ASSET',     'DEBIT',  true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|110')::uuid, '110', 'PIUTANG PEMBIAYAAN',      'ASSET',     'DEBIT',  true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|2')::uuid,   '2',   'KEWAJIBAN',               'LIABILITY', 'CREDIT', false, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|201')::uuid, '201', 'SIMPANAN ANGGOTA',        'LIABILITY', 'CREDIT', true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|202')::uuid, '202', 'SIMPANAN BERJANGKA',      'LIABILITY', 'CREDIT', true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|3')::uuid,   '3',   'EKUITAS',                 'EQUITY',    'CREDIT', false, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|301')::uuid, '301', 'MODAL ANGGOTA',           'EQUITY',    'CREDIT', true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|4')::uuid,   '4',   'PENDAPATAN',              'REVENUE',   'CREDIT', false, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|401')::uuid, '401', 'PENDAPATAN BUNGA',        'REVENUE',   'CREDIT', true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|402')::uuid, '402', 'PENDAPATAN PROVISI',      'REVENUE',   'CREDIT', true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|5')::uuid,   '5',   'BEBAN',                   'EXPENSE',   'DEBIT',  false, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|501')::uuid, '501', 'BEBAN BUNGA',             'EXPENSE',   'DEBIT',  true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|502')::uuid, '502', 'BEBAN OPERASIONAL',       'EXPENSE',   'DEBIT',  true,  'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;
