/**
 * Test unit web untuk T-139c (tanpa DOM, tanpa jaringan): visibilitas aksi dari state run,
 * aturan tombol "Jalankan penutupan", polling, label status, dan pemetaan `params.reason`.
 */
import type { Problem } from "@kran/api-client";
import { describe, expect, it } from "vitest";

import * as m from "#lib/paraglide/messages.js";
import {
  canStartRun,
  daycloseProblemMessage,
  errorCodeHint,
  isActiveRunState,
  runActionsFor,
  runStateLabel,
  shortHash,
  shouldPoll,
  taskKindLabel,
  taskStateLabel,
  type DayCloseRunSummary,
  type DayCloseStatus,
  type RunState,
} from "#lib/app/dayclose.js";

const RUN_ID = "11111111-1111-7111-8111-111111111111";

function summary(overrides: Partial<DayCloseRunSummary> = {}): DayCloseRunSummary {
  return {
    runId: RUN_ID,
    businessDate: "2026-10-28",
    scopeType: "INSTITUTION",
    levels: ["EOD"],
    state: "RUNNING",
    startedAt: "2026-10-28T09:00:00Z",
    finishedAt: null,
    summaryHash: null,
    taskCounts: { ok: 0, failed: 0, skipped: 0, total: 0 },
    ...overrides,
  };
}

function status(
  businessDate: DayCloseStatus["businessDate"],
  activeRun: DayCloseRunSummary | null = null,
  latestRun: DayCloseRunSummary | null = null,
): DayCloseStatus {
  return { businessDate, activeRun, latestRun };
}

function openDate(date = "2026-10-28"): NonNullable<DayCloseStatus["businessDate"]> {
  return { date, state: "OPEN", frozenAt: null };
}

function problem(statusCode: number, reason?: string, i18nKey = "error_conflict"): Problem {
  return {
    type: "about:blank",
    title: "problem",
    status: statusCode,
    code: "problem",
    i18nKey,
    traceId: "trace-1",
    ...(reason === undefined ? {} : { params: { reason } }),
  };
}

describe("runActionsFor", () => {
  it("menyembunyikan semua aksi tanpa izin kelola", () => {
    expect(runActionsFor(summary(), false)).toEqual([]);
    expect(runActionsFor(summary({ state: "PAUSED" }), false)).toEqual([]);
  });

  it("menampilkan pause + cancel selama run berjalan", () => {
    for (const state of ["PLANNED", "PRECHECK", "RUNNING", "POSTCHECK"] as const) {
      expect(runActionsFor(summary({ state }), true)).toEqual(["pause", "cancel"]);
    }
  });

  it("menampilkan resume + cancel pada run yang bisa dilanjutkan", () => {
    for (const state of ["PAUSED", "FAILED", "BLOCKED"] as const) {
      expect(runActionsFor(summary({ state }), true)).toEqual(["resume", "cancel"]);
    }
  });

  it("tidak menawarkan aksi pada run yang sudah berakhir", () => {
    for (const state of ["COMPLETED", "CANCELED"] as const) {
      expect(runActionsFor(summary({ state }), true)).toEqual([]);
    }
    expect(runActionsFor(null, true)).toEqual([]);
  });
});

describe("canStartRun", () => {
  it("butuh izin kelola dan tanggal buku yang ada", () => {
    expect(canStartRun(status(openDate()), false)).toBe(false);
    expect(canStartRun(null, true)).toBe(false);
    expect(canStartRun(status(null), true)).toBe(false);
  });

  it("relevan hanya saat tanggal buku OPEN tanpa run aktif", () => {
    expect(canStartRun(status(openDate()), true)).toBe(true);
    expect(canStartRun(status({ ...openDate(), state: "CLOSING" }), true)).toBe(false);
    expect(canStartRun(status({ ...openDate(), state: "CLOSED" }), true)).toBe(false);
    expect(
      canStartRun(status(openDate(), summary({ state: "PAUSED" })), true),
    ).toBe(false);
  });

  it("menolak run baru bila tanggal itu masih punya run yang harus diselesaikan", () => {
    expect(canStartRun(status(openDate(), null, summary({ state: "FAILED" })), true)).toBe(false);
    expect(
      canStartRun(status(openDate(), null, summary({ state: "COMPLETED" })), true),
    ).toBe(false);
  });

  it("mengizinkan run baru setelah run tanggal itu dibatalkan", () => {
    expect(canStartRun(status(openDate(), null, summary({ state: "CANCELED" })), true)).toBe(true);
  });

  it("run terakhir dari tanggal lama tidak menghalangi tanggal buku berjalan", () => {
    const od = openDate("2026-10-29");
    const latest = summary({ businessDate: "2026-10-28", state: "COMPLETED" });
    expect(canStartRun(status(od, null, latest), true)).toBe(true);
  });
});

