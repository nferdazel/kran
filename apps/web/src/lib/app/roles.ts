/**
 * Label peran operator (spec §13) untuk kode peran yang dikirim `SessionInfo.roles`.
 *
 * Kode peran adalah identifier (`teller`, `product_checker`, ...) yang tersimpan di
 * `platform.role.code`; katalog i18n memegang terjemahannya (`role_*`). Peran yang belum dikenal
 * ditampilkan apa adanya, bukan diganti label karangan (spec §16.2: jangan mengarang konten).
 */

import * as m from "#lib/paraglide/messages.js";

const ROLE_LABELS: Record<string, () => string> = {
  platform_admin: () => m.role_platform_admin(),
  param_maker: () => m.role_param_maker(),
  param_checker: () => m.role_param_checker(),
  teller: () => m.role_teller(),
  product_checker: () => m.role_product_checker(),
  ops_admin: () => m.role_ops_admin(),
  ledger_admin: () => m.role_ledger_admin(),
  cash_admin: () => m.role_cash_admin(),
  product_maker: () => m.role_product_maker(),
};

export function roleLabel(code: string): string {
  const label = ROLE_LABELS[code];
  return label === undefined ? code : label();
}
