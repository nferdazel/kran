/**
 * Test unit web untuk T-088d (tanpa DOM, tanpa DB).
 *
 * Dijalankan dengan binary vitest milik `packages/ui` (lihat `vitest.d.ts`):
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * Yang diuji di sini adalah logika murni: validasi form, pratinjau nominal, sidik kunci
 * idempotensi, dan pemetaan `params.reason` → pesan katalog. Parser uang sendiri diuji di
 * `packages/ui/tests/money.test.ts` (rumah modul `money.ts`).
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import * as m from "#lib/paraglide/messages.js";
import {
  NARRATION_MAX_LENGTH,
  cashIdentity,
  isAccountId,
  previewAmount,
  shortcutModeForKey,
  tellerProblemMessage,
  transferIdentity,
  validateAmount,
  validateCashForm,
  validateTransferForm,
} from "#lib/app/teller.js";

const ACCOUNT = "11111111-1111-4111-8111-111111111111";
const OTHER_ACCOUNT = "22222222-2222-4222-8222-222222222222";

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

describe("isAccountId", () => {
  it("menerima UUID dan menolak bentuk lain", () => {
    expect(isAccountId(ACCOUNT)).toBe(true);
    expect(isAccountId(` ${ACCOUNT} `)).toBe(true);
    expect(isAccountId("0000000012")).toBe(false);
    expect(isAccountId("")).toBe(false);
  });
});

describe("validateAmount", () => {
  it("menerima nominal dan menormalkan ke 4 desimal", () => {
    expect(validateAmount("150000")).toEqual({ ok: true, amount: "150000.0000" });
    expect(validateAmount("150000,5")).toEqual({ ok: true, amount: "150000.5000" });
  });

  it("memetakan setiap galat parser ke pesan yang berbeda", () => {
    const empty = validateAmount("");
    const format = validateAmount("abc");
    const zero = validateAmount("0");
    const precision = validateAmount("1.234");

    expect(empty).toEqual({ ok: false, error: { field: "amount", message: m.teller_error_amount_empty() } });
    expect(format).toEqual({
      ok: false,
      error: { field: "amount", message: m.teller_error_amount_format() },
    });
    expect(zero).toEqual({ ok: false, error: { field: "amount", message: m.teller_error_amount_zero() } });
    expect(precision).toEqual({
      ok: false,
      error: { field: "amount", message: m.teller_error_amount_precision() },
    });
  });
});

describe("previewAmount", () => {
  it("memberi desimal polos saat sah dan string kosong saat belum", () => {
    expect(previewAmount("250000,50")).toBe("250000.5000");
    expect(previewAmount("")).toBe("");
    expect(previewAmount("0")).toBe("");
  });
});

describe("validateCashForm", () => {
  it("lolos dengan isian lengkap dan memangkas keterangan", () => {
    expect(
      validateCashForm({ accountId: ACCOUNT, amountRaw: "300000", narration: "  setoran awal " }),
    ).toEqual({
      ok: true,
      accountId: ACCOUNT,
      amount: "300000.0000",
      narration: "setoran awal",
    });
  });

  it("menunjuk field rekening lebih dulu", () => {
    expect(validateCashForm({ accountId: "", amountRaw: "1", narration: "" })).toEqual({
      ok: false,
      error: { field: "accountId", message: m.teller_error_account_required() },
    });
    expect(validateCashForm({ accountId: "abc", amountRaw: "1", narration: "" })).toEqual({
      ok: false,
      error: { field: "accountId", message: m.teller_error_account_invalid() },
    });
  });

  it("menolak keterangan lebih dari batas kolom", () => {
    const tooLong = "x".repeat(NARRATION_MAX_LENGTH + 1);
    expect(validateCashForm({ accountId: ACCOUNT, amountRaw: "1", narration: tooLong })).toEqual({
      ok: false,
      error: { field: "narration", message: m.teller_error_narration_too_long() },
    });
  });
});

describe("validateTransferForm", () => {
  it("lolos dengan dua rekening berbeda", () => {
    expect(
      validateTransferForm({
        sourceAccountId: ACCOUNT,
        destinationAccountId: OTHER_ACCOUNT,
        amountRaw: "50000",
        narration: "",
      }),
    ).toEqual({
      ok: true,
      sourceAccountId: ACCOUNT,
      destinationAccountId: OTHER_ACCOUNT,
      amount: "50000.0000",
      narration: "",
    });
  });

  it("menolak rekening tujuan kosong atau sama", () => {
    expect(
      validateTransferForm({
        sourceAccountId: ACCOUNT,
        destinationAccountId: "",
        amountRaw: "50000",
        narration: "",
      }),
    ).toEqual({
      ok: false,
      error: { field: "destinationAccountId", message: m.teller_error_destination_required() },
    });

    expect(
      validateTransferForm({
        sourceAccountId: ACCOUNT,
        destinationAccountId: ACCOUNT.toUpperCase(),
        amountRaw: "50000",
        narration: "",
      }),
    ).toEqual({
      ok: false,
      error: { field: "destinationAccountId", message: m.teller_error_destination_same() },
    });
  });
});

describe("sidik kunci idempotensi", () => {
  it("berubah ketika nominal berubah", () => {
    const first = cashIdentity({
      accountId: ACCOUNT,
      direction: "WITHDRAWAL",
      amount: "100000.0000",
      narration: "",
    });
    const second = cashIdentity({
      accountId: ACCOUNT,
      direction: "WITHDRAWAL",
      amount: "100001.0000",
      narration: "",
    });
    expect(first).toBe(
      cashIdentity({
        accountId: ACCOUNT,
        direction: "WITHDRAWAL",
        amount: "100000.0000",
        narration: "",
      }),
    );
    expect(first === second).toBe(false);
  });

  it("cash dan transfer tidak pernah bertabrakan", () => {
    expect(
      transferIdentity({
        sourceAccountId: ACCOUNT,
        destinationAccountId: OTHER_ACCOUNT,
        amount: "1.0000",
        narration: "",
      }),
    ).toBe(
      transferIdentity({
        sourceAccountId: ACCOUNT,
        destinationAccountId: OTHER_ACCOUNT,
        amount: "1.0000",
        narration: "",
      }),
    );

    expect(
      transferIdentity({
        sourceAccountId: ACCOUNT,
        destinationAccountId: OTHER_ACCOUNT,
        amount: "1.0000",
        narration: "",
      }) ===
        cashIdentity({
          accountId: ACCOUNT,
          direction: "DEPOSIT",
          amount: "1.0000",
          narration: "",
        }),
    ).toBe(false);
  });
});

describe("tellerProblemMessage: params.reason", () => {
  it("memetakan setiap sebab domain yang dikenal", () => {
    expect(tellerProblemMessage(problem(409, "insufficient_funds"))).toBe(
      m.teller_error_insufficient_funds(),
    );
    expect(tellerProblemMessage(problem(409, "period_closed"))).toBe(m.teller_error_period_closed());
    expect(tellerProblemMessage(problem(409, "account_not_active"))).toBe(
      m.teller_error_account_not_active(),
    );
    expect(tellerProblemMessage(problem(403, "branch_not_allowed"))).toBe(
      m.teller_error_branch_not_allowed(),
    );
    expect(tellerProblemMessage(problem(409, "no_open_session"))).toBe(
      m.teller_error_no_open_session(),
    );
  });

  it("404 selalu jadi pesan rekening tidak ditemukan", () => {
    expect(tellerProblemMessage(problem(404))).toBe(m.teller_not_found());
  });

  it("403 tanpa sebab jadi pesan izin teller", () => {
    expect(tellerProblemMessage(problem(403))).toBe(m.teller_denied());
  });

  it("sebab tak dikenal jatuh ke pesan amplop", () => {
    expect(tellerProblemMessage(problem(400, "unknown_reason", "error_bad_request"))).toBe(
      m.error_bad_request(),
    );
    expect(tellerProblemMessage(problem(500, undefined, "error_internal_error"))).toBe(
      m.error_internal_error(),
    );
  });
});

describe("shortcutModeForKey", () => {
  const shortcuts = { DEPOSIT: "F4", WITHDRAWAL: "F5", TRANSFER: "F9" };

  it("memetakan tombol yang dikonfigurasi, tanpa peduli huruf besar/kecil", () => {
    expect(shortcutModeForKey(shortcuts, "F4")).toBe("DEPOSIT");
    expect(shortcutModeForKey(shortcuts, "f5")).toBe("WITHDRAWAL");
    expect(shortcutModeForKey(shortcuts, " F9 ")).toBe("TRANSFER");
  });

  it("tombol lain atau parameter kosong tidak memicu mode", () => {
    expect(shortcutModeForKey(shortcuts, "F6")).toBeNull();
    expect(shortcutModeForKey(shortcuts, "")).toBeNull();
    expect(shortcutModeForKey({}, "F4")).toBeNull();
    expect(shortcutModeForKey({ DEPOSIT: "" }, "")).toBeNull();
  });
});
