-- Migrasi awal modul `hello` (spec §9.1(11): expand-only).
--
-- Satu modul = satu schema Postgres (spec §6.3). Tabel ditambahkan lewat migrasi bernomor
-- lebih besar; perubahan destruktif butuh header `-- dbtools:destructive <alasan>` dan
-- keputusan terpisah.
CREATE SCHEMA IF NOT EXISTS hello;
