/**
 * Glue layar teller (T-088d): klien endpoint tunai/PB, pemetaan galat domain, validasi form, dan
 * kunci idempotensi. Logika murni (validasi, pemetaan pesan, sidik kunci) dipisah dari komponen
 * supaya bisa diuji vitest tanpa DOM dan tanpa DB.
 *
 * Catatan kontrak (per 23 Okt 2026):
 *  - `POST /teller/cash-transactions` dan `POST /teller/transfers` mewajibkan `Idempotency-Key`.
 *  - Konflik domain 409 selalu datang sebagai `i18nKey: "error_conflict"`; sebabnya ada di
 *    `params.reason` (`insufficient_funds`, `period_closed`, `account_not_active`,
 *    `branch_not_allowed`, `no_open_session`). Karena itu pemetaannya per `reason`, bukan lewat
 *    `i18nKey` (pola `paramProblemMessage` di `errors.ts`).
 *  - API sesi kas teller (T-093) belum ada: modul ini tidak mengarang status sesi.
 *  - Pencarian nomor rekening belum ada: UI menerima `accountId` (UUID) apa adanya. Lihat TODO
 *    di halaman teller.
 */
import type { Problem } from "@kran/api-client";
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";
import { parseMoneyInput } from "@kran/ui/money";

import { api } from "#lib/app/api.js";
import { problemMessage } from "#lib/app/errors.js";

export type DepositAccount = components["schemas"]["DepositAccount"];
export type CashTransaction = components["schemas"]["CashTransaction"];
export type Transfer = components["schemas"]["Transfer"];

/** Setor (masuk kas) atau tarik (keluar kas). */
export type CashDirection = "DEPOSIT" | "WITHDRAWAL";
/** Jenis pekerjaan di layar teller; `TRANSFER` = pemindahbukuan antar rekening. */
export type TellerMode = CashDirection | "TRANSFER";

/** Batas kolom `narration` di kontrak. Batas teknis kolom, bukan aturan bisnis. */
export const NARRATION_MAX_LENGTH = 200;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type TellerField = "accountId" | "destinationAccountId" | "amount" | "narration";

export interface TellerFormError {
  field: TellerField;
  message: string;
}

/** Nomor rekening belum bisa dicari (T-105); untuk sekarang UI menerima UUID rekening. */
export function isAccountId(value: string): boolean {
  return UUID_PATTERN.test(value.trim());
}

function amountErrorMessage(error: "empty" | "invalid_format" | "not_positive" | "too_precise"): string {
  if (error === "empty") return m.teller_error_amount_empty();
  if (error === "too_precise") return m.teller_error_amount_precision();
  if (error === "not_positive") return m.teller_error_amount_zero();
  return m.teller_error_amount_format();
}

/**
 * Nominal terketik → desimal polos 4 desimal, atau galat yang menunjuk field `amount`.
 * Parser-nya di `@kran/ui/money` (satu pintu uang, D-097); di sini hanya pesan yang dilokalkan.
 */
export function validateAmount(
  raw: string,
): { ok: true; amount: string } | { ok: false; error: TellerFormError } {
  const parsed = parseMoneyInput(raw);
  if (parsed.ok) return { ok: true, amount: parsed.value };
  return { ok: false, error: { field: "amount", message: amountErrorMessage(parsed.error) } };
}

/** Pratinjau nominal: desimal polos 4 desimal bila isian sah, `""` bila belum. */
export function previewAmount(raw: string): string {
  const parsed = parseMoneyInput(raw);
  return parsed.ok ? parsed.value : "";
}

function accountIdError(field: "accountId" | "destinationAccountId", raw: string): TellerFormError | null {
  const value = raw.trim();
  if (value === "") {
    return {
      field,
      message:
        field === "destinationAccountId"
          ? m.teller_error_destination_required()
          : m.teller_error_account_required(),
    };
  }
  if (!isAccountId(value)) {
    return {
      field,
      message:
        field === "destinationAccountId"
          ? m.teller_error_destination_invalid()
          : m.teller_error_account_invalid(),
    };
  }
  return null;
}

function narrationError(raw: string): TellerFormError | null {
  if (raw.trim().length > NARRATION_MAX_LENGTH) {
    return { field: "narration", message: m.teller_error_narration_too_long() };
  }
  return null;
}

export interface CashFormInput {
  accountId: string;
  amountRaw: string;
  narration: string;
}

export interface CashFormValue {
  accountId: string;
  amount: string;
  narration: string;
}

