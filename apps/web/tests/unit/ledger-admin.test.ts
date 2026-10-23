/**
 * Test unit web untuk T-116 (tanpa DOM, tanpa DB).
 *
 * Dijalankan dengan binary vitest milik `packages/ui` (lihat `vitest.d.ts`):
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * Yang diuji = logika murni: validasi form periode/COA/pembalik, ketersediaan aksi tutup, dan
 * pemetaan galat domain. Perilaku layar (fokus, konfirmasi inline) diuji e2e.
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import * as m from "#lib/paraglide/messages.js";
import {
  canClosePeriod,
  coaAccountTypeLabel,
  findOverlappingPeriod,
  isIsoDate,
  isUuid,
  ledgerAdminProblemMessage,
  rangesOverlap,
  validateCoaForm,
  validatePeriodForm,
  validateReason,
  validateReverseForm,
} from "#lib/app/ledger-admin.js";

const JOURNAL = "11111111-1111-4111-8111-111111111111";

function problem(status: number, reason?: string): Problem {
  return {
    type: "about:blank",
    title: "problem",
    status,
    code: status === 409 ? "CONFLICT" : "FORBIDDEN",
    i18nKey: status === 409 ? "error_conflict" : "error_forbidden",
    traceId: "trace-1",
    ...(reason === undefined ? {} : { params: { reason } }),
  };
}

describe("isIsoDate", () => {
  it("menerima tanggal yang benar-benar ada dan menolak sisanya", () => {
    expect(isIsoDate("2026-01-31")).toBe(true);
    expect(isIsoDate(" 2026-12-01 ")).toBe(true);
    expect(isIsoDate("2026-02-31")).toBe(false);
    expect(isIsoDate("2026-13-01")).toBe(false);
    expect(isIsoDate("31-01-2026")).toBe(false);
    expect(isIsoDate("")).toBe(false);
  });
});

describe("isUuid", () => {
  it("menerima UUID dan menolak bentuk lain", () => {
    expect(isUuid(JOURNAL)).toBe(true);
    expect(isUuid(` ${JOURNAL.toUpperCase()} `)).toBe(true);
    expect(isUuid("nope")).toBe(false);
    expect(isUuid("")).toBe(false);
  });
});

describe("rangesOverlap", () => {
  it("rentang inklusif: ujung yang bersentuhan dihitung tumpang tindih", () => {
    expect(rangesOverlap({ startsOn: "2026-01-01", endsOn: "2026-01-31" }, { startsOn: "2026-01-31", endsOn: "2026-02-28" })).toBe(true);
    expect(rangesOverlap({ startsOn: "2026-01-01", endsOn: "2026-01-31" }, { startsOn: "2026-02-01", endsOn: "2026-02-28" })).toBe(false);
  });
});

describe("findOverlappingPeriod", () => {
  const periods = [
    { startsOn: "2026-01-01", endsOn: "2026-01-31" },
    { startsOn: "2026-03-01", endsOn: "2026-03-31" },
  ];

  it("mengembalikan periode yang bertabrakan, atau null bila bebas", () => {
    expect(findOverlappingPeriod({ startsOn: "2026-01-15", endsOn: "2026-02-10" }, periods)).toEqual(periods[0]);
    expect(findOverlappingPeriod({ startsOn: "2026-02-01", endsOn: "2026-02-28" }, periods)).toBeNull();
  });
});

describe("canClosePeriod", () => {
  it("hanya periode OPEN yang bisa ditutup", () => {
    expect(canClosePeriod({ status: "OPEN" })).toBe(true);
    expect(canClosePeriod({ status: "CLOSED" })).toBe(false);
  });
});

describe("validatePeriodForm", () => {
  const existing = [{ startsOn: "2026-01-01", endsOn: "2026-01-31" }];

  it("lolos dan menormalkan rentang yang bebas", () => {
    expect(validatePeriodForm({ startsOn: " 2026-03-01 ", endsOn: "2026-03-31" }, existing)).toEqual({
      ok: true,
      startsOn: "2026-03-01",
      endsOn: "2026-03-31",
    });
  });

  it("menunjuk field wajib lebih dulu", () => {
    expect(validatePeriodForm({ startsOn: "", endsOn: "2026-03-31" }, existing)).toEqual({
      ok: false,
      error: { field: "startsOn", message: m.ledger_admin_error_starts_required() },
    });
    expect(validatePeriodForm({ startsOn: "2026-03-01", endsOn: "" }, existing)).toEqual({
      ok: false,
      error: { field: "endsOn", message: m.ledger_admin_error_ends_required() },
    });
  });

  it("menolak tanggal tidak sah dan urutan terbalik", () => {
    expect(validatePeriodForm({ startsOn: "2026-02-31", endsOn: "2026-03-31" }, existing)).toEqual({
      ok: false,
      error: { field: "startsOn", message: m.ledger_admin_error_date_invalid() },
    });
    expect(validatePeriodForm({ startsOn: "2026-03-31", endsOn: "2026-03-01" }, existing)).toEqual({
      ok: false,
      error: { field: "endsOn", message: m.ledger_admin_error_ends_before_starts() },
    });
  });

  it("menolak rentang yang tumpang tindih sebelum POST", () => {
    expect(validatePeriodForm({ startsOn: "2026-01-15", endsOn: "2026-02-15" }, existing)).toEqual({
      ok: false,
      error: { field: "startsOn", message: m.ledger_admin_error_period_overlap() },
    });
  });
});

describe("validateCoaForm", () => {
  it("lolos dan memangkas spasi berlebih pada nama", () => {
    expect(
      validateCoaForm({ code: " 101 ", name: "  Kas   Tunai ", accountType: "ASSET", postable: true }),
    ).toEqual({ ok: true, code: "101", name: "Kas Tunai", accountType: "ASSET", postable: true });
  });

  it("menolak kode kosong atau terlalu panjang", () => {
    expect(validateCoaForm({ code: "", name: "Kas", accountType: "ASSET", postable: true })).toEqual({
      ok: false,
      error: { field: "code", message: m.ledger_admin_error_code_required() },
    });
    expect(
      validateCoaForm({ code: "9".repeat(33), name: "Kas", accountType: "ASSET", postable: true }),
    ).toEqual({
      ok: false,
      error: { field: "code", message: m.ledger_admin_error_code_too_long() },
    });
  });

  it("menolak nama kosong atau terlalu pendek", () => {
    expect(validateCoaForm({ code: "101", name: "  ", accountType: "ASSET", postable: true })).toEqual({
      ok: false,
      error: { field: "name", message: m.ledger_admin_error_name_required() },
    });
    expect(validateCoaForm({ code: "101", name: "K", accountType: "ASSET", postable: true })).toEqual({
      ok: false,
      error: { field: "name", message: m.ledger_admin_error_name_too_short() },
    });
  });

  it("menolak tipe yang tidak dipilih atau tidak dikenal", () => {
    expect(validateCoaForm({ code: "101", name: "Kas", accountType: "", postable: true })).toEqual({
      ok: false,
      error: { field: "accountType", message: m.ledger_admin_error_type_required() },
    });
    expect(validateCoaForm({ code: "101", name: "Kas", accountType: "CASH", postable: true })).toEqual({
      ok: false,
      error: { field: "accountType", message: m.ledger_admin_error_type_required() },
    });
  });

  it("label tipe akun berbeda per tipe", () => {
    const labels = (["ASSET", "LIABILITY", "EQUITY", "REVENUE", "EXPENSE"] as const).map(
      coaAccountTypeLabel,
    );
    expect(new Set(labels).size).toEqual(5);
  });
});

describe("validateReason", () => {
  it("wajib dan dibatasi panjangnya", () => {
    expect(validateReason("  ")).toEqual({
      ok: false,
      error: { field: "reason", message: m.ledger_admin_error_reason_required() },
    });
    expect(validateReason("x".repeat(501))).toEqual({
      ok: false,
      error: { field: "reason", message: m.ledger_admin_error_reason_too_long() },
    });
    expect(validateReason(" tutup Januari 2026 ")).toEqual({ ok: true, reason: "tutup Januari 2026" });
  });
});

describe("validateReverseForm", () => {
  it("lolos dengan UUID dan alasan", () => {
    expect(validateReverseForm({ journalId: ` ${JOURNAL} `, reason: "salah posting" })).toEqual({
      ok: true,
      journalId: JOURNAL,
      reason: "salah posting",
    });
  });

  it("menunjuk field journalId lebih dulu", () => {
    expect(validateReverseForm({ journalId: "", reason: "x" })).toEqual({
      ok: false,
      error: { field: "journalId", message: m.ledger_admin_error_journal_required() },
    });
    expect(validateReverseForm({ journalId: "nope", reason: "x" })).toEqual({
      ok: false,
      error: { field: "journalId", message: m.ledger_admin_error_journal_invalid() },
    });
    expect(validateReverseForm({ journalId: JOURNAL, reason: " " })).toEqual({
      ok: false,
      error: { field: "reason", message: m.ledger_admin_error_reason_required() },
    });
  });
});

describe("ledgerAdminProblemMessage", () => {
  it("memakai params.reason bila server menyertakannya", () => {
    expect(ledgerAdminProblemMessage(problem(409, "period_no_overlap"), "open_period")).toEqual(
      m.ledger_admin_error_period_overlap(),
    );
    expect(ledgerAdminProblemMessage(problem(403, "branch_not_allowed"), "create_coa")).toEqual(
      m.ledger_admin_error_branch_not_allowed(),
    );
  });

  it("tanpa params.reason, sebab 409 mengikuti aksi", () => {
    expect(ledgerAdminProblemMessage(problem(409), "open_period")).toEqual(
      m.ledger_admin_error_period_overlap(),
    );
    expect(ledgerAdminProblemMessage(problem(409), "close_period")).toEqual(
      m.ledger_admin_error_period_closed(),
    );
    expect(ledgerAdminProblemMessage(problem(409), "create_coa")).toEqual(
      m.ledger_admin_error_coa_duplicate(),
    );
    expect(ledgerAdminProblemMessage(problem(409), "reverse_journal")).toEqual(
      m.ledger_admin_error_conflict(),
    );
  });

  it("memetakan 403/404 dan jatuh kembali ke amplop untuk sisanya", () => {
    expect(ledgerAdminProblemMessage(problem(403), "close_period")).toEqual(
      m.ledger_admin_error_denied(),
    );
    expect(ledgerAdminProblemMessage(problem(404), "close_period")).toEqual(
      m.ledger_admin_error_not_found(),
    );
  });
});
