-- Rule posting perpindahan jatuh tempo deposito berjangka (T-138d, D-155).
--
-- Keputusan pemilik (D-155) menentukan dua perpindahan yang belum punya rule:
--   ARO NONE                DepositMatured      : D 202 SIMPANAN BERJANGKA / K 201 SIMPANAN ANGGOTA
--   ARO PRINCIPAL_AND_INTEREST
--                           InterestCapitalized : D 204 BUNGA AKRUAL     / K 202 SIMPANAN BERJANGKA
--
-- Bunga yang dibayar ke rekening simpanan memakai `InterestPosted` (D 204 / K 201) yang sudah ada di
-- `0065`. Rule itu **tidak** diduplikasi di sini: dua rule untuk event yang sama akan membuat
-- `selectRule` ambigu saat kondisi sama-sama cocok, dan `buildLines` menolak ambiguitas itu.
--
-- Rule di bawah generik (tanpa `product_code` dan tanpa `conditions`), sama seperti `InterestAccrued`/
-- `InterestPosted`: perpindahannya ditentukan jenis rekening sumber pada saat task berjalan, bukan
-- atribut produk. `postRuleJournalSync` tetap mengirim payload produk/`accountType` sebagai konteks,
-- dan rule tanpa kondisi cocok untuk semua payload.
--
-- Pokok yang tidak keluar (ARO `PRINCIPAL`) tidak butuh rule: saldo rekening tidak berubah, jadi tidak
-- ada jurnal. Bunga nol juga tidak dijurnal — ledger menolak jurnal nol, dan task melewatinya.
--
-- NEEDS-COMPLIANCE-REVIEW: penomoran akun (`202`, `204`, `201`) adalah struktur pilot, bukan kutipan
-- SAK/PSAK (REG-011 `V!`, spec §4). Idempoten: `ON CONFLICT ... DO NOTHING`.

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|DepositMatured|generic')::uuid, 'DepositMatured', NULL,
   '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|InterestCapitalized|generic')::uuid, 'InterestCapitalized', NULL,
   '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|DepositMatured|generic')::uuid, 1, 'DEBIT', '202'),
  (md5('ledger.posting_rule|DepositMatured|generic')::uuid, 2, 'CREDIT', '201'),
  (md5('ledger.posting_rule|InterestCapitalized|generic')::uuid, 1, 'DEBIT', '204'),
  (md5('ledger.posting_rule|InterestCapitalized|generic')::uuid, 2, 'CREDIT', '202')
ON CONFLICT (rule_id, line_no) DO NOTHING;
