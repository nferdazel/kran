-- Index untuk filter `action LIKE 'x%'` pada jejak audit (T-133/DB-11). Expand-only.
--
-- `GET /api/v1/audit?action=` menerjemahkan filter menjadi `action LIKE 'nilai%'`. Tanpa index,
-- Postgres memindai **seluruh** `audit_log` (urut mundur) lalu memotong `LIMIT` — makin mahal
-- seiring bertambahnya jejak, dan jejak audit tidak pernah dipangkas (O-013/DB-12).
--
-- `text_pattern_ops` dipakai supaya index tetap dipakai untuk `LIKE` berprefiks apa pun collation
-- database-nya; index btree biasa hanya mendukung `LIKE` berprefiks pada collation C.
--
-- Idempoten: `IF NOT EXISTS`.

CREATE INDEX IF NOT EXISTS audit_log_action_pattern_idx
  ON platform.audit_log (action text_pattern_ops);
