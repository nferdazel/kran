-- 0001: schema `platform` (tabel lintas-modul — spec §9.2).
-- Expand-only.

CREATE SCHEMA IF NOT EXISTS platform;

COMMENT ON SCHEMA platform IS
  'Tabel lintas modul: audit, outbox/inbox, parameter, user/role/session (spec §9.2).';
