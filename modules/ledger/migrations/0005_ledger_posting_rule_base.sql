-- Posting rule awal (T-074), idempoten.
--
-- NEEDS-COMPLIANCE-REVIEW: mapping di bawah adalah **contoh struktur** untuk pilot, bukan kutipan
-- SAK EP/PSAK (REG-011 `V!`). Akun & rule final menunggu compliance/accounting owner.
--
-- Ditaruh di migrasi (bukan `packs/*/seed/`) karena seed pack hanya diterapkan `dbtools seed --dev`
-- sehingga produksi tidak akan menerimanya (sama seperti COA T-072, lihat O-066).

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|DepositPosted')::uuid, 'DepositPosted', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|FeeCharged')::uuid, 'FeeCharged', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|DepositPosted')::uuid, 1, 'DEBIT', '101'),
  (md5('ledger.posting_rule|DepositPosted')::uuid, 2, 'CREDIT', '201'),
  (md5('ledger.posting_rule|FeeCharged')::uuid, 1, 'DEBIT', '101'),
  (md5('ledger.posting_rule|FeeCharged')::uuid, 2, 'CREDIT', '402')
ON CONFLICT (rule_id, line_no) DO NOTHING;
