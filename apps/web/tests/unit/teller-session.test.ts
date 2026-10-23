/**
 * Test unit web untuk panel sesi kas T-108 (tanpa DOM, tanpa DB).
 *
 * Dijalankan dengan binary vitest milik `packages/ui` (lihat `vitest.d.ts`):
 *   cd apps/web && node ../../packages/ui/node_modules/vitest/vitest.mjs run tests/unit
 *
 * Yang diuji di sini logika murni: validasi hitungan kas, sidik kunci idempotensi, pemetaan
 * `params.reason` → pesan katalog, klasifikasi respons `sessions/current`, gerbang form transaksi,
 * dan ringkasan selisih. Perilaku sesi di server diuji backend (`itapi_teller`).
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import * as m from "#lib/paraglide/messages.js";
import {
  SESSION_NOTE_MAX_LENGTH,
  currentSessionOutcome,
  parseCashCount,
  sessionCloseIdentity,
  sessionNoteError,
  sessionOpenIdentity,
  sessionPostingGate,
  tellerSessionProblemMessage,
  validateCountedCash,
  validateOpeningFloat,
  varianceDirection,
  varianceSummary,
} from "#lib/app/teller-session.js";

const BRANCH = "11111111-1111-4111-8111-111111111111";
const SESSION = "33333333-3333-4333-8333-333333333333";

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

describe("parseCashCount", () => {
  it("meneruskan aturan parser uang, kecuali nol yang diterima", () => {
    expect(parseCashCount("125000,25")).toEqual({ ok: true, value: "125000.2500" });
    expect(parseCashCount("0000125")).toEqual({ ok: true, value: "125.0000" });
    expect(parseCashCount("0")).toEqual({ ok: true, value: "0.0000" });
    expect(parseCashCount("00,00")).toEqual({ ok: true, value: "0.0000" });
    expect(parseCashCount("")).toEqual({ ok: false, error: "empty" });
    expect(parseCashCount("12,345")).toEqual({ ok: false, error: "too_precise" });
    expect(parseCashCount("12x")).toEqual({ ok: false, error: "invalid_format" });
  });
});

describe("validateOpeningFloat", () => {
  it("menerima nilai biasa dan nol, menormalkan ke 4 desimal", () => {
    expect(validateOpeningFloat("500000")).toEqual({ ok: true, amount: "500000.0000" });
    expect(validateOpeningFloat("150000,5")).toEqual({ ok: true, amount: "150000.5000" });
    // Laci boleh kosong: nol diterima, berbeda dari nominal transaksi.
    expect(validateOpeningFloat("0")).toEqual({ ok: true, amount: "0.0000" });
    expect(validateOpeningFloat("0,00")).toEqual({ ok: true, amount: "0.0000" });
  });

  it("menunjuk field float awal dengan pesan tiap galat parser", () => {
    expect(validateOpeningFloat("")).toEqual({
      ok: false,
      error: { field: "openingFloat", message: m.teller_session_error_float_required() },
    });
    expect(validateOpeningFloat("abc")).toEqual({
      ok: false,
      error: { field: "openingFloat", message: m.teller_error_amount_format() },
    });
    expect(validateOpeningFloat("1.234")).toEqual({
      ok: false,
      error: { field: "openingFloat", message: m.teller_error_amount_precision() },
    });
    expect(validateOpeningFloat("-500")).toEqual({
      ok: false,
      error: { field: "openingFloat", message: m.teller_error_amount_format() },
    });
  });
});

describe("validateCountedCash", () => {
  it("memakai label field sendiri saat kosong dan menerima nol", () => {
    expect(validateCountedCash("")).toEqual({
      ok: false,
      error: { field: "countedCash", message: m.teller_session_error_counted_required() },
    });
    expect(validateCountedCash("0")).toEqual({ ok: true, amount: "0.0000" });
    expect(validateCountedCash("250000,75")).toEqual({ ok: true, amount: "250000.7500" });
  });
});

describe("sessionNoteError", () => {
  it("menerima catatan sampai batas kolom dan menolak lebih", () => {
    expect(sessionNoteError("")).toEqual(null);
    expect(sessionNoteError("x".repeat(SESSION_NOTE_MAX_LENGTH))).toEqual(null);
    expect(sessionNoteError("x".repeat(SESSION_NOTE_MAX_LENGTH + 1))).toEqual({
      field: "sessionNote",
      message: m.teller_session_error_note_too_long(),
    });
  });
});

describe("sidik kunci idempotensi sesi", () => {
  it("berubah ketika nilai kas atau catatan berubah", () => {
    const first = sessionOpenIdentity({ branchId: BRANCH, openingFloat: "500000.0000", note: "" });
    expect(first).toBe(sessionOpenIdentity({ branchId: BRANCH, openingFloat: "500000.0000", note: "" }));
    expect(
      first === sessionOpenIdentity({ branchId: BRANCH, openingFloat: "500001.0000", note: "" }),
    ).toBe(false);
    expect(
      first === sessionOpenIdentity({ branchId: BRANCH, openingFloat: "500000.0000", note: "kas pagi" }),
    ).toBe(false);
  });

  it("buka dan tutup tidak pernah bertabrakan", () => {
    expect(
      sessionCloseIdentity({ sessionId: SESSION, countedCash: "0.0000", note: "" }) ===
        sessionCloseIdentity({ sessionId: SESSION, countedCash: "0.0000", note: "" }),
    ).toBe(true);
    expect(
      sessionCloseIdentity({ sessionId: SESSION, countedCash: "0.0000", note: "" }) ===
        sessionOpenIdentity({ branchId: SESSION, openingFloat: "0.0000", note: "" }),
    ).toBe(false);
  });
});

describe("currentSessionOutcome", () => {
  it("hanya 200 = sesi terbuka dan 404 session_not_open = belum ada sesi", () => {
    expect(currentSessionOutcome(200, undefined)).toBe("open");
    expect(currentSessionOutcome(404, "session_not_open")).toBe("missing");
  });

  it("menandai respons lain sebagai gagal (form transaksi ditutup)", () => {
    expect(currentSessionOutcome(404, undefined)).toBe("failed");
    expect(currentSessionOutcome(403, "branch_not_allowed")).toBe("failed");
    expect(currentSessionOutcome(500, undefined)).toBe("failed");
  });
});

describe("sessionPostingGate", () => {
  const closed = { branchKnown: true, loading: false, failed: false, missing: false, stale: false };

  it("membuka form hanya saat sesi OPEN dan statusnya pasti", () => {
    expect(sessionPostingGate(closed)).toEqual({ blocked: false });
  });

  it("menutup form tanpa cabang, saat memuat, atau saat galat (fail-closed)", () => {
    expect(sessionPostingGate({ ...closed, branchKnown: false })).toEqual({
      blocked: true,
      tone: "muted",
      message: m.teller_transaction_need_account(),
    });
    expect(sessionPostingGate({ ...closed, branchKnown: false, loading: true })).toEqual({
      blocked: true,
      tone: "muted",
      message: m.teller_transaction_need_account(),
    });
    expect(sessionPostingGate({ ...closed, loading: true })).toEqual({
      blocked: true,
      tone: "muted",
      message: m.teller_session_blocked_loading(),
    });
    expect(sessionPostingGate({ ...closed, failed: true })).toEqual({
      blocked: true,
      tone: "alert",
      message: m.teller_session_blocked_error(),
    });
  });

  it("memetakan sesi bertanggal lain dan sesi yang belum dibuka ke jalan keluar", () => {
    expect(sessionPostingGate({ ...closed, stale: true })).toEqual({
      blocked: true,
      tone: "alert",
      message: m.teller_error_session_business_date_mismatch(),
    });
    expect(sessionPostingGate({ ...closed, missing: true })).toEqual({
      blocked: true,
      tone: "muted",
      message: m.teller_error_no_open_session(),
    });
  });

  it("sesi bertanggal lain lebih dulu daripada sesi yang belum dibuka", () => {
    expect(sessionPostingGate({ ...closed, missing: true, stale: true })).toEqual({
      blocked: true,
      tone: "alert",
      message: m.teller_error_session_business_date_mismatch(),
    });
  });
});

describe("tellerSessionProblemMessage: params.reason", () => {
  it("memetakan setiap sebab domain endpoint sesi", () => {
    expect(tellerSessionProblemMessage(problem(409, "session_already_open"))).toBe(
      m.teller_session_error_already_open(),
    );
    expect(tellerSessionProblemMessage(problem(409, "insufficient_vault"))).toBe(
      m.teller_session_error_insufficient_vault(),
    );
    expect(tellerSessionProblemMessage(problem(409, "vault_not_configured"))).toBe(
      m.teller_session_error_vault_missing(),
    );
    expect(tellerSessionProblemMessage(problem(409, "session_not_open"))).toBe(
      m.teller_session_error_already_closed(),
    );
    expect(tellerSessionProblemMessage(problem(409, "session_not_owned"))).toBe(
      m.teller_session_error_not_owned(),
    );
    expect(tellerSessionProblemMessage(problem(403, "branch_not_allowed"))).toBe(
      m.teller_session_branch_not_allowed(),
    );
  });

  it("404 sesi tidak dikenal dan 403 izin sesi punya pesan sendiri", () => {
    expect(tellerSessionProblemMessage(problem(404))).toBe(m.teller_session_error_not_found());
    expect(tellerSessionProblemMessage(problem(403))).toBe(m.teller_session_denied());
  });

  it("sebab tak dikenal jatuh ke pesan amplop", () => {
    expect(tellerSessionProblemMessage(problem(400, "unknown_reason", "error_bad_request"))).toBe(
      m.error_bad_request(),
    );
    expect(tellerSessionProblemMessage(problem(500, undefined, "error_internal_error"))).toBe(
      m.error_internal_error(),
    );
  });
});

describe("selisih kas", () => {
  it("membaca arah dari tanda desimal string", () => {
    expect(varianceDirection("0.0000")).toBe("even");
    expect(varianceDirection("0,00")).toBe("even");
    expect(varianceDirection("-0.0000")).toBe("even");
    expect(varianceDirection("25000.0000")).toBe("over");
    expect(varianceDirection("-50000.0000")).toBe("short");
  });

  it("menyebut selisih dengan kata + nominal bertanda, nol sebagai kata saja", () => {
    expect(varianceSummary("0.0000")).toBe(m.teller_session_variance_even());
    expect(varianceSummary("-50000.0000")).toContain(m.teller_session_variance_short());
    expect(varianceSummary("-50000.0000")).toMatch(/-50[.,]000/);
    expect(varianceSummary("12500.0000")).toContain(m.teller_session_variance_over());
    expect(varianceSummary("12500.0000")).toMatch(/12[.,]500/);
  });
});
