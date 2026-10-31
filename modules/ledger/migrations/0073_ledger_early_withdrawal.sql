-- Pencairan dini deposito berjangka: pendapatan denda + pembayaran bunga ke kas (T-146, D-164).
--
-- Akun `403 PENDAPATAN DENDA` **baru**: COA awal (`0002`) hanya punya `401` bunga dan `402`
-- provisi. Penalti pencairan dini bukan bunga dan bukan provisi, jadi menumpangkannya ke salah satu
-- akun itu akan salah klasifikasi di laporan pendapatan.
--
-- Dua rule, keduanya tanpa kondisi (hanya dipakai jalur pencairan dini):
--   InterestPaidEarly      : D 204 BUNGA AKRUAL / K 101.2 KAS
--   EarlyWithdrawalPenalty : D 101.2 KAS      / K 403 PENDAPATAN DENDA
--
-- Pokok memakai rule yang sudah ada: `DepositWithdrawn` berkondisi `TIME_DEPOSIT` (`0067`) —
-- D 202 SIMPANAN BERJANGKA / K 101.2. Tiga jurnal itu menghasilkan kas bersih
-- `−(pokok + bunga) + penalti`, yaitu jumlah yang benar-benar diserahkan ke anggota.
--
-- NEEDS-COMPLIANCE-REVIEW: kode akun `403` adalah struktur pilot, bukan kutipan SAK/PSAK
-- (REG-011 `V!`). Idempoten: `ON CONFLICT ... DO NOTHING`.

INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|403')::uuid, '403', 'PENDAPATAN DENDA', 'REVENUE', 'CREDIT', true, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|InterestPaidEarly|generic')::uuid, 'InterestPaidEarly', NULL,
   '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|EarlyWithdrawalPenalty|generic')::uuid, 'EarlyWithdrawalPenalty', NULL,
   '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|InterestPaidEarly|generic')::uuid, 1, 'DEBIT', '204'),
  (md5('ledger.posting_rule|InterestPaidEarly|generic')::uuid, 2, 'CREDIT', '101.2'),
  (md5('ledger.posting_rule|EarlyWithdrawalPenalty|generic')::uuid, 1, 'DEBIT', '101.2'),
  (md5('ledger.posting_rule|EarlyWithdrawalPenalty|generic')::uuid, 2, 'CREDIT', '403')
ON CONFLICT (rule_id, line_no) DO NOTHING;
