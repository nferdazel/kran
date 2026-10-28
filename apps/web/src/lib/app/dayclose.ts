/**
 * Glue layar monitor penutupan buku (T-139c): klien endpoint day-close, label status, aturan
 * visibilitas aksi, dan pemetaan galat. Logika murni dipisah dari komponen supaya bisa diuji
 * vitest tanpa DOM.
 *
 * Kontrak yang dipegang:
 *  - `GET /dayclose/status` mengembalikan tanggal buku (`null` sebelum `ctl bootstrap`), run aktif,
 *    dan run terakhir. `activeRun` **termasuk** `PAUSED`: server menganggapnya belum berakhir.
 *  - Aksi penutupan berjalan sinkron di dalam permintaan (D-153). Batas waktu atau koneksi putus
 *    berarti "tidak tahu", bukan "belum terjadi": UI tidak pernah mengulang aksi otomatis.
 *  - Penolakan keadaan datang sebagai `409` dengan sebab mesin di `params.reason`; UI memetakan
 *    kode itu ke katalog, bukan menampilkan `detail` mentah server.
 *  - Kode galat task (`DAY-3xx`) ditampilkan apa adanya. Keterangannya disalin dari runbook
 *    `docs/runbooks/dayclose.md`; kode yang tidak dikenal tidak diberi arti karangan.
 */
import type { Problem } from "@kran/api-client";
import type { components } from "@kran/api-client/schema";

import * as m from "#lib/paraglide/messages.js";

import { api } from "#lib/app/api.js";
import { problemMessage } from "#lib/app/errors.js";

export type DayCloseStatus = components["schemas"]["DayCloseStatus"];
export type DayCloseBusinessDate = NonNullable<DayCloseStatus["businessDate"]>;
export type DayCloseRunSummary = components["schemas"]["DayCloseRunSummary"];
export type DayCloseRunDetail = components["schemas"]["DayCloseRunDetail"];
export type DayCloseTaskState = components["schemas"]["DayCloseTaskState"];
export type DayCloseChunkState = components["schemas"]["DayCloseChunkState"];

export type BusinessDateState = DayCloseBusinessDate["state"];
export type RunState = DayCloseRunSummary["state"];
export type TaskState = DayCloseTaskState["state"];
export type ChunkState = DayCloseChunkState["state"];
export type TaskKind = DayCloseTaskState["kind"];
export type DayCloseAction = "run" | "resume" | "pause" | "cancel";
export type StatusTone = "ok" | "warning" | "danger" | "info" | "neutral";

/** Pilihan batas riwayat; batas kontrak 1..100, default server 20. */
export const RUN_LIMITS = [20, 50, 100] as const;
export const DEFAULT_RUN_LIMIT = 20;
/** Jeda polling selagi run aktif (spec §11.7: 2–3 detik). */
export const POLL_INTERVAL_MS = 2500;

/** State yang masih bisa dilanjutkan (kontrak `resume`). */
export const RESUMABLE_RUN_STATES: readonly RunState[] = ["PAUSED", "FAILED", "BLOCKED"];
/** State yang masih dianggap berjalan oleh server (`activeRunFor`), termasuk `PAUSED`. */
const ACTIVE_RUN_STATES: readonly RunState[] = [
  "PLANNED",
  "PRECHECK",
  "RUNNING",
  "POSTCHECK",
  "PAUSED",
];
/** State yang masih bisa dihentikan di batas chunk (kontrak `pause`). */
const PAUSABLE_RUN_STATES: readonly RunState[] = ["PLANNED", "PRECHECK", "RUNNING", "POSTCHECK"];
/** Server hanya menolak `cancel` setelah run benar-benar berakhir. */
const FINISHED_RUN_STATES: readonly RunState[] = ["COMPLETED", "CANCELED"];

const BUSINESS_DATE_STATE_LABELS: Record<BusinessDateState, () => string> = {
  OPEN: () => m.dayclose_business_date_open(),
  CLOSING: () => m.dayclose_business_date_closing(),
  CLOSED: () => m.dayclose_business_date_closed(),
};

