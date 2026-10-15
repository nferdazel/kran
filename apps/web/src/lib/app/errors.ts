/**
 * Terjemahan amplop error RFC 9457 (spec §13/§16): UI memakai `problem.i18nKey`, bukan
 * `title`/`detail` mentah. Pesan yang belum dikenali jatuh ke `error_generic`.
 */
import type { Problem } from "@kran/api-client";

import * as m from "#lib/paraglide/messages.js";

/**
 * Peta `i18nKey` server → pesan katalog. Nilainya berupa thunk supaya tiap pemanggilan membaca
 * bahasa aktif (fungsi Paraglide bukan store).
 */
const PROBLEM_MESSAGES: Record<string, () => string> = {
  error_bad_request: () => m.error_bad_request(),
  error_conflict: () => m.error_conflict(),
  error_forbidden: () => m.error_forbidden(),
  error_internal_error: () => m.error_internal_error(),
  error_method_not_allowed: () => m.error_method_not_allowed(),
  error_not_found: () => m.error_not_found(),
  error_not_implemented: () => m.error_not_implemented(),
  error_unauthorized: () => m.error_unauthorized(),
  error_upgrade_required: () => m.error_upgrade_required(),
};

export function problemMessage(problem: Problem): string {
  const template = PROBLEM_MESSAGES[problem.i18nKey];
  return template ? template() : m.error_generic();
}

/**
 * Pesan untuk alur ganti kata sandi (T-027).
 *
 * `problemMessage` memetakan menurut `i18nKey` (jenis masalah), tetapi di sini dua sebab berbeda
 * sama-sama datang sebagai 400/403 — kata sandi lama tidak cocok dan kata sandi baru melanggar
 * kebijakan — dan server membedakannya lewat `params.reason`. Tanpa pemetaan ini, pengguna hanya
 * melihat "permintaan tidak sah" tanpa tahu bagian mana yang harus diperbaiki.
 */
export function passwordProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  if (reason === "old_password_mismatch") return m.password_error_old();
  if (reason === "password_policy") return m.password_error_policy();
  return problemMessage(problem);
}
