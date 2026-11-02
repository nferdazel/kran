/**
 * Glue layar pinjaman (T-170/T-173): label status/golongan, pemetaan kegagalan domain, dan klien
 * empat aksi tulis (pencairan, pembayaran, restrukturisasi, hapus buku).
 *
 * Logika murni (tanpa DOM, tanpa jaringan selain pemanggilan endpoint) supaya bisa diuji vitest.
 * Yang **tidak** ada di sini: aritmetika uang. Sisa kewajiban datang dari server
 * (`principalOutstanding`), bukan dihitung ulang di peramban dengan `number` — uang tidak boleh
 * melewati float (AGENTS.md §1.3). Pratinjau hanya memformat string desimal yang dikirim apa adanya.
 *
 * Catatan kontrak (T-163…T-168): keempat endpoint mewajibkan `Idempotency-Key`. Konflik domain 409
 * membawa `params.reason` yang stabil (`not_approved`, `already_disbursed`, `insufficient_balance`,
 * …), jadi pesannya dipetakan per `reason`, bukan per `i18nKey` amplop.
 */

import type { Problem } from "@kran/api-client";

import * as m from "#lib/paraglide/messages.js";
import { parseMoneyInput } from "@kran/ui/money";

import { api } from "#lib/app/api.js";
import { problemMessage } from "#lib/app/errors.js";
import type { DepositAccount, LoanStatus } from "#lib/app/types.js";

/** Empat aksi tulis pada layar detail pinjaman. */
export type LoanAction = "disburse" | "payment" | "restructure" | "write-off";

/** Batas kolom `reason` di kontrak; batas teknis, bukan aturan bisnis. */
export const LOAN_REASON_MAX_LENGTH = 500;

const STATUS_MESSAGES: Record<LoanStatus, () => string> = {
  APPLIED: () => m.loans_status_applied(),
  APPROVED: () => m.loans_status_approved(),
  ACTIVE: () => m.loans_status_active(),
  CLOSED: () => m.loans_status_closed(),
  WRITTEN_OFF: () => m.loans_status_written_off(),
};

/** Label status pinjaman; nilai tak dikenal ditampilkan apa adanya, bukan ditebak. */
export function loanStatusLabel(status: string): string {
  const template = STATUS_MESSAGES[status as LoanStatus];
  return template === undefined ? status : template();
}

const GRADE_MESSAGES: Record<string, () => string> = {
  COLLECTIBLE: () => m.loans_grade_collectible(),
  SPECIAL_MENTION: () => m.loans_grade_special_mention(),
  SUBSTANDARD: () => m.loans_grade_substandard(),
  DOUBTFUL: () => m.loans_grade_doubtful(),
  LOSS: () => m.loans_grade_loss(),
};

/** Golongan kolektibilitas; `null` = belum pernah dinilai task regrading. */
export function collectibilityLabel(grade: string | null | undefined): string {
  if (grade === null || grade === undefined || grade === "") return m.loans_grade_none();
  const template = GRADE_MESSAGES[grade];
  return template === undefined ? grade : template();
}

/** Nilai uang opsional: `null` = belum ada (mis. pinjaman belum dicairkan), bukan nol. */
export function valueOrDash(value: string | null | undefined): string | null {
  return value === null || value === undefined ? null : value;
}

/**
 * Rekening yang boleh dipilih sebagai sumber dana: `ACTIVE` **dan** satu cabang dengan akad.
 * `GET /deposit/accounts?partyId=` menyaring per izin cabang pemanggil, bukan cabang pinjaman, jadi
 * operator multi-cabang tetap bisa melihat rekening cabang lain; menawarkannya hanya menghasilkan
 * `account_branch_mismatch` setelah konfirmasi. Server tetap penjaga terakhir, seperti untuk
 * `account_not_active`.
 */
export function activePartyAccounts(
  accounts: readonly DepositAccount[],
  branchId?: string,
): DepositAccount[] {
  return accounts.filter(
    (account) =>
      account.status === "ACTIVE" && (branchId === undefined || account.branchId === branchId),
  );
}

export function loadPartyAccounts(partyId: string, signal?: AbortSignal) {
  return api.GET("/api/v1/deposit/accounts", { params: { query: { partyId } }, signal });
}

