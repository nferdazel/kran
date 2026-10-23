/**
 * Glue layar administrasi pengguna (T-117): validasi form penugasan role, ketersediaan aksi status,
 * dan pemetaan `params.reason` server → pesan katalog. Logika murni (tanpa DOM, tanpa jaringan)
 * supaya bisa diuji vitest.
 *
 * Cerminan aturan server (`auth_service.roleAssignmentProblem` + `handlers_users`): role ber-scope
 * `BRANCH` wajib menyertakan cabang berbentuk UUID, role `INSTITUTION` tidak boleh. Aksi status
 * hanya yang sah untuk status sekarang (`INACTIVE` → enable, `LOCKED` → unlock); server tetap
 * otoritas terakhir dan penolakannya dipetakan lewat `userProblemMessage`.
 */
import type { Problem } from "@kran/api-client";

import * as m from "#lib/paraglide/messages.js";
import { problemMessage } from "#lib/app/errors.js";
import type { RoleSummary, UserSummary } from "#lib/app/types.js";

export type { RoleSummary, UserSummary };

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: string): boolean {
  return UUID_PATTERN.test(value.trim());
}

export type AssignError =
  | { readonly kind: "role_missing" }
  | { readonly kind: "branch_required" }
  | { readonly kind: "branch_forbidden" }
  | { readonly kind: "branch_invalid" };

/**
 * Validasi form penugasan terhadap scope role terpilih. Mengembalikan `null` bila sah. Role yang
 * tidak ada di katalog = `role_missing` (form belum benar-benar terisi).
 */
export function assignRoleError(
  role: RoleSummary | undefined,
  branchId: string,
): AssignError | null {
  if (role === undefined) return { kind: "role_missing" };
  const branch = branchId.trim();
  if (role.scope === "BRANCH") {
    if (branch === "") return { kind: "branch_required" };
    if (!isUuid(branch)) return { kind: "branch_invalid" };
    return null;
  }
  return branch === "" ? null : { kind: "branch_forbidden" };
}

export function assignErrorText(error: AssignError): string {
  switch (error.kind) {
    case "role_missing":
      return m.users_error_role_missing();
    case "branch_required":
      return m.users_error_branch_required();
    case "branch_forbidden":
      return m.users_error_branch_forbidden();
    case "branch_invalid":
      return m.users_error_branch_invalid();
  }
}

export type StatusAction = "disable" | "enable" | "unlock";

/** Aksi status yang sah untuk status sekarang; server memvalidasi ulang dan menolak sisanya. */
export function availableStatusActions(status: string): StatusAction[] {
  const actions: StatusAction[] = [];
  // `disable` masuk akal untuk akun yang masih aktif/terkunci; akun yang sudah INACTIVE tidak
  // ditawarkan (yang berlaku adalah `enable`).
  if (status !== "INACTIVE") actions.push("disable");
  if (status === "INACTIVE") actions.push("enable");
  if (status === "LOCKED") actions.push("unlock");
  return actions;
}

const REASON_MESSAGES: Record<string, () => string> = {
  user_not_found: () => m.users_error_user_not_found(),
  role_not_found: () => m.users_error_role_not_found(),
  role_scope: () => m.users_error_role_scope(),
  already_granted: () => m.users_error_already_granted(),
  sod_conflict: () => m.users_error_sod_conflict(),
  not_granted: () => m.users_error_not_granted(),
  last_admin: () => m.users_error_last_admin(),
  not_inactive: () => m.users_error_not_inactive(),
  not_locked: () => m.users_error_not_locked(),
  role_missing: () => m.users_error_role_missing(),
  branch_invalid: () => m.users_error_branch_invalid(),
  branch_not_allowed: () => m.users_error_branch_not_allowed(),
  body_invalid: () => m.users_error_body_invalid(),
};

/** Pesan kegagalan administrasi pengguna; sebab tak dikenal jatuh kembali ke pesan amplop. */
export function userProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : REASON_MESSAGES[reason];
  return template === undefined ? problemMessage(problem) : template();
}

export function statusLabel(status: string): string {
  if (status === "ACTIVE") return m.users_status_active();
  if (status === "INACTIVE") return m.users_status_inactive();
  if (status === "LOCKED") return m.users_status_locked();
  if (status === "SUSPENDED") return m.users_status_suspended();
  return status;
}
