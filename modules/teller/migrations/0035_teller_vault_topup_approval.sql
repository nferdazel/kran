-- Top-up vault dengan maker-checker (T-118, memo §4; menutup O-098).
--
-- Sebelum ini `POST /teller/vault/topups` langsung menaikkan saldo vault: satu pemegang izin bisa
-- menyuntik kas tanpa persetujuan kedua, tanpa bukti sumber dana, dan tanpa jurnal GL (O-097/O-098).
-- Sekarang top-up adalah **pengajuan** (PENDING) yang harus disetujui akun lain; persetujuan
-- menulis saldo vault + jurnal `D 101.1 KAS DI VAULT / K <sumber>` + audit + event dalam satu
-- transaksi.
--
-- Kenapa tabel, bukan "dua izin pada satu request": bentuk ini mengikuti pola maker-checker yang
-- sudah ada (`platform.param_value` PENDING→ACTIVE, `product.product_version` DRAFT→ACTIVE) dan
-- memberi bukti yang bisa ditelaah (nominal, akun sumber, alasan, siapa memutuskan).
--
-- **Sumber dana = keputusan approver per pengajuan** (`source_account`), bukan nilai default di
-- kode: memo T-118 menandainya keputusan pemilik, dan approver melihat persis apa yang disetujui.
-- Akun sumber wajib postable + ASSET (divalidasi handler).
--
-- Izin: `teller.vault.submit` (pengaju) dan `teller.vault.approve` (penyetuju). Bentuk kode
-- **wajib tiga segmen** `modul.resource.action` (spec §13, `validPermissionCode`); varian
-- `teller.vault.topup.submit` akan ditolak fail-closed di runtime. Izin lama `teller.vault.topup`
-- (0026) tetap ada di katalog demi kompatibilitas data, tetapi tidak lagi dipakai rute mana pun.
-- Self-approval ditolak CHECK + handler.
--
-- Idempotent: `CREATE TABLE IF NOT EXISTS`, permission `ON CONFLICT (code) DO NOTHING`, grant
-- `ON CONFLICT DO NOTHING`.

CREATE TABLE IF NOT EXISTS teller.vault_topup_request (
  request_id     uuid PRIMARY KEY,
  branch_id      uuid NOT NULL,
  amount         numeric(24,4) NOT NULL CHECK (amount > 0),
  source_account text NOT NULL REFERENCES ledger.coa_account(code),
  note           text NOT NULL CHECK (length(btrim(note)) BETWEEN 1 AND 200),
  status         text NOT NULL DEFAULT 'PENDING'
                 CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  requested_by   uuid NOT NULL,
  decided_by     uuid,
  decided_at     timestamptz,
  decision_note  text,
  journal_id     uuid,
  created_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vault_topup_decision_chk CHECK (
    (status = 'PENDING' AND decided_by IS NULL AND decided_at IS NULL)
    OR (status IN ('APPROVED', 'REJECTED') AND decided_by IS NOT NULL AND decided_at IS NOT NULL)),
  CONSTRAINT vault_topup_self_approval_chk CHECK (decided_by IS NULL OR decided_by <> requested_by),
  CONSTRAINT vault_topup_journal_chk CHECK (
    (status = 'APPROVED') = (journal_id IS NOT NULL))
);

COMMENT ON TABLE teller.vault_topup_request IS
  'Pengajuan top-up vault (T-118): PENDING → APPROVED/REJECTED oleh akun lain; persetujuan '
  'menulis saldo vault + jurnal D 101.1 / K source_account dalam satu transaksi.';

CREATE INDEX IF NOT EXISTS vault_topup_request_branch_idx
  ON teller.vault_topup_request (branch_id, status, created_at DESC);

INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'teller.vault.submit', 'teller', 'vault', 'submit',
   'perm.teller.vault.submit'),
  (gen_random_uuid(), 'teller.vault.approve', 'teller', 'vault', 'approve',
   'perm.teller.vault.approve')
ON CONFLICT (code) DO NOTHING;

-- Pengaju: kas admin, ops admin (administrasi harian), dan `platform_admin` (break-glass).
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('cash_admin', 'ops_admin', 'platform_admin')
   AND p.code = 'teller.vault.submit'
ON CONFLICT DO NOTHING;

-- Penyetuju: kas admin (pemegang kas operasional) dan `platform_admin`. `ops_admin` sengaja tidak
-- ikut supaya pengaju punya penyetuju lain yang nyata.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('cash_admin', 'platform_admin')
   AND p.code = 'teller.vault.approve'
ON CONFLICT DO NOTHING;

-- Hak akses role runtime (pola `teller/0007`): baca untuk daftar, tulis untuk pengajuan/keputusan.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT SELECT, INSERT, UPDATE ON teller.vault_topup_request TO kran_runtime;
  END IF;
END
$$;
