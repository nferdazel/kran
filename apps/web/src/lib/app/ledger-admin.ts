/**
 * Glue layar admin buku besar (T-116): validasi form periode/COA/pembalik dan pemetaan galat
 * domain. Logika murni (tanpa DOM, tanpa jaringan) supaya bisa diuji vitest.
 *
 * Catatan kontrak (per 23 Okt 2026):
 *  - Handler API (`handlers_ledger.nim`, `handlers_journals.nim`) mengirim 409 sebagai
 *    `i18nKey: "error_conflict"` **tanpa** `params.reason`; sebab sesungguhnya hanya ada di
 *    `detail` berbahasa Indonesia yang tidak boleh ditampilkan UI. Karena itu 409 dipetakan per
 *    aksi (satu sebab per aksi: tumpang tindih, sudah ditutup, kode duplikat, jurnal sudah
 *    dibalik), dan bila kelak server menambah `params.reason` tabel alasan dipakai lebih dulu.
 *  - Bentuk kode COA ditentukan parameter `ledger.coa.code_pattern` (tidak diketahui klien), jadi
 *    validasi klien hanya memeriksa wajib-isi dan batas kolom; kecocokan pola tetap otoritas server.
 *  - Batas panjang mengikuti kolom domain: kode 32, nama 2..200, alasan 500.
 *  - Jurnal immutable: layar ini hanya menyediakan pembalik, tidak ada edit/hapus.
 */
import type { Problem } from "@kran/api-client";
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";
import { problemMessage } from "#lib/app/errors.js";

export type Period = components["schemas"]["Period"];
export type CoaAccount = components["schemas"]["CoaAccount"];
export type JournalHeader = components["schemas"]["JournalHeader"];

export type CoaAccountType = components["schemas"]["CoaAccount"]["accountType"];

/** Batas kolom domain, bukan aturan bisnis (`modules/ledger/domain`). */
export const COA_CODE_MAX_LENGTH = 32;
export const COA_NAME_MIN_LENGTH = 2;
export const COA_NAME_MAX_LENGTH = 200;
export const REASON_MAX_LENGTH = 500;

export const ACCOUNT_TYPES: readonly CoaAccountType[] = [
  "ASSET",
  "LIABILITY",
  "EQUITY",
  "REVENUE",
  "EXPENSE",
];

/** Aksi tulis layar ini; dipakai memetakan 409 yang tidak membawa `params.reason`. */
export type LedgerAdminAction =
  | "open_period"
  | "close_period"
  | "create_coa"
  | "reverse_journal";

