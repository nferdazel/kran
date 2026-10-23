-- Role scope enforcement + teller parameter read (RBAC hardening).
--
-- Two independent gaps found by the RBAC audit:
--
-- 1. Role scope. `platform.role` had no notion of whether a role is meaningful at institution
--    level or only within one branch. Nothing stopped `ctl create-user` from provisioning a
--    branch-only role (`teller`) without `--branch`, which produced a **global** grant that saw
--    every branch, nor an institution role (`product_checker`, `platform_admin`, `param_*`) with
--    `--branch`, which produced an account that institution routes never authorize (they call
--    `authorizedAtBranch(..., "")`, and a branch-limited grant does not cover the institution
--    target). The application now reads this column in `createUserWithRole` / role assignment and
--    rejects the mismatched combination before any row is written (see `auth_service`).
--
-- 2. `teller` lacked `platform.param.read`. The operator UI renders the configured F4/F5/F9
--    shortcuts from `platform.ui.shortcut.*`, which are exposed through the parameter read path
--    and therefore require this permission; without it the shortcuts never load. The grant is
--    read-only: teller gets no submit/approve rights (those stay with the maker/checker roles).
--
-- Structural, so it belongs in a migration (like 0008/0022-0027), not in institution parameters.
-- Idempotent so it is safe to re-run.

ALTER TABLE platform.role
  ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'INSTITUTION'
    CONSTRAINT role_scope_chk CHECK (scope IN ('INSTITUTION', 'BRANCH'));

COMMENT ON COLUMN platform.role.scope IS
  'Scope penugasan role: INSTITUTION = grant harus tanpa cabang, BRANCH = grant harus menamai satu cabang. Ditegakkan aplikasi saat provisioning/penugasan.';

-- Only `teller` is branch-bound today: its duties (cash session, cash/transfer posting, vault) are
-- per branch. Every other role is institution-level.
UPDATE platform.role SET scope = 'BRANCH' WHERE code = 'teller';

-- Explicit grant, pattern of 0008/0022-0027: list the permission code, never "all rows".
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'teller'
   AND p.code = 'platform.param.read'
ON CONFLICT DO NOTHING;
