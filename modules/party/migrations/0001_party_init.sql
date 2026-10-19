-- Migrasi awal modul `party` (T-070, spec §9.1(11): expand-only).
--
-- Satu modul = satu schema Postgres (spec §6.3). Data PII (NIK, alamat, dokumen) **belum** ada di
-- sini: masuk T-071 bersama field crypto, supaya tidak ada kolom sensitif yang lahir plaintext.
CREATE SCHEMA IF NOT EXISTS party;

-- Nomor urut CIF. Sequence (bukan tabel counter) karena CIF boleh berlubang saat transaksi batal;
-- format/lebar/prefix adalah parameter `party.cif.format`, bukan kode.
CREATE SEQUENCE party.cif_seq START WITH 1 INCREMENT BY 1 NO MAXVALUE CACHE 1;

CREATE TABLE party.party (
  party_id     uuid PRIMARY KEY,
  cif          text NOT NULL CHECK (length(cif) BETWEEN 1 AND 32),
  kind         text NOT NULL CHECK (kind IN ('PERSON', 'ORG')),
  display_name text NOT NULL CHECK (length(display_name) BETWEEN 2 AND 200),
  status       text NOT NULL DEFAULT 'ACTIVE'
               CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
  branch_id    uuid NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid NOT NULL,
  CONSTRAINT party_cif_unique UNIQUE (cif)
);

CREATE INDEX party_branch_idx ON party.party (branch_id);
