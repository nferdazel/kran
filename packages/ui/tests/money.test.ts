import { describe, expect, it } from "vitest";
import { addMoney, formatMoney, parseMoneyInput } from "../src/money.js";

/**
 * T-083 / D-136: uang diformat dari string desimal tanpa float.
 *  - 2 desimal (default) = skala penyimpanan; `4` hanya untuk kebutuhan tampilan khusus.
 *  - Pembulatan half-even, bukan half-up.
 *  - Pemisah mengikuti locale; simbol mata uang bukan urusan fungsi ini (DESIGN §6).
 */

describe("formatMoney: locale & presisi", () => {
  it("id-ID 2 desimal (default) memakai titik ribuan dan koma desimal", () => {
    expect(formatMoney("1500000")).toBe("1.500.000,00");
    expect(formatMoney("1234567.89")).toBe("1.234.567,89");
  });

  it("4 desimal tetap bisa diminta bila tampilan membutuhkannya", () => {
    expect(formatMoney("1500000", { decimals: 4 })).toBe("1.500.000,0000");
  });

  it("en-US memakai koma ribuan dan titik desimal", () => {
    expect(formatMoney("1500000.5", { locale: "en-US" })).toBe("1,500,000.50");
  });

  it("nol tetap tampil dengan presisi penuh", () => {
    expect(formatMoney("0")).toBe("0,00");
    expect(formatMoney("0.00", { decimals: 2 })).toBe("0,00");
  });
});

describe("formatMoney: pembulatan half-even", () => {
  it("tepat setengah turun bila digit terakhir genap", () => {
    expect(formatMoney("0.005")).toBe("0,00");
    expect(formatMoney("1.005", { decimals: 2 })).toBe("1,00");
  });

  it("tepat setengah naik bila digit terakhir ganjil", () => {
    expect(formatMoney("0.015")).toBe("0,02");
    expect(formatMoney("1.015", { decimals: 2 })).toBe("1,02");
  });

  it("lebih dari setengah selalu naik, termasuk sisa digit setelah 5", () => {
    expect(formatMoney("0.0051")).toBe("0,01");
    expect(formatMoney("0.009")).toBe("0,01");
  });
});

describe("formatMoney: presisi & tanda", () => {
  it("nilai di atas 2^53 tidak kehilangan digit", () => {
    expect(formatMoney("9007199254740993.00")).toBe("9.007.199.254.740.993,00");
    expect(formatMoney("9007199254740993.99995")).toBe("9.007.199.254.740.994,00");
  });

  it("negatif memakai minus di depan digit", () => {
    expect(formatMoney("-12.5")).toBe("-12,50");
  });

  it("nilai yang membulat ke nol tidak menampilkan -0", () => {
    expect(formatMoney("-0.004")).toBe("0,00");
  });

  it("menolak masukan yang bukan desimal", () => {
    for (const bad of ["", "abc", "1,5", "1.2.3", "1e6"]) {
      expect(() => formatMoney(bad)).toThrow(/bukan desimal/);
    }
  });
});

describe("addMoney: total laporan tanpa float", () => {
  it("menjumlahkan desimal apa adanya", () => {
    expect(addMoney("1000.00", "150.50")).toBe("1150.50");
    expect(addMoney("-0.01", "0.02")).toBe("0.01");
  });

  it("tetap tepat di atas 2^53", () => {
    expect(addMoney("9007199254740993.01", "0.01")).toBe("9007199254740993.02");
  });

  it("menolak masukan bukan desimal", () => {
    expect(() => addMoney("1,5", "2")).toThrow(/bukan desimal/);
  });
});

/**
 * Input nominal tunai (T-088d). Parser menerima yang diketik teller (digit + satu pemisah
 * desimal, maksimum 2 desimal) dan mengeluarkan desimal polos 2 desimal untuk kontrak API.
 */
describe("parseMoneyInput: bentuk yang diterima", () => {
  it("digit saja dan satu desimal", () => {
    expect(parseMoneyInput("150000")).toEqual({ ok: true, value: "150000.00" });
    expect(parseMoneyInput("150000.5")).toEqual({ ok: true, value: "150000.50" });
    expect(parseMoneyInput("150000,25")).toEqual({ ok: true, value: "150000.25" });
  });

  it("spasi di tepi diabaikan, nol di depan dibuang", () => {
    expect(parseMoneyInput("  150000  ")).toEqual({ ok: true, value: "150000.00" });
    expect(parseMoneyInput("0007")).toEqual({ ok: true, value: "7.00" });
  });

  it("nilai kurang dari satu", () => {
    expect(parseMoneyInput("0,5")).toEqual({ ok: true, value: "0.50" });
    expect(parseMoneyInput("0.01")).toEqual({ ok: true, value: "0.01" });
  });
});

describe("parseMoneyInput: bentuk yang ditolak", () => {
  it("kosong", () => {
    expect(parseMoneyInput("")).toEqual({ ok: false, error: "empty" });
    expect(parseMoneyInput("   ")).toEqual({ ok: false, error: "empty" });
  });

  it("nol dan bentuk nol", () => {
    expect(parseMoneyInput("0")).toEqual({ ok: false, error: "not_positive" });
    expect(parseMoneyInput("000")).toEqual({ ok: false, error: "not_positive" });
    expect(parseMoneyInput("0,00")).toEqual({ ok: false, error: "not_positive" });
  });

  it("bukan digit / pemisah ganda / pemisah menggantung", () => {
    for (const bad of ["abc", "1e6", "-5", "1.2.3", "1,2,3", "150,", ",5", "1 500", "+5"]) {
      expect(parseMoneyInput(bad)).toEqual({ ok: false, error: "invalid_format" });
    }
  });

  it("lebih dari 2 desimal", () => {
    expect(parseMoneyInput("150000,005")).toEqual({ ok: false, error: "too_precise" });
    expect(parseMoneyInput("150.000")).toEqual({ ok: false, error: "too_precise" });
  });
});

