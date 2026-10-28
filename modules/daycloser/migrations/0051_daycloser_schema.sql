-- 0051: kerangka day-close — run, task, chunk, registry, checkpoint (spec §11.8).
--
-- Expand-only: hanya CREATE. Tidak ada nilai bisnis di sini; yang menyimpan angka adalah
-- `platform.param_value` (daycloser.chunk_size, daycloser.max_attempts,
-- daycloser.retry_backoff_seconds) dan dibekukan ke `run.param_snapshot` saat run dibuat.
--
-- Deviasi dari ringkasan DDL spec §11.8 (disengaja, dicatat di docs/DECISIONS.md D-148):
--   1. `param_snapshot_id uuid` diganti `param_snapshot jsonb` + `param_snapshot_hash` —
--      snapshot parameter institusi belum punya tabel sendiri, dan FK ke tabel yang tidak ada
--      hanya menunda kerja tanpa menambah jaminan.
--   2. `scope_id` bertipe `text` (sama dengan `platform.business_date`), bukan uuid: scope dapat
--      berupa institusi (kosong) atau cabang.
--   3. Kolom `control` ditambahkan — pause/cancel dibaca orkestrator di batas chunk (spec §11.7).

CREATE SCHEMA IF NOT EXISTS daycloser;

COMMENT ON SCHEMA daycloser IS
  'Orkestrasi penutupan hari/bulan/tahun (spec §11). Modul lain hanya mendaftarkan task; tidak ada batch/cron sendiri (AGENTS.md §1.7).';

CREATE TABLE daycloser.run (
  run_id              uuid PRIMARY KEY,
  scope_type          text NOT NULL DEFAULT 'INSTITUTION',
  scope_id            text,
  business_date       date NOT NULL,
  levels              text[] NOT NULL,
  mode                text NOT NULL DEFAULT 'REAL',
  state               text NOT NULL,
  control             text NOT NULL DEFAULT 'NONE',
  param_snapshot      jsonb NOT NULL,
  param_snapshot_hash text NOT NULL,
  started_at          timestamptz,
  finished_at         timestamptz,
  started_by          uuid,
  summary_hash        text,
  CONSTRAINT run_scope_chk CHECK (scope_type IN ('INSTITUTION', 'BRANCH')),
  CONSTRAINT run_root_scope_chk CHECK (scope_type = 'INSTITUTION' OR scope_id IS NOT NULL),
  CONSTRAINT run_levels_chk CHECK (array_length(levels, 1) >= 1),
  CONSTRAINT run_mode_chk CHECK (mode IN ('REAL', 'SIMULATION')),
  CONSTRAINT run_state_chk CHECK (state IN
    ('PLANNED','PRECHECK','RUNNING','POSTCHECK','COMPLETED','FAILED','BLOCKED','PAUSED','CANCELED')),
  CONSTRAINT run_control_chk CHECK (control IN ('NONE', 'PAUSE', 'CANCEL')),
  CONSTRAINT run_summary_chk CHECK (summary_hash IS NULL OR state = 'COMPLETED')
);

COMMENT ON TABLE daycloser.run IS
  'Satu eksekusi penutupan untuk satu business date & scope (spec §11.2). `summary_hash` = segel bukti hasil run.';
COMMENT ON COLUMN daycloser.run.param_snapshot IS
  'Parameter daycloser.* efektif saat run dibuat; dipakai ulang pada resume supaya perubahan parameter di tengah run tidak mengubah perilaku.';

-- Hanya satu run per (scope, tanggal) kecuali yang sudah COMPLETED/CANCELED. FAILED dan BLOCKED
-- **ikut** di sini: keduanya belum selesai dan harus dilanjutkan (`resume`) atau dibatalkan, bukan
-- diulang dari nol — mengulang akan mengeksekusi ulang chunk yang sudah sukses untuk task yang
-- boleh `NONE` idempotensinya.
CREATE UNIQUE INDEX run_one_per_date_uq
  ON daycloser.run (scope_type, COALESCE(scope_id, ''), business_date)
  WHERE state IN ('PLANNED','PRECHECK','RUNNING','POSTCHECK','PAUSED','FAILED','BLOCKED');

CREATE INDEX run_state_idx ON daycloser.run (state);
CREATE INDEX run_business_date_idx ON daycloser.run (business_date);

