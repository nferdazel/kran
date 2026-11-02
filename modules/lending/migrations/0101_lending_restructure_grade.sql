-- Penanda restrukturisasi untuk penilaian kolektibilitas (O-123, D-197).
--
-- **Kenapa disimpan, bukan dihitung ulang.** Setelah restrukturisasi, DPD dihitung dari jadwal aktif
-- yang jatuh temponya di masa depan, jadi DPD saja selalu menghasilkan "lancar". Aturan POJK 1/2024
-- menuntut pembanding **kualitas sebelum restrukturisasi**: paling tinggi kurang lancar bila
-- sebelumnya diragukan/macet, dan tidak berubah bila sebelumnya lancar/DPK/kurang lancar. Nilai
-- "sebelum" itu tidak bisa direkonstruksi dari jadwal, jadi disimpan saat restrukturisasi.
--
-- `grade_cap` adalah batas atas (tidak boleh lebih baik dari ini) sampai pinjaman punya cukup periode
-- pembayaran bersih. `restructured_on` kosong berarti pinjaman tidak (atau belum) direstrukturisasi
-- pada versi skema ini; baris lama tidak di-backfill karena nilai "sebelum" mereka tidak tercatat.
ALTER TABLE lending.loan
  ADD COLUMN restructured_on date,
  ADD COLUMN grade_before_restructure text,
  ADD COLUMN grade_cap text;

ALTER TABLE lending.loan
  ADD CONSTRAINT lending_loan_grade_before_chk CHECK (
    grade_before_restructure IS NULL OR grade_before_restructure IN
      ('COLLECTIBLE', 'SPECIAL_MENTION', 'SUBSTANDARD', 'DOUBTFUL', 'LOSS')),
  ADD CONSTRAINT lending_loan_grade_cap_chk CHECK (
    grade_cap IS NULL OR grade_cap IN
      ('COLLECTIBLE', 'SPECIAL_MENTION', 'SUBSTANDARD', 'DOUBTFUL', 'LOSS')),
  -- Penanda dan batasnya satu paket: batas tanpa tanggal tidak bisa dijelaskan, tanggal tanpa batas
  -- membuat penilaian kembali ke perilaku lama tanpa jejak bahwa pinjaman pernah direstrukturisasi.
  ADD CONSTRAINT lending_loan_restructured_pair_chk CHECK (
    (restructured_on IS NULL) = (grade_cap IS NULL));

COMMENT ON COLUMN lending.loan.restructured_on IS
  'Tanggal buku restrukturisasi terakhir (O-123, D-197). NULL = belum pernah direstrukturisasi.';
COMMENT ON COLUMN lending.loan.grade_before_restructure IS
  'Golongan kolektibilitas saat restrukturisasi; NULL bila pinjaman belum pernah dinilai.';
COMMENT ON COLUMN lending.loan.grade_cap IS
  'Batas atas golongan setelah restrukturisasi sampai periode pembayaran bersih terpenuhi.';
