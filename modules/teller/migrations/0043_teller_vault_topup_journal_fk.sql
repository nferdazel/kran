-- FK + keunikan jurnal pada pengajuan top-up vault (T-129/DB-2).
--
-- **Konteks.** `teller.vault_topup_request.journal_id` (0035) hanya `uuid` tanpa FK dan tanpa
-- UNIQUE, padahal pola yang sama di `deposit/0004` dan `deposit/0007` punya keduanya. Akibatnya
-- baris APPROVED bisa menunjuk jurnal yang tidak ada (mis. setelah pemulihan DB yang tidak lengkap)
-- dan satu jurnal bisa dipakai dua pengajuan — laporan kas jadi tidak bisa direkonsiliasi.
--
-- **Expand-only.** FK ditambahkan `NOT VALID` lalu `VALIDATE CONSTRAINT`: penambahan tidak memindai
-- tabel (tidak mengunci lama saat deploy) dan validasi hanya mengunci lembut setelahnya. Unique
-- index parsial `WHERE journal_id IS NOT NULL` karena baris SUBMITTED/REJECTED memang belum punya
-- jurnal.
--
-- Idempoten: `IF NOT EXISTS` pada constraint dan index supaya migrasi bisa dijalankan ulang pada DB
-- yang sudah menerimanya lewat pemulihan manual.

DO $$
BEGIN
  IF NOT EXISTS (
      SELECT 1 FROM pg_constraint
       WHERE conname = 'vault_topup_request_journal_fk'
         AND conrelid = 'teller.vault_topup_request'::regclass) THEN
    ALTER TABLE teller.vault_topup_request
      ADD CONSTRAINT vault_topup_request_journal_fk
      FOREIGN KEY (journal_id) REFERENCES ledger.journal (journal_id) NOT VALID;
  END IF;
END
$$;

ALTER TABLE teller.vault_topup_request
  VALIDATE CONSTRAINT vault_topup_request_journal_fk;

CREATE UNIQUE INDEX IF NOT EXISTS vault_topup_request_journal_uq
  ON teller.vault_topup_request (journal_id)
  WHERE journal_id IS NOT NULL;
