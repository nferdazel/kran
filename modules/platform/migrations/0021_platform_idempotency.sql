-- T-084 / D-098: kunci idempotensi untuk endpoint pembuat objek.
--
-- Baris ditulis **di dalam transaksi bisnis** pemanggil, bukan oleh middleware: kalau operasi
-- bisnis gagal, klaim ikut ter-rollback sehingga percobaan ulang dengan kunci yang sama tetap
-- boleh. Replay hanya menyimpan respons sukses (2xx); respons error tidak pernah di-cache.
CREATE TABLE platform.idempotency_key (
  principal_id    uuid NOT NULL REFERENCES platform.app_user(user_id) ON DELETE CASCADE,
  key             text NOT NULL,
  operation_id    text NOT NULL,
  request_hash    text NOT NULL,
  response_status integer,
  response_body   jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  expires_at      timestamptz NOT NULL,
  PRIMARY KEY (principal_id, key),
  CONSTRAINT idempotency_key_len_chk CHECK (length(key) BETWEEN 1 AND 200),
  CONSTRAINT idempotency_key_operation_chk CHECK (length(operation_id) > 0),
  CONSTRAINT idempotency_key_hash_chk CHECK (length(request_hash) > 0),
  CONSTRAINT idempotency_status_chk
    CHECK (response_status IS NULL OR (response_status >= 200 AND response_status < 300)),
  CONSTRAINT idempotency_time_chk CHECK (expires_at > created_at),
  CONSTRAINT idempotency_completed_chk CHECK (completed_at IS NULL OR completed_at >= created_at),
  CONSTRAINT idempotency_complete_chk CHECK (
    (response_status IS NULL AND response_body IS NULL AND completed_at IS NULL)
    OR (response_status IS NOT NULL AND response_body IS NOT NULL AND completed_at IS NOT NULL)
  )
);

COMMENT ON TABLE platform.idempotency_key IS
  'Klaim Idempotency-Key per principal (D-098). Ditulis dalam transaksi bisnis; replay hanya 2xx.';

-- Pembersihan baris kedaluwarsa berjalan lewat daycloser (task terpisah); indeks ini yang
-- membuat sapuannya murah.
CREATE INDEX idempotency_expires_idx ON platform.idempotency_key (expires_at);
