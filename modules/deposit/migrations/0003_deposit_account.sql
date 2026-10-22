-- Rekening simpanan + cache saldo (T-088a, spec §9.2). Expand-only: hanya CREATE.
--
-- **Nomor berkas `0002`, bukan `0001`/`0003` yang lebih intuitif.** Urutan migrasi global adalah
-- `(seq, nama modul, nama berkas)` (`tools/dbtools/lib.nim:migrationsOf`), jadi pada seq yang sama
-- modul yang abjadnya lebih dulu berjalan lebih dulu. Modul `deposit` < `product`, sehingga
-- `deposit/0002` berjalan **sebelum** `product/0002` yang membuat `product.product` /
-- `product.product_version` — padahal tabel ini mem-FK keduanya. Karena itu tabel akun ditaruh di
-- seq 3 (`0003_deposit_account.sql`) supaya berada setelah `product/0002`. Berkas `0002` sengaja
-- tidak dipakai. Diverifikasi `./task dbtools validate` + migrasi di DB kosong lewat `itaccount`.
--
-- Saldo disimpan **satu baris per rekening** (`account_balance`) sebagai cache untuk operasi
-- saldo (T-088b); sumber kebenaran tetap jurnal ledger (spec §9.1(4)). CHECK `balance >= 0` adalah
-- backstop DB; jalur tulis menegakkan syarat yang sama sebelum UPDATE (T-088b).
--
-- Kolom `currency` **tidak** ada: asumsi satu mata uang (spec §2.2; T-088 §8 butir 6).
-- `status` hanya ACTIVE/CLOSED — DORMANT/FROZEN belum punya aturan (T-088 §8 butir 8).
--
-- Nomor rekening **provisoris**: 10 digit zero-padded dari `deposit.account_seq`, tanpa check
-- digit. Bentuk final (prefix/check digit) menunggu parameter `deposit.account.number_format`
-- yang belum dibuat (belum ada konsumen di T-088a). **NEEDS-COMPLIANCE-REVIEW**: jangan mengarang
-- format lain sebelum pemilik/compliance memutuskan.

CREATE TABLE deposit.account (
  account_id         uuid PRIMARY KEY,
  account_no         text NOT NULL CHECK (length(account_no) BETWEEN 1 AND 32),
  party_id           uuid NOT NULL REFERENCES party.party(party_id),
  product_id         uuid NOT NULL REFERENCES product.product(product_id),
  product_version_id uuid NOT NULL REFERENCES product.product_version(version_id),
  branch_id          uuid NOT NULL,
  account_type       text NOT NULL CHECK (account_type IN ('SAVINGS')),
  status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CLOSED')),
  opened_on          date NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid NOT NULL,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  updated_by         uuid NOT NULL,
  CONSTRAINT deposit_account_no_uq UNIQUE (account_no)
);

COMMENT ON TABLE deposit.account IS
  'Rekening simpanan (T-088a): identitas + produk/versi yang dipin. Saldo ada di account_balance; '
  'satu cabang per rekening (branch_id), tanpa FK karena belum ada tabel cabang.';

CREATE INDEX deposit_account_party_idx ON deposit.account (party_id);
CREATE INDEX deposit_account_branch_idx ON deposit.account (branch_id);

CREATE TABLE deposit.account_balance (
  account_id uuid PRIMARY KEY REFERENCES deposit.account(account_id) ON DELETE RESTRICT,
  balance    numeric(24,4) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE deposit.account_balance IS
  'Cache saldo satu baris per rekening (T-088a). CHECK balance >= 0 = backstop DB; operasi yang '
  'menolak saldo negatif ada di jalur tulis (T-088b). Angka disimpan numeric(24,4), tanpa float.';
