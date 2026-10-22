-- Posting rule transaksi simpanan (T-088b), idempoten.
--
-- Rule `DepositPosted` (D 101 KAS / K 201 SIMPANAN) sudah dibuat `0005_ledger_posting_rule_base.sql`
-- dan **dipakai ulang** untuk setor tunai — tidak diduplikasi di sini. Yang ditambahkan hanya sisi
-- kebalikannya untuk tarik tunai: `DepositWithdrawn` = D 201 / K 101 (uang keluar dari kas).
--
-- NEEDS-COMPLIANCE-REVIEW: mapping akun adalah **struktur pilot**, bukan kutipan SAK EP/PSAK
-- (REG-011 `V!`). Akun & rule final menunggu compliance/accounting owner (sama seperti `0005`).
--
-- Akun `101`/`201` sudah ada dari `0002_ledger_coa_base.sql`; rule berasal dari data, bukan literal
-- di kode (spec §10.5). Idempoten: `ON CONFLICT DO NOTHING` supaya aman dijalankan ulang.

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|DepositWithdrawn')::uuid, 'DepositWithdrawn', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|DepositWithdrawn')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|DepositWithdrawn')::uuid, 2, 'CREDIT', '101')
ON CONFLICT (rule_id, line_no) DO NOTHING;
