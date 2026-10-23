-- Akun & rule posting simpanan koperasi (T-111, memo SME), idempoten.
--
-- Simpanan **pokok** & **wajib** adalah **ekuitas** anggota, bukan kewajiban institusi: setoran ke
-- rekening berjenis itu diposting ke akun ekuitas terpisah (`301.1`/`301.2`), bukan `201`. Rule
-- berkondisi `{"savingsKind": "POKOK"/"WAJIB"}` dipilih resolver sebagai rule paling spesifik;
-- rule generik `DepositPosted` (`0005`, kondisi kosong) tetap menjadi **fallback** untuk rekening
-- tanpa klasifikasi / SUKARELA / TABUNGAN.
--
-- NEEDS-COMPLIANCE-REVIEW: penomoran akun (`301.1`/`301.2`) & klasifikasi ekuitas-vs-liabilitas
-- adalah **struktur pilot**, bukan kutipan SAK EP/PSAK (REG-011 `V!`, spec §4). Akun & rule final
-- menunggu keputusan compliance/accounting owner sebelum laporan/pilot.
--
-- Tidak ada `DepositWithdrawn` untuk POKOK/WAJIB: penarikan & PB dari jenis itu diblokir di
-- handler (409 `savings_kind_locked`), jadi tidak boleh ada template keluar yang menyesatkan.
-- Rule product-specific **tidak** dicampur dengan rule kind-specific untuk event yang sama
-- (ambigu) — event `DepositPosted` hanya punya satu rule kind-specific per jenis.
--
-- Idempoten: `ON CONFLICT DO NOTHING` supaya aman dijalankan ulang.

INSERT INTO ledger.coa_account
  (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
VALUES
  (md5('ledger.coa|301.1')::uuid, '301.1', 'SIMPANAN POKOK ANGGOTA', 'EQUITY', 'CREDIT', true, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.coa|301.2')::uuid, '301.2', 'SIMPANAN WAJIB ANGGOTA', 'EQUITY', 'CREDIT', true, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO ledger.posting_rule
  (rule_id, event_type, product_code, conditions, priority, status, created_by, updated_by)
VALUES
  (md5('ledger.posting_rule|DepositPosted|POKOK')::uuid, 'DepositPosted', NULL,
   '{"savingsKind": "POKOK"}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1'),
  (md5('ledger.posting_rule|DepositPosted|WAJIB')::uuid, 'DepositPosted', NULL,
   '{"savingsKind": "WAJIB"}'::jsonb, 100, 'ACTIVE', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
ON CONFLICT (rule_id) DO NOTHING;

INSERT INTO ledger.posting_rule_line (rule_id, line_no, side, gl_account)
VALUES
  (md5('ledger.posting_rule|DepositPosted|POKOK')::uuid, 1, 'DEBIT', '101'),
  (md5('ledger.posting_rule|DepositPosted|POKOK')::uuid, 2, 'CREDIT', '301.1'),
  (md5('ledger.posting_rule|DepositPosted|WAJIB')::uuid, 1, 'DEBIT', '101'),
  (md5('ledger.posting_rule|DepositPosted|WAJIB')::uuid, 2, 'CREDIT', '301.2')
ON CONFLICT (rule_id, line_no) DO NOTHING;
