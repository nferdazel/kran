-- Penyisihan penghapusan aset produktif (PPAP/CKPN) per tanggal buku (T-167).
--
-- **Kenapa snapshot per tanggal, bukan kolom "penyisihan terkini".** Yang dijurnal setiap hari buku
-- adalah **selisih** terhadap penyisihan kemarin. Tanpa nilai per tanggal, tidak ada cara
-- membuktikan bahwa jurnal hari ini memang sebesar perubahan yang benar, dan run ulang tidak bisa
-- dibedakan dari run pertama (pola yang sama dengan D-184).
--
-- `base_amount` disimpan apa adanya: penyisihan adalah `base × rate` yang dibulatkan sekali
-- (D-180 butir 3). Menyimpan hasil saja akan membuat laporan tidak bisa menjelaskan angkanya.
-- `rate_micro` memakai satuan `Rate` (1e6 = 100%), sama dengan tabel parameter dan domain.
CREATE TABLE lending.ppap_snapshot (
  loan_id       uuid NOT NULL REFERENCES lending.loan(loan_id),
  business_date date NOT NULL,
  grade         text NOT NULL CHECK (grade IN
                  ('COLLECTIBLE', 'SPECIAL_MENTION', 'SUBSTANDARD', 'DOUBTFUL', 'LOSS')),
  base_amount   numeric(24,2) NOT NULL CHECK (base_amount >= 0),
  rate_micro    bigint NOT NULL CHECK (rate_micro >= 0 AND rate_micro <= 1000000),
  allowance     numeric(24,2) NOT NULL CHECK (allowance >= 0),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lending_ppap_snapshot_pk PRIMARY KEY (loan_id, business_date)
);

CREATE INDEX lending_ppap_snapshot_date_idx ON lending.ppap_snapshot (business_date);

COMMENT ON TABLE lending.ppap_snapshot IS
  'Penyisihan PPAP per pinjaman per tanggal buku (T-167). PK (loan_id, business_date) = '
  'idempotensi task; selisih terhadap tanggal buku sebelumnya yang dijurnal.';
