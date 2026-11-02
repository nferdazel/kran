-- Hak akses role runtime untuk tabel transaksi `lending` yang lahir **setelah** `0080` (O-126).
--
-- `lending/0080` memberi `GRANT ... ON ALL TABLES IN SCHEMA lending` pada saat itu (seq 80); tabel
-- yang dibuat sesudahnya tidak tercakup. Di produksi `kran_runtime` mendapat "permission denied"
-- sementara seluruh test tetap hijau karena test memakai role migrator — persis mode kegagalan yang
-- sudah dicatat di `deposit/0070` dan `teller/0007`.
--
-- Ketahuan saat penutupan buku pertama di pilot (2 Nov 2026): rencana chunk `lending.ppap_provision`
-- gagal karena `permission denied for table ppap_snapshot`. Audit `has_table_privilege` menemukan
-- tujuh tabel lending tanpa hak sama sekali — bukan hanya PPAP, jadi penutupan lending dan pencairan
-- pertama akan gagal berantai.
--
-- Isi grant diturunkan dari pernyataan yang benar-benar dipakai kode (`modules/lending/infrastructure`,
-- `apps/api/src/daycloser_lending.nim`): **INSERT + SELECT** saja. Tidak ada `UPDATE`/`DELETE` pada
-- ketujuh tabel ini (upsert memakai `ON CONFLICT ... DO NOTHING`, yang hanya butuh INSERT) — koreksi
-- data tetap lewat jurnal pembalik, bukan menimpa baris. Nomor urut jadwal (`version_no`) dibuat
-- dengan INSERT baris baru, bukan UPDATE baris lama.
--
-- Aturan yang berlaku: setiap tabel baru di schema modul butuh migrasi grant sendiri. No-op bila role
-- belum ada (dev/CI).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT SELECT, INSERT ON
      lending.loan_schedule,
      lending.payment,
      lending.payment_allocation,
      lending.collectibility_snapshot,
      lending.ppap_snapshot,
      lending.writeoff,
      lending.recovery
    TO kran_runtime;
  END IF;
END
$$;
