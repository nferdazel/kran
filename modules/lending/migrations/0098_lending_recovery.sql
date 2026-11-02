-- Pemulihan pasca hapus buku (O-122, T-176): uang yang masuk setelah piutang dihapusbukukan.
--
-- Satu baris per penerimaan, bukan satu baris per pinjaman: anggota bisa membayar bertahap, dan
-- auditor harus bisa melihat kapan uang masuk. Batas kumulatif (tidak boleh melebihi nilai yang
-- dihapusbukukan) diperiksa di aplikasi terhadap `lending.writeoff` + `sum(lending.recovery)`;
-- CHECK di sini hanya menolak nilai negatif dan total yang tidak konsisten.
CREATE TABLE lending.recovery (
  recovery_id    uuid PRIMARY KEY,
  loan_id        uuid NOT NULL REFERENCES lending.loan(loan_id),
  business_date  date NOT NULL,
  account_id     uuid NOT NULL,
  principal_amount numeric(24,2) NOT NULL CHECK (principal_amount >= 0),
  interest_amount  numeric(24,2) NOT NULL CHECK (interest_amount >= 0),
  penalty_amount   numeric(24,2) NOT NULL CHECK (penalty_amount >= 0),
  total_amount     numeric(24,2) NOT NULL CHECK (total_amount > 0),
  reason         text NOT NULL CHECK (length(btrim(reason)) > 0),
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL,
  CONSTRAINT lending_recovery_total_chk
    CHECK (total_amount = principal_amount + interest_amount + penalty_amount)
);

CREATE INDEX lending_recovery_loan_idx ON lending.recovery (loan_id, business_date);