const RUN_STATE_LABELS: Record<RunState, () => string> = {
  PLANNED: () => m.dayclose_run_state_planned(),
  PRECHECK: () => m.dayclose_run_state_precheck(),
  RUNNING: () => m.dayclose_run_state_running(),
  POSTCHECK: () => m.dayclose_run_state_postcheck(),
  COMPLETED: () => m.dayclose_run_state_completed(),
  FAILED: () => m.dayclose_run_state_failed(),
  BLOCKED: () => m.dayclose_run_state_blocked(),
  PAUSED: () => m.dayclose_run_state_paused(),
  CANCELED: () => m.dayclose_run_state_canceled(),
};

const TASK_STATE_LABELS: Record<TaskState, () => string> = {
  PENDING: () => m.dayclose_task_state_pending(),
  READY: () => m.dayclose_task_state_ready(),
  RUNNING: () => m.dayclose_task_state_running(),
  SUCCEEDED: () => m.dayclose_task_state_succeeded(),
  FAILED: () => m.dayclose_task_state_failed(),
  SKIPPED: () => m.dayclose_task_state_skipped(),
  CANCELED: () => m.dayclose_task_state_canceled(),
};

const CHUNK_STATE_LABELS: Record<ChunkState, () => string> = {
  PENDING: () => m.dayclose_chunk_state_pending(),
  RUNNING: () => m.dayclose_chunk_state_running(),
  SUCCEEDED: () => m.dayclose_chunk_state_succeeded(),
  FAILED: () => m.dayclose_chunk_state_failed(),
};

const TASK_KIND_LABELS: Record<TaskKind, () => string> = {
  PRECHECK: () => m.dayclose_kind_precheck(),
  PROCESS: () => m.dayclose_kind_process(),
  POSTCHECK: () => m.dayclose_kind_postcheck(),
  REPORT: () => m.dayclose_kind_report(),
};

/**
 * Ikon status per state. Bentuk + teks + warna (DESIGN §8); ikon selalu `aria-hidden`, jadi
 * pembaca layar hanya mendengar labelnya.
 */
const BUSINESS_DATE_STATE_ICONS: Record<BusinessDateState, string> = {
  OPEN: "○",
  CLOSING: "◐",
  CLOSED: "✔",
};

const RUN_STATE_ICONS: Record<RunState, string> = {
  PLANNED: "○",
  PRECHECK: "◐",
  RUNNING: "◐",
  POSTCHECK: "◐",
  COMPLETED: "✔",
  FAILED: "✕",
  BLOCKED: "!",
  PAUSED: "‖",
  CANCELED: "–",
};

const TASK_STATE_ICONS: Record<TaskState, string> = {
  PENDING: "○",
  READY: "○",
  RUNNING: "◐",
  SUCCEEDED: "✔",
  FAILED: "✕",
  SKIPPED: "–",
  CANCELED: "–",
};

const CHUNK_STATE_ICONS: Record<ChunkState, string> = {
  PENDING: "○",
  RUNNING: "◐",
  SUCCEEDED: "✔",
  FAILED: "✕",
};

const BUSINESS_DATE_STATE_TONES: Record<BusinessDateState, StatusTone> = {
  OPEN: "ok",
  CLOSING: "warning",
  CLOSED: "neutral",
};

const RUN_STATE_TONES: Record<RunState, StatusTone> = {
  PLANNED: "neutral",
  PRECHECK: "info",
  RUNNING: "info",
  POSTCHECK: "info",
  COMPLETED: "ok",
  FAILED: "danger",
  BLOCKED: "danger",
  PAUSED: "warning",
  CANCELED: "neutral",
};

const TASK_STATE_TONES: Record<TaskState, StatusTone> = {
  PENDING: "neutral",
  READY: "neutral",
  RUNNING: "info",
  SUCCEEDED: "ok",
  FAILED: "danger",
  SKIPPED: "neutral",
  CANCELED: "neutral",
};

const CHUNK_STATE_TONES: Record<ChunkState, StatusTone> = {
  PENDING: "neutral",
  RUNNING: "info",
  SUCCEEDED: "ok",
  FAILED: "danger",
};

export function businessDateStateLabel(state: BusinessDateState): string {
  return BUSINESS_DATE_STATE_LABELS[state]();
}

export function businessDateStateIcon(state: BusinessDateState): string {
  return BUSINESS_DATE_STATE_ICONS[state];
}

export function businessDateStateTone(state: BusinessDateState): StatusTone {
  return BUSINESS_DATE_STATE_TONES[state];
}

export function runStateLabel(state: RunState): string {
  return RUN_STATE_LABELS[state]();
}

