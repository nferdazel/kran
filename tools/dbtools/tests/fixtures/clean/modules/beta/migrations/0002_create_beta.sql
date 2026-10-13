-- Komentar ini menyebut drop table / truncate, tetapi bukan DDL.
CREATE TABLE IF NOT EXISTS platform.beta (
  beta_id uuid PRIMARY KEY,
  keterangan text DEFAULT 'truncate bukan perintah di sini'
);
