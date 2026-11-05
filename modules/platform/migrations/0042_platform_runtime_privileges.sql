-- Hak tulis role runtime pada tabel yang harusnya immutable (T-129/DB-1, spec §9.1(3)).
--
-- **Konteks.** Runbook `docs/runbooks/db-roles.md` memberi `kran_runtime` `SELECT, INSERT, UPDATE,
-- DELETE` di **semua** tabel, lalu hanya mencabut `UPDATE/DELETE/TRUNCATE` pada `platform.audit_log`.
-- Akibatnya imutabilitas `ledger.journal`/`journal_line` bergantung pada trigger saja — padahal spec
-- menulis "trigger **+ privilege**", dan pemilik DB (bukan aplikasi) yang menjalankan
-- `UPDATE ledger.journal …` lewat koneksi runtime tidak akan ditahan apa pun. Baris `SUPERSEDED` di
-- `platform.param_value` (riwayat efektif-dated) juga bisa dihapus begitu saja.
--
-- **Kenapa migrasi, bukan hanya runbook.** Runbook adalah tindakan sekali di klaster produksi; ia
-- tidak ikut terpasang di lingkungan baru dan tidak diperiksa gate apa pun. Migrasi berjalan di
-- setiap deploy, jadi invarian ini ikut terbawa. `REVOKE` pada objek yang tidak pernah di-grant
-- adalah no-op: aman di DB dev/test yang tidak punya role runtime.
--
-- **Catatan default privilege.** `ALTER DEFAULT PRIVILEGES` tidak bisa mengecualikan tabel
-- tertentu, jadi tabel immutable **baru** harus dicabut hak tulisnya di migrasinya sendiri (pola
-- yang sama dengan berkas ini). Runbook diperbarui dengan peringatan itu.
--
-- Idempoten: `REVOKE` berulang tidak berefek bila haknya sudah tidak ada.

DO $$
DECLARE
  runtime constant text := 'kran_runtime';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = runtime) THEN
    RAISE NOTICE 'role % tidak ada di klaster ini — tidak ada hak yang dicabut (dev/test)',
      runtime;
    RETURN;
  END IF;

  -- Ledger: jurnal dan barisnya hanya boleh ditambah. Koreksi = jurnal pembalik (spec §9.1(3)).
  EXECUTE format(
    'REVOKE UPDATE, DELETE, TRUNCATE ON ledger.journal, ledger.journal_line FROM %I', runtime);

  -- Audit: append-only (sudah dicabut runbook; diulang supaya invarian punya satu sumber di repo).
  EXECUTE format(
    'REVOKE UPDATE, DELETE, TRUNCATE ON platform.audit_log FROM %I', runtime);

  -- Riwayat parameter efektif-dated: baris lama tetap dibaca; yang dilarang hanya menghapusnya.
  EXECUTE format('REVOKE DELETE, TRUNCATE ON platform.param_value FROM %I', runtime);
END
$$;
