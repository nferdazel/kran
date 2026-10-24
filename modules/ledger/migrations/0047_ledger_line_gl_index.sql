-- Index untuk kolom yang dipakai FK + laporan (T-133/DB-9). Expand-only: hanya CREATE INDEX.
--
-- `ledger.journal_line.gl_account` adalah FK ke `ledger.coa_account(code)` dan dipakai setiap
-- laporan saldo/trial balance (`GROUP BY gl_account`, join bagan akun, dan pengecekan akun yang
-- bergerak). Postgres **tidak** membuat index otomatis untuk sisi anak FK, jadi tanpa index ini
-- pemangkasan/penghapusan akun dan laporan per akun memindai seluruh `journal_line` — tabel yang
-- tumbuh paling cepat di sistem ini.
--
-- `CONCURRENTLY` sengaja tidak dipakai: migrasi berjalan di dalam transaksi, dan `CREATE INDEX
-- CONCURRENTLY` tidak boleh di dalam blok transaksi. Ukuran tabel pilot masih kecil; bila kelak
-- perlu index tanpa mengunci, jalur yang benar adalah migrasi terpisah di luar transaksi.
--
-- Idempoten: `IF NOT EXISTS`.

CREATE INDEX IF NOT EXISTS journal_line_gl_account_idx
  ON ledger.journal_line (gl_account);
