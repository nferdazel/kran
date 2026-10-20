-- Katalog izin jurnal `ledger` (T-073). Kode izin terikat kode program → migrasi, bukan setelan.
INSERT INTO platform.permission (permission_id, code, module, resource, action, description_key)
VALUES
  (gen_random_uuid(), 'ledger.journal.read', 'ledger', 'journal', 'read', 'perm.ledger.journal.read'),
  (gen_random_uuid(), 'ledger.journal.reverse', 'ledger', 'journal', 'reverse',
   'perm.ledger.journal.reverse')
ON CONFLICT (code) DO NOTHING;

INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'platform_admin'
   AND p.code IN ('ledger.journal.read', 'ledger.journal.reverse')
ON CONFLICT DO NOTHING;
