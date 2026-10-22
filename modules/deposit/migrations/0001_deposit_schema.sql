-- Migrasi awal modul `deposit` (T-088a, spec §9.1(11): expand-only).
--
-- Satu modul = satu schema Postgres (spec §6.3). Tabel ditambahkan lewat migrasi bernomor lebih
-- besar; perubahan destruktif butuh header `-- dbtools:destructive <alasan>` dan keputusan
-- terpisah.
CREATE SCHEMA IF NOT EXISTS deposit;

-- Nomor urut rekening simpanan. Sequence (bukan tabel counter) karena nomor boleh berlubang saat
-- transaksi batal; nomor bisnis tidak boleh dipakai ulang (spec §9.1(8)). **Format** nomor dari
-- sequence ini masih provisoris — lihat `0003_deposit_account.sql` + `MODULE.md`.
CREATE SEQUENCE deposit.account_seq START WITH 1 INCREMENT BY 1 NO MAXVALUE CACHE 1;
