/**
 * Test unit web untuk T-115 (tanpa DOM, tanpa DB).
 *
 * Dijalankan dengan binary vitest milik `packages/ui` (lihat `vitest.d.ts`):
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * Yang diuji: penyaringan produk simpanan (`savingsProducts`), label status party, dan pemetaan
 * `params.reason` → pesan katalog pada buka rekening.
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import * as m from "#lib/paraglide/messages.js";
import {
  accountOpenProblemMessage,
  partyStatusLabel,
  savingsProducts,
  type ProductSummary,
} from "#lib/app/accounts.js";

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

function product(overrides: Partial<ProductSummary> = {}): ProductSummary {
  return {
    productId: "p1",
    code: "SAV-1",
    name: "Simpanan",
    productType: "SAVINGS",
    createdAt: "2026-01-01T00:00:00Z",
    currentVersion: { versionNo: 1, effectiveFrom: "2020-01-01" },
    ...overrides,
  };
}

describe("savingsProducts", () => {
  it("hanya menyisakan SAVINGS yang punya versi ACTIVE", () => {
    const list = [
      product({ productId: "a" }),
      product({ productId: "b", productType: "LOAN" }),
      product({ productId: "c", currentVersion: null }),
    ];
    expect(savingsProducts(list).map((item) => item.productId)).toEqual(["a"]);
  });

  it("daftar kosong = kosong", () => {
    expect(savingsProducts([])).toEqual([]);
  });
});

describe("partyStatusLabel", () => {
  it("menerjemahkan tiga status kontrak", () => {
    expect(partyStatusLabel("ACTIVE")).toBe(m.accounts_status_active());
    expect(partyStatusLabel("SUSPENDED")).toBe(m.accounts_status_suspended());
    expect(partyStatusLabel("CLOSED")).toBe(m.accounts_status_closed());
  });
});

describe("accountOpenProblemMessage", () => {
  it("memetakan params.reason 409 ke pesan spesifik", () => {
    expect(accountOpenProblemMessage(problem(409, "party_not_active"))).toBe(
      m.accounts_error_party_not_active(),
    );
    expect(accountOpenProblemMessage(problem(409, "branch_mismatch"))).toBe(
      m.accounts_error_branch_mismatch(),
    );
    expect(accountOpenProblemMessage(problem(409, "product_not_active"))).toBe(
      m.accounts_error_product_not_active(),
    );
  });

  it("403 = pesan izin", () => {
    expect(accountOpenProblemMessage(problem(403, undefined, "error_forbidden"))).toBe(
      m.accounts_error_forbidden(),
    );
  });

  it("reason tak dikenal jatuh ke pesan amplop", () => {
    expect(accountOpenProblemMessage(problem(409, "other", "error_conflict"))).toBe(
      m.error_conflict(),
    );
  });
});
