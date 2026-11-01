-- Aturan jurnal pembayaran angsuran (T-165) dan akun pendapatan denda.
--
-- Pembayaran dari rekening simpanan anggota: saldo simpanan turun (D 201), lawannya tergantung
-- komponen yang dibayar. Satu rule per komponen karena `posting_rule` memakai **satu nominal** per
-- jurnal — komponen yang nol tidak menghasilkan jurnal nol, dan komponen yang bukan nol tidak
-- boleh menumpang jurnal komponen lain (laporan pendapatan bunga jadi salah kalau pokok ikut).
--
--   110 PIUTANG PEMBIAYAAN   (ASSET, postable)   ← pokok yang dibayar
--   401 PENDAPATAN BUNGA     (REVENUE, postable) ← bunga yang dibayar
--   403 PENDAPATAN DENDA     (REVENUE, postable) ← denda yang dibayar
--
-- Akun 403 baru: COA dasar dibuat sebelum modul `lending` ada, dan menumpangkan denda ke 401 akan
-- membuat "pendapatan bunga" memuat denda. **NEEDS-COMPLIANCE-REVIEW** — nama/kode akun ini contoh
-- struktur pilot, bukan kutipan standar akuntansi (REG-011 `V!`).
INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|403')::uuid, '403', 'PENDAPATAN DENDA', 'REVENUE', 'CREDIT', true, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|LoanPrincipalPaid')::uuid, 'LoanPrincipalPaid', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|LoanInterestPaid')::uuid, 'LoanInterestPaid', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|LoanPenaltyPaid')::uuid, 'LoanPenaltyPaid', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|LoanPrincipalPaid')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|LoanPrincipalPaid')::uuid, 2, 'CREDIT', '110'),
  (md5('ledger.posting_rule|LoanInterestPaid')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|LoanInterestPaid')::uuid, 2, 'CREDIT', '401'),
  (md5('ledger.posting_rule|LoanPenaltyPaid')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|LoanPenaltyPaid')::uuid, 2, 'CREDIT', '403')
ON CONFLICT (rule_id, line_no) DO NOTHING;