export type CashFormResult =
  | ({ ok: true } & CashFormValue)
  | { ok: false; error: TellerFormError };

export function validateCashForm(input: CashFormInput): CashFormResult {
  const account = accountIdError("accountId", input.accountId);
  if (account !== null) return { ok: false, error: account };
  const amount = validateAmount(input.amountRaw);
  if (!amount.ok) return { ok: false, error: amount.error };
  const narration = narrationError(input.narration);
  if (narration !== null) return { ok: false, error: narration };
  return {
    ok: true,
    accountId: input.accountId.trim(),
    amount: amount.amount,
    narration: input.narration.trim(),
  };
}

export interface TransferFormInput {
  sourceAccountId: string;
  destinationAccountId: string;
  amountRaw: string;
  narration: string;
}

export interface TransferFormValue {
  sourceAccountId: string;
  destinationAccountId: string;
  amount: string;
  narration: string;
}

export type TransferFormResult =
  | ({ ok: true } & TransferFormValue)
  | { ok: false; error: TellerFormError };

export function validateTransferForm(input: TransferFormInput): TransferFormResult {
  const source = accountIdError("accountId", input.sourceAccountId);
  if (source !== null) return { ok: false, error: source };
  const destination = accountIdError("destinationAccountId", input.destinationAccountId);
  if (destination !== null) return { ok: false, error: destination };
  if (input.destinationAccountId.trim().toLowerCase() === input.sourceAccountId.trim().toLowerCase()) {
    return { ok: false, error: { field: "destinationAccountId", message: m.teller_error_destination_same() } };
  }
  const amount = validateAmount(input.amountRaw);
  if (!amount.ok) return { ok: false, error: amount.error };
  const narration = narrationError(input.narration);
  if (narration !== null) return { ok: false, error: narration };
  return {
    ok: true,
    sourceAccountId: input.sourceAccountId.trim(),
    destinationAccountId: input.destinationAccountId.trim(),
    amount: amount.amount,
    narration: input.narration.trim(),
  };
}

/**
 * Sidik isi form untuk kunci idempotensi: kunci baru dibuat saat sidik berubah, sehingga mengganti
 * nominal setelah kegagalan 5xx memulai permintaan baru (bukan replay dengan isi berbeda → 409).
 */
export function cashIdentity(input: {
  accountId: string;
  direction: CashDirection;
  amount: string;
  narration: string;
}): string {
  return JSON.stringify(["cash", input.accountId, input.direction, input.amount, input.narration]);
}

export function transferIdentity(input: {
  sourceAccountId: string;
  destinationAccountId: string;
  amount: string;
  narration: string;
}): string {
  return JSON.stringify([
    "transfer",
    input.sourceAccountId,
    input.destinationAccountId,
    input.amount,
    input.narration,
  ]);
}

/** Kunci idempotensi per pemanggil (D-098); panjang `crypto.randomUUID()` jauh di bawah 156. */
export function newIdempotencyKey(): string {
  return crypto.randomUUID();
}

const PROBLEM_REASON_MESSAGES: Record<string, () => string> = {
  insufficient_funds: () => m.teller_error_insufficient_funds(),
  period_closed: () => m.teller_error_period_closed(),
  account_not_active: () => m.teller_error_account_not_active(),
  branch_not_allowed: () => m.teller_error_branch_not_allowed(),
  no_open_session: () => m.teller_error_no_open_session(),
};

/**
 * Pesan galat transaksi. Urutan: `params.reason` (409/403 domain), lalu 404 rekening, lalu 403
 * izin, terakhir amplop `problemMessage` biasa. Tidak menyebut angka saldo: 409 tidak membawa
 * saldo, dan mengarang angka dilarang.
 */
export function tellerProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : PROBLEM_REASON_MESSAGES[reason];
  if (template !== undefined) return template();
  if (problem.status === 404) return m.teller_not_found();
  if (problem.status === 403) return m.teller_denied();
  return problemMessage(problem);
}

export function loadDepositAccount(accountId: string) {
  return api.GET("/api/v1/deposit/accounts/{accountId}", {
    params: { path: { accountId } },
  });
}

export function postCashTransaction(
  body: { accountId: string; direction: CashDirection; amount: string; narration?: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/teller/cash-transactions", {
    params: { header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}

export function postTransfer(
  body: { sourceAccountId: string; destinationAccountId: string; amount: string; narration?: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/teller/transfers", {
    params: { header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}
