-- Nomor rekening memakai kode cabang (D-135). Kolom `deposit.account.account_no` yang sudah ada
-- adalah 10 digit nomor urut global tanpa prefiks; setelah master cabang lahir
-- (`platform/0030_platform_branch_master.sql`) nomor baru berbentuk **kode cabang 3 digit +
-- nomor urut 7 digit**.
--
-- Migrasi ini menyeragamkan rekening lama: setiap rekening yang prefiksnya bukan kode cabangnya
-- mendapat nomor baru dari `deposit.account_seq` (nomor bisnis tidak pernah dipakai ulang, spec
-- §9.1(8), jadi nomor lama tidak didaur ulang). Rekening di cabang yang belum terdaftar
-- dibiarkan apa adanya — tidak ada kode yang bisa dipakai, dan menebak kode berarti mengarang data.
--
-- Nomor urut tetap **global** (bukan per cabang): prefiks sudah membedakan cabang, dan sequence
-- global membuat satu rekening tidak bisa mendapat nomor yang sama di cabang lain.
--
-- Urutan berkas: seq `31` supaya berjalan setelah `platform/0030` (urutan migrasi global =
-- `(seq, nama modul, nama berkas)`), karena migrasi ini membaca `platform.branch`.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT a.account_id, b.code
      FROM deposit.account a
      JOIN platform.branch b ON b.branch_id = a.branch_id
     WHERE left(a.account_no, 3) IS DISTINCT FROM b.code
     ORDER BY a.account_no
  LOOP
    UPDATE deposit.account
       SET account_no = r.code || lpad(nextval('deposit.account_seq')::text, 7, '0'),
           updated_at = now()
     WHERE account_id = r.account_id;
  END LOOP;
END
$$;

COMMENT ON COLUMN deposit.account.account_no IS
  'Nomor rekening (D-135): 3 digit kode cabang (platform.branch.code) + 7 digit nomor urut '
  'deposit.account_seq. Check digit belum ada (O-104).';
