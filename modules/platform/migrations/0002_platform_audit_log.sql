-- 0002: `platform.audit_log` — append-only + hash chain (spec §9.1(7), §18.2).
--
-- Rantai: setiap baris menyimpan `prev_hash` (hash baris sebelumnya) dan `hash` =
-- SHA-256(prev_hash || '|' || payload-kanonik-baris). Payload memakai bentuk teks yang
-- **stabil** (UTC eksplisit, tanggal ISO, `host(inet)`) supaya verifikasi tidak bergantung
-- pada `TimeZone`/`DateStyle` sesi.
--
-- Batas yang diketahui (jujur): rantai mendeteksi perubahan tanpa rekalkulasi. Penyerang
-- dengan hak tulis penuh bisa menulis ulang seluruh ekor rantai; itu ditutup oleh *anchor*
-- harian (hash dirantai ke tempat terpisah, spec §18.2) — task terpisah, lihat
-- docs/OPEN_ITEMS.md.
--
-- Expand-only: hanya CREATE.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE platform.audit_log (
  seq           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  audit_id      uuid NOT NULL DEFAULT gen_random_uuid(),
  recorded_at   timestamptz NOT NULL DEFAULT now(),
  business_date date,
  actor_user_id uuid,
  actor_role    text,
  branch_id     uuid,
  request_id    text,
  client_ip     inet,
  device        text,
  action        text NOT NULL,
  resource_type text NOT NULL,
  resource_id   text,
  reason        text,
  before_value  jsonb,
  after_value   jsonb,
  prev_hash     text NOT NULL,
  hash          text NOT NULL,
  CONSTRAINT audit_log_audit_id_uq UNIQUE (audit_id)
);

COMMENT ON TABLE platform.audit_log IS
  'Append-only + hash chain (tamper-evident). Verifikasi: SELECT * FROM platform.audit_verify().';

COMMENT ON COLUMN platform.audit_log.before_value IS 'Snapshot sebelum perubahan (jsonb, tanpa PII mentah — lihat spec §18.2 masking).';

CREATE FUNCTION platform.audit_log_payload(r platform.audit_log) RETURNS text
LANGUAGE sql STABLE AS $fn$
  SELECT jsonb_build_object(
    'audit_id', r.audit_id::text,
    'recorded_at', to_char(r.recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'business_date', to_char(r.business_date, 'YYYY-MM-DD'),
    'actor_user_id', r.actor_user_id::text,
    'actor_role', r.actor_role,
    'branch_id', r.branch_id::text,
    'request_id', r.request_id,
    'client_ip', host(r.client_ip),
    'device', r.device,
    'action', r.action,
    'resource_type', r.resource_type,
    'resource_id', r.resource_id,
    'reason', r.reason,
    'before', r.before_value,
    'after', r.after_value
  )::text
$fn$;

CREATE FUNCTION platform.audit_log_chain() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE
  prev_hash_value text;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'platform.audit_log hanya menerima INSERT (dapat %)', TG_OP;
  END IF;
  -- Serialkan append: hash harus merantai ke baris terakhir yang benar-benar commit.
  PERFORM pg_advisory_xact_lock(hashtext('platform.audit_log'));
  SELECT a.hash INTO prev_hash_value
  FROM platform.audit_log a ORDER BY a.seq DESC LIMIT 1;
  IF prev_hash_value IS NULL THEN
    prev_hash_value := repeat('0', 64);
  END IF;
  NEW.prev_hash := prev_hash_value;
  NEW.hash := encode(
    digest(prev_hash_value || '|' || platform.audit_log_payload(NEW), 'sha256'), 'hex');
  RETURN NEW;
END
$fn$;

CREATE TRIGGER audit_log_chain_trg
  BEFORE INSERT ON platform.audit_log
  FOR EACH ROW EXECUTE FUNCTION platform.audit_log_chain();

CREATE FUNCTION platform.audit_log_immutable() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  RAISE EXCEPTION
    'platform.audit_log append-only: % ditolak (spec §9.1(3), §18.2)', TG_OP
    USING ERRCODE = 'restrict_violation';
END
$fn$;

CREATE TRIGGER audit_log_no_change_trg
  BEFORE UPDATE OR DELETE ON platform.audit_log
  FOR EACH ROW EXECUTE FUNCTION platform.audit_log_immutable();

CREATE TRIGGER audit_log_no_purge_trg
  BEFORE TRUNCATE ON platform.audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION platform.audit_log_immutable();

CREATE INDEX audit_log_recorded_at_idx ON platform.audit_log (recorded_at);
CREATE INDEX audit_log_resource_idx ON platform.audit_log (resource_type, resource_id);
CREATE INDEX audit_log_actor_idx ON platform.audit_log (actor_user_id, recorded_at);

CREATE FUNCTION platform.audit_verify(p_from_seq bigint DEFAULT 0)
RETURNS TABLE (seq bigint, row_hash_ok boolean, link_ok boolean,
               expected_hash text, actual_hash text)
LANGUAGE sql STABLE AS $fn$
  WITH ordered AS (
    SELECT a AS r, lag(a.hash) OVER (ORDER BY a.seq) AS previous_hash
    FROM platform.audit_log a
  )
  SELECT (o.r).seq AS seq,
         (o.r).hash = encode(
            digest((o.r).prev_hash || '|' || platform.audit_log_payload(o.r), 'sha256'),
            'hex') AS row_hash_ok,
         coalesce(o.previous_hash, repeat('0', 64)) = (o.r).prev_hash AS link_ok,
         encode(
            digest((o.r).prev_hash || '|' || platform.audit_log_payload(o.r), 'sha256'),
            'hex') AS expected_hash,
         (o.r).hash AS actual_hash
  FROM ordered o
  WHERE (o.r).seq >= p_from_seq
  ORDER BY (o.r).seq
$fn$;
