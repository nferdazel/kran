-- Sesi kas teller + vault + arus kas laci (T-093, spec §9.2/§11.6/§13). Expand-only: hanya CREATE.
--
-- **Nomor berkas `0006` (bukan `0002`)**: urutan migrasi global adalah `(seq, modul, berkas)`
-- (`tools/dbtools/lib.nim:migrationsOf`). Tabel di sini mem-FK `platform.app_user`
-- (`platform/0006`) dan `deposit.transaction` (`deposit/0004`). Pada seq 6 modul `platform`
-- berjalan **sebelum** `teller` (abjad), dan `deposit/0004` sudah lewat di seq 4 — jadi FK aman
-- (D-122). Diverifikasi `./task dbtools validate` + migrasi dari skema kosong lewat `itsession`.
--
-- **Tanpa jurnal GL.** T-093 tidak memposting jurnal untuk kas teller/variance: COA baru
-- ("kas teller"/"kas pusat") adalah keputusan akuntansi yang belum diambil (lihat
-- `docs/ACCEPTED-LIMITS.md`). Karena itu tidak ada kolom `journal_id` di sini.
--
-- **Tanpa FK `branch_id`**: belum ada tabel cabang (preseden `deposit/0003`).
--
-- **`vault` saldo awal** diisi lewat seed dev + runbook (top-up/rekonsiliasi = T-107, di luar
-- scope). `cash_movement` hanya 2 tipe (`CASH_IN`/`CASH_OUT`); opening float & counted cash adalah
-- **kolom sesi**, bukan baris movement (hindari tipe enum tanpa pemakai, D-095).

CREATE TABLE teller.vault (
  branch_id  uuid PRIMARY KEY,
  balance    numeric(24,4) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE teller.vault IS
  'Saldo kas fisik satu vault per cabang (T-093). Bertambah saat sesi ditutup (counted cash) dan '
  'berkurang saat sesi dibuka (opening float). CHECK balance >= 0 = backstop DB; operasi yang '
  'menolak saldo kurang ada di jalur tulis. Angka numeric(24,4), tanpa float.';

CREATE TABLE teller.teller_session (
  session_id     uuid PRIMARY KEY,
  branch_id      uuid NOT NULL,
  teller_user_id uuid NOT NULL REFERENCES platform.app_user(user_id),
  business_date  date NOT NULL,
  status         text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED')),
  opening_float  numeric(24,4) NOT NULL CHECK (opening_float >= 0),
  opened_at      timestamptz NOT NULL DEFAULT now(),
  opened_by      uuid NOT NULL REFERENCES platform.app_user(user_id),
  expected_cash  numeric(24,4),
  counted_cash   numeric(24,4),
  variance       numeric(24,4),
  note           text CHECK (note IS NULL OR length(note) <= 200),
  closed_at      timestamptz,
  closed_by      uuid REFERENCES platform.app_user(user_id),
  -- Sesi CLOSED wajib punya seluruh kolom penutup; sesi OPEN wajib tidak punya satu pun.
  CONSTRAINT teller_session_closed_chk CHECK (
    (status = 'CLOSED') = (closed_at IS NOT NULL AND counted_cash IS NOT NULL
                           AND expected_cash IS NOT NULL AND variance IS NOT NULL)),
  -- Variance = counted - expected, ditegakkan DB supaya baris tidak bisa "menyimpang" dari angka.
  CONSTRAINT teller_session_variance_chk CHECK (
    variance IS NULL OR variance = counted_cash - expected_cash)
);

COMMENT ON TABLE teller.teller_session IS
  'Sesi kas teller (T-093): satu sesi OPEN per (cabang, teller) dijaga partial unique index. '
  'opening_float masuk dari vault saat buka; expected_cash = opening_float + Σ CASH_IN − Σ CASH_OUT '
  'dihitung saat tutup; variance = counted_cash − expected_cash (positif = kas lebih). Tanpa GL.';

-- Satu sesi OPEN per (teller, cabang). Sesi lama tetap boleh ditutup; setelah CLOSED, sesi baru bebas.
CREATE UNIQUE INDEX teller_session_one_open_uq
  ON teller.teller_session (branch_id, teller_user_id) WHERE status = 'OPEN';

CREATE INDEX teller_session_branch_date_idx ON teller.teller_session (branch_id, business_date);

CREATE TABLE teller.cash_movement (
  movement_id    uuid PRIMARY KEY,
  session_id     uuid NOT NULL REFERENCES teller.teller_session(session_id),
  movement_type  text NOT NULL CHECK (movement_type IN ('CASH_IN', 'CASH_OUT')),
  amount         numeric(24,4) NOT NULL CHECK (amount > 0),
  -- Satu transaksi tunai = tepat satu baris movement (paritas `expected_cash`).
  transaction_id uuid NOT NULL REFERENCES deposit.transaction(transaction_id),
  business_date  date NOT NULL,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL,
  CONSTRAINT teller_cash_movement_transaction_uq UNIQUE (transaction_id)
);

COMMENT ON TABLE teller.cash_movement IS
  'Arus kas laci per sesi (T-093): CASH_IN (setoran masuk laci) / CASH_OUT (penarikan keluar laci). '
  'Setiap baris menunjuk tepat satu `deposit.transaction` (FK + UNIQUE) yang ditulis di transaksi DB '
  'yang sama; tanpa ini `expected_cash` bisa salah. Baris immutable (koreksi = transaksi baru).';

CREATE INDEX teller_cash_movement_session_idx ON teller.cash_movement (session_id);

-- Movement immutable: UPDATE/DELETE/TRUNCATE ditolak trigger `ledger.reject_mutation()` yang sudah
-- ada sejak `ledger/0003` (preseden `deposit/0005`). Tanpa ini, arus laci bisa dihitung ulang
-- dengan menghapus baris sehingga variance tutup menjadi palsu.
CREATE TRIGGER teller_cash_movement_immutable
  BEFORE UPDATE OR DELETE ON teller.cash_movement
  FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();

CREATE TRIGGER teller_cash_movement_no_truncate
  BEFORE TRUNCATE ON teller.cash_movement
  FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
