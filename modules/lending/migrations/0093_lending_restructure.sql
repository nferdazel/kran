-- Restrukturisasi pinjaman (T-168): jadwal **versi baru**, jadwal lama diarsipkan.
--
-- **Kenapa versi, bukan UPDATE.** Trigger `lending/0089` membekukan `due_on`/`*_due` pada baris yang
-- sudah dibayar, dan itu benar: kewajiban yang sudah dibayar tidak boleh diubah. Restrukturisasi
-- karena itu menambah satu jadwal baru dan menandai jadwal lama `superseded_on`, bukan menimpa.
-- Riwayat jadwal yang ditandatangani anggota tetap terbaca, dan `payment_allocation` lama tetap
-- menunjuk baris yang benar.
--
-- **Penomoran angsuran berlanjut**, tidak mulai dari 1: `lending.payment_allocation` menunjuk
-- `(payment_id, installment_no)` tanpa versi, jadi nomor yang dipakai ulang akan membuat alokasi
-- lama terbaca sebagai alokasi jadwal baru. Versi 2 melanjutkan dari nomor terakhir versi 1.
--
-- Backfill versi 1 untuk jadwal yang sudah ada: tanpa itu tabel versi bolong untuk pinjaman lama,
-- dan laporan "berapa kali akad ini direstrukturisasi" tidak bisa dijawab.
ALTER TABLE lending.installment
  ADD COLUMN schedule_version integer NOT NULL DEFAULT 1,
  ADD COLUMN superseded_on date;

ALTER TABLE lending.installment
  ADD CONSTRAINT lending_installment_schedule_version_chk CHECK (schedule_version >= 1);

-- Hanya jadwal aktif yang dibaca pembayaran/kolektibilitas; indeks parsial menjaga kueri itu murah
-- tanpa memindai riwayat.
CREATE INDEX lending_installment_active_idx
  ON lending.installment (loan_id, due_on)
  WHERE superseded_on IS NULL;

CREATE TABLE lending.loan_schedule (
  loan_id     uuid NOT NULL REFERENCES lending.loan(loan_id),
  version_no  integer NOT NULL CHECK (version_no >= 1),
  created_on  date NOT NULL,
  reason      text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  created_by  uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lending_loan_schedule_pk PRIMARY KEY (loan_id, version_no)
);

COMMENT ON TABLE lending.loan_schedule IS
  'Versi jadwal pinjaman (T-168). Versi 1 = jadwal pencairan; versi berikutnya = restrukturisasi, '
  'dengan alasan dan pelakunya. Baris jadwal lama ditandai `superseded_on`, tidak dihapus.';

INSERT INTO lending.loan_schedule (loan_id, version_no, created_on, reason, created_by)
SELECT l.loan_id, 1, coalesce(l.disbursed_on, l.created_at::date), 'jadwal awal (backfill)',
       l.applied_by
  FROM lending.loan l
 WHERE EXISTS (SELECT 1 FROM lending.installment i WHERE i.loan_id = l.loan_id)
ON CONFLICT DO NOTHING;
