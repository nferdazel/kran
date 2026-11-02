-- Akun dan aturan jurnal hapus buku (T-168).
--
-- Hapus buku menutup seluruh sisa piutang. Penyisihan yang sudah dibentuk (111, D-185) dipakai lebih
-- dulu; kekurangannya menjadi beban. Karena template jurnal Fase 1 memaksa **tepat satu debit dan
-- satu kredit** per jurnal, dua bagian itu dijurnal terpisah — bukan satu jurnal tiga baris:
--
--   LoanWriteOffProvisioned  D 111 PENYISIHAN KERUGIAN PIUTANG / K 110 PIUTANG PEMBIAYAAN
--   LoanWriteOffExpense      D 504 BEBAN HAPUS BUKU           / K 110 PIUTANG PEMBIAYAAN
--
-- Keduanya bernominal positif; bagian yang nol tidak dijurnal sama sekali. **NEEDS-COMPLIANCE-REVIEW**
-- — kode/nama akun `504` adalah usulan struktur pilot, bukan kutipan standar akuntansi (REG-011 `V!`).
INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|504')::uuid, '504', 'BEBAN HAPUS BUKU', 'EXPENSE', 'DEBIT', true, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|LoanWriteOffProvisioned')::uuid, 'LoanWriteOffProvisioned', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|LoanWriteOffExpense')::uuid, 'LoanWriteOffExpense', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|LoanWriteOffProvisioned')::uuid, 1, 'DEBIT', '111'),
  (md5('ledger.posting_rule|LoanWriteOffProvisioned')::uuid, 2, 'CREDIT', '110'),
  (md5('ledger.posting_rule|LoanWriteOffExpense')::uuid, 1, 'DEBIT', '504'),
  (md5('ledger.posting_rule|LoanWriteOffExpense')::uuid, 2, 'CREDIT', '110')
ON CONFLICT (rule_id, line_no) DO NOTHING;
