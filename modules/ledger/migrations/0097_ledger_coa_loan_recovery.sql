-- Akun dan aturan jurnal pemulihan pasca hapus buku (O-122, T-176).
--
-- Setelah hapus buku, piutang (`110`) sudah tidak ada di neraca: seluruh sisa kewajiban sudah
-- dibebankan (lihat `0095_ledger_coa_writeoff.sql`). Karena itu uang yang masuk belakangan **bukan**
-- pengurangan piutang, melainkan pendapatan. Satu rule per komponen, sama seperti pembayaran
-- angsuran, supaya laporan pendapatan bunga/denda tidak tercampur:
--
--   LoanRecoveryPrincipal  D 201 SIMPANAN (kewajiban) / K 409 PENDAPATAN LAIN-LAIN
--   LoanRecoveryInterest   D 201                      / K 401 PENDAPATAN BUNGA
--   LoanRecoveryPenalty    D 201                      / K 403 PENDAPATAN DENDA
--
-- **NEEDS-COMPLIANCE-REVIEW** — kode/nama akun `409` adalah usulan struktur pilot, bukan kutipan
-- standar akuntansi (REG-011 `V!`). Alternatif yang sah secara akuntansi adalah mengkredit `504`
-- (pengembalian beban hapus buku); keputusan pemilik dicatat di D-191.
-- **HUMAN-REVIEW-REQUIRED** — jalur uang: perubahan akun di sini mengubah laporan laba rugi.
INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|409')::uuid, '409', 'PENDAPATAN LAIN-LAIN', 'REVENUE', 'CREDIT', true, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|LoanRecoveryPrincipal')::uuid, 'LoanRecoveryPrincipal', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|LoanRecoveryInterest')::uuid, 'LoanRecoveryInterest', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|LoanRecoveryPenalty')::uuid, 'LoanRecoveryPenalty', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|LoanRecoveryPrincipal')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|LoanRecoveryPrincipal')::uuid, 2, 'CREDIT', '409'),
  (md5('ledger.posting_rule|LoanRecoveryInterest')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|LoanRecoveryInterest')::uuid, 2, 'CREDIT', '401'),
  (md5('ledger.posting_rule|LoanRecoveryPenalty')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|LoanRecoveryPenalty')::uuid, 2, 'CREDIT', '403')
ON CONFLICT (rule_id, line_no) DO NOTHING;
