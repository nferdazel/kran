-- Hapus buku (T-168): jejak lengkap, bukan sekadar perubahan status.
--
-- Status `WRITTEN_OFF` sudah ada di CHECK sejak `lending/0078`, tetapi tanpa tanggal/pelaku/alasan
-- seorang auditor tidak bisa menjawab "siapa menghapusbukukan piutang ini dan kapan". CHECK di bawah
-- memaksa ketiganya terisi **tepat** saat status itu dipakai, sehingga status dan jejaknya tidak
-- bisa menyimpang.
ALTER TABLE lending.loan
  ADD COLUMN written_off_on date,
  ADD COLUMN written_off_by uuid,
  ADD COLUMN written_off_reason text;

ALTER TABLE lending.loan
  ADD CONSTRAINT lending_loan_written_off_chk CHECK (
    (status = 'WRITTEN_OFF'
       AND written_off_on IS NOT NULL
       AND written_off_by IS NOT NULL
       AND written_off_reason IS NOT NULL)
    OR (status <> 'WRITTEN_OFF'
       AND written_off_on IS NULL
       AND written_off_by IS NULL
       AND written_off_reason IS NULL));

-- Rincian nilai yang dihapusbukukan: piutang bruto (pokok/bunga/denda), berapa yang ditutup
-- penyisihan, dan berapa yang menjadi beban. Tanpa rincian ini, laporan "berapa yang dihapusbukukan
-- dan berapa yang sudah disisihkan" hanya bisa ditebak dari jurnal agregat.
CREATE TABLE lending.writeoff (
  loan_id           uuid PRIMARY KEY REFERENCES lending.loan(loan_id),
  business_date     date NOT NULL,
  principal_amount  numeric(24,2) NOT NULL CHECK (principal_amount >= 0),
  interest_amount   numeric(24,2) NOT NULL CHECK (interest_amount >= 0),
  penalty_amount    numeric(24,2) NOT NULL CHECK (penalty_amount >= 0),
  allowance_applied numeric(24,2) NOT NULL CHECK (allowance_applied >= 0),
  expense_amount    numeric(24,2) NOT NULL CHECK (expense_amount >= 0),
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        uuid NOT NULL,
  -- Pembagian harus menutup seluruh nilai: tidak ada bagian yang "hilang di tengah".
  CONSTRAINT lending_writeoff_split_chk
    CHECK (allowance_applied + expense_amount =
           principal_amount + interest_amount + penalty_amount)
);

COMMENT ON TABLE lending.writeoff IS
  'Hapus buku (T-168): nilai piutang yang dihapus, berapa ditutup penyisihan (111) dan berapa '
  'menjadi beban (504). Satu baris per pinjaman — hapus buku hanya sekali.';
