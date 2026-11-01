-- Akad/fasilitas pinjaman + cache saldo (T-161, spec §9.2).
--
-- Produk **versi** yang di-pin, bukan produk: syarat pinjaman (metode, tenor, rate) dibekukan saat
-- akad, sehingga versi produk baru tidak mengubah pinjaman yang sudah berjalan.
--
-- `party_id` mem-FK `party.party`; `branch_id` tidak mem-FK karena tabel cabang belum ada
-- (sama seperti `deposit.account`).
--
-- Saldo disimpan satu baris per pinjaman sebagai cache untuk operasi pembayaran; sumber kebenaran
-- tetap `lending.installment` + jurnal ledger (spec §9.1(4)). CHECK `>= 0` adalah backstop DB.

CREATE TABLE lending.loan (
  loan_id            uuid PRIMARY KEY,
  party_id           uuid NOT NULL REFERENCES party.party(party_id),
  product_version_id uuid NOT NULL REFERENCES lending.loan_product_version(version_id),
  branch_id          uuid NOT NULL,
  principal          numeric(24,2) NOT NULL CHECK (principal > 0),
  status             text NOT NULL CHECK (
    status IN ('APPLIED', 'APPROVED', 'ACTIVE', 'CLOSED', 'WRITTEN_OFF')
  ),
  disbursed_on       date,
  maturity_on        date,
  applied_by         uuid NOT NULL,
  approved_by        uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  -- Empat mata juga di akad: status di atas APPLIED harus punya penyetuju yang berbeda.
  CONSTRAINT lending_loan_approver_chk CHECK (
    status = 'APPLIED' OR (approved_by IS NOT NULL AND approved_by <> applied_by)
  ),
  -- Pinjaman yang sudah berjalan wajib punya tanggal cair; tanpa itu umur pinjaman (DPD) tidak
  -- bisa dihitung.
  CONSTRAINT lending_loan_disbursed_chk CHECK (
    status IN ('APPLIED', 'APPROVED') OR disbursed_on IS NOT NULL
  ),
  CONSTRAINT lending_loan_maturity_chk CHECK (
    maturity_on IS NULL OR disbursed_on IS NULL OR maturity_on >= disbursed_on
  )
);

COMMENT ON TABLE lending.loan IS
  'Akad pinjaman (T-161): syarat dibekukan lewat product_version_id. Saldo ada di loan_balance.';

CREATE INDEX lending_loan_party_idx ON lending.loan (party_id);
CREATE INDEX lending_loan_branch_idx ON lending.loan (branch_id);
CREATE INDEX lending_loan_status_idx ON lending.loan (status);

CREATE TABLE lending.loan_balance (
  loan_id              uuid PRIMARY KEY REFERENCES lending.loan(loan_id),
  principal_outstanding numeric(24,2) NOT NULL DEFAULT 0 CHECK (principal_outstanding >= 0),
  interest_overdue      numeric(24,2) NOT NULL DEFAULT 0 CHECK (interest_overdue >= 0),
  penalty_outstanding   numeric(24,2) NOT NULL DEFAULT 0 CHECK (penalty_outstanding >= 0),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE lending.loan_balance IS
  'Cache saldo pinjaman (T-161); sumber kebenaran jadwal + jurnal. CHECK >= 0 adalah backstop.';
