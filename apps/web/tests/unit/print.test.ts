/**
 * Test unit web untuk T-094 (tanpa DOM, tanpa DB).
 *
 * Dijalankan dengan binary vitest milik `packages/ui` (lihat `vitest.d.ts`):
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * Yang diuji di sini adalah view-model murni dokumen cetak: validasi format/rentang tanggal,
 * pengurutan baris, arah, referensi, dan total (jumlah baris subledger — bukan saldo berjalan).
 * Tampilan/aksara tidak diuji di sini; itu ranah e2e.
 */
import { describe, expect, it } from "vitest";

import {
  isIsoDate,
  sortStatementRows,
  statementReference,
  statementTotals,
  validateRange,
  type AccountStatement,
  type StatementRow,
} from "#lib/app/print.js";

function row(
  over: Pick<StatementRow, "direction" | "amount" | "businessDate"> & Partial<StatementRow>,
): StatementRow {
  return {
    kind: "CASH",
    journalId: "00000000-0000-4000-8000-000000000000",
    narration: "",
    transactionId: "11111111-1111-4111-8111-111111111111",
    transferId: null,
    ...over,
  };
}

describe("isIsoDate", () => {
  it("menerima tanggal yang ada dan menolak yang lain", () => {
    expect(isIsoDate("2026-10-22")).toBe(true);
    expect(isIsoDate("2024-02-29")).toBe(true); // kabisat
    expect(isIsoDate("2026-02-29")).toBe(false); // bukan kabisat
    expect(isIsoDate("2026-02-31")).toBe(false);
    expect(isIsoDate("2026-13-01")).toBe(false);
    expect(isIsoDate("2026-00-10")).toBe(false);
    expect(isIsoDate("2026-1-3")).toBe(false);
    expect(isIsoDate("")).toBe(false);
  });
});

describe("validateRange", () => {
  it("menuntut kedua tanggal", () => {
    expect(validateRange("", "2026-10-31")).toEqual({ ok: false, reason: "required" });
    expect(validateRange("2026-10-01", "  ")).toEqual({ ok: false, reason: "required" });
  });

  it("menolak format salah dan rentang terbalik", () => {
    expect(validateRange("2026-02-31", "2026-03-01")).toEqual({ ok: false, reason: "invalid" });
    expect(validateRange("2026-10-31", "2026-10-01")).toEqual({ ok: false, reason: "invalid" });
  });

  it("menerima rentang sah dan memangkas spasi", () => {
    expect(validateRange(" 2026-10-01 ", "2026-10-31")).toEqual({
      ok: true,
      from: "2026-10-01",
      to: "2026-10-31",
    });
    // Rentang satu hari juga sah.
    expect(validateRange("2026-10-01", "2026-10-01")).toEqual({
      ok: true,
      from: "2026-10-01",
      to: "2026-10-01",
    });
  });
});

describe("sortStatementRows", () => {
  it("mengurutkan menurut tanggal dan stabil pada tanggal sama", () => {
    const first = row({ direction: "IN", amount: "1.0000", businessDate: "2026-10-02" });
    const second = row({ direction: "OUT", amount: "2.0000", businessDate: "2026-10-01" });
    const third = row({ direction: "IN", amount: "3.0000", businessDate: "2026-10-02" });
    const sorted = sortStatementRows([first, second, third]);
    expect(sorted.map((r) => r.amount)).toEqual(["2.0000", "1.0000", "3.0000"]);
  });
});

describe("statementReference", () => {
  it("memakai id tunai atau id PB, tepat satu terisi", () => {
    expect(statementReference(row({ direction: "IN", amount: "1.0000", businessDate: "2026-10-01" }))).toBe(
      "11111111-1111-4111-8111-111111111111",
    );
    expect(
      statementReference(
        row({
          direction: "OUT",
          amount: "1.0000",
          businessDate: "2026-10-01",
          transactionId: null,
          transferId: "22222222-2222-4222-8222-222222222222",
        }),
      ),
    ).toBe("22222222-2222-4222-8222-222222222222");
  });
});

describe("statementTotals", () => {
  it("menjumlahkan masuk dan keluar terpisah; net = masuk - keluar", () => {
    const totals = statementTotals([
      row({ direction: "IN", amount: "100.0000", businessDate: "2026-10-01" }),
      row({ direction: "IN", amount: "50.0000", businessDate: "2026-10-02" }),
      row({
        direction: "OUT",
        amount: "30.0000",
        businessDate: "2026-10-03",
        transactionId: null,
        transferId: "33333333-3333-4333-8333-333333333333",
      }),
    ]);
    expect(totals).toEqual({ inflow: "150.0000", outflow: "30.0000", net: "120.0000" });
  });

  it("net negatif bila keluar melebihi masuk", () => {
    const totals = statementTotals([
      row({ direction: "IN", amount: "10.0000", businessDate: "2026-10-01" }),
      row({ direction: "OUT", amount: "25.0000", businessDate: "2026-10-02" }),
    ]);
    expect(totals).toEqual({ inflow: "10.0000", outflow: "25.0000", net: "-15.0000" });
  });

  it("tanpa baris = nol", () => {
    expect(statementTotals([])).toEqual({ inflow: "0.0000", outflow: "0.0000", net: "0.0000" });
  });

  it("tipe status statement tersedia dari kontrak (dipakai halaman)", () => {
    const statement: AccountStatement = {
      accountNo: "0000000001",
      status: "ACTIVE",
      branchId: "44444444-4444-4444-8444-444444444444",
      from: "2026-10-01",
      to: "2026-10-31",
      rows: [],
    };
    expect(statement.status).toBe("ACTIVE");
  });
});
