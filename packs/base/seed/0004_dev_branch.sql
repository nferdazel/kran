-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2).
--
-- Cabang uji untuk e2e teller/print/buka rekening. Sejak D-135 nomor rekening memakai prefiks
-- **kode cabang 3 digit** dari `platform.branch`, dan `POST /api/v1/deposit/accounts` menolak
-- cabang yang belum terdaftar (409 `branch_not_registered`). Tanpa baris ini setiap e2e yang
-- membuka rekening lewat API gagal.
--
-- Kode `002` (bukan `001`): `001` sudah dipakai cabang pilot di migrasi `platform/0030`, yang juga
-- berjalan di DB dev/CI. Idempoten supaya seed boleh dijalankan berulang.

INSERT INTO platform.branch (branch_id, code, name)
VALUES ('e2e00000-0000-4000-8000-000000000001', '002', 'Cabang Uji')
ON CONFLICT DO NOTHING;
