-- Jurnal kas teller: buka/tutup sesi dan selisih kas (T-118, O-097 opsi A).
--
-- Sebelum ini saldo `teller.vault` dan kas di laci tidak punya jejak di buku besar, sehingga kas
-- pilot tidak bisa direkonsiliasi ke `ledger.journal_line`. Migrasi ini menyiapkan **posting rule**
-- untuk empat kejadian; handler sesi mempostingnya sinkron di transaksi yang sama dengan mutasi
-- vault (`postRuleJournalSync`), sama seperti transaksi tunai deposit.
--
-- NEEDS-COMPLIANCE-REVIEW (REG-011, spec §4 `V!`): pemetaan akun adalah usulan pilot dari memo
-- T-118 §5, bukan kutipan SAK EP/PSAK.
--
-- Arah jurnal (lihat memo T-118 §5; deviasi sadar pada kaki selisih, dicatat di MODULE.md):
--   * `TellerSessionOpened`  : D 101.2 KAS DI TELLER / K 101.1 KAS DI VAULT (float pindah ke laci)
--   * `TellerSessionClosed`  : D 101.1 KAS DI VAULT  / K 101.2 KAS DI TELLER (kas fisik kembali)
--   * `TellerCashOverage`    : D 101.2 KAS DI TELLER / K 101.9 SELISIH KAS  (laci lebih)
--   * `TellerCashShortage`   : D 101.9 SELISIH KAS   / K 101.2 KAS DI TELLER (laci kurang)
--
-- Kaki selisih sengaja memakai akun laci (`101.2`), bukan vault: setelah `TellerSessionClosed`
-- saldo laci = expected − counted = −variance, jadi hanya akun laci yang bisa dinolkan oleh jurnal
-- selisih. Versi memo yang menaruh kaki selisih di vault akan meninggalkan saldo laci tidak nol.
-- Nominal jurnal selisih = |variance| (tanda menentukan event mana yang dipakai).
--
-- Idempoten: `ON CONFLICT DO NOTHING` pada rule dan baris.

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|TellerSessionOpened')::uuid, 'TellerSessionOpened', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|TellerSessionClosed')::uuid, 'TellerSessionClosed', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|TellerCashOverage')::uuid, 'TellerCashOverage', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|TellerCashShortage')::uuid, 'TellerCashShortage', NULL,
   '{}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|TellerSessionOpened')::uuid, 1, 'DEBIT', '101.2'),
  (md5('ledger.posting_rule|TellerSessionOpened')::uuid, 2, 'CREDIT', '101.1'),
  (md5('ledger.posting_rule|TellerSessionClosed')::uuid, 1, 'DEBIT', '101.1'),
  (md5('ledger.posting_rule|TellerSessionClosed')::uuid, 2, 'CREDIT', '101.2'),
  (md5('ledger.posting_rule|TellerCashOverage')::uuid, 1, 'DEBIT', '101.2'),
  (md5('ledger.posting_rule|TellerCashOverage')::uuid, 2, 'CREDIT', '101.9'),
  (md5('ledger.posting_rule|TellerCashShortage')::uuid, 1, 'DEBIT', '101.9'),
  (md5('ledger.posting_rule|TellerCashShortage')::uuid, 2, 'CREDIT', '101.2')
ON CONFLICT (rule_id, line_no) DO NOTHING;
