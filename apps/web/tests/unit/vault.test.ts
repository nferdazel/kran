/**
 * Test unit web untuk T-121 (tanpa DOM, tanpa DB): validasi form pengajuan, sidik kunci
 * idempotensi, dan pemetaan `params.reason` ke pesan katalog.
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import * as m from "#lib/paraglide/messages.js";
import {
  NOTE_MAX_LENGTH,
  SOURCE_MAX_LENGTH,
  statusLabel,
  topUpIdentity,
  validateTopUp,
  vaultProblemMessage,
} from "#lib/app/vault.js";

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

const VALID = { amount: "50000", sourceAccount: "102", note: "[BANK] slip 123 | isi vault" };

describe("validateTopUp", () => {
  it("menerima isian sah dan menormalkan nominal ke 4 desimal", () => {
    const result = validateTopUp(VALID);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.amount).toBe("50000.0000");
      expect(result.value.sourceAccount).toBe("102");
    }
  });

  it("memangkas spasi tepi akun sumber dan bukti, tanpa mengubah isi tengah", () => {
    const result = validateTopUp({ ...VALID, sourceAccount: " 102 ", note: "  a b  " });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.value.sourceAccount).toBe("102");
      expect(result.value.note).toBe("a b");
    }
  });

  it("menolak nominal kosong, nol, dan lebih dari 2 desimal", () => {
    for (const [amount, message] of [
      ["", m.teller_error_amount_empty()],
      ["0", m.teller_error_amount_zero()],
      ["1.234", m.teller_error_amount_precision()],
    ] as const) {
      const result = validateTopUp({ ...VALID, amount });
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(result.error.field).toBe("amount");
        expect(result.error.message).toBe(message);
      }
    }
  });

  it("mewajibkan akun sumber dan membatasi panjangnya", () => {
    const empty = validateTopUp({ ...VALID, sourceAccount: "  " });
    expect(empty.ok).toBe(false);
    if (!empty.ok) expect(empty.error.message).toBe(m.vault_error_source_required());

    const long = validateTopUp({ ...VALID, sourceAccount: "1".repeat(SOURCE_MAX_LENGTH + 1) });
    expect(long.ok).toBe(false);
    if (!long.ok) expect(long.error.field).toBe("sourceAccount");
  });

  it("mewajibkan bukti dan membatasi 200 karakter (K-4)", () => {
    const empty = validateTopUp({ ...VALID, note: "   " });
    expect(empty.ok).toBe(false);
    if (!empty.ok) expect(empty.error.message).toBe(m.vault_error_note_required());

    const long = validateTopUp({ ...VALID, note: "x".repeat(NOTE_MAX_LENGTH + 1) });
    expect(long.ok).toBe(false);
    if (!long.ok) expect(long.error.message).toBe(m.vault_error_note_too_long());
  });

  it("membatasi panjang kode akun, bukan bentuknya (aturan akun milik server)", () => {
    const result = validateTopUp({ ...VALID, sourceAccount: "bukan-kode-akun" });
    expect(result.ok).toBe(true);
  });
});

describe("topUpIdentity", () => {
  it("sama untuk isian sama, berbeda saat nominal berubah", () => {
    const base = { branchId: "b1", amount: "50000.0000", sourceAccount: "102", note: "n" };
    expect(topUpIdentity(base)).toBe(topUpIdentity({ ...base }));
    expect(
      topUpIdentity(base) === topUpIdentity({ ...base, amount: "60000.0000" }),
    ).toBe(false);
  });
});

describe("statusLabel", () => {
  it("menerjemahkan ketiga status", () => {
    expect(statusLabel("PENDING")).toBe(m.vault_status_pending());
    expect(statusLabel("APPROVED")).toBe(m.vault_status_approved());
    expect(statusLabel("REJECTED")).toBe(m.vault_status_rejected());
  });
});

describe("vaultProblemMessage", () => {
  it("memakai reason domain lebih dulu", () => {
    const cases: ReadonlyArray<readonly [string, string]> = [
      ["topup_exceeds_limit", m.vault_error_limit()],
      ["source_account_invalid", m.vault_error_source_invalid()],
      ["topup_request_conflict", m.vault_error_conflict()],
      ["topup_request_not_pending", m.vault_error_not_pending()],
      ["self_approval", m.vault_error_self_approval()],
      ["topup_request_not_found", m.vault_error_not_found()],
      ["vault_not_configured", m.vault_error_vault_missing()],
      ["branch_not_allowed", m.vault_error_branch()],
    ];
    for (const [reason, expected] of cases) {
      expect(vaultProblemMessage(problem(409, reason))).toBe(expected);
    }
  });

  it("jatuh ke pesan status lalu amplop problem", () => {
    expect(vaultProblemMessage(problem(404, undefined, "error_not_found"))).toBe(
      m.vault_error_not_found(),
    );
    expect(vaultProblemMessage(problem(403, undefined, "error_forbidden"))).toBe(
      m.vault_error_branch(),
    );
    expect(vaultProblemMessage(problem(500, undefined, "error_internal_error"))).toBe(
      m.error_internal_error(),
    );
  });
});
