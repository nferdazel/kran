-- Migrasi awal modul `teller` (T-093, spec §9.2). Satu modul = satu schema Postgres (spec §6.3);
-- expand-only: hanya CREATE.
--
-- Berkas ini **hanya** membuat schema (tanpa tabel). Tabel sesi/vault mem-FK `platform.app_user`
-- (dibuat `platform/0006`) dan `deposit.transaction` (dibuat `deposit/0004`); urutan migrasi global
-- `(seq, modul, berkas)` menjalankan `teller` **setelah** `platform` pada seq yang sama, tetapi
-- `deposit/0004` berada di seq 4 dan `deposit` juga lebih dulu secara abjad — karena itu tabel
-- ditaruh di seq 6 (`0006_teller_session.sql`, D-122). Nomor `0002`..`0005` sengaja dilewati.
CREATE SCHEMA IF NOT EXISTS teller;