export function runStateIcon(state: RunState): string {
  return RUN_STATE_ICONS[state];
}

export function runStateTone(state: RunState): StatusTone {
  return RUN_STATE_TONES[state];
}

export function taskStateLabel(state: TaskState): string {
  return TASK_STATE_LABELS[state]();
}

export function taskStateIcon(state: TaskState): string {
  return TASK_STATE_ICONS[state];
}

export function taskStateTone(state: TaskState): StatusTone {
  return TASK_STATE_TONES[state];
}

export function chunkStateLabel(state: ChunkState): string {
  return CHUNK_STATE_LABELS[state]();
}

export function chunkStateIcon(state: ChunkState): string {
  return CHUNK_STATE_ICONS[state];
}

export function chunkStateTone(state: ChunkState): StatusTone {
  return CHUNK_STATE_TONES[state];
}

export function taskKindLabel(kind: TaskKind): string {
  return TASK_KIND_LABELS[kind]();
}

/** State yang belum berakhir. `PAUSED` termasuk: server masih menganggap run itu aktif. */
export function isActiveRunState(state: RunState): boolean {
  return ACTIVE_RUN_STATES.includes(state);
}

/** Polling hanya berguna selama ada run yang belum berakhir. */
export function shouldPoll(status: DayCloseStatus | null): boolean {
  if (status === null || status.activeRun === null) return false;
  return isActiveRunState(status.activeRun.state);
}

/**
 * Aksi yang masuk akal untuk satu run. Server tetap otoritas terakhir; ini hanya mencegah tombol
 * yang pasti ditolak (mis. `pause` pada run `PAUSED`, `resume` pada run `COMPLETED`).
 */
export function runActionsFor(run: DayCloseRunSummary | null, canManage: boolean): DayCloseAction[] {
  if (!canManage || run === null) return [];
  const actions: DayCloseAction[] = [];
  if (RESUMABLE_RUN_STATES.includes(run.state)) actions.push("resume");
  if (PAUSABLE_RUN_STATES.includes(run.state)) actions.push("pause");
  // `FAILED`/`BLOCKED` bukan state berjalan, tetapi masih bisa dibatalkan (tanggal dibuka kembali).
  if (!FINISHED_RUN_STATES.includes(run.state)) actions.push("cancel");
  return actions;
}

/**
 * Apakah tombol "Jalankan penutupan" relevan sekarang.
 *
 * Ditampilkan hanya bila tanggal buku ada dan `OPEN`, tidak ada run aktif (termasuk `PAUSED`),
 * dan tanggal itu belum punya run yang harus di-resume/dibatalkan. Tanggal tanpa baris buku
 * (`null`) sengaja **tidak** menampilkan tombol: bootstrap hanya lewat `ctl` di server.
 */
export function canStartRun(status: DayCloseStatus | null, canManage: boolean): boolean {
  if (!canManage || status === null) return false;
  if (status.businessDate === null || status.businessDate.state !== "OPEN") return false;
  if (status.activeRun !== null) return false;
  const latest = status.latestRun;
  if (latest === null) return true;
  // Run dari tanggal lama tidak menghalangi tanggal buku berjalan (buku sudah maju).
  if (latest.businessDate !== status.businessDate.date) return true;
  return latest.state === "CANCELED";
}

/** Segel bukti dipotong untuk tabel; nilainya utuh di panel detail. */
export function shortHash(hash: string | null): string {
  if (hash === null || hash === "") return "";
  return hash.length <= 12 ? hash : `${hash.slice(0, 12)}…`;
}

