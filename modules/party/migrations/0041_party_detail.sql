-- Detail party (orang/lembaga) + alamat: kolom PII terenkripsi (T-078, spec §8/§9.2/§18.2).
-- Expand-only: hanya CREATE.
--
-- Bentuk & alasan mengikuti D-069 (dokumen identitas): **tiap kolom sensitif** disimpan sebagai
-- tiga turunan, nilai aslinya tidak pernah masuk kolom:
--   * `<col>_enc`  = ciphertext field crypto (AAD = nama tabel `party_person`/`party_org`/`address`);
--     CHECK bentuk ciphertext membuat penyimpanan plaintext gagal di DB, bukan hanya di kode.
--     Konsekuensi: format ciphertext berversi — kenaikan versi (v2) butuh migrasi expand baru.
--   * `<col>_bidx` = blind index (HMAC-SHA256 dengan kunci turunan terpisah, hex 64) untuk
--     pencarian kesamaan; nilai asli tidak pernah muncul.
--   * `<col>_mask` = bentuk tersamar (dua karakter terakhir) supaya UI bisa menampilkan petunjuk
--     tanpa mendekripsi (§18.2: default masked). Ini **bukan rahasia** dan disimpan sengaja.
--
-- **HUMAN-REVIEW-REQUIRED**: area PII/enkripsi (AGENTS.md §8). Format kolom mengikuti D-069 supaya
-- tidak berubah lagi setelah ada data.
--
-- `party_person` dan `party_org` 1:1 dengan party (PK = party_id); `address` menyimpan alamat
-- (untuk sekarang 1:1 lewat `UNIQUE (party_id)`, tapi PK-nya id sendiri agar bisa tumbuh ke 1:N
-- tanpa migrasi destruktif).

CREATE TABLE party.party_person (
  party_id        uuid PRIMARY KEY REFERENCES party.party(party_id) ON DELETE RESTRICT,
  legal_name_enc  text NOT NULL CHECK (legal_name_enc LIKE 'kran:enc:v1:%'),
  legal_name_bidx text NOT NULL CHECK (legal_name_bidx ~ '^[0-9a-f]{64}$'),
  legal_name_mask text NOT NULL CHECK (char_length(legal_name_mask) <= 2),
  birth_date_enc  text NOT NULL CHECK (birth_date_enc LIKE 'kran:enc:v1:%'),
  birth_date_bidx text NOT NULL CHECK (birth_date_bidx ~ '^[0-9a-f]{64}$'),
  birth_date_mask text NOT NULL CHECK (char_length(birth_date_mask) <= 2),
  sex_enc         text NOT NULL CHECK (sex_enc LIKE 'kran:enc:v1:%'),
  sex_bidx        text NOT NULL CHECK (sex_bidx ~ '^[0-9a-f]{64}$'),
  sex_mask        text NOT NULL CHECK (char_length(sex_mask) <= 2),
  occupation_enc  text NOT NULL CHECK (occupation_enc LIKE 'kran:enc:v1:%'),
  occupation_bidx text NOT NULL CHECK (occupation_bidx ~ '^[0-9a-f]{64}$'),
  occupation_mask text NOT NULL CHECK (char_length(occupation_mask) <= 2),
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid NOT NULL
);

CREATE INDEX party_person_name_bidx_idx ON party.party_person (legal_name_bidx);

COMMENT ON TABLE party.party_person IS
  'Detail PII orang per party (T-078). Tiap field disimpan ciphertext+blind index+bentuk '
  'tersamar (pola D-069); nilai aslinya tidak pernah plaintext. Kriptografi dibuat composition '
  'root (apps/api), bukan modul.';

CREATE TABLE party.party_org (
  party_id        uuid PRIMARY KEY REFERENCES party.party(party_id) ON DELETE RESTRICT,
  legal_name_enc  text NOT NULL CHECK (legal_name_enc LIKE 'kran:enc:v1:%'),
  legal_name_bidx text NOT NULL CHECK (legal_name_bidx ~ '^[0-9a-f]{64}$'),
  legal_name_mask text NOT NULL CHECK (char_length(legal_name_mask) <= 2),
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid NOT NULL
);

CREATE INDEX party_org_name_bidx_idx ON party.party_org (legal_name_bidx);

COMMENT ON TABLE party.party_org IS
  'Detail PII lembaga per party (T-078): nama resmi. Pola penyimpanan sama dengan '
  'party.party_person (D-069).';

CREATE TABLE party.address (
  address_id      uuid PRIMARY KEY,
  party_id        uuid NOT NULL REFERENCES party.party(party_id) ON DELETE RESTRICT,
  line_enc        text NOT NULL CHECK (line_enc LIKE 'kran:enc:v1:%'),
  line_bidx       text NOT NULL CHECK (line_bidx ~ '^[0-9a-f]{64}$'),
  line_mask       text NOT NULL CHECK (char_length(line_mask) <= 2),
  city_enc        text NOT NULL CHECK (city_enc LIKE 'kran:enc:v1:%'),
  city_bidx       text NOT NULL CHECK (city_bidx ~ '^[0-9a-f]{64}$'),
  city_mask       text NOT NULL CHECK (char_length(city_mask) <= 2),
  postal_code_enc  text NOT NULL CHECK (postal_code_enc LIKE 'kran:enc:v1:%'),
  postal_code_bidx text NOT NULL CHECK (postal_code_bidx ~ '^[0-9a-f]{64}$'),
  postal_code_mask text NOT NULL CHECK (char_length(postal_code_mask) <= 2),
  created_at      timestamptz NOT NULL DEFAULT now(),
  created_by      uuid NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid NOT NULL,
  -- Untuk sekarang satu alamat aktif per party; PK tetap id sendiri agar 1:N menyusul tanpa
  -- migrasi destruktif. Upsert memakai `ON CONFLICT (party_id)`.
  CONSTRAINT address_party_uq UNIQUE (party_id)
);

CREATE INDEX address_party_idx ON party.address (party_id);

COMMENT ON TABLE party.address IS
  'Alamat party (T-078): baris alamat, kota, kode pos — tiap kolom ciphertext+blind index+bentuk '
  'tersamar (pola D-069). Belum ada alamat ganda (1:1) sampai kebutuhan 1:N muncul.';
