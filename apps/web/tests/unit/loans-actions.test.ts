/**
 * Test unit web untuk aksi tulis pinjaman T-173 (tanpa DOM, tanpa DB).
 *
 * Dijalankan dengan binary vitest milik `packages/ui` (lihat `vitest.d.ts`):
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * Yang diuji: penyaringan rekening sumber, validasi isian (nominal/tenor/alasan), dan pemetaan
 * `params.reason` → pesan katalog. Yang **tidak** diuji di sini: aritmetika uang (milik
 * `packages/ui/tests/money.test.ts`) dan aturan bisnis server (sisa kewajiban, saldo, golongan).
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import type { DepositAccount } from "#lib/app/types.js";
import {
  LOAN_REASON_MAX_LENGTH,
  activePartyAccounts,
  loanActionProblemMessage,
  validateLoanReason,
  validatePaymentAmount,
  validateTenor,
} from "#lib/app/loans.js";
import * as m from "#lib/paraglide/messages.js";

function problem(status: number, reason?: string, i18nKey = "error_conflict"): Problem {
  return {
    type: "about:blank",
    title: "problem",
    status,
    code: "problem",
    i18nKey,
    traceId: "trace-1",
    ...(reason === undefined ? {} : { params: { reason } }),
  };
}

function account(overrides: Partial<DepositAccount> = {}): DepositAccount {
  return {
    accountId: "11111111-1111-4111-8111-111111111111",
    accountNo: "0000000001",
    partyId: "22222222-2222-4222-8222-222222222222",
    productId: "33333333-3333-4333-8333-333333333333",
    productCode: "SAV-1",
    productVersionId: "44444444-4444-4444-8444-444444444444",
    branchId: "55555555-5555-4555-8555-555555555555",
    accountType: "SAVINGS",
    status: "ACTIVE",
    balance: "150000.00",
    openedOn: "2026-01-01",
    createdAt: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

describe("activePartyAccounts", () => {
  it("hanya menyisakan rekening ACTIVE dan mempertahankan urutan server", () => {
    const list = [
      account({ accountId: "a", status: "ACTIVE" }),
      account({ accountId: "b", status: "DORMANT" }),
      account({ accountId: "c", status: "CLOSED" }),
      account({ accountId: "d", status: "ACTIVE" }),
    ];
    expect(activePartyAccounts(list).map((item) => item.accountId)).toEqual(["a", "d"]);
  });

  it("tidak mengubah daftar masukan", () => {
    const list = [account({ status: "DORMANT" })];
    activePartyAccounts(list);
    expect(list).toHaveLength(1);
  });
});

describe("validatePaymentAmount", () => {
  it("menormalkan nominal ke desimal polos 2 desimal", () => {
    expect(validatePaymentAmount("150000")).toEqual({ ok: true, amount: "150000.00" });
    expect(validatePaymentAmount("150000,5")).toEqual({ ok: true, amount: "150000.50" });
  });

  it("memetakan tiap galat parser ke pesan yang berbeda", () => {
    const empty = validatePaymentAmount("");
    const zero = validatePaymentAmount("0");
    const precision = validatePaymentAmount("1.234");
    const format = validatePaymentAmount("abc");
    expect(empty).toEqual({ ok: false, message: m.loans_error_amount_empty() });
    expect(zero).toEqual({ ok: false, message: m.loans_error_amount_zero() });
    expect(precision).toEqual({ ok: false, message: m.loans_error_amount_precision() });
    expect(format).toEqual({ ok: false, message: m.loans_error_amount_format() });
  });
});

describe("validateTenor", () => {
  it("menerima bilangan bulat minimal 1 bulan", () => {
    expect(validateTenor("6")).toEqual({ ok: true, tenorMonths: 6 });
    expect(validateTenor(" 12 ")).toEqual({ ok: true, tenorMonths: 12 });
  });

  it("menolak kosong, pecahan, nol, dan bukan angka", () => {
    for (const raw of ["", "0", "1.5", "6 bulan", "-3"]) {
      expect(validateTenor(raw).ok).toBe(false);
    }
  });
});

describe("validateLoanReason", () => {
  it("memangkas spasi dan menerima 1..500 karakter", () => {
    expect(validateLoanReason("  penurunan omzet  ")).toEqual({
      ok: true,
      reason: "penurunan omzet",
    });
    const longest = "a".repeat(LOAN_REASON_MAX_LENGTH);
    expect(validateLoanReason(longest)).toEqual({ ok: true, reason: longest });
  });

  it("menolak kosong dan lebih dari batas kontrak", () => {
    expect(validateLoanReason("   ")).toEqual({ ok: false, message: m.loans_error_reason_empty() });
    expect(validateLoanReason("a".repeat(LOAN_REASON_MAX_LENGTH + 1))).toEqual({
      ok: false,
      message: m.loans_error_reason_too_long(),
    });
  });
});

describe("loanActionProblemMessage", () => {
  it("menyebut sebab domain yang dikenal, bukan pesan amplop", () => {
    const cases: [string, string][] = [
      ["not_approved", m.loans_error_not_approved()],
      ["already_disbursed", m.loans_error_already_disbursed()],
      ["not_disbursed", m.loans_error_not_disbursed()],
      ["loan_inactive", m.loans_error_loan_inactive()],
      ["schedule_missing", m.loans_error_schedule_missing()],
      ["amount_exceeds_outstanding", m.loans_error_amount_exceeds_outstanding()],
      ["insufficient_balance", m.loans_error_insufficient_balance()],
      ["account_party_mismatch", m.loans_error_account_party_mismatch()],
      ["account_branch_mismatch", m.loans_error_account_branch_mismatch()],
      ["account_not_active", m.loans_error_account_not_active()],
      ["allocation_conflict", m.loans_error_allocation_conflict()],
      ["not_loss", m.loans_error_not_loss()],
      ["already_written_off", m.loans_error_already_written_off()],
      ["nothing_to_write_off", m.loans_error_nothing_to_write_off()],
      ["restructure_invalid", m.loans_error_restructure_invalid()],
      ["product_version_missing", m.loans_error_product_version_missing()],
    ];
    for (const [reason, expected] of cases) {
      expect(loanActionProblemMessage(problem(409, reason))).toBe(expected);
    }
  });

  it("403 tanpa sebab = izin, 404 tanpa sebab = akad tidak ditemukan", () => {
    expect(loanActionProblemMessage(problem(403, undefined, "error_forbidden"))).toBe(
      m.loans_action_denied(),
    );
    expect(loanActionProblemMessage(problem(404, undefined, "error_not_found"))).toBe(
      m.loans_detail_not_found(),
    );
  });

  it("sebab tak dikenal jatuh ke pesan amplop, bukan tebakan", () => {
    expect(loanActionProblemMessage(problem(409, "reason_baru"))).toBe(m.error_conflict());
  });
});
