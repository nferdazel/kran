/**
 * Glue panel sesi kas di layar teller (T-108): klien current/open/close, validasi hitungan kas,
 * pemetaan galat sesi, dan gerbang form transaksi. Logika murni (validasi, pemetaan, gerbang)
 * dipisah dari komponen supaya bisa diuji vitest tanpa DOM dan tanpa DB.
 *
 * Catatan kontrak (23 Okt 2026):
 *  - `GET /teller/sessions/current?branchId=` → 200 `TellerSession`; 404 dengan
 *    `params.reason=session_not_open` bila belum ada sesi (bukan 200 dengan `null`).
 *  - `POST /teller/sessions` dan `POST /teller/sessions/{sessionId}/close` mewajibkan
 *    `Idempotency-Key`; konflik domain 409 membawa sebabnya di `params.reason`
 *    (`session_already_open`, `insufficient_vault`, `vault_not_configured`, `session_not_open`,
 *    `session_not_owned`, `branch_not_allowed`).
 *  - Float awal dan kas hasil hitung boleh nol, sedangkan `parseMoneyInput` menolak nol (parser itu
 *    dipakai untuk nominal transaksi). Jadi nol dibentuk di sini, tetap tanpa float.
 *  - Layar belum punya pemilih cabang; cabang sesi = cabang rekening yang sedang dimuat, yaitu
 *    cabang yang sama dengan yang dipakai `POST /teller/cash-transactions`.
 */
import type { Problem } from "@kran/api-client";
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";
import { parseMoneyInput, type MoneyInputError } from "@kran/ui/money";

import { api } from "#lib/app/api.js";
import { problemMessage } from "#lib/app/errors.js";
import { formatMoney } from "#lib/app/format.js";

export type TellerSession = components["schemas"]["TellerSession"];
export type TellerSessionClose = components["schemas"]["TellerSessionClose"];

/** Batas kolom `note` di kontrak (`TellerSessionOpenRequest`/`TellerSessionCloseRequest`). */
export const SESSION_NOTE_MAX_LENGTH = 200;

export type TellerSessionField = "openingFloat" | "countedCash" | "sessionNote";

export interface TellerSessionFormError {
  field: TellerSessionField;
  message: string;
}

const ZERO_INPUT_PATTERN = /^0+(?:[.,]0{1,2})?$/;

/**
 * Hitungan kas (float awal atau kas hasil hitung) → desimal polos 4 desimal. Sama ketat dengan
 * `parseMoneyInput` (satu pintu uang, D-097), kecuali satu hal: nol diterima, karena laci boleh
 * kosong dan selisih nol adalah hasil normal.
 */
export function parseCashCount(
  raw: string,
): { ok: true; value: string } | { ok: false; error: MoneyInputError } {
  const parsed = parseMoneyInput(raw);
  if (parsed.ok) return parsed;
  if (parsed.error === "not_positive" && ZERO_INPUT_PATTERN.test(raw.trim())) {
    return { ok: true, value: "0.0000" };
  }
  return parsed;
}

function cashCountError(field: TellerSessionField, error: MoneyInputError): TellerSessionFormError {
  if (error === "empty") {
    return {
      field,
      message:
        field === "countedCash"
          ? m.teller_session_error_counted_required()
          : m.teller_session_error_float_required(),
    };
  }
  if (error === "too_precise") return { field, message: m.teller_error_amount_precision() };
  return { field, message: m.teller_error_amount_format() };
}

export function validateOpeningFloat(
  raw: string,
): { ok: true; amount: string } | { ok: false; error: TellerSessionFormError } {
  const parsed = parseCashCount(raw);
  if (parsed.ok) return { ok: true, amount: parsed.value };
  return { ok: false, error: cashCountError("openingFloat", parsed.error) };
}

export function validateCountedCash(
  raw: string,
): { ok: true; amount: string } | { ok: false; error: TellerSessionFormError } {
  const parsed = parseCashCount(raw);
  if (parsed.ok) return { ok: true, amount: parsed.value };
  return { ok: false, error: cashCountError("countedCash", parsed.error) };
}

export function sessionNoteError(note: string): TellerSessionFormError | null {
  if (note.trim().length > SESSION_NOTE_MAX_LENGTH) {
    return { field: "sessionNote", message: m.teller_session_error_note_too_long() };
  }
  return null;
}

/** Sidik isi form buka sesi untuk kunci idempotensi (pola `cashIdentity` di `teller.ts`). */
export function sessionOpenIdentity(input: {
  branchId: string;
  openingFloat: string;
  note: string;
}): string {
  return JSON.stringify(["session-open", input.branchId, input.openingFloat, input.note]);
}

/** Sidik isi form tutup sesi untuk kunci idempotensi. */
export function sessionCloseIdentity(input: {
  sessionId: string;
  countedCash: string;
  note: string;
}): string {
  return JSON.stringify(["session-close", input.sessionId, input.countedCash, input.note]);
}

