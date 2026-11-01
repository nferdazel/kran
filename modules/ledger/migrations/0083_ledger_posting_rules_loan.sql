-- Aturan jurnal pencairan pinjaman (T-164).
--
-- Angka akun di sini **data**, bukan konstanta kode (spec §10.5): perubahan pemetaan GL cukup
-- lewat baris `ledger.posting_rule*`, tanpa deploy. Nilainya memakai COA dasar yang sudah ada:
--
--   110 PIUTANG PEMBIAYAAN   (ASSET, postable)  → bertambah sebesar pokok yang dicairkan
--   201 SIMPANAN ANGGOTA     (LIABILITY, postable) → bertambah di rekening anggota penerima
--
-- **NEEDS-COMPLIANCE-REVIEW**: pemetaan akun 110 untuk pinjaman konvensional belum ditinjau
-- compliance (COA dasar disusun sebelum modul `lending` ada). Strukturnya sengaja lewat rule supaya
-- akun final bisa diganti tanpa migrasi.
INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|LoanDisbursed')::uuid, 'LoanDisbursed', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|LoanDisbursed')::uuid, 1, 'DEBIT', '110'),
  (md5('ledger.posting_rule|LoanDisbursed')::uuid, 2, 'CREDIT', '201')
ON CONFLICT (rule_id, line_no) DO NOTHING;

-- Pencairan yang **batal**/dikoreksi memakai jurnal pembalik (spec §9.1(3)), bukan rule lain.
COMMENT ON TABLE ledger.posting_rule IS
  'Aturan jurnal per event. `LoanDisbursed` (T-164): D 110 Piutang Pembiayaan / K 201 Simpanan '
  'Anggota — nilai akun adalah data yang bisa diganti, bukan konstanta kode.';
