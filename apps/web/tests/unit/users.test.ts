/**
 * Test unit layar administrasi pengguna (T-117, tanpa DOM, tanpa DB).
 *
 * Yang diuji adalah logika murni: validasi penugasan role (cerminan `roleAssignmentProblem` server),
 * aksi status yang sah, pemetaan `params.reason` → pesan katalog, dan label status.
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import * as m from "#lib/paraglide/messages.js";
import type { RoleSummary } from "#lib/app/types.js";
import {
  assignErrorText,
  assignRoleError,
  availableStatusActions,
  isUuid,
  statusLabel,
  userProblemMessage,
} from "#lib/app/users.js";

const BRANCH_ROLE: RoleSummary = { code: "teller", scope: "BRANCH", isSystem: false };
const INSTITUTION_ROLE: RoleSummary = { code: "product_checker", scope: "INSTITUTION", isSystem: false };
const BRANCH = "b0000000-0000-4000-8000-000000000001";

function problem(reason: string): Problem {
  return {
    type: "/problems/conflict",
    title: "Conflict",
    status: 409,
    code: "CONFLICT",
    i18nKey: "error_conflict",
    params: { reason },
    traceId: "trace",
  };
}

describe("assignRoleError", () => {
  it("role belum dipilih → role_missing", () => {
    expect(assignRoleError(undefined, "")).toEqual({ kind: "role_missing" });
  });

  it("role BRANCH butuh cabang UUID", () => {
    expect(assignRoleError(BRANCH_ROLE, "")).toEqual({ kind: "branch_required" });
    expect(assignRoleError(BRANCH_ROLE, "bukan-uuid")).toEqual({ kind: "branch_invalid" });
    expect(assignRoleError(BRANCH_ROLE, BRANCH)).toBeNull();
  });

  it("role INSTITUTION menolak cabang", () => {
    expect(assignRoleError(INSTITUTION_ROLE, "")).toBeNull();
    expect(assignRoleError(INSTITUTION_ROLE, BRANCH)).toEqual({ kind: "branch_forbidden" });
  });

  it("assignErrorText menerjemahkan setiap jenis", () => {
    expect(assignErrorText({ kind: "role_missing" })).toBe(m.users_error_role_missing());
    expect(assignErrorText({ kind: "branch_required" })).toBe(m.users_error_branch_required());
    expect(assignErrorText({ kind: "branch_forbidden" })).toBe(m.users_error_branch_forbidden());
    expect(assignErrorText({ kind: "branch_invalid" })).toBe(m.users_error_branch_invalid());
  });
});

describe("isUuid", () => {
  it("menerima UUID dan menolak sisanya", () => {
    expect(isUuid(BRANCH)).toBe(true);
    expect(isUuid(`  ${BRANCH}  `)).toBe(true);
    expect(isUuid("")).toBe(false);
    expect(isUuid("teller")).toBe(false);
  });
});

describe("availableStatusActions", () => {
  it("ACTIVE → nonaktifkan", () => {
    expect(availableStatusActions("ACTIVE")).toEqual(["disable"]);
  });

  it("INACTIVE → aktifkan", () => {
    expect(availableStatusActions("INACTIVE")).toEqual(["enable"]);
  });

  it("LOCKED → nonaktifkan atau buka kunci", () => {
    expect(availableStatusActions("LOCKED")).toEqual(["disable", "unlock"]);
  });

  it("SUSPENDED → nonaktifkan", () => {
    expect(availableStatusActions("SUSPENDED")).toEqual(["disable"]);
  });
});

describe("userProblemMessage", () => {
  it("memetakan reason yang dikenal", () => {
    expect(userProblemMessage(problem("last_admin"))).toBe(m.users_error_last_admin());
    expect(userProblemMessage(problem("sod_conflict"))).toBe(m.users_error_sod_conflict());
    expect(userProblemMessage(problem("not_locked"))).toBe(m.users_error_not_locked());
  });

  it("reason tak dikenal jatuh ke pesan amplop (i18nKey)", () => {
    expect(userProblemMessage(problem("something_else"))).toBe(m.error_conflict());
  });
});

describe("statusLabel", () => {
  it("menerjemahkan status yang dikenal, dan meneruskan yang lain apa adanya", () => {
    expect(statusLabel("ACTIVE")).toBe(m.users_status_active());
    expect(statusLabel("INACTIVE")).toBe(m.users_status_inactive());
    expect(statusLabel("LOCKED")).toBe(m.users_status_locked());
    expect(statusLabel("SUSPENDED")).toBe(m.users_status_suspended());
    expect(statusLabel("WEIRD")).toBe("WEIRD");
  });
});
