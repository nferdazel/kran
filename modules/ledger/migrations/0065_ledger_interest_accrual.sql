-- Akun & rule posting akrual bunga deposito berjangka (T-138b, D-152 + amendemen).
--
-- Alur yang diputuskan pemilik (D-152, amendemen 28 Okt 2026):
--   harian (EOD)  InterestAccrued : D 501 BEBAN BUNGA   / K 204 BUNGA AKRUAL
--   saat posting  InterestPosted  : D 204 BUNGA AKRUAL  / K 201 SIMPANAN ANGGOTA
--
-- `204`, bukan `203`: `203 TITIPAN PENGURUS` sudah ada sejak migrasi `0036`. Karena
-- `coa_account` punya UNIQUE (code) dan seed memakai `ON CONFLICT (code) DO NOTHING`, memakai
-- `203` akan **diam-diam** memakai akun yang salah tanpa galat apa pun.
--
-- Pokok deposito sendiri masuk `202 SIMPANAN BERJANGKA` (bukan `201`). Rule untuk itu **belum**
-- ada di sini: `DepositPosted` saat ini satu rule generik (K 201) untuk semua simpanan, dan
-- memisahkan per jenis rekening butuh kondisi `accountType` di payload event — pekerjaan T-138c.
-- Sampai itu mendarat, deposito berjangka belum boleh dibuka untuk anggota nyata.
--
-- NEEDS-COMPLIANCE-REVIEW: kode akun `204` dan penempatan beban di `501` adalah struktur pilot,
-- bukan kutipan SAK/PSAK (REG-011 `V!`, spec §4). Angka akrual (rate, basis hari, skala) tetap
-- parameter produk, bukan nilai di sini (D-137/O-084).
--
-- Idempoten: `ON CONFLICT ... DO NOTHING` supaya aman dijalankan ulang.

INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|204')::uuid, '204', 'BUNGA AKRUAL', 'LIABILITY', 'CREDIT', true, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|InterestAccrued|generic')::uuid, 'InterestAccrued', NULL,
   '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|InterestPosted|generic')::uuid, 'InterestPosted', NULL,
   '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|InterestAccrued|generic')::uuid, 1, 'DEBIT', '501'),
  (md5('ledger.posting_rule|InterestAccrued|generic')::uuid, 2, 'CREDIT', '204'),
  (md5('ledger.posting_rule|InterestPosted|generic')::uuid, 1, 'DEBIT', '204'),
  (md5('ledger.posting_rule|InterestPosted|generic')::uuid, 2, 'CREDIT', '201')
ON CONFLICT (rule_id, line_no) DO NOTHING;
