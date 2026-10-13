-- 0003: `platform.outbox` + `platform.inbox` (spec §12.4, §19.1).
--
-- Outbox ditulis **dalam transaksi yang sama** dengan perubahan state (at-least-once),
-- `inbox` per konsumen untuk de-dup (efektif once).
--
-- `dedup_key` = kunci idempotensi peristiwa (mis. `param.update:<entity>:<version>`); UNIQUE,
-- sehingga publisher yang di-retry tidak menghasilkan peristiwa ganda.
--
-- Expand-only: hanya CREATE.

CREATE TABLE platform.outbox (
  outbox_id      uuid PRIMARY KEY,
  seq            bigint GENERATED ALWAYS AS IDENTITY,
  occurred_at    timestamptz NOT NULL DEFAULT now(),
  available_at   timestamptz NOT NULL DEFAULT now(),
  event_type     text NOT NULL,
  event_version  int  NOT NULL DEFAULT 1,
  aggregate_type text NOT NULL,
  aggregate_id   text NOT NULL,
  payload        jsonb NOT NULL,
  headers        jsonb NOT NULL DEFAULT '{}'::jsonb,
  dedup_key      text NOT NULL,
  status         text NOT NULL DEFAULT 'PENDING',
  attempts       int  NOT NULL DEFAULT 0,
  locked_by      text,
  locked_at      timestamptz,
  last_error     text,
  CONSTRAINT outbox_status_chk CHECK (status IN ('PENDING','IN_FLIGHT','DONE','DEAD')),
  CONSTRAINT outbox_dedup_key_uq UNIQUE (dedup_key),
  CONSTRAINT outbox_seq_uq UNIQUE (seq)
);

COMMENT ON TABLE platform.outbox IS
  'Transactional outbox: ditulis satu transaksi dengan perubahan state; dispatcher memakai FOR UPDATE SKIP LOCKED.';

COMMENT ON COLUMN platform.outbox.dedup_key IS
  'Kunci idempotensi peristiwa; UNIQUE mencegah peristiwa ganda saat retry (spec §12.4).';

COMMENT ON COLUMN platform.outbox.available_at IS
  'Dispatch boleh dilakukan setelah waktu ini (backoff setelah kegagalan).';

CREATE INDEX outbox_dispatch_idx ON platform.outbox (status, available_at, seq);

CREATE TABLE platform.inbox (
  consumer    text NOT NULL,
  event_id    uuid NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (consumer, event_id)
);

COMMENT ON TABLE platform.inbox IS
  'De-dup per konsumen: INSERT ... ON CONFLICT DO NOTHING; 0 baris = sudah pernah diproses.';
