-- Saldo awal vault kas: akun titipan pengurus + posting rule (T-118/O-105, D-134).
--
-- **Konteks.** Vault pilot dibentuk lewat SQL seed `10.000.000` (D-129) tanpa jurnal, sehingga
-- `teller.vault` tidak bisa direkonsiliasi dengan buku besar (O-105). Karena jurnal immutable dan
-- `101` (induk) non-postable sejak `ledger/0033`, koreksinya hanya bisa berupa **jurnal baru** yang
-- mendebit `101.1 KAS DI VAULT` dan mengkredit akun sumber dana.
--
-- **Keputusan pemilik (didelegasikan, D-134):** sumber dana diperlakukan sebagai **kewajiban**
-- (titipan pengurus), bukan ekuitas. Alasan: uang pilot disediakan pemilik/pengurus dan belum ada
-- pernyataan setoran modal; liabilitas tidak memberikan hak SHU dan bisa diklasifikasi ulang ke
-- ekuitas lewat jurnal baru bila pemilik menyatakannya sebagai modal. `NEEDS-COMPLIANCE-REVIEW`:
-- klasifikasi akhir (ekuitas vs liabilitas) menunggu accounting/compliance owner.
--
-- **Migrasi ini hanya menyiapkan struktur** (akun + rule). Jurnalnya sendiri diposting sekali lewat
-- `ctl post-opening-balance` (teraudit, idempoten) saat periode tanggal bisnis OPEN — bukan di
-- migrasi, karena jurnal butuh periode OPEN yang tidak ada di setiap lingkungan saat migrasi jalan.
--
-- Idempoten: `ON CONFLICT` pada akun, rule, dan baris rule.

INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|203')::uuid, '203', 'TITIPAN PENGURUS', 'LIABILITY', 'CREDIT', true, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|LedgerCashOpening')::uuid, 'LedgerCashOpening', NULL, '{}'::jsonb,
   100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|LedgerCashOpening')::uuid, 1, 'DEBIT', '101.1'),
  (md5('ledger.posting_rule|LedgerCashOpening')::uuid, 2, 'CREDIT', '203')
ON CONFLICT (rule_id, line_no) DO NOTHING;