describe("isActiveRunState / shouldPoll", () => {
  it("PAUSED masih dihitung aktif, state berakhir tidak", () => {
    const active: RunState[] = ["PLANNED", "PRECHECK", "RUNNING", "POSTCHECK", "PAUSED"];
    const finished: RunState[] = ["COMPLETED", "FAILED", "BLOCKED", "CANCELED"];
    for (const state of active) expect(isActiveRunState(state)).toBe(true);
    for (const state of finished) expect(isActiveRunState(state)).toBe(false);
  });

  it("polling mengikuti run aktif dan berhenti saat tidak ada", () => {
    expect(shouldPoll(null)).toBe(false);
    expect(shouldPoll(status(openDate(), null))).toBe(false);
    expect(shouldPoll(status(openDate(), summary({ state: "RUNNING" })))).toBe(true);
    expect(shouldPoll(status(openDate(), summary({ state: "PAUSED" })))).toBe(true);
  });
});

describe("label status", () => {
  it("menerjemahkan seluruh state run tanpa duplikat", () => {
    const states: RunState[] = [
      "PLANNED",
      "PRECHECK",
      "RUNNING",
      "POSTCHECK",
      "COMPLETED",
      "FAILED",
      "BLOCKED",
      "PAUSED",
      "CANCELED",
    ];
    const labels = states.map((state) => runStateLabel(state));
    for (const label of labels) expect(label.length).toBeGreaterThan(0);
    expect(new Set(labels).size).toBe(states.length);
    expect(runStateLabel("COMPLETED")).toBe(m.dayclose_run_state_completed());
  });

  it("menerjemahkan state task dan jenis task", () => {
    expect(taskStateLabel("FAILED")).toBe(m.dayclose_task_state_failed());
    expect(taskKindLabel("POSTCHECK")).toBe(m.dayclose_kind_postcheck());
    expect(taskKindLabel("REPORT")).toBe(m.dayclose_kind_report());
  });
});

describe("shortHash", () => {
  it("memotong segel panjang dan membiarkan yang pendek", () => {
    expect(shortHash(null)).toBe("");
    expect(shortHash("abc")).toBe("abc");
    expect(shortHash("123456789012")).toBe("123456789012");
    expect(shortHash("1234567890123")).toBe("123456789012…");
  });
});

describe("errorCodeHint", () => {
  it("memberi keterangan hanya untuk kode yang tercatat di runbook", () => {
    expect(errorCodeHint("DAY-301")).toBe(m.dayclose_code_301());
    expect(errorCodeHint("DAY-324")).toBe(m.dayclose_code_324());
    expect(errorCodeHint("DAY-999")).toBe("");
    expect(errorCodeHint(null)).toBe("");
  });
});

describe("daycloseProblemMessage", () => {
  it("memakai reason domain lebih dulu", () => {
    const cases: ReadonlyArray<readonly [string, string]> = [
      ["run_exists", m.dayclose_error_run_exists()],
      ["not_working_day", m.dayclose_error_not_working_day()],
      ["business_date_mismatch", m.dayclose_error_business_date_mismatch()],
      ["bootstrap_required", m.dayclose_error_bootstrap_required()],
      ["bootstrap_not_allowed", m.dayclose_error_bootstrap_not_allowed()],
      ["business_date_closing", m.dayclose_error_business_date_closing()],
      ["business_date_closed", m.dayclose_error_business_date_closed()],
      ["scope_locked", m.dayclose_error_scope_locked()],
      ["not_running", m.dayclose_error_not_running()],
      ["already_finished", m.dayclose_error_already_finished()],
      ["already_canceled", m.dayclose_error_already_canceled()],
      ["run_not_found", m.dayclose_error_run_not_found()],
      ["invalid_business_date", m.dayclose_error_invalid_date()],
      ["branch_not_allowed", m.dayclose_error_denied()],
      ["dayclose_error", m.dayclose_error_unknown()],
    ];
    for (const [reason, expected] of cases) {
      expect(daycloseProblemMessage(problem(409, reason))).toBe(expected);
    }
  });

  it("jatuh ke status lalu amplop problem", () => {
    expect(daycloseProblemMessage(problem(404, undefined, "error_not_found"))).toBe(
      m.dayclose_error_run_not_found(),
    );
    expect(daycloseProblemMessage(problem(403, undefined, "error_forbidden"))).toBe(
      m.dayclose_error_denied(),
    );
    expect(daycloseProblemMessage(problem(500, undefined, "error_internal_error"))).toBe(
      m.error_internal_error(),
    );
  });
});
