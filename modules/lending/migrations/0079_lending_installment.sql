-- Jadwal angsuran (T-161, D-180 butir 1): satu baris per jatuh tempo.
--
-- Jadwal **disimpan**, bukan dihitung ulang saat dibaca: metode jadwal bisa berbeda antar produk,
-- dan membentuk ulang jadwal setelah pencairan berarti mengubah angka yang sudah disepakati
-- anggota. `paid_*` menumpuk pembayaran (T-165); baris yang sudah dibayar tidak boleh diubah.
--
-- CHECK `paid_* <= *_due` menutup kelebihan bayar per komponen tanpa memisahkan tabel pembayaran;
-- urutan alokasi yang menentukan komponen mana yang menerima uang ada di parameter (D-180 butir 4).

CREATE TABLE lending.installment (
  loan_id         uuid NOT NULL REFERENCES lending.loan(loan_id),
  no              integer NOT NULL CHECK (no > 0),
  due_on          date NOT NULL,
  principal_due   numeric(24,2) NOT NULL CHECK (principal_due >= 0),
  interest_due    numeric(24,2) NOT NULL CHECK (interest_due >= 0),
  penalty_due     numeric(24,2) NOT NULL CHECK (penalty_due >= 0),
  paid_principal  numeric(24,2) NOT NULL DEFAULT 0 CHECK (paid_principal >= 0),
  paid_interest   numeric(24,2) NOT NULL DEFAULT 0 CHECK (paid_interest >= 0),
  paid_penalty    numeric(24,2) NOT NULL DEFAULT 0 CHECK (paid_penalty >= 0),
  paid_on         date,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lending_installment_pk PRIMARY KEY (loan_id, no),
  CONSTRAINT lending_installment_principal_chk CHECK (paid_principal <= principal_due),
  CONSTRAINT lending_installment_interest_chk CHECK (paid_interest <= interest_due),
  CONSTRAINT lending_installment_penalty_chk CHECK (paid_penalty <= penalty_due),
  -- Total kewajiban harus positif: baris nol tidak pernah perlu ada dan menyulitkan deteksi jadwal
  -- yang gagal dibentuk.
  CONSTRAINT lending_installment_total_chk CHECK (principal_due + interest_due + penalty_due > 0)
);

COMMENT ON TABLE lending.installment IS
  'Jadwal angsuran (T-161): satu baris per jatuh tempo, dibekukan setelah dibayar.';

CREATE INDEX lending_installment_due_idx ON lending.installment (due_on);

-- Baris yang sudah menerima pembayaran tidak boleh diubah atau dihapus: koreksi lewat jurnal
-- pembalik + baris baru, sama seperti `deposit.transaction` (memakai `ledger.reject_mutation()`).
CREATE FUNCTION lending.reject_paid_installment_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.paid_principal > 0 OR OLD.paid_interest > 0 OR OLD.paid_penalty > 0 THEN
    RAISE EXCEPTION 'baris jadwal yang sudah dibayar tidak boleh diubah; koreksi lewat jurnal pembalik';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$$;

CREATE TRIGGER lending_installment_immutable
  BEFORE UPDATE OR DELETE ON lending.installment
  FOR EACH ROW EXECUTE FUNCTION lending.reject_paid_installment_mutation();
