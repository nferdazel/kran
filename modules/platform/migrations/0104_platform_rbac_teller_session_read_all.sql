-- Izin lintas-teller untuk membaca arus kas sesi kas (C-02, pentest ronde 2).
--
-- **Konteks.** `GET /api/v1/teller/sessions/{sessionId}/transactions` dulu hanya memeriksa cabang
-- sesi, bukan pemiliknya, sehingga teller lain di cabang yang sama bisa membaca nomor rekening,
-- nominal, arah, narasi, dan id jurnal transaksi rekannya. Penutupan sesi sudah menolak sesi asing
-- (`session_not_owned`), dan `GET current` menyaring per teller — jadi izin bacanya yang memang
-- kurang, bukan aturannya.
--
-- **Bentuk.** Pemilik sesi tetap memakai `teller.session.read` (sudah dipegang peran `teller` sejak
-- `0027`). Membaca sesi **orang lain** menuntut izin terpisah `teller.session.read_all`, diberikan
-- ke peran pengawas yang memang perlu membetulkan laci: `cash_admin` (penyediaan kas/vault cabang)
-- dan `platform_admin`. Peran `teller` **tidak** mendapatkannya — menambahkannya di sini akan
-- mengembalikan persis temuan yang ditutup.
--
-- **Kenapa izin baru, bukan memperluas `teller.session.read`.** `read` dipegang setiap teller; kalau
-- ia dibuat cukup untuk sesi siapa pun, tidak ada lagi batas antar-teller. Daftar grant ditulis
-- eksplisit (pola `0024`/`0025`), jadi peran yang ditambahkan kemudian tidak ikut diam-diam.
--
-- Idempoten (`ON CONFLICT DO NOTHING`).

INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'teller.session.read_all', 'teller', 'session', 'read_all',
   'perm.teller.session.read_all')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code IN ('cash_admin', 'platform_admin')
   AND p.code = 'teller.session.read_all'
ON CONFLICT DO NOTHING;
