-- Rule posting untuk PB pencairan dini deposito berjangka (T-148, D-164).
--
-- Jalur tunai (`0073`) memakai kas laci `101.2` di kaki lawannya. PB tidak menyentuh kas: pokok,
-- bunga, dan penalti berpindah antar dua rekening simpanan, jadi kaki lawannya `201 SIMPANAN
-- ANGGOTA`. Karena `ledger.journal` tidak menyimpan `rule_id`, pemisahan jalur dilakukan lewat
-- `event_type` yang berbeda — bukan kondisi pada payload (payload tidak tahu kanal).
--
--   DepositWithdrawnViaTransfer      : D 202 SIMPANAN BERJANGKA / K 201  (pokok)
--   InterestPaidEarlyViaTransfer     : D 204 BUNGA AKRUAL      / K 201  (bunga)
--   EarlyWithdrawalPenaltyViaTransfer: D 201                   / K 403  (penalti)
--
-- Efek gabungan: `202 −pokok`, `204 −bunga`, `403 +penalti`, `201 +pokok+bunga−penalti`. Tiap jurnal
-- seimbang sendiri (template satu D/K, T-076), dan total `201+202` berubah sebesar `bunga−penalti` —
-- sama dengan perubahan total saldo subledger, sehingga gate `ledger.subledger_vs_gl` tetap cocok.
--
-- NEEDS-COMPLIANCE-REVIEW: pemetaan `201/202/204/403` adalah struktur pilot (REG-011 `V!`).
-- Idempoten: `ON CONFLICT ... DO NOTHING`.

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|DepositWithdrawnViaTransfer|generic')::uuid,
   'DepositWithdrawnViaTransfer', NULL, '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|InterestPaidEarlyViaTransfer|generic')::uuid,
   'InterestPaidEarlyViaTransfer', NULL, '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|EarlyWithdrawalPenaltyViaTransfer|generic')::uuid,
   'EarlyWithdrawalPenaltyViaTransfer', NULL, '{}'::jsonb, 100, 'ACTIVE',
   '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|DepositWithdrawnViaTransfer|generic')::uuid, 1, 'DEBIT', '202'),
  (md5('ledger.posting_rule|DepositWithdrawnViaTransfer|generic')::uuid, 2, 'CREDIT', '201'),
  (md5('ledger.posting_rule|InterestPaidEarlyViaTransfer|generic')::uuid, 1, 'DEBIT', '204'),
  (md5('ledger.posting_rule|InterestPaidEarlyViaTransfer|generic')::uuid, 2, 'CREDIT', '201'),
  (md5('ledger.posting_rule|EarlyWithdrawalPenaltyViaTransfer|generic')::uuid, 1, 'DEBIT', '201'),
  (md5('ledger.posting_rule|EarlyWithdrawalPenaltyViaTransfer|generic')::uuid, 2, 'CREDIT', '403')
ON CONFLICT (rule_id, line_no) DO NOTHING;
