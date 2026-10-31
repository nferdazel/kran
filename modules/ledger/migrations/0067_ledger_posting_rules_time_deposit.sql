-- Rule posting pokok deposito berjangka (T-138d, D-152 + amendemen 28 Okt 2026).
--
-- Keputusan pemilik: pokok deposito berjangka masuk **202 SIMPANAN BERJANGKA**, bukan `201`
-- (yang tetap milik tabungan), supaya kewajiban deposito bisa dipisahkan di laporan. Saat jatuh
-- tempo, pokok + bunga pindah ke rekening simpanan anggota (`201`).
--
-- Dua rule lama (`DepositPosted` dari `0005`, `DepositWithdrawn` dari `0012`) tetap generik untuk
-- semua rekening non-deposito. Rule di bawah **berkondisi** `accountType = TIME_DEPOSIT`, jadi
-- `specificityOf` memilihnya untuk rekening berjangka (kondisi = kekhususan) tanpa mengubah
-- perilaku tabungan. Payload pemilihan rule berasal dari `postJournalSync`, yang sudah mengirim
-- `accountType` (`apps/api/src/deposit_posting.nim`).
--
-- Penarikan sebelum jatuh tempo **tidak** diblokir di sini dan tidak punya penalti: aturannya
-- produk/kebijakan dan belum diputuskan (dicatat di `docs/OPEN_ITEMS.md`). Yang dijaga rule ini
-- hanya agar saldo dan GL tidak pernah memakai akun yang berbeda dari kewajibannya.
--
-- NEEDS-COMPLIANCE-REVIEW: penomoran akun (`202`) adalah struktur pilot, bukan kutipan SAK/PSAK
-- (REG-011 `V!`). Idempoten: `ON CONFLICT DO NOTHING`.

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|DepositPosted|TIME_DEPOSIT')::uuid, 'DepositPosted', NULL,
   '{"accountType": "TIME_DEPOSIT"}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|DepositWithdrawn|TIME_DEPOSIT')::uuid, 'DepositWithdrawn', NULL,
   '{"accountType": "TIME_DEPOSIT"}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|DepositPosted|TIME_DEPOSIT')::uuid, 1, 'DEBIT', '101.2'),
  (md5('ledger.posting_rule|DepositPosted|TIME_DEPOSIT')::uuid, 2, 'CREDIT', '202'),
  (md5('ledger.posting_rule|DepositWithdrawn|TIME_DEPOSIT')::uuid, 1, 'DEBIT', '202'),
  (md5('ledger.posting_rule|DepositWithdrawn|TIME_DEPOSIT')::uuid, 2, 'CREDIT', '101.2')
ON CONFLICT (rule_id, line_no) DO NOTHING;