export function loanDisburse(
  loanId: string,
  body: { accountId: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/lending/loans/{loanId}/disburse", {
    params: { path: { loanId }, header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}

export function loanPay(
  loanId: string,
  body: { accountId: string; amount: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/lending/loans/{loanId}/payments", {
    params: { path: { loanId }, header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}

export function loanRestructure(
  loanId: string,
  body: { tenorMonths: number; reason: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/lending/loans/{loanId}/restructure", {
    params: { path: { loanId }, header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}

export function loanWriteOff(loanId: string, body: { reason: string }, idempotencyKey: string) {
  return api.POST("/api/v1/lending/loans/{loanId}/write-off", {
    params: { path: { loanId }, header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}

/** Nominal terketik → desimal polos 2 desimal untuk pratinjau dan body, tanpa menyentuh float. */
export function paymentAmountPreview(raw: string): string {
  const parsed = parseMoneyInput(raw);
  return parsed.ok ? parsed.value : "";
}

/**
 * Validasi nominal pembayaran. Parser uang satu pintu (`@kran/ui/money`, D-097); batas "melebihi
 * sisa kewajiban" dan "saldo tidak cukup" **tidak** diperiksa di sini — server yang punya angka.
 */
export function validatePaymentAmount(
  raw: string,
): { ok: true; amount: string } | { ok: false; message: string } {
  const parsed = parseMoneyInput(raw);
  if (parsed.ok) return { ok: true, amount: parsed.value };
  if (parsed.error === "empty") return { ok: false, message: m.loans_error_amount_empty() };
  if (parsed.error === "too_precise") return { ok: false, message: m.loans_error_amount_precision() };
  if (parsed.error === "not_positive") return { ok: false, message: m.loans_error_amount_zero() };
  return { ok: false, message: m.loans_error_amount_format() };
}

/** Tenor baru: bilangan bulat minimal 1 bulan; batas atas milik kontrak/versi produk, bukan UI. */
export function validateTenor(
  raw: string,
): { ok: true; tenorMonths: number } | { ok: false; message: string } {
  const value = raw.trim();
  if (value === "") return { ok: false, message: m.loans_error_tenor_empty() };
  if (!/^\d+$/.test(value)) return { ok: false, message: m.loans_error_tenor_invalid() };
  const months = Number.parseInt(value, 10);
  if (months < 1) return { ok: false, message: m.loans_error_tenor_invalid() };
  return { ok: true, tenorMonths: months };
}

/** Alasan wajib 1–500 karakter, sama dengan kontrak; tidak dilonggarkan di UI. */
export function validateLoanReason(
  raw: string,
): { ok: true; reason: string } | { ok: false; message: string } {
  const reason = raw.trim();
  if (reason === "") return { ok: false, message: m.loans_error_reason_empty() };
  if (reason.length > LOAN_REASON_MAX_LENGTH) {
    return { ok: false, message: m.loans_error_reason_too_long() };
  }
  return { ok: true, reason };
}

const REASON_MESSAGES: Record<string, () => string> = {
  loan_not_found: () => m.loans_detail_not_found(),
  not_approved: () => m.loans_error_not_approved(),
  already_disbursed: () => m.loans_error_already_disbursed(),
  not_disbursed: () => m.loans_error_not_disbursed(),
  loan_inactive: () => m.loans_error_loan_inactive(),
  schedule_missing: () => m.loans_error_schedule_missing(),
  amount_exceeds_outstanding: () => m.loans_error_amount_exceeds_outstanding(),
  insufficient_balance: () => m.loans_error_insufficient_balance(),
  account_party_mismatch: () => m.loans_error_account_party_mismatch(),
  account_branch_mismatch: () => m.loans_error_account_branch_mismatch(),
  account_not_active: () => m.loans_error_account_not_active(),
  allocation_conflict: () => m.loans_error_allocation_conflict(),
  not_loss: () => m.loans_error_not_loss(),
  already_written_off: () => m.loans_error_already_written_off(),
  nothing_to_write_off: () => m.loans_error_nothing_to_write_off(),
  restructure_invalid: () => m.loans_error_restructure_invalid(),
  product_version_missing: () => m.loans_error_product_version_missing(),
  account_not_found: () => m.loans_error_account_not_found(),
  account_without_balance: () => m.loans_error_account_without_balance(),
  schedule_invalid: () => m.loans_error_schedule_invalid(),
};

/**
 * Pesan kegagalan pinjaman; sebab yang dikenal dipetakan, sisanya jatuh ke pesan amplop.
 * `loan_not_found` dipakai GET detail dan juga untuk akad di cabang lain — server sengaja
 * menjawab 404 agar keberadaan akad tidak bocor.
 */
export function loanProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : REASON_MESSAGES[reason];
  return template === undefined ? problemMessage(problem) : template();
}

/**
 * Pesan kegagalan aksi tulis. Urutan: `params.reason` (403/404/409 domain), lalu 403 izin tanpa
 * alasan, lalu pesan amplop. Sebab tak dikenal tidak ditebak (pola `tellerProblemMessage`).
 */
export function loanActionProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : REASON_MESSAGES[reason];
  if (template !== undefined) return template();
  if (problem.status === 403) return m.loans_action_denied();
  if (problem.status === 404) return m.loans_detail_not_found();
  return problemMessage(problem);
}