/** Hasil `GET /teller/sessions/current`: sesi terbuka, belum ada sesi, atau gagal. */
export type CurrentSessionOutcome = "open" | "missing" | "failed";

/**
 * `404 session_not_open` = belum ada sesi (keadaan awal hari, bukan galat); selain 200 dan 404 itu
 * berarti panel tidak bisa memastikan status sesi dan form transaksi harus ditutup (fail-closed).
 */
export function currentSessionOutcome(status: number, reason: string | undefined): CurrentSessionOutcome {
  if (status === 200) return "open";
  if (status === 404 && reason === "session_not_open") return "missing";
  return "failed";
}

export type SessionGateTone = "muted" | "alert";

/**
 * Gerbang form transaksi tunai: tanpa cabang, sesi sedang dimuat, status sesi tidak pasti, sesi
 * bertanggal bisnis lain, atau belum ada sesi berarti form ditutup. Setiap pesan memberi jalan
 * keluar (muat rekening, buka sesi, tutup sesi lama, muat ulang sesi).
 */
export type SessionGate =
  | { blocked: false }
  | { blocked: true; tone: SessionGateTone; message: string };

export interface SessionGateInput {
  branchKnown: boolean;
  loading: boolean;
  failed: boolean;
  missing: boolean;
  stale: boolean;
}

export function sessionPostingGate(input: SessionGateInput): SessionGate {
  if (!input.branchKnown) {
    return { blocked: true, tone: "muted", message: m.teller_transaction_need_account() };
  }
  if (input.loading) {
    return { blocked: true, tone: "muted", message: m.teller_session_blocked_loading() };
  }
  if (input.failed) {
    return { blocked: true, tone: "alert", message: m.teller_session_blocked_error() };
  }
  if (input.stale) {
    return {
      blocked: true,
      tone: "alert",
      message: m.teller_error_session_business_date_mismatch(),
    };
  }
  if (input.missing) {
    return { blocked: true, tone: "muted", message: m.teller_error_no_open_session() };
  }
  return { blocked: false };
}

export type VarianceDirection = "over" | "short" | "even";

/** Arah selisih kas dari desimal string (tanpa float): `-` = kas kurang, nol = pas. */
export function varianceDirection(variance: string): VarianceDirection {
  const text = variance.trim();
  const negative = text.startsWith("-");
  const digits = (negative ? text.slice(1) : text).replace(/[.,]/g, "");
  if (!/^[0-9]+$/.test(digits)) throw new Error(`variance bukan desimal: ${variance}`);
  if (!/[1-9]/.test(digits)) return "even";
  return negative ? "short" : "over";
}

/**
 * Selisih kas sebagai kata + nominal bertanda (DESIGN §6: selisih selalu disertai kata, bukan
 * warna atau tanda saja). Nol hanya jadi kata, tidak diulang sebagai nominal.
 */
export function varianceSummary(variance: string): string {
  const direction = varianceDirection(variance);
  if (direction === "even") return m.teller_session_variance_even();
  const word =
    direction === "over" ? m.teller_session_variance_over() : m.teller_session_variance_short();
  return `${word} ${formatMoney(variance, { decimals: 2 })}`;
}

const SESSION_PROBLEM_REASONS: Record<string, () => string> = {
  session_already_open: () => m.teller_session_error_already_open(),
  insufficient_vault: () => m.teller_session_error_insufficient_vault(),
  vault_not_configured: () => m.teller_session_error_vault_missing(),
  session_not_open: () => m.teller_session_error_already_closed(),
  session_not_owned: () => m.teller_session_error_not_owned(),
  branch_not_allowed: () => m.teller_session_branch_not_allowed(),
};

/**
 * Pesan galat endpoint sesi. Urutan: `params.reason` (409/403 domain), lalu 404 sesi tidak
 * dikenal, lalu 403 izin sesi, terakhir amplop `problemMessage` biasa. `404 session_not_open` pada
 * `GET sessions/current` bukan galat dan tidak lewat sini (lihat `currentSessionOutcome`).
 */
export function tellerSessionProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : SESSION_PROBLEM_REASONS[reason];
  if (template !== undefined) return template();
  if (problem.status === 404) return m.teller_session_error_not_found();
  if (problem.status === 403) return m.teller_session_denied();
  return problemMessage(problem);
}

export function loadCurrentTellerSession(branchId: string) {
  return api.GET("/api/v1/teller/sessions/current", {
    params: { query: { branchId } },
  });
}

export function openTellerSession(
  body: { branchId: string; openingFloat: string; note?: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/teller/sessions", {
    params: { header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}

export function closeTellerSession(
  sessionId: string,
  body: { countedCash: string; note?: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/teller/sessions/{sessionId}/close", {
    params: { path: { sessionId }, header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}
