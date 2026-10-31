/**
 * Glue layar vault kas (T-121): klien endpoint vault/top-up, validasi form, pemetaan galat, dan
 * kunci idempotensi. Logika murni dipisah dari komponen supaya bisa diuji vitest tanpa DOM.
 *
 * Kontrak (per 24 Okt 2026):
 *  - `GET /teller/vault?branchId=` → saldo; **404 `vault_not_configured`** bukan saldo nol.
 *  - `POST /teller/vault/topups` mewajibkan `Idempotency-Key` dan **wajib** `note` (K-4: format
 *    `[JENIS SUMBER] <jenis bukti> <no-ref> | <tujuan>`; UI hanya menyebutkan formatnya).
 *  - Approve/reject hanya untuk pemegang `teller.vault.approve`; pengaju tidak boleh menyetujui
 *    pengajuannya sendiri (409 `self_approval`).
 *  - Konflik domain datang sebagai `i18nKey: "error_conflict"` dengan sebab di `params.reason`,
 *    jadi pemetaan pesan memakai `reason` (pola `tellerProblemMessage`).
 */
import type { Problem } from "@kran/api-client";
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";
import { parseMoneyInput } from "@kran/ui/money";

import { api } from "#lib/app/api.js";
import { problemMessage } from "#lib/app/errors.js";

export type TellerVault = components["schemas"]["TellerVault"];
export type TopUpRecord = components["schemas"]["TellerVaultTopUpRecord"];
export type TopUpStatus = NonNullable<TopUpRecord["status"]>;

/** Batas kolom `note` di kontrak (200). Batas teknis, bukan aturan bisnis. */
export const NOTE_MAX_LENGTH = 200;
/** Batas kolom `sourceAccount` di kontrak (32). */
export const SOURCE_MAX_LENGTH = 32;

export const STATUSES: readonly TopUpStatus[] = ["PENDING", "APPROVED", "REJECTED"];

export type TopUpField = "amount" | "sourceAccount" | "note";

export interface TopUpFieldError {
  field: TopUpField;
  message: string;
}

export interface TopUpInput {
  amount: string;
  sourceAccount: string;
  note: string;
}

export function statusLabel(status: TopUpStatus): string {
  if (status === "PENDING") return m.vault_status_pending();
  if (status === "APPROVED") return m.vault_status_approved();
  return m.vault_status_rejected();
}

function amountErrorMessage(
  error: "empty" | "invalid_format" | "not_positive" | "too_precise",
): string {
  if (error === "empty") return m.teller_error_amount_empty();
  if (error === "too_precise") return m.teller_error_amount_precision();
  if (error === "not_positive") return m.teller_error_amount_zero();
  return m.teller_error_amount_format();
}

/**
 * Isian form → nilai siap kirim, atau galat pertama yang menunjuk field.
 *
 * `note` wajib dan tidak dipangkas isinya (spasi tengah bermakna); hanya ujungnya dibuang.
 * `sourceAccount` tidak diperiksa bentuknya di sini: server yang memutuskan akun mana yang sah
 * (ASSET, aktif, postable, bukan akun vault). Klien hanya menolak kosong/terlalu panjang, supaya
 * tidak menyalin aturan bisnis ke UI.
 */
export function validateTopUp(
  input: TopUpInput,
): { ok: true; value: { amount: string; sourceAccount: string; note: string } } | { ok: false; error: TopUpFieldError } {
  const parsed = parseMoneyInput(input.amount);
  if (!parsed.ok) {
    return { ok: false, error: { field: "amount", message: amountErrorMessage(parsed.error) } };
  }

  const sourceAccount = input.sourceAccount.trim();
  if (sourceAccount === "") {
    return {
      ok: false,
      error: { field: "sourceAccount", message: m.vault_error_source_required() },
    };
  }
  if (sourceAccount.length > SOURCE_MAX_LENGTH) {
    return {
      ok: false,
      error: { field: "sourceAccount", message: m.vault_error_source_too_long() },
    };
  }

  const note = input.note.trim();
  if (note === "") {
    return { ok: false, error: { field: "note", message: m.vault_error_note_required() } };
  }
  if (note.length > NOTE_MAX_LENGTH) {
    return { ok: false, error: { field: "note", message: m.vault_error_note_too_long() } };
  }

  return { ok: true, value: { amount: parsed.value, sourceAccount, note } };
}

/** Sidik isian pengajuan: kunci idempotensi dipakai ulang hanya untuk isian yang sama. */
export function topUpIdentity(input: { branchId: string; amount: string; sourceAccount: string; note: string }): string {
  return JSON.stringify(["vault-topup", input.branchId, input.amount, input.sourceAccount, input.note]);
}

export function newIdempotencyKey(): string {
  return crypto.randomUUID();
}

const PROBLEM_REASON_MESSAGES: Record<string, () => string> = {
  topup_exceeds_limit: () => m.vault_error_limit(),
  source_account_invalid: () => m.vault_error_source_invalid(),
  topup_request_conflict: () => m.vault_error_conflict(),
  topup_request_not_pending: () => m.vault_error_not_pending(),
  self_approval: () => m.vault_error_self_approval(),
  topup_request_not_found: () => m.vault_error_not_found(),
  vault_not_configured: () => m.vault_error_vault_missing(),
  branch_not_allowed: () => m.vault_error_branch(),
};

/**
 * Pesan galat layar vault. Urutan: `params.reason` (domain), lalu 404/403, terakhir amplop biasa.
 * Tidak ada angka yang dikarang: limit dan saldo tidak ikut di pesan.
 */
export function vaultProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : PROBLEM_REASON_MESSAGES[reason];
  if (template !== undefined) return template();
  if (problem.status === 404) return m.vault_error_not_found();
  if (problem.status === 403) return m.vault_error_branch();
  return problemMessage(problem);
}


export function loadVault(branchId: string) {
  return api.GET("/api/v1/teller/vault", { params: { query: { branchId } } });
}

export function loadTopUps(branchId: string, status?: TopUpStatus) {
  return api.GET("/api/v1/teller/vault/topups", {
    params: { query: status === undefined ? { branchId } : { branchId, status } },
  });
}

export function submitTopUp(
  body: { branchId: string; amount: string; sourceAccount: string; note: string },
  idempotencyKey: string,
) {
  return api.POST("/api/v1/teller/vault/topups", {
    params: { header: { "Idempotency-Key": idempotencyKey } },
    body,
  });
}

export function approveTopUp(requestId: string, idempotencyKey: string) {
  return api.POST("/api/v1/teller/vault/topups/{requestId}/approve", {
    params: { path: { requestId }, header: { "Idempotency-Key": idempotencyKey } },
  });
}

export function rejectTopUp(requestId: string, reason: string) {
  return api.POST("/api/v1/teller/vault/topups/{requestId}/reject", {
    params: { path: { requestId } },
    body: { reason },
  });
}
