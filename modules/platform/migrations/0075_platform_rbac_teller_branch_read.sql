-- Teller boleh membaca master cabang (T-141/D-160).
--
-- Layar kas adalah stasiun kerja: sesi kas dibuka untuk satu cabang **sebelum** rekening anggota
-- dimuat (DESIGN §11). Untuk memilih cabang, operator butuh daftar cabang, dan daftar itu hanya
-- tersedia lewat `GET /api/v1/branches` yang menuntut `platform.branch.read`.
--
-- Izin ini **baca saja** dan sudah dimiliki peran operator lain sejak `0037` (ops_admin, cash_admin,
-- ledger_admin); peran `teller` yang ditambahkan `0027` terlewat. Tanpa grant ini, teller tidak bisa
-- memakai layar kas tanpa memuat rekening — persis kebuntuan yang ditutup T-141.
--
-- Idempoten (`ON CONFLICT DO NOTHING`).

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'teller' AND p.code = 'platform.branch.read'
ON CONFLICT DO NOTHING;
