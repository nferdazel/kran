-- Migrasi awal modul `ledger` (T-072, spec §9.1(11): expand-only). Hanya CREATE.
--
-- COA & periode adalah fondasi jurnal double-entry (T-073). Belum ada saldo/jurnal di sini.
--   * `coa_account.normal_side` disimpan eksplisit (laporan membutuhkannya) tetapi dijaga CHECK
--     konsisten dengan `account_type`: ASSET/EXPENSE = DEBIT, LIABILITY/EQUITY/REVENUE = CREDIT.
--     Ini invarian akuntansi, bukan setelan institusi — format kode COA yang merupakan
--     kebijakan institusi ada di parameter `ledger.coa.code_pattern` (spec §10.5).
--   * `coa_account` **tidak** punya kolom cabang: GL dimiliki institusi, bukan cabang (spec §9).
--   * `period` memakai rentang tanggal **inklusif**. `EXCLUDE … WITH &&` menolak periode
--     tumpang tindih tanpa perlu kode aplikasi. Exclusion **murni antar-range** memakai opclass
--     `range_ops` bawaan PostgreSQL (tidak butuh `btree_gist`); ekstensi itu baru diperlukan bila
--     kelak digabung kolom skalar (mis. `branch_id WITH =`), dan dipasang migrasi platform 0004.
--   * Urutan penutupan (tidak menutup periode lebih awal saat sebelumnya masih terbuka) **tidak**
--     ditegakkan di sini; itu orkestrasi EOD/EOM (`daycloser`, Fase 5). Lihat `docs/tasks/T-072.md`.

CREATE SCHEMA IF NOT EXISTS ledger;

CREATE TABLE ledger.coa_account (
  account_id   uuid PRIMARY KEY,
  code         text NOT NULL CHECK (length(code) BETWEEN 1 AND 32),
  name         text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 200),
  account_type text NOT NULL
               CHECK (account_type IN ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE')),
  normal_side  text NOT NULL CHECK (normal_side IN ('DEBIT', 'CREDIT')),
  postable     boolean NOT NULL DEFAULT true,
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'INACTIVE')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid NOT NULL,
  CONSTRAINT coa_normal_side_chk CHECK (
    (account_type IN ('ASSET', 'EXPENSE') AND normal_side = 'DEBIT')
    OR (account_type IN ('LIABILITY', 'EQUITY', 'REVENUE') AND normal_side = 'CREDIT')),
  CONSTRAINT coa_code_uq UNIQUE (code)
);

CREATE INDEX coa_type_idx ON ledger.coa_account (account_type);

COMMENT ON TABLE ledger.coa_account IS
  'Chart of Accounts (T-072). Format kode = parameter ledger.coa.code_pattern; normal_side '
  'diturunkan dari account_type dan dijaga CHECK. Akun header/induk: postable = false.';

CREATE TABLE ledger.period (
  period_id  uuid PRIMARY KEY,
  starts_on  date NOT NULL,
  ends_on    date NOT NULL,
  status     text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN', 'CLOSED')),
  closed_at  timestamptz,
  closed_by  uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NOT NULL,
  CONSTRAINT period_order_chk CHECK (ends_on >= starts_on),
  CONSTRAINT period_closed_chk CHECK (
    (status = 'CLOSED' AND closed_at IS NOT NULL AND closed_by IS NOT NULL)
    OR (status = 'OPEN' AND closed_at IS NULL AND closed_by IS NULL)),
  CONSTRAINT period_no_overlap EXCLUDE USING gist (daterange(starts_on, ends_on, '[]') WITH &&)
);

CREATE INDEX period_range_idx ON ledger.period (starts_on, ends_on);

COMMENT ON TABLE ledger.period IS
  'Periode akuntansi (T-072), rentang inklusif. Tumpang tindih ditolak EXCLUDE; urutan tutup '
  'diatur daycloser (Fase 5), bukan constraint di sini.';
