<script lang="ts">
  /**
   * Monitor penutupan buku (T-139c): status tanggal buku, run aktif, riwayat, detail task, dan aksi
   * operator. Bagian dari Fase 3 (spec §11.7, §16.2).
   *
   * Keputusan yang mengikat:
   *  - Server otoritas terakhir. Layar hanya menyembunyikan aksi yang pasti ditolak (mis. `resume`
   *    pada run `COMPLETED`), lalu memetakan `params.reason` ke pesan katalog.
   *  - Aksi sinkron (D-153): selama permintaan berjalan, semua tombol dinonaktifkan dan status
   *    "sedang diproses" diumumkan. Koneksi putus berarti "tidak tahu", bukan "belum terjadi":
   *    aksi tidak pernah diulang otomatis, dan pengguna diminta memuat ulang.
   *  - Polling hanya selama ada run yang belum berakhir. `setTimeout` berantai dibersihkan saat
   *    komponen ditinggalkan; tidak ada `setInterval` yang bisa tertinggal.
   *  - Status selalu teks + ikon + warna (DESIGN §8), jadi tetap terbaca tanpa membedakan warna.
   *  - Konfirmasi hanya untuk aksi yang mengubah tanggal buku (`run`, `cancel`). Dialog memakai
   *    elemen native + focus trap eksplisit, seperti command palette.
   */
  import { onMount, tick } from "svelte";

  import * as m from "#lib/paraglide/messages.js";
  import {
    DEFAULT_RUN_LIMIT,
    POLL_INTERVAL_MS,
    RUN_LIMITS,
    businessDateStateIcon,
    businessDateStateLabel,
    businessDateStateTone,
    canStartRun,
    cancelDayClose,
    chunkStateIcon,
    chunkStateLabel,
    chunkStateTone,
    daycloseProblemMessage,
    errorCodeHint,
    loadDayCloseRun,
    loadDayCloseRuns,
    loadDayCloseStatus,
    pauseDayClose,
    resumeDayClose,
    runActionsFor,
    runStateIcon,
    runStateLabel,
    runStateTone,
    shortHash,
    shouldPoll,
    startDayClose,
    taskKindLabel,
    taskStateIcon,
    taskStateLabel,
    taskStateTone,
    type DayCloseAction,
    type DayCloseRunDetail,
    type DayCloseRunSummary,
    type DayCloseStatus,
    type StatusTone,
  } from "#lib/app/dayclose.js";
  import { formatDate, formatDateTime } from "#lib/app/format.js";
  import type { SessionInfo } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  const session: SessionInfo = $derived(data.session);
  const canRead = $derived(session.permissions.includes("dayclose.run.read"));
  const canManage = $derived(session.permissions.includes("dayclose.run.manage"));

  let status = $state<DayCloseStatus | null>(null);
  let runs = $state<DayCloseRunSummary[]>([]);
  let detail = $state<DayCloseRunDetail | null>(null);
  let limit = $state(DEFAULT_RUN_LIMIT);
  let selectedRunId = $state("");

  let loading = $state(true);
  let loadingRuns = $state(false);
  let loadingDetail = $state(false);
  let loadError = $state("");
  let detailError = $state("");
  let actionError = $state("");
  let notice = $state("");
  let busyAction = $state<DayCloseAction | "">("");

  let confirmKind = $state<"run" | "cancel" | null>(null);
  let confirmRunId = $state("");
  let confirmDate = $state("");
  /** Elemen pemegang fokus sebelum dialog dibuka; dikembalikan saat dialog ditutup. */
  let restoreFocusTo: HTMLElement | null = null;

  let pollTimer: ReturnType<typeof setTimeout> | null = null;
  let destroyed = false;

  function targetRunId(): string {
    if (selectedRunId !== "") return selectedRunId;
    return status?.activeRun?.runId ?? status?.latestRun?.runId ?? "";
  }

  const effectiveRunId = $derived(targetRunId());

  const currentRun = $derived.by((): DayCloseRunSummary | null => {
    if (status === null) return null;
    if (detail !== null && detail.runId === effectiveRunId) return detail;
    if (status.activeRun !== null && status.activeRun.runId === effectiveRunId) return status.activeRun;
    if (status.latestRun !== null && status.latestRun.runId === effectiveRunId) return status.latestRun;
    return runs.find((run) => run.runId === effectiveRunId) ?? null;
  });

  const actions = $derived(runActionsFor(currentRun, canManage));
  const showRunButton = $derived(canStartRun(status, canManage));

  interface ActionButton {
    action: DayCloseAction;
    label: string;
    primary: boolean;
  }

  const actionButtons = $derived.by((): ActionButton[] =>
    actions.map((action) => ({
      action,
      label: actionLabel(action),
      primary: action === "resume",
    })),
  );

  function actionLabel(action: DayCloseAction): string {
    if (action === "run") return m.dayclose_action_run();
    if (action === "resume") return m.dayclose_action_resume();
    if (action === "pause") return m.dayclose_action_pause();
    return m.dayclose_action_cancel();
  }

  function stopPolling(): void {
    if (pollTimer !== null) {
      clearTimeout(pollTimer);
      pollTimer = null;
    }
  }

  function schedulePoll(): void {
    stopPolling();
    if (destroyed || !canRead || busyAction !== "") return;
    if (!shouldPoll(status)) return;
    pollTimer = setTimeout(() => {
      pollTimer = null;
      void pollTick();
    }, POLL_INTERVAL_MS);
  }

  async function loadStatus(): Promise<boolean> {
    try {
      const { data: payload, error } = await loadDayCloseStatus();
      if (destroyed) return false;
      if (error) {
        if (loadError === "") loadError = daycloseProblemMessage(error);
        return false;
      }
      status = payload ?? null;
      return true;
    } catch {
      if (!destroyed && loadError === "") loadError = m.error_generic();
      return false;
    }
  }

  async function loadRuns(quiet = false): Promise<void> {
    if (!quiet) loadingRuns = true;
    try {
      const { data: payload, error } = await loadDayCloseRuns(limit);
      if (destroyed) return;
      if (error) {
        if (!quiet && loadError === "") loadError = daycloseProblemMessage(error);
        return;
      }
      runs = payload?.runs ?? [];
    } catch {
      if (!destroyed && !quiet && loadError === "") loadError = m.error_generic();
    } finally {
      if (!quiet) loadingRuns = false;
    }
  }

  async function loadDetail(runId: string, quiet = false): Promise<void> {
    if (runId === "") {
      detail = null;
      return;
    }
    if (!quiet) {
      loadingDetail = true;
      detailError = "";
    }
    try {
      const { data: payload, error } = await loadDayCloseRun(runId);
      if (destroyed) return;
      if (error) {
        if (!quiet) {
          detail = null;
          detailError = daycloseProblemMessage(error);
        }
        return;
      }
      detail = payload ?? null;
      if (!quiet) detailError = "";
    } catch {
      if (!destroyed && !quiet) {
        detail = null;
        detailError = m.error_generic();
      }
    } finally {
      if (!quiet) loadingDetail = false;
    }
  }

  async function loadAll(): Promise<void> {
    if (!canRead) {
      loading = false;
      return;
    }
    stopPolling();
    loading = true;
    loadError = "";
    detailError = "";
    try {
      await loadStatus();
      await Promise.all([loadRuns(), loadDetail(targetRunId())]);
    } finally {
      if (!destroyed) {
        loading = false;
        schedulePoll();
      }
    }
  }

  /** Muat ulang setelah aksi: status dulu, karena run yang baru selesai mengubah tanggal buku. */
  async function refreshAfterAction(): Promise<void> {
    loadError = "";
    await loadStatus();
    await Promise.all([loadRuns(true), loadDetail(targetRunId(), true)]);
    schedulePoll();
  }

  async function pollTick(): Promise<void> {
    if (destroyed) return;
    const before = status?.activeRun ?? null;
    try {
      const { data: payload, error } = await loadDayCloseStatus();
      if (destroyed) return;
      if (error) return;
      status = payload ?? null;
      const target = selectedRunId !== "" ? selectedRunId : (status?.activeRun?.runId ?? "");
      if (target !== "") await loadDetail(target, true);
      const after = status?.activeRun ?? null;
      const changed =
        (after?.runId ?? "") !== (before?.runId ?? "") || (after?.state ?? "") !== (before?.state ?? "");
      if (changed || after === null) await loadRuns(true);
    } catch {
      // Jaringan putus: biarkan status terakhir tampil dan coba lagi di tick berikutnya.
    } finally {
      schedulePoll();
    }
  }

  async function performAction(action: DayCloseAction, runId: string): Promise<void> {
    if (busyAction !== "") return;
    busyAction = action;
    actionError = "";
    notice = "";
    stopPolling();
    try {
      const result =
        action === "run"
          ? await startDayClose()
          : action === "resume"
            ? await resumeDayClose(runId)
            : action === "pause"
              ? await pauseDayClose(runId)
              : await cancelDayClose(runId);
      if (!result.response.ok || result.data === undefined) {
        actionError =
          result.error === undefined ? m.error_generic() : daycloseProblemMessage(result.error);
        return;
      }
      const state = result.data.state;
      if (action === "run") {
        notice =
          state === "COMPLETED"
            ? m.dayclose_notice_run_completed()
            : m.dayclose_notice_run_stopped({ state: runStateLabel(state) });
      } else if (action === "resume") {
        notice =
          state === "COMPLETED"
            ? m.dayclose_notice_resume_completed()
            : m.dayclose_notice_run_stopped({ state: runStateLabel(state) });
      } else if (action === "pause") {
        notice = m.dayclose_notice_pause();
      } else {
        notice = m.dayclose_notice_cancel();
      }
      selectedRunId = result.data.runId;
    } catch {
      // Batas waktu atau jaringan putus: hasilnya tidak diketahui, dan aksi TIDAK diulang.
      actionError = m.dayclose_action_unknown();
    } finally {
      busyAction = "";
      await refreshAfterAction();
    }
  }

  function selectRun(runId: string): void {
    if (selectedRunId === runId) return;
    selectedRunId = runId;
    void loadDetail(runId);
  }

  async function onLimitChange(): Promise<void> {
    loadError = "";
    await loadRuns();
  }

  function confirmDialog(): HTMLDialogElement | null {
    return document.getElementById("dayclose-confirm") as HTMLDialogElement | null;
  }

  async function openConfirm(kind: "run" | "cancel", runId = ""): Promise<void> {
    if (busyAction !== "" || status === null) return;
    restoreFocusTo = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    confirmKind = kind;
    confirmRunId = runId;
    if (kind === "run") {
      confirmDate = status.businessDate === null ? "" : formatDate(status.businessDate.date);
    } else {
      confirmDate = currentRun === null ? "" : formatDate(currentRun.businessDate);
    }
    await tick();
    const dialog = confirmDialog();
    if (dialog !== null && !dialog.open) dialog.showModal();
    document.getElementById("dayclose-confirm-dismiss")?.focus();
  }

  function closeConfirm(): void {
    confirmDialog()?.close();
  }

  /** `close` datang dari Esc, tombol, atau `closeConfirm()`: satu jalur pemulihan fokus. */
  function onDialogClose(): void {
    confirmKind = null;
    confirmRunId = "";
    confirmDate = "";
    const target = restoreFocusTo;
    restoreFocusTo = null;
    // Pemicu bisa sudah nonaktif karena aksinya sedang berjalan; fokus yang hilang ke `body`
    // membuat pengguna keyboard kehilangan tempat. Jatuh ke landmark utama.
    if (
      target !== null &&
      target.isConnected &&
      !(target instanceof HTMLButtonElement && target.disabled)
    ) {
      target.focus();
      return;
    }
    const fallback = document.getElementById("main");
    if (fallback !== null) fallback.focus();
  }

  function trapTab(event: KeyboardEvent): void {
    const dialog = confirmDialog();
    if (dialog === null) return;
    const focusables = [...dialog.querySelectorAll<HTMLElement>("button:not([disabled])")];
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (first === undefined || last === undefined) return;
    const active = document.activeElement;
    if (event.shiftKey) {
      const inside = active instanceof Node && dialog.contains(active);
      if (!inside || active === first) {
        event.preventDefault();
        last.focus();
      }
      return;
    }
    if (active === last) {
      event.preventDefault();
      first.focus();
    }
  }

  function onDialogKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      event.preventDefault();
      closeConfirm();
      return;
    }
    if (event.key === "Tab") trapTab(event);
  }

  async function confirmNow(): Promise<void> {
    const kind = confirmKind;
    const runId = confirmRunId;
    if (kind === null) return;
    closeConfirm();
    await performAction(kind === "run" ? "run" : "cancel", runId);
  }

  onMount(() => {
    if (!canRead) {
      loading = false;
      return;
    }
    void loadAll();
    return () => {
      destroyed = true;
      stopPolling();
    };
  });
