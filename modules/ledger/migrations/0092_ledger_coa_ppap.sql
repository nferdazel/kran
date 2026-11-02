-- Akun dan aturan jurnal penyisihan piutang (PPAP/CKPN, T-167).
--
--   503 BEBAN PENYISIHAN PIUTANG   (EXPENSE, postable)  → bertambah saat menyisihkan
--   111 PENYISIHAN KERUGIAN PIUTANG (ASSET, postable)   → dikredit; saldo kreditnya mengurangi
--                                                         piutang 110 di neraca
--
-- **Kenapa 111 bertipe ASSET dengan `normal_side` DEBIT.** Invarian `coa_normal_side_chk` mengunci
-- `ASSET → DEBIT`, dan **O-075** melarang memaksa akun kontra menjadi `LIABILITY`. Akun ini karena
-- itu dikredit meski bertipe aset: di neraca, saldo 111 tampil negatif dan piutang neto jadi benar
-- (110 debit + 111 kredit). Presentasi itulah bentuk akun kontra; tipe akun kontra yang resmi tetap
-- menunggu keputusan O-075/REG-011. **NEEDS-COMPLIANCE-REVIEW** — nama, kode, dan posisi akun adalah
-- usulan struktur pilot, bukan kutipan standar akuntansi.
INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|111')::uuid, '111', 'PENYISIHAN KERUGIAN PIUTANG', 'ASSET', 'DEBIT', true,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|503')::uuid, '503', 'BEBAN PENYISIHAN PIUTANG', 'EXPENSE', 'DEBIT', true,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

-- Dua rule dengan arah berlawanan. Selisih negatif **tidak** dijurnal sebagai nominal negatif:
-- jurnal pembalik adalah bentuk yang bisa diaudit (spec §9.1(3)), nominal negatif bukan.
INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|PpapProvisioned')::uuid, 'PpapProvisioned', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|PpapReleased')::uuid, 'PpapReleased', NULL, '{}'::jsonb, 100,
   'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|PpapProvisioned')::uuid, 1, 'DEBIT', '503'),
  (md5('ledger.posting_rule|PpapProvisioned')::uuid, 2, 'CREDIT', '111'),
  (md5('ledger.posting_rule|PpapReleased')::uuid, 1, 'DEBIT', '111'),
  (md5('ledger.posting_rule|PpapReleased')::uuid, 2, 'CREDIT', '503')
ON CONFLICT (rule_id, line_no) DO NOTHING;
