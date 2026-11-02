/**
 * Glue layar pinjaman (T-170): label status/golongan dan pemetaan kegagalan domain.
 *
 * Logika murni (tanpa DOM, tanpa jaringan) supaya bisa diuji vitest. Yang **tidak** ada di sini:
 * aritmetika uang. Sisa kewajiban datang dari server (`principalOutstanding`), bukan dihitung ulang
 * di peramban dengan `number` — uang tidak boleh melewati float (AGENTS.md §1.3).
 */

import type { Problem } from "@kran/api-client";

import * as m from "#lib/paraglide/messages.js";
import { problemMessage } from "#lib/app/errors.js";
import type { LoanStatus } from "#lib/app/types.js";

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

const REASON_MESSAGES: Record<string, () => string> = {
  loan_not_found: () => m.loans_detail_not_found(),
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
