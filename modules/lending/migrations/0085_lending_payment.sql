-- Pembayaran angsuran pinjaman (T-165).
--
-- Dua tabel, satu alasan: `lending.payment` menyimpan **peristiwa** (nominal, rekening sumber,
-- tanggal buku, rincian per komponen), `lending.payment_allocation` menyimpan **tujuan** per baris
-- jadwal. Tanpa tabel kedua, "uang 1.500.000 ini menutup baris ke berapa" hanya bisa ditebak dari
-- total, dan sengketa anggota tidak bisa dijawab dari data.
--
-- CHECK `principal_paid + interest_paid + penalty_paid = amount` bukan hiasan: alokasi yang
-- kehilangan satu sen di tengah jalan akan terlihat sebagai pembayaran yang tidak pernah sampai.
CREATE TABLE lending.payment (
  payment_id     uuid PRIMARY KEY,
  loan_id        uuid NOT NULL REFERENCES lending.loan(loan_id),
  account_id     uuid NOT NULL REFERENCES deposit.account(account_id),
  amount         numeric(24,2) NOT NULL CHECK (amount > 0),
  principal_paid numeric(24,2) NOT NULL DEFAULT 0 CHECK (principal_paid >= 0),
  interest_paid  numeric(24,2) NOT NULL DEFAULT 0 CHECK (interest_paid >= 0),
  penalty_paid   numeric(24,2) NOT NULL DEFAULT 0 CHECK (penalty_paid >= 0),
  business_date  date NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL,
  CONSTRAINT lending_payment_sum_chk
    CHECK (principal_paid + interest_paid + penalty_paid = amount)
);

CREATE INDEX lending_payment_loan_idx ON lending.payment (loan_id, business_date);

CREATE TABLE lending.payment_allocation (
  payment_id     uuid NOT NULL REFERENCES lending.payment(payment_id),
  installment_no integer NOT NULL CHECK (installment_no > 0),
  component      text NOT NULL CHECK (component IN ('PRINCIPAL', 'INTEREST', 'PENALTY')),
  amount         numeric(24,2) NOT NULL CHECK (amount > 0),
  CONSTRAINT lending_payment_allocation_pk PRIMARY KEY (payment_id, installment_no, component)
);

COMMENT ON TABLE lending.payment IS
  'Pembayaran angsuran (T-165): satu baris per peristiwa bayar, dengan rincian komponen yang '
  'jumlahnya tepat sama dengan nominal.';
COMMENT ON TABLE lending.payment_allocation IS
  'Alokasi pembayaran ke baris jadwal (T-165): menutup baris ke berapa, komponen apa, berapa.';
