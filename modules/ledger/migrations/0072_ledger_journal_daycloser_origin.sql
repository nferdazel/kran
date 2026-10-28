-- Penanda provenance jurnal milik run penutupan buku (T-140).
--
-- Gate pasca-tutup `ledger.no_late_postings` (`DAY-310`) menandai jurnal bertanggal buku yang
-- **direkam setelah** tanggal dibekukan; tujuannya menangkap tulisan HTTP yang lolos sebelum freeze
-- lalu commit sesudahnya. Masalahnya: jurnal yang **dibuat oleh task penutupan itu sendiri**
-- (akrual bunga, perpindahan jatuh tempo) juga direkam setelah freeze, sehingga setiap penutupan
-- dengan rekening berjangka akan diblokir gate-nya sendiri — ditemukan saat benchmark EOD T-140.
--
-- Kolom ini memberi provenance yang bisa dipercaya: task day-close mengisi `run_id`-nya, dan gate
-- mengabaikan jurnal ber-`daycloser_run_id`. Tanpa FK lintas modul (pola `deposit.transaction`),
-- supaya urutan migrasi/rollback antar schema tidak saling mengunci.
--
-- Idempoten (expand-only, `ADD COLUMN IF NOT EXISTS`).

ALTER TABLE ledger.journal
  ADD COLUMN IF NOT EXISTS daycloser_run_id uuid;

CREATE INDEX IF NOT EXISTS journal_daycloser_run_idx
  ON ledger.journal (daycloser_run_id)
  WHERE daycloser_run_id IS NOT NULL;

COMMENT ON COLUMN ledger.journal.daycloser_run_id IS
  'Run day-close yang membuat jurnal ini (NULL = jurnal dari jalur bisnis). Dipakai gate '
  'ledger.no_late_postings untuk membedakan tulisan terlambat dari jurnal penutupan itu sendiri.';