</script>

{#snippet stateBadge(tone: StatusTone, icon: string, label: string)}
  <span
    class="kran-badge"
    class:kran-badge--ok={tone === "ok"}
    class:kran-badge--warning={tone === "warning"}
    class:kran-badge--danger={tone === "danger"}
    class:kran-badge--info={tone === "info"}
  >
    <span aria-hidden="true">{icon}</span>
    {label}
  </span>
{/snippet}

<svelte:head>
  <title>{m.common_app_title()} · {m.dayclose_title()}</title>
</svelte:head>

<div class="dayclose-head">
  <div>
    <h1 class="dayclose-title">{m.dayclose_title()}</h1>
    <p class="dayclose-intro">{m.dayclose_intro()}</p>
  </div>
  <button
    class="kran-button"
    type="button"
    onclick={() => void loadAll()}
    disabled={loading || busyAction !== "" || !canRead}
  >
    {m.dayclose_reload()}
  </button>
</div>

{#if !canRead}
  <p class="kran-alert" role="alert">{m.dayclose_denied()}</p>
{:else if loading}
  <p role="status">{m.dayclose_loading()}</p>
{:else}
  {#if loadError}
    <p class="kran-alert" role="alert">{loadError}</p>
    <p>
      <button class="kran-button" type="button" onclick={() => void loadAll()}>
        {m.app_retry()}
      </button>
    </p>
  {/if}
  {#if actionError}
    <p class="kran-alert" role="alert">{actionError}</p>
  {/if}
  {#if notice}
    <p class="dayclose-notice" role="status">{notice}</p>
  {/if}

  {#if status === null}
    {#if !loadError}
      <p class="kran-alert" role="alert">{m.error_generic()}</p>
      <p>
        <button class="kran-button" type="button" onclick={() => void loadAll()}>
          {m.app_retry()}
        </button>
      </p>
    {/if}
  {:else}
    <section class="kran-card" aria-labelledby="dayclose-status-heading">
      <div class="dayclose-section-head">
        <h2 id="dayclose-status-heading">{m.dayclose_status_heading()}</h2>
        {#if showRunButton}
          <button
            class="kran-button kran-button--primary"
            type="button"
            onclick={() => void openConfirm("run")}
            disabled={busyAction !== ""}
          >
            {busyAction === "run" ? m.dayclose_action_running_label() : m.dayclose_action_run()}
          </button>
        {/if}
      </div>

      {#if busyAction !== ""}
        <p class="dayclose-running" role="status">{m.dayclose_action_running()}</p>
      {/if}

      <dl class="dayclose-facts">
        <dt>{m.dayclose_business_date_label()}</dt>
        <dd>
          {#if status.businessDate === null}
            <span class="dayclose-muted">{m.dayclose_business_date_missing()}</span>
          {:else}
            <span>{formatDate(status.businessDate.date)}</span>
          {/if}
        </dd>

        <dt>{m.dayclose_col_state()}</dt>
        <dd>
          {#if status.businessDate === null}
            <span class="kran-muted">—</span>
          {:else}
            {@render stateBadge(
              businessDateStateTone(status.businessDate.state),
              businessDateStateIcon(status.businessDate.state),
              businessDateStateLabel(status.businessDate.state),
            )}
          {/if}
        </dd>

        <dt>{m.dayclose_frozen_at_label()}</dt>
        <dd>
          {#if status.businessDate?.frozenAt}
            {formatDateTime(status.businessDate.frozenAt)}
          {:else}
            <span class="kran-muted">—</span>
          {/if}
        </dd>

        <dt>{m.dayclose_active_run_label()}</dt>
        <dd>
          {#if status.activeRun === null}
            <span class="kran-muted">{m.dayclose_no_active_run()}</span>
          {:else}
            <span class="dayclose-run-line">
              <span>{formatDate(status.activeRun.businessDate)}</span>
              <span aria-hidden="true">·</span>
              {@render stateBadge(
                runStateTone(status.activeRun.state),
                runStateIcon(status.activeRun.state),
                runStateLabel(status.activeRun.state),
              )}
              <span aria-hidden="true">·</span>
              <span class="dayclose-sub"
                >{m.dayclose_col_started()}: {formatDateTime(status.activeRun.startedAt)}</span
              >
            </span>
          {/if}
        </dd>

        <dt>{m.dayclose_latest_run_label()}</dt>
        <dd>
          {#if status.latestRun === null}
            <span class="kran-muted">{m.dayclose_no_latest_run()}</span>
          {:else}
            <span class="dayclose-run-line">
              <span>{formatDate(status.latestRun.businessDate)}</span>
              <span aria-hidden="true">·</span>
              {@render stateBadge(
                runStateTone(status.latestRun.state),
                runStateIcon(status.latestRun.state),
                runStateLabel(status.latestRun.state),
              )}
              <span aria-hidden="true">·</span>
              <span class="dayclose-sub"
                >{m.dayclose_col_started()}: {formatDateTime(status.latestRun.startedAt)}</span
              >
            </span>
          {/if}
        </dd>
      </dl>
    </section>

    <section class="kran-card" aria-labelledby="dayclose-history-heading">
      <div class="dayclose-section-head">
        <div>
          <h2 id="dayclose-history-heading">{m.dayclose_history_heading()}</h2>
          <p class="dayclose-sub">{m.dayclose_history_intro()}</p>
        </div>
        <div class="dayclose-limit">
          <label class="kran-label" for="dayclose-limit">{m.dayclose_limit_label()}</label>
          <select
            class="kran-select"
            id="dayclose-limit"
            bind:value={limit}
            onchange={() => void onLimitChange()}
          >
            {#each RUN_LIMITS as value (value)}
              <option {value}>{value}</option>
            {/each}
          </select>
        </div>
      </div>

      {#if loadingRuns}
        <p role="status">{m.dayclose_history_loading()}</p>
      {/if}

      {#if runs.length === 0 && !loadingRuns}
        <p class="kran-muted">{m.dayclose_history_empty()}</p>
      {:else if runs.length > 0}
        <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
        <div
          class="kran-table-wrap"
          role="region"
          tabindex="0"
          aria-label={m.common_table_region({ name: m.dayclose_history_heading() })}
        >
          <table class="kran-table">
            <caption class="kran-visually-hidden">{m.dayclose_history_caption()}</caption>
            <thead>
              <tr>
                <th scope="col">{m.dayclose_col_business_date()}</th>
                <th scope="col">{m.dayclose_col_levels()}</th>
                <th scope="col">{m.dayclose_col_state()}</th>
                <th scope="col">{m.dayclose_col_started()}</th>
                <th scope="col">{m.dayclose_col_finished()}</th>
                <th scope="col" class="kran-num">{m.dayclose_col_ok()}</th>
                <th scope="col" class="kran-num">{m.dayclose_col_failed()}</th>
                <th scope="col" class="kran-num">{m.dayclose_col_skipped()}</th>
                <th scope="col" class="kran-num">{m.dayclose_col_total()}</th>
                <th scope="col">{m.dayclose_col_seal()}</th>
                <th scope="col">{m.dayclose_col_detail()}</th>
              </tr>
            </thead>
            <tbody>
              {#each runs as run (run.runId)}
                <tr class:kran-table__selected={run.runId === effectiveRunId}>
                  <th scope="row">
                    <span class="dayclose-row-date">
                      {#if run.runId === effectiveRunId}
                        <span class="dayclose-selected-mark" aria-hidden="true">▸</span>
                        <span class="kran-visually-hidden">{m.dayclose_selected_badge()}</span>
                      {/if}
                      {formatDate(run.businessDate)}
                    </span>
                  </th>
                  <td class="dayclose-levels">{run.levels.join(" · ")}</td>
                  <td>
                    {@render stateBadge(
                      runStateTone(run.state),
                      runStateIcon(run.state),
                      runStateLabel(run.state),
                    )}
                  </td>
                  <td>{formatDateTime(run.startedAt)}</td>
                  <td>
                    {#if run.finishedAt === null}
                      <span class="kran-muted">—</span>
                    {:else}
                      {formatDateTime(run.finishedAt)}
                    {/if}
                  </td>
                  <td class="kran-num">{run.taskCounts.ok}</td>
                  <td class="kran-num">{run.taskCounts.failed}</td>
                  <td class="kran-num">{run.taskCounts.skipped}</td>
                  <td class="kran-num">{run.taskCounts.total}</td>
                  <td>
                    {#if run.summaryHash === null}
                      <span class="kran-muted">—</span>
                    {:else}
                      <code class="dayclose-hash">{shortHash(run.summaryHash)}</code>
                    {/if}
                  </td>
                  <td>
                    <button
                      class="kran-button dayclose-row-button"
                      type="button"
                      onclick={() => selectRun(run.runId)}
                      aria-label={m.dayclose_open_detail_aria({
                        date: formatDate(run.businessDate),
                      })}
                    >
                      {m.dayclose_open_detail()}
                    </button>
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </section>

    {#if effectiveRunId !== ""}
      <section class="kran-card" aria-labelledby="dayclose-detail-heading">
        <div class="dayclose-section-head">
          <h2 id="dayclose-detail-heading">{m.dayclose_detail_heading()}</h2>
          <div class="dayclose-actions" aria-busy={busyAction !== ""}>
            {#each actionButtons as button (button.action)}
              <button
                class="kran-button"
                class:kran-button--primary={button.primary}
                class:dayclose-button-danger={button.action === "cancel"}
                type="button"
                onclick={() =>
                  button.action === "cancel"
                    ? void openConfirm("cancel", currentRun?.runId ?? "")
                    : void performAction(button.action, currentRun?.runId ?? "")}
                disabled={busyAction !== "" || currentRun === null}
              >
                {busyAction === button.action
                  ? m.dayclose_action_running_label()
                  : button.label}
              </button>
            {/each}
          </div>
        </div>

        {#if loadingDetail}
          <p role="status">{m.dayclose_detail_loading()}</p>
        {:else if detailError}
          <p class="kran-alert" role="alert">{detailError}</p>
          <p>
            <button
              class="kran-button"
              type="button"
              onclick={() => void loadDetail(effectiveRunId)}
            >
              {m.app_retry()}
            </button>
          </p>
        {:else if detail === null || detail.runId !== effectiveRunId}
          <p class="kran-muted">{m.dayclose_detail_empty()}</p>
        {:else}
          <dl class="dayclose-facts dayclose-detail-meta">
            <dt>{m.dayclose_detail_run_id()}</dt>
            <dd><code class="dayclose-hash dayclose-hash--full">{detail.runId}</code></dd>

            <dt>{m.dayclose_business_date_label()}</dt>
            <dd>{formatDate(detail.businessDate)}</dd>

            <dt>{m.dayclose_col_levels()}</dt>
            <dd class="dayclose-levels">{detail.levels.join(" · ")}</dd>

            <dt>{m.dayclose_col_state()}</dt>
            <dd>
              {@render stateBadge(
                runStateTone(detail.state),
                runStateIcon(detail.state),
                runStateLabel(detail.state),
              )}
            </dd>

            <dt>{m.dayclose_col_started()}</dt>
            <dd>{formatDateTime(detail.startedAt)}</dd>

            <dt>{m.dayclose_col_finished()}</dt>
            <dd>
              {#if detail.finishedAt === null}
                <span class="kran-muted">—</span>
              {:else}
                {formatDateTime(detail.finishedAt)}
              {/if}
            </dd>

            <dt>{m.dayclose_col_ok()}</dt>
            <dd>{detail.taskCounts.ok}</dd>

            <dt>{m.dayclose_col_failed()}</dt>
            <dd>{detail.taskCounts.failed}</dd>

            <dt>{m.dayclose_col_skipped()}</dt>
            <dd>{detail.taskCounts.skipped}</dd>

            <dt>{m.dayclose_col_total()}</dt>
            <dd>{detail.taskCounts.total}</dd>

            <dt>{m.dayclose_col_seal()}</dt>
            <dd>
              {#if detail.summaryHash === null}
                <span class="kran-muted">—</span>
              {:else}
                <code class="dayclose-hash dayclose-hash--full">{detail.summaryHash}</code>
              {/if}
            </dd>
          </dl>

          <h3 class="dayclose-tasks-heading">{m.dayclose_detail_tasks_heading()}</h3>

          {#if detail.tasks.length === 0}
            <p class="kran-muted">{m.dayclose_tasks_empty()}</p>
          {:else}
            <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
            <div
              class="kran-table-wrap"
              role="region"
              tabindex="0"
              aria-label={m.common_table_region({ name: m.dayclose_detail_tasks_heading() })}
            >
              <table class="kran-table">
                <caption class="kran-visually-hidden">{m.dayclose_detail_tasks_caption()}</caption>
                <thead>
                  <tr>
                    <th scope="col">{m.dayclose_col_task()}</th>
                    <th scope="col">{m.dayclose_col_state()}</th>
                    <th scope="col">{m.dayclose_col_kind()}</th>
                    <th scope="col">{m.dayclose_col_critical()}</th>
                    <th scope="col" class="kran-num">{m.dayclose_col_attempt()}</th>
                    <th scope="col">{m.dayclose_col_error()}</th>
                    <th scope="col">{m.dayclose_col_reason()}</th>
                  </tr>
                </thead>
                <tbody>
                  {#each detail.tasks as task (task.taskId)}
                    <tr>
                      <th scope="row" class="dayclose-task-id">{task.taskId}</th>
                      <td>
                        {@render stateBadge(
                          taskStateTone(task.state),
                          taskStateIcon(task.state),
                          taskStateLabel(task.state),
                        )}
                      </td>
                      <td>{taskKindLabel(task.kind)}</td>
                      <td>{task.critical ? m.dayclose_yes() : m.dayclose_no()}</td>
                      <td class="kran-num">{task.attempt}</td>
                      <td class="dayclose-error-cell">
                        {#if task.errorCode === null}
                          <span class="kran-muted">—</span>
                        {:else}
                          <code class="dayclose-error-code">{task.errorCode}</code>
                          {#if errorCodeHint(task.errorCode) !== ""}
                            <span class="dayclose-hint">{errorCodeHint(task.errorCode)}</span>
                          {/if}
                        {/if}
                      </td>
                      <td class="dayclose-reason">
                        {#if task.reason === null || task.reason === ""}
                          <span class="kran-muted">—</span>
                        {:else}
                          {task.reason}
                        {/if}
                      </td>
                    </tr>
                    {#if task.chunks.length > 0}
                      <tr class="dayclose-chunks-row">
                        <td colspan="7">
                          <p class="dayclose-chunks-label">{m.dayclose_chunks_label()}</p>
                          <ul class="dayclose-chunks" aria-label={m.dayclose_chunks_label()}>
                            {#each task.chunks as chunk (chunk.chunkNo)}
                              <li class="dayclose-chunk-line">
                                <span>{m.dayclose_chunk_no({ no: chunk.chunkNo })}</span>
                                <span aria-hidden="true">·</span>
                                {@render stateBadge(
                                  chunkStateTone(chunk.state),
                                  chunkStateIcon(chunk.state),
                                  chunkStateLabel(chunk.state),
                                )}
                                <span aria-hidden="true">·</span>
                                <span class="dayclose-sub"
                                  >{m.dayclose_col_attempt()}: {chunk.attempt}</span
                                >
                                {#if chunk.errorCode !== null}
                                  <span aria-hidden="true">·</span>
                                  <code class="dayclose-error-code">{chunk.errorCode}</code>
                                {/if}
                              </li>
                            {/each}
                          </ul>
                        </td>
                      </tr>
                    {/if}
                  {/each}
                </tbody>
              </table>
            </div>
          {/if}
        {/if}
      </section>
    {/if}
  {/if}
{/if}

<dialog
  id="dayclose-confirm"
  class="dayclose-dialog"
  aria-labelledby="dayclose-confirm-title"
  aria-describedby="dayclose-confirm-body"
  onkeydown={onDialogKeydown}
  onclose={onDialogClose}
>
  <h2 class="dayclose-dialog-title" id="dayclose-confirm-title">
    {confirmKind === "run"
      ? m.dayclose_confirm_run_title()
      : m.dayclose_confirm_cancel_title()}
  </h2>
  <p class="dayclose-dialog-body" id="dayclose-confirm-body">
    {#if confirmKind === "run"}
      {m.dayclose_confirm_run_body({ date: confirmDate })}
    {:else}
      {m.dayclose_confirm_cancel_body({ date: confirmDate })}
    {/if}
  </p>
  <div class="dayclose-dialog-actions">
    <button
      class="kran-button"
      id="dayclose-confirm-dismiss"
      type="button"
      onclick={closeConfirm}
    >
      {m.dayclose_confirm_dismiss()}
    </button>
    <button
      class="kran-button"
      class:kran-button--primary={confirmKind === "run"}
      class:dayclose-button-danger={confirmKind !== "run"}
      type="button"
      onclick={() => void confirmNow()}
    >
      {confirmKind === "run"
        ? m.dayclose_confirm_run_action()
        : m.dayclose_confirm_cancel_action()}
    </button>
  </div>
</dialog>

<style>
  .dayclose-head {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    justify-content: space-between;
    gap: var(--space-3);
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    margin-block-end: var(--space-4);
  }

  .dayclose-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .dayclose-intro {
    margin: var(--space-1) 0 0;
    max-inline-size: 62ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .dayclose-section-head {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-end;
    justify-content: space-between;
    gap: var(--space-3);
    margin-block-end: var(--space-3);
  }

  .dayclose-section-head h2 {
    margin: 0;
  }

  .dayclose-facts {
    display: grid;
    grid-template-columns: max-content minmax(0, 1fr);
    gap: var(--space-2) var(--space-4);
    margin: 0;
  }

  .dayclose-facts dt {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .dayclose-facts dd {
    margin: 0;
    min-inline-size: 0;
    overflow-wrap: anywhere;
  }

  .dayclose-run-line {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
  }

  .dayclose-sub {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .dayclose-muted {
    color: var(--color-text-muted);
  }

  .dayclose-notice {
    padding-block: var(--space-2);
    padding-inline: var(--space-3);
    border: 1px solid var(--color-primary);
    border-radius: var(--radius-md);
    color: var(--color-text);
  }

  .dayclose-running {
    margin: 0 0 var(--space-3);
    padding-block: var(--space-2);
    padding-inline: var(--space-3);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .dayclose-limit {
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
    min-inline-size: 7rem;
  }

  .dayclose-limit .kran-select {
    min-block-size: var(--control-height-primary);
  }

  .dayclose-levels {
    white-space: nowrap;
    font-variant-numeric: tabular-nums slashed-zero;
  }

  .dayclose-row-date {
    display: inline-flex;
    align-items: center;
    gap: var(--space-1);
  }

  .dayclose-selected-mark {
    color: var(--color-primary);
  }

  .dayclose-hash {
    font-family: var(--font-mono);
    font-size: var(--text-xs);
  }

  .dayclose-hash--full {
    font-size: var(--text-xs);
    overflow-wrap: anywhere;
  }

  .dayclose-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-2);
  }

  .dayclose-actions .kran-button {
    min-block-size: var(--control-height-primary);
  }

  .dayclose-button-danger {
    border-color: var(--color-danger);
    color: var(--color-danger);
  }

  .dayclose-button-danger:hover {
    background: var(--color-danger-tint);
  }

  .dayclose-detail-meta {
    margin-block-end: var(--space-4);
  }

  .dayclose-tasks-heading {
    margin: 0 0 var(--space-2);
    font-size: var(--text-base);
    font-weight: 600;
  }

  .dayclose-task-id {
    font-family: var(--font-mono);
    font-size: var(--text-xs);
    white-space: nowrap;
  }

  .dayclose-row-button {
    white-space: nowrap;
  }

  .dayclose-error-cell,
  .dayclose-reason {
    max-inline-size: 28rem;
    overflow-wrap: anywhere;
  }

  .dayclose-error-code {
    font-family: var(--font-mono);
    font-size: var(--text-xs);
  }

  .dayclose-hint {
    display: block;
    margin-block-start: var(--space-1);
    color: var(--color-text-muted);
    font-size: var(--text-xs);
  }

  .dayclose-chunks-row td {
    background: var(--color-surface);
  }

  .dayclose-chunks-label {
    margin: 0 0 var(--space-1);
    color: var(--color-text-muted);
    font-size: var(--text-xs);
  }

  .dayclose-chunks {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-1) var(--space-4);
    margin: 0;
    padding-inline-start: var(--space-4);
  }

  .dayclose-chunk-line {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
  }

  .dayclose-dialog {
    inline-size: min(32rem, calc(100vw - var(--space-6)));
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-lg);
    background: var(--color-surface-raised);
    color: var(--color-text);
    box-shadow: var(--shadow-2);
    font: inherit;
  }

  .dayclose-dialog::backdrop {
    /* Scrim hitam di kedua tema, sama dengan command palette: tujuannya meredupkan latar, bukan
       mewarnai, jadi tidak memakai token teks yang justru menjadi terang di tema gelap. */
    background: rgb(0 0 0 / 0.45);
  }

  .dayclose-dialog-title {
    margin: 0 0 var(--space-2);
    font-size: var(--text-md);
    font-weight: 600;
  }

  .dayclose-dialog-body {
    margin: 0 0 var(--space-4);
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .dayclose-dialog-actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: var(--space-2);
  }

  .dayclose-dialog-actions .kran-button {
    min-block-size: var(--control-height-primary);
  }

  @media (max-width: 640px) {
    .dayclose-head {
      padding-inline: var(--space-3);
    }

    /* Di layar sempit kolom id yang panjang tidak boleh mendorong status keluar layar: id
       membungkus dalam lebar tetap, sisanya tetap terjangkau lewat gulir region tabel. */
    .dayclose-task-id {
      min-inline-size: 10rem;
      white-space: normal;
      overflow-wrap: anywhere;
    }

    .dayclose-facts {
      grid-template-columns: minmax(0, 1fr);
      gap: var(--space-1);
    }

    .dayclose-facts dt {
      margin-block-start: var(--space-2);
    }

    .dayclose-facts dd {
      margin-block-end: var(--space-1);
    }

    .dayclose-actions {
      justify-content: flex-start;
    }
  }
</style>