CREATE TABLE daycloser.task (
  run_id      uuid NOT NULL REFERENCES daycloser.run(run_id),
  task_id     text NOT NULL,
  kind        text NOT NULL,
  critical    boolean NOT NULL,
  state       text NOT NULL,
  attempt     integer NOT NULL DEFAULT 0,
  started_at  timestamptz,
  finished_at timestamptz,
  error       jsonb,
  metrics     jsonb,
  PRIMARY KEY (run_id, task_id),
  CONSTRAINT task_kind_chk CHECK (kind IN ('PRECHECK','PROCESS','POSTCHECK','REPORT')),
  CONSTRAINT task_state_chk CHECK (state IN
    ('PENDING','READY','RUNNING','SUCCEEDED','FAILED','SKIPPED','CANCELED')),
  CONSTRAINT task_attempt_chk CHECK (attempt >= 0)
);

COMMENT ON TABLE daycloser.task IS
  'State per task dalam satu run (spec §11.3). `error` menyimpan kode+pesan diagnostik, bukan teks UI.';

CREATE TABLE daycloser.chunk (
  run_id      uuid NOT NULL,
  task_id     text NOT NULL,
  chunk_no    integer NOT NULL,
  range_start text,
  range_end   text,
  state       text NOT NULL,
  attempt     integer NOT NULL DEFAULT 0,
  started_at  timestamptz,
  finished_at timestamptz,
  error       jsonb,
  PRIMARY KEY (run_id, task_id, chunk_no),
  CONSTRAINT chunk_task_fk FOREIGN KEY (run_id, task_id)
    REFERENCES daycloser.task(run_id, task_id),
  CONSTRAINT chunk_state_chk CHECK (state IN ('PENDING','RUNNING','SUCCEEDED','FAILED')),
  CONSTRAINT chunk_no_chk CHECK (chunk_no >= 0),
  CONSTRAINT chunk_attempt_chk CHECK (attempt >= 0)
);

COMMENT ON TABLE daycloser.chunk IS
  'Checkpoint per potongan kerja (spec §11.3). `range_start`/`range_end` metadata untuk audit/UI; task memilih datanya dari chunk_no.';

CREATE TABLE daycloser.task_registry (
  task_id         text PRIMARY KEY,
  module          text NOT NULL,
  levels          text[] NOT NULL,
  kind            text NOT NULL,
  critical        boolean NOT NULL,
  idempotency     text NOT NULL,
  partition       text NOT NULL,
  required_params text[] NOT NULL DEFAULT '{}',
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT task_registry_levels_chk CHECK (array_length(levels, 1) >= 1),
  CONSTRAINT task_registry_kind_chk CHECK (kind IN ('PRECHECK','PROCESS','POSTCHECK','REPORT')),
  CONSTRAINT task_registry_idem_chk CHECK (idempotency IN
    ('PER_BUSINESS_DATE','PER_ENTITY','NONE')),
  CONSTRAINT task_registry_partition_chk CHECK (partition IN ('SINGLE','BY_CHUNK_COUNT'))
);

COMMENT ON TABLE daycloser.task_registry IS
  'Salinan registry task saat boot (spec §11.4) untuk UI & audit; kebenaran eksekusi tetap registry in-process.';

CREATE TABLE daycloser.checkpoint (
  scope_type         text NOT NULL,
  scope_id           text NOT NULL DEFAULT '',
  task_id            text NOT NULL,
  entity_key         text NOT NULL,
  last_business_date date NOT NULL,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (scope_type, scope_id, task_id, entity_key),
  CONSTRAINT checkpoint_scope_chk CHECK (scope_type IN ('INSTITUTION', 'BRANCH'))
);

COMMENT ON TABLE daycloser.checkpoint IS
  'Checkpoint per entitas untuk task idempoten PER_ENTITY (spec §11.4). Hanya boleh maju — dijaga repositori.';

-- Hak role runtime. Pola sama dengan modul lain: no-op bila role belum ada (dev/CI).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'kran_runtime') THEN
    GRANT USAGE ON SCHEMA daycloser TO kran_runtime;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA daycloser TO kran_runtime;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA daycloser TO kran_runtime;
  END IF;
END
$$;
