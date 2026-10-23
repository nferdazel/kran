-- Pilot operator roles (T-114).
--
-- The shipped catalogue only had `platform_admin`, `param_maker`, and `param_checker`, so a pilot
-- could not run without handing every operator the admin role. This migration adds the two roles
-- the deposit/teller slice actually needs, following the explicit-grant pattern of 0008/0022-0026:
-- permission codes belong to code (`handlers_teller*.nim`, `handlers_product.nim`), not to
-- institution parameters, so they live in a migration. Idempotent.

INSERT INTO platform.role (role_id, code, name_key, is_system)
VALUES
  (gen_random_uuid(), 'teller', 'role.teller', false),
  (gen_random_uuid(), 'product_checker', 'role.product_checker', false)
ON CONFLICT (code) DO NOTHING;

-- Teller: open/close own cash session, post cash and transfer transactions, read the branch vault
-- and deposit accounts. No catalogue/approval rights, no ledger period control.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'teller'
   AND p.code IN ('teller.session.open', 'teller.session.close', 'teller.session.read',
                  'teller.transaction.post', 'teller.vault.read',
                  'deposit.account.read', 'party.party.read')
ON CONFLICT DO NOTHING;

-- Product approval is a checker duty, like parameter approval, but it is not the parameter
-- checker's job: `param_checker` must stay unable to read or approve the product catalogue so a
-- parameter approver cannot silently become a product approver. Give the catalogue read/approve
-- pair to a separate role instead.
INSERT INTO platform.role_permission (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM platform.role r, platform.permission p
 WHERE r.code = 'product_checker'
   AND p.code IN ('product.catalog.read', 'product.catalog.approve')
ON CONFLICT DO NOTHING;
