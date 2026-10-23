-- Posting rule pemindahbukuan simpanan (T-088c), idempoten.
--
-- Rule `DepositTransferred` = D 201 SIMPANAN / K 201 SIMPANAN. Kedua sisi GL memakai akun **yang
-- sama** (kewajiban simpanan), sehingga jurnal ini **net-nol di buku besar** (D = K pada akun 201);
-- yang berpindah adalah kewajiban terhadap dua pemilik rekening berbeda. Perpindahan **per
-- rekening** dicatat di `deposit.transfer` (sumber & tujuan), bukan di GL — relevan untuk
-- rekonsiliasi Fase 3 (T-101). Batas ini dicatat di `MODULE.md` + `docs/ACCEPTED-LIMITS.md`.
--
-- NEEDS-COMPLIANCE-REVIEW: mapping akun adalah **struktur pilot**, bukan kutipan SAK EP/PSAK
-- (REG-011 `V!`). Akun & rule final menunggu compliance/accounting owner (sama seperti `0005`).
--
-- Akun `201` sudah ada dari `0002_ledger_coa_base.sql`; rule dari data, bukan literal di kode
-- (spec §10.5). Idempoten: `ON CONFLICT DO NOTHING` supaya aman dijalankan ulang.

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|DepositTransferred')::uuid, 'DepositTransferred', NULL, '{}'::jsonb,
   100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|DepositTransferred')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|DepositTransferred')::uuid, 2, 'CREDIT', '201')
ON CONFLICT (rule_id, line_no) DO NOTHING;