const ERROR_CODE_HINTS: Record<string, () => string> = {
  "DAY-301": () => m.dayclose_code_301(),
  "DAY-302": () => m.dayclose_code_302(),
  "DAY-303": () => m.dayclose_code_303(),
  "DAY-304": () => m.dayclose_code_304(),
  "DAY-305": () => m.dayclose_code_305(),
  "DAY-306": () => m.dayclose_code_306(),
  "DAY-307": () => m.dayclose_code_307(),
  "DAY-308": () => m.dayclose_code_308(),
  "DAY-309": () => m.dayclose_code_309(),
  "DAY-310": () => m.dayclose_code_310(),
  "DAY-311": () => m.dayclose_code_311(),
  "DAY-312": () => m.dayclose_code_312(),
  "DAY-320": () => m.dayclose_code_320(),
  "DAY-321": () => m.dayclose_code_321(),
  "DAY-322": () => m.dayclose_code_322(),
  "DAY-323": () => m.dayclose_code_323(),
  "DAY-324": () => m.dayclose_code_324(),
  "DAY-325": () => m.dayclose_code_325(),
  "DAY-326": () => m.dayclose_code_326(),
  "DAY-327": () => m.dayclose_code_327(),
  "DAY-328": () => m.dayclose_code_328(),
  "DAY-330": () => m.dayclose_code_330(),
  "DAY-331": () => m.dayclose_code_331(),
  "DAY-332": () => m.dayclose_code_332(),
  "DAY-333": () => m.dayclose_code_333(),
  "DAY-334": () => m.dayclose_code_334(),
  "DAY-335": () => m.dayclose_code_335(),
  "DAY-336": () => m.dayclose_code_336(),
  "DAY-337": () => m.dayclose_code_337(),
  "DAY-340": () => m.dayclose_code_340(),
  "DAY-341": () => m.dayclose_code_341(),
  "DAY-342": () => m.dayclose_code_342(),
  "DAY-343": () => m.dayclose_code_343(),
  "DAY-344": () => m.dayclose_code_344(),
  "DAY-345": () => m.dayclose_code_345(),
  "DAY-346": () => m.dayclose_code_346(),
  "DAY-347": () => m.dayclose_code_347(),
};

/** Keterangan singkat kode galat, hanya untuk kode yang tercatat di runbook. */
export function errorCodeHint(code: string | null): string {
  if (code === null) return "";
  const hint = ERROR_CODE_HINTS[code];
  return hint === undefined ? "" : hint();
}

const PROBLEM_REASON_MESSAGES: Record<string, () => string> = {
  run_exists: () => m.dayclose_error_run_exists(),
  not_working_day: () => m.dayclose_error_not_working_day(),
  business_date_mismatch: () => m.dayclose_error_business_date_mismatch(),
  bootstrap_required: () => m.dayclose_error_bootstrap_required(),
  bootstrap_not_allowed: () => m.dayclose_error_bootstrap_not_allowed(),
  business_date_closing: () => m.dayclose_error_business_date_closing(),
  business_date_closed: () => m.dayclose_error_business_date_closed(),
  scope_locked: () => m.dayclose_error_scope_locked(),
  not_running: () => m.dayclose_error_not_running(),
  already_finished: () => m.dayclose_error_already_finished(),
  already_canceled: () => m.dayclose_error_already_canceled(),
  run_not_found: () => m.dayclose_error_run_not_found(),
  invalid_business_date: () => m.dayclose_error_invalid_date(),
  business_date_required: () => m.dayclose_error_invalid_date(),
  branch_not_allowed: () => m.dayclose_error_denied(),
  dayclose_error: () => m.dayclose_error_unknown(),
};

/**
 * Pesan galat layar day-close. Urutan: `params.reason` (domain), lalu 404/403, terakhir amplop
 * biasa. Tidak ada teks server yang ditampilkan mentah.
 */
export function daycloseProblemMessage(problem: Problem): string {
  const reason = problem.params?.reason;
  const template = reason === undefined ? undefined : PROBLEM_REASON_MESSAGES[reason];
  if (template !== undefined) return template();
  if (problem.status === 404) return m.dayclose_error_run_not_found();
  if (problem.status === 403) return m.dayclose_error_denied();
  return problemMessage(problem);
}

export function loadDayCloseStatus() {
  return api.GET("/api/v1/dayclose/status");
}

export function loadDayCloseRuns(limit: number) {
  return api.GET("/api/v1/dayclose/runs", { params: { query: { limit } } });
}

export function loadDayCloseRun(runId: string) {
  return api.GET("/api/v1/dayclose/runs/{runId}", { params: { path: { runId } } });
}

export function startDayClose() {
  return api.POST("/api/v1/dayclose/run");
}

export function resumeDayClose(runId: string) {
  return api.POST("/api/v1/dayclose/runs/{runId}/resume", { params: { path: { runId } } });
}

export function pauseDayClose(runId: string) {
  return api.POST("/api/v1/dayclose/runs/{runId}/pause", { params: { path: { runId } } });
}

export function cancelDayClose(runId: string) {
  return api.POST("/api/v1/dayclose/runs/{runId}/cancel", { params: { path: { runId } } });
}
