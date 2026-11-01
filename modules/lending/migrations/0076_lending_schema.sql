-- Schema modul `lending` (T-161, spec §6.3: satu modul = satu schema Postgres).
--
-- Expand-only: hanya CREATE. Tabel ditambahkan lewat migrasi bernomor lebih besar; perubahan
-- destruktif butuh header `-- dbtools:destructive <alasan>` dan keputusan terpisah.
--
-- Nomor 0076+ dipilih karena modul ini mem-FK `party.party` dan `product.product_version`; urutan
-- migrasi global adalah `(seq, nama modul, nama berkas)`, dan seq yang lebih besar menjamin kedua
-- tabel itu sudah ada.
CREATE SCHEMA IF NOT EXISTS lending;
