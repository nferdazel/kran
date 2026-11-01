-- Baris jadwal boleh menerima pembayaran bertahap (T-165), tetapi **kewajibannya** tetap beku
-- begitu ada pembayaran.
--
-- Fungsi dari `0079` menolak setiap UPDATE pada baris yang sudah punya `paid_* > 0`. Itu benar
-- untuk tujuan aslinya (baris lunas tidak bisa diubah) tetapi salah untuk pembayaran: satu
-- pembayaran menyentuh satu baris lebih dari sekali (bunga lalu pokok), dan pembayaran berikutnya
-- menyentuh baris yang sama — semuanya ditolak trigger, sehingga angsuran tidak mungkin dicicil.
--
-- Yang dijaga sekarang, per kasus:
--   DELETE  — tetap ditolak bila baris sudah menerima pembayaran. Menghapus baris berbayar
--             menghilangkan bukti kewajiban yang sudah dibayar anggota.
--   UPDATE  — `loan_id`, `no`, `due_on`, dan ketiga kolom `*_due` **tidak boleh** berubah bila
--             sudah ada pembayaran (mengubah kewajiban setelah uang diterima = mengarang utang).
--             `paid_*` hanya boleh **naik** (pembayaran tidak bisa dikurangi/dibatalkan lewat
--             UPDATE; koreksi resmi lewat jurnal pembalik), dan `paid_on` yang sudah terisi tidak
--             boleh diubah/dikosongkan.
--
-- Tidak ada tabel/kolom/baris yang dihapus: hanya badan fungsi diganti.
CREATE OR REPLACE FUNCTION lending.reject_paid_installment_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.paid_principal > 0 OR OLD.paid_interest > 0 OR OLD.paid_penalty > 0 THEN
      RAISE EXCEPTION
        'baris jadwal yang sudah dibayar tidak boleh dihapus; koreksi lewat jurnal pembalik';
    END IF;
    RETURN OLD;
  END IF;

  -- UPDATE: baris yang belum menerima pembayaran bebas disesuaikan (jadwal masih DRAFT).
  IF OLD.paid_principal > 0 OR OLD.paid_interest > 0 OR OLD.paid_penalty > 0 THEN
    IF NEW.loan_id <> OLD.loan_id OR NEW.no <> OLD.no OR NEW.due_on <> OLD.due_on
       OR NEW.principal_due <> OLD.principal_due
       OR NEW.interest_due <> OLD.interest_due
       OR NEW.penalty_due <> OLD.penalty_due THEN
      RAISE EXCEPTION
        'kewajiban baris jadwal yang sudah dibayar tidak boleh diubah; koreksi lewat jurnal pembalik';
    END IF;
    IF NEW.paid_principal < OLD.paid_principal
       OR NEW.paid_interest < OLD.paid_interest
       OR NEW.paid_penalty < OLD.paid_penalty THEN
      RAISE EXCEPTION
        'pembayaran tidak boleh dikurangi lewat UPDATE; koreksi lewat jurnal pembalik';
    END IF;
    IF OLD.paid_on IS NOT NULL AND (NEW.paid_on IS NULL OR NEW.paid_on <> OLD.paid_on) THEN
      RAISE EXCEPTION 'tanggal pelunasan baris jadwal tidak boleh diubah';
    END IF;
  END IF;

  RETURN NEW;
END
$$;
