-- Akrual bunga deposito berjangka per hari buku (T-138c, D-152).
--
-- Satu baris = satu rentang akrual untuk satu rekening pada satu tanggal buku. Kunci primer
-- `(account_id, business_date)` adalah penjaga idempotensi: menjalankan ulang penutupan tanggal
-- yang sama tidak bisa mencatat akrual kedua untuk rekening itu.
--
-- **Kenapa `amount` dan `cumulative` dua-duanya.** Keputusan pemilik (28 Okt 2026): pembulatan
-- dilakukan **sekali per rentang**, bukan per hari, supaya tidak ada selisih yang menumpuk
-- terhadap bunga yang dijanjikan di akhir tenor. `cumulative` = bunga yang dibulatkan sekali dari
-- `opened_on` sampai `business_date`; `amount` = `cumulative` dikurangi `cumulative` baris
-- sebelumnya, yaitu bagian yang dijurnal pada tanggal itu. Karena itu `SUM(amount)` per rekening
-- selalu sama dengan satu pembulatan rentang penuh, dan pembaca tabel bisa memeriksanya tanpa
-- menghitung ulang.
--
-- `days` adalah hari akrual **menurut basis** (`product.savings.day_count_basis`), bukan selisih
-- kalender: pada 30/360 satu bulan dihitung 30 hari, dan sebagian rentang pendek bisa 0 hari.
-- `basis_days` disimpan bersama barisnya supaya laporan lama tidak berubah arti bila parameter
-- produk diubah kemudian (parameter bersifat effective-dated; baris akrual bersifat arsip).
--
-- `journal_id` tanpa FK, sama seperti `deposit.transaction.journal_id`: modul `deposit` tidak
-- memiliki tabel `ledger`, dan FK lintas modul akan membuat urutan migrasi/rollback saling
-- mengunci. Jurnalnya sendiri immutable di `ledger`.
--
-- Tidak ada baris untuk rekening `CLOSED` (keputusan pemilik: rekening tutup tidak diakrualkan).
-- Status `DORMANT` **tetap** diakrualkan — status itu membatasi transaksi, bukan perjanjian bunga.
CREATE TABLE deposit.interest_accrual (
  account_id    uuid NOT NULL REFERENCES deposit.account(account_id) ON DELETE RESTRICT,
  business_date date NOT NULL,
  principal     numeric(24,2) NOT NULL CHECK (principal >= 0),
  days          integer NOT NULL CHECK (days > 0),
  rate_percent  numeric(12,4) NOT NULL CHECK (rate_percent >= 0),
  basis_days    integer NOT NULL CHECK (basis_days > 0),
  amount        numeric(24,2) NOT NULL CHECK (amount >= 0),
  cumulative    numeric(24,2) NOT NULL CHECK (cumulative >= 0),
  journal_id    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, business_date),
  CONSTRAINT interest_accrual_amount_le_cumulative_chk CHECK (amount <= cumulative)
);

COMMENT ON TABLE deposit.interest_accrual IS
  'Akrual bunga deposito berjangka per tanggal buku (T-138c). PK (account_id, business_date) = '
  'idempotensi; amount = bagian yang dijurnal hari itu, cumulative = total yang dibulatkan sekali '
  'dari opened_on. Baris tanpa journal_id berarti bunganya nol (tidak ada jurnal nol).';

COMMENT ON COLUMN deposit.interest_accrual.principal IS
  'Saldo pokok yang dipakai menghitung (cache deposit.account_balance saat akrual).';
COMMENT ON COLUMN deposit.interest_accrual.days IS
  'Hari akrual menurut basis (0 tidak disimpan; rentang tanpa hari tidak punya baris).';
COMMENT ON COLUMN deposit.interest_accrual.rate_percent IS
  'Rate tahunan dalam persen dari binding versi produk (mis. 2.5000 = 2,5% p.a.).';
COMMENT ON COLUMN deposit.interest_accrual.basis_days IS
  'Pembagi tahun basis saat baris ditulis (365/360), disimpan supaya arsip tidak berubah arti.';
COMMENT ON COLUMN deposit.interest_accrual.cumulative IS
  'Bunga kumulatif dibulatkan SEKALI dari opened_on sampai business_date (D-152).';

-- Pencarian "akrual terakhir rekening ini" memakai PK (prefix account_id + urutan business_date),
-- jadi tidak perlu indeks tambahan. Indeks tanggal dipakai laporan/rekonsiliasi per hari buku.
CREATE INDEX interest_accrual_business_date_idx
  ON deposit.interest_accrual (business_date);
