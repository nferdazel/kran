-- Kolektibilitas pinjaman (T-166): nilai terkini di akad + snapshot harian.
--
-- **Kenapa snapshot, bukan hanya kolom.** Task day-close harus idempoten per tanggal buku: `UPDATE`
-- pada kolom saja akan "berhasil" berapa kali pun dijalankan, sehingga tidak ada cara membedakan
-- "sudah diproses" dari "diproses ulang" dan audit bisa berlipat. Primary key `(loan_id,
-- business_date)` membuat kebenaran itu milik skema, bukan milik kode pemanggil.
--
-- Nilai golongan adalah teks ber-CHECK, bukan enum DB: daftar golongan hidup di domain
-- (`lending/domain/collectibility.nim`) dan dipakai bersama PPAP (T-167).
ALTER TABLE lending.loan
  ADD COLUMN collectibility text,
  ADD CONSTRAINT lending_loan_collectibility_chk CHECK (
    collectibility IS NULL OR collectibility IN
      ('COLLECTIBLE', 'SPECIAL_MENTION', 'SUBSTANDARD', 'DOUBTFUL', 'LOSS'));

CREATE TABLE lending.collectibility_snapshot (
  loan_id       uuid NOT NULL REFERENCES lending.loan(loan_id),
  business_date date NOT NULL,
  dpd           integer NOT NULL CHECK (dpd >= 0),
  grade         text NOT NULL CHECK (grade IN
                  ('COLLECTIBLE', 'SPECIAL_MENTION', 'SUBSTANDARD', 'DOUBTFUL', 'LOSS')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lending_collectibility_snapshot_pk PRIMARY KEY (loan_id, business_date)
);

COMMENT ON COLUMN lending.loan.collectibility IS
  'Golongan kolektibilitas terkini (T-166). NULL = belum pernah dinilai oleh task day-close.';
COMMENT ON TABLE lending.collectibility_snapshot IS
  'Penilaian kolektibilitas per tanggal buku (T-166). Primary key (loan_id, business_date) = '
  'idempotensi task day-close; nilai historis dipakai PPAP (T-167).';