export interface FormError<Field extends string> {
  readonly field: Field;
  readonly message: string;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;

export function isUuid(value: string): boolean {
  return UUID_PATTERN.test(value.trim());
}

/** `YYYY-MM-DD` yang benar-benar ada (31 Feb ditolak), bukan sekadar berbentuk tanggal. */
export function isIsoDate(value: string): boolean {
  const match = ISO_DATE_PATTERN.exec(value.trim());
  if (match === null) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}

export type DateRange = { readonly startsOn: string; readonly endsOn: string };

/** Rentang inklusif — sama dengan semantik `startsOn`..`endsOn` di kontrak. */
export function rangesOverlap(a: DateRange, b: DateRange): boolean {
  return a.startsOn <= b.endsOn && b.startsOn <= a.endsOn;
}

/** Periode yang tumpang tindih dengan rentang usulan; `null` bila bebas. */
export function findOverlappingPeriod(
  range: DateRange,
  periods: readonly DateRange[],
): DateRange | null {
  return periods.find((period) => rangesOverlap(range, period)) ?? null;
}

/** Periode CLOSED tidak bisa ditutup lagi — aksinya dinonaktifkan, bukan disembunyikan. */
export function canClosePeriod(period: Pick<Period, "status">): boolean {
  return period.status === "OPEN";
}

function dateError(field: "startsOn" | "endsOn", message: string): FormError<"startsOn" | "endsOn"> {
  return { field, message };
}

export interface PeriodFormInput {
  readonly startsOn: string;
  readonly endsOn: string;
}

export type PeriodFormResult =
  | { readonly ok: true; readonly startsOn: string; readonly endsOn: string }
  | { readonly ok: false; readonly error: FormError<"startsOn" | "endsOn"> };

/**
 * Validasi form buka periode. Tumpang tindih diperiksa terhadap periode yang sudah dimuat supaya
 * pengguna melihat sebabnya sebelum POST; server tetap otoritas terakhir (409 `period_no_overlap`).
 */
export function validatePeriodForm(
  input: PeriodFormInput,
  periods: readonly DateRange[],
): PeriodFormResult {
  const startsOn = input.startsOn.trim();
  if (startsOn === "") {
    return { ok: false, error: dateError("startsOn", m.ledger_admin_error_starts_required()) };
  }
  if (!isIsoDate(startsOn)) {
    return { ok: false, error: dateError("startsOn", m.ledger_admin_error_date_invalid()) };
  }
  const endsOn = input.endsOn.trim();
  if (endsOn === "") {
    return { ok: false, error: dateError("endsOn", m.ledger_admin_error_ends_required()) };
  }
  if (!isIsoDate(endsOn)) {
    return { ok: false, error: dateError("endsOn", m.ledger_admin_error_date_invalid()) };
  }
  if (endsOn < startsOn) {
    return { ok: false, error: dateError("endsOn", m.ledger_admin_error_ends_before_starts()) };
  }
  if (findOverlappingPeriod({ startsOn, endsOn }, periods) !== null) {
    return { ok: false, error: dateError("startsOn", m.ledger_admin_error_period_overlap()) };
  }
  return { ok: true, startsOn, endsOn };
}

export interface CoaFormInput {
  readonly code: string;
  readonly name: string;
  /** Nilai mentah dari `<select>`; keanggotaan `ACCOUNT_TYPES` diperiksa di sini. */
  readonly accountType: string;
  readonly postable: boolean;
}

export type CoaField = "code" | "name" | "accountType";

export type CoaFormResult =
  | {
      readonly ok: true;
      readonly code: string;
      readonly name: string;
      readonly accountType: CoaAccountType;
      readonly postable: boolean;
    }
  | { readonly ok: false; readonly error: FormError<CoaField> };

export function validateCoaForm(input: CoaFormInput): CoaFormResult {
  const code = input.code.trim();
  if (code === "") {
    return { ok: false, error: { field: "code", message: m.ledger_admin_error_code_required() } };
  }
  if (code.length > COA_CODE_MAX_LENGTH) {
    return { ok: false, error: { field: "code", message: m.ledger_admin_error_code_too_long() } };
  }
  const name = input.name.trim().replace(/\s+/g, " ");
  if (name === "") {
    return { ok: false, error: { field: "name", message: m.ledger_admin_error_name_required() } };
  }
  if (name.length < COA_NAME_MIN_LENGTH) {
    return { ok: false, error: { field: "name", message: m.ledger_admin_error_name_too_short() } };
  }
  if (name.length > COA_NAME_MAX_LENGTH) {
    return { ok: false, error: { field: "name", message: m.ledger_admin_error_name_too_long() } };
  }
  const accountType = ACCOUNT_TYPES.find((type) => type === input.accountType);
  if (accountType === undefined) {
    return {
      ok: false,
      error: { field: "accountType", message: m.ledger_admin_error_type_required() },
    };
  }
  return { ok: true, code, name, accountType, postable: input.postable };
}

const ACCOUNT_TYPE_LABELS: Record<CoaAccountType, () => string> = {
  ASSET: () => m.ledger_admin_type_asset(),
  LIABILITY: () => m.ledger_admin_type_liability(),
  EQUITY: () => m.ledger_admin_type_equity(),
  REVENUE: () => m.ledger_admin_type_revenue(),
  EXPENSE: () => m.ledger_admin_type_expense(),
};

export function coaAccountTypeLabel(type: CoaAccountType): string {
  return ACCOUNT_TYPE_LABELS[type]();
}

export type ReasonFormResult =
  | { readonly ok: true; readonly reason: string }
  | { readonly ok: false; readonly error: FormError<"reason"> };

/** Alasan wajib (tutup periode & pembalik): masuk jejak audit, bukan hiasan. */
export function validateReason(raw: string): ReasonFormResult {
  const reason = raw.trim();
  if (reason === "") {
    return { ok: false, error: { field: "reason", message: m.ledger_admin_error_reason_required() } };
  }
  if (reason.length > REASON_MAX_LENGTH) {
    return { ok: false, error: { field: "reason", message: m.ledger_admin_error_reason_too_long() } };
  }
  return { ok: true, reason };
}

export interface ReverseFormInput {
  readonly journalId: string;
  readonly reason: string;
}

export type ReverseField = "journalId" | "reason";

export type ReverseFormResult =
  | { readonly ok: true; readonly journalId: string; readonly reason: string }
  | { readonly ok: false; readonly error: FormError<ReverseField> };

export function validateReverseForm(input: ReverseFormInput): ReverseFormResult {
  const journalId = input.journalId.trim();
  if (journalId === "") {
    return {
      ok: false,
      error: { field: "journalId", message: m.ledger_admin_error_journal_required() },
    };
  }
  if (!isUuid(journalId)) {
    return {
      ok: false,
      error: { field: "journalId", message: m.ledger_admin_error_journal_invalid() },
    };
  }
  const reason = validateReason(input.reason);
  if (!reason.ok) return reason;
  return { ok: true, journalId, reason: reason.reason };
}

/**
 * Alasan 409/403 tingkat domain → pesan katalog. Dipakai lebih dulu bila server menyertakan
 * `params.reason`; kalau tidak, sebab per aksi dipakai (lihat catatan kontrak di atas).
 */
const PROBLEM_REASON_MESSAGES: Record<string, () => string> = {
  branch_not_allowed: () => m.ledger_admin_error_branch_not_allowed(),
  period_no_overlap: () => m.ledger_admin_error_period_overlap(),
  period_closed: () => m.ledger_admin_error_period_closed(),
  coa_code_duplicate: () => m.ledger_admin_error_coa_duplicate(),
  journal_already_reversed: () => m.ledger_admin_error_journal_reversed(),
};

const ACTION_CONFLICT_MESSAGES: Record<LedgerAdminAction, () => string> = {
  open_period: () => m.ledger_admin_error_period_overlap(),
  close_period: () => m.ledger_admin_error_period_closed(),
  create_coa: () => m.ledger_admin_error_coa_duplicate(),
  reverse_journal: () => m.ledger_admin_error_conflict(),
};

export function ledgerAdminProblemMessage(problem: Problem, action: LedgerAdminAction): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : PROBLEM_REASON_MESSAGES[reason];
  if (template !== undefined) return template();
  if (problem.status === 409) return ACTION_CONFLICT_MESSAGES[action]();
  if (problem.status === 404) return m.ledger_admin_error_not_found();
  if (problem.status === 403) return m.ledger_admin_error_denied();
  return problemMessage(problem);
}
