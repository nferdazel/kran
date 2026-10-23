-- DEV/TEST ONLY — jangan dipakai di produksi (spec §18.2).
--
-- Fixture buku besar minimum untuk e2e T-079 (`/app/ledger`): izin **baca** buku besar untuk
-- `param_maker` (dev.maker), satu periode tahun berjalan, dan satu jurnal demo seimbang
-- (D 101 KAS / K 201 SIMPANAN). Tanpa ini layar buku besar — tempat kerja pertama setelah login —
-- hanya menampilkan "tidak punya izin membaca jurnal" atau "belum ada periode akuntansi", sehingga
-- gate axe/keyboard tidak bisa menyentuh tabelnya.
--
-- Batas sadar: **hanya baca** yang diberikan (`ledger.period.manage` tetap tidak), supaya pemisahan
-- tugas tetap utuh; angka jurnal sintetis, bukan klaim akuntansi (REG-011 `V!` tetap menunggu
-- compliance). Idempoten: periode `ON CONFLICT DO NOTHING` (menangkap bentrok PK **dan** constraint
-- EXCLUDE `period_no_overlap`), jurnal/baris dijaga `WHERE NOT EXISTS` supaya jurnal immutable tidak
-- pernah disisipkan ulang (trigger `journal_period_open` tidak ikut menyala bila baris sudah ada).

-- 1. Izin baca buku besar untuk dev.maker (`param_maker`). Bersihkan dulu, lalu beri ulang yang benar.
DELETE FROM platform.role_permission rp
 USING platform.role r, platform.permission p
 WHERE rp.role_id = r.role_id
   AND rp.permission_id = p.permission_id
   AND r.code = 'param_maker'
   AND p.code IN ('ledger.coa.read', 'ledger.period.read', 'ledger.journal.read');

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'param_maker'
   AND p.code IN ('ledger.coa.read', 'ledger.period.read', 'ledger.journal.read')
ON CONFLICT DO NOTHING;

-- 2. Periode tahun berjalan (id deterministik per tahun). Periode lama tidak diubah.
INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
SELECT md5('dev|ledger-period|' || to_char(now(), 'YYYY'))::uuid,
       date_trunc('year', now())::date,
       (date_trunc('year', now()) + interval '1 year' - interval '1 day')::date,
       'OPEN',
       md5('dev|dev.maker')::uuid,
       md5('dev|dev.maker')::uuid
ON CONFLICT DO NOTHING;

-- 3. Jurnal demo seimbang pada tanggal bisnis hari ini (di dalam periode di atas).
INSERT INTO ledger.journal (journal_id, business_date, value_date, source_event, source_ref,
                            idempotency_key, created_by)
SELECT md5('dev|ledger-journal|' || to_char(now(), 'YYYY-MM-DD'))::uuid,
       current_date,
       current_date,
       'dev.seed',
       md5('dev|ledger-seed')::uuid,
       'dev-seed-journal-' || to_char(now(), 'YYYY-MM-DD'),
       md5('dev|dev.maker')::uuid
 WHERE NOT EXISTS (
   SELECT 1 FROM ledger.journal
    WHERE idempotency_key = 'dev-seed-journal-' || to_char(now(), 'YYYY-MM-DD'));

-- 4. Baris jurnal. Satu `INSERT` banyak-baris: constraint trigger `journal_balanced` bertipe
--    DEFERRABLE, tetapi satu pernyataan tetap lebih aman walau skrip dijalankan tanpa transaksi.
INSERT INTO ledger.journal_line (journal_id, line_no, gl_account, branch_id, debit, credit)
SELECT md5('dev|ledger-journal|' || to_char(now(), 'YYYY-MM-DD'))::uuid,
       v.line_no,
       v.gl_account,
       'e2e00000-0000-4000-8000-000000000001'::uuid,
       v.debit,
       v.credit
  FROM (VALUES (1, '101', 10.0000::numeric, 0::numeric),
               (2, '201', 0::numeric, 10.0000::numeric)) AS v(line_no, gl_account, debit, credit)
 WHERE NOT EXISTS (
   SELECT 1 FROM ledger.journal_line
    WHERE journal_id = md5('dev|ledger-journal|' || to_char(now(), 'YYYY-MM-DD'))::uuid);
