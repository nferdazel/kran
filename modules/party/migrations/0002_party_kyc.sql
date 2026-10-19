-- KYC & risiko modul `party` (T-071, spec §9.2/§18.2). Expand-only: hanya CREATE.
--
-- Bentuk & alasan (D-069):
--   * `identity_doc.number_enc` = ciphertext field crypto (AAD nama tabel `identity_doc`).
--     Nomor dokumen identitas (NIK/NPWP/paspor) **tidak pernah** disimpan plaintext; CHECK
--     bentuk ciphertext membuat penyimpanan plaintext gagal di DB, bukan hanya di kode.
--     Konsekuensi: format ciphertext berversi — kenaikan versi butuh migrasi expand baru.
--   * `number_bidx` = blind index (HMAC-SHA256 dengan kunci turunan terpisah, hex 64) untuk
--     pencarian kesamaan & deteksi duplikat. NIK hanya 16 digit, jadi hash polos tidak cukup.
--   * `number_last2` = dua karakter terakhir (bentuk tersamar) supaya UI bisa menampilkan
--     petunjuk tanpa mendekripsi (§18.2: default masked).
--   * `kyc_profile` satu baris per party (status + rating berjalan + jadwal re-KYC).
--   * `risk_rating` = **riwayat append-only**: setiap penilaian tercatat, tidak ada UPDATE/DELETE.

CREATE TABLE party.identity_doc (
  doc_id       uuid PRIMARY KEY,
  party_id     uuid NOT NULL REFERENCES party.party(party_id) ON DELETE RESTRICT,
  doc_type     text NOT NULL CHECK (length(doc_type) BETWEEN 1 AND 32),
  number_enc   text NOT NULL CHECK (number_enc LIKE 'kran:enc:v1:%'),
  number_bidx  text NOT NULL CHECK (number_bidx ~ '^[0-9a-f]{64}$'),
  number_last2 text NOT NULL CHECK (number_last2 ~ '^[A-Z0-9]{1,2}$'),
  issued_at    date,
  expires_at   date,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   uuid NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid NOT NULL,
  CONSTRAINT identity_doc_period_chk CHECK (
    expires_at IS NULL OR issued_at IS NULL OR expires_at >= issued_at),
  -- Satu nomor dokumen = satu baris, lintas party: itu inti deteksi duplikat (409 dari API).
  CONSTRAINT identity_doc_number_uq UNIQUE (doc_type, number_bidx)
);

CREATE INDEX identity_doc_party_idx ON party.identity_doc (party_id);

COMMENT ON TABLE party.identity_doc IS
  'Dokumen identitas party (T-071). number_enc = ciphertext field crypto (AAD identity_doc); '
  'number_bidx = blind index untuk duplikat; number_last2 = bentuk tersamar untuk UI.';

CREATE TABLE party.kyc_profile (
  party_id         uuid PRIMARY KEY REFERENCES party.party(party_id) ON DELETE RESTRICT,
  status           text NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING', 'VERIFIED', 'REJECTED')),
  risk_level       text NOT NULL CHECK (length(risk_level) BETWEEN 1 AND 32),
  risk_assessed_at timestamptz,
  next_review_due  date,
  created_at       timestamptz NOT NULL DEFAULT now(),
  created_by       uuid NOT NULL,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid NOT NULL
);

CREATE INDEX kyc_profile_review_idx ON party.kyc_profile (next_review_due);

COMMENT ON TABLE party.kyc_profile IS
  'Profil KYC per party (T-071): status, rating risiko berjalan, jadwal re-KYC. '
  'Nilai yang sah berasal dari parameter (party.kyc.risk_levels / review_months), bukan CHECK DB.';

CREATE TABLE party.risk_rating (
  rating_id   uuid PRIMARY KEY,
  party_id    uuid NOT NULL REFERENCES party.party(party_id) ON DELETE RESTRICT,
  level       text NOT NULL CHECK (length(level) BETWEEN 1 AND 32),
  reason      text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  assessed_at timestamptz NOT NULL,
  assessed_by uuid NOT NULL
);

CREATE INDEX risk_rating_party_idx ON party.risk_rating (party_id, assessed_at DESC);

COMMENT ON TABLE party.risk_rating IS
  'Riwayat penilaian risiko (append-only, T-071). Level berjalan = baris terbaru dan dicerminkan '
  'di party.kyc_profile. Penilaian manual oleh petugas; skor otomatis bukan lingkup task ini.';

CREATE FUNCTION party.risk_rating_immutable() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'party.risk_rating bersifat append-only (riwayat risiko tidak boleh diubah)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER risk_rating_immutable
  BEFORE UPDATE OR DELETE ON party.risk_rating
  FOR EACH ROW EXECUTE FUNCTION party.risk_rating_immutable();
