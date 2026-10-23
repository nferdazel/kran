<script lang="ts">
  /**
   * Shell kerja Fase 0 (spec §23): daftar nilai parameter, pengajuan (maker) + persetujuan
   * (checker), jejak audit, dan penanda realtime.
   *
   * Pembaruan datang dari dua arah: fetch ulang eksplisit setelah aksi, dan peristiwa
   * `param.changed` dari hub realtime (spec §19.2) — keduanya **tanpa reload halaman**, sehingga
   * pengguna tidak kehilangan posisi kerjanya.
   *
   * Aksi ditampilkan menurut izin sesi (`platform.param.submit` / `platform.param.approve`),
   * bukan menurut jenis pengguna: izin adalah sumber kebenaran (spec §13).
   */
  import { goto } from "$app/navigation";
  import { onMount } from "svelte";

  import type { Problem } from "@kran/api-client";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { paramProblemMessage } from "#lib/app/errors.js";
  import { formatClock, formatDate, formatDateTime } from "#lib/app/format.js";
  import {
    connectRealtime,
    type RealtimeClient,
    type RealtimeState,
  } from "#lib/app/realtime.js";
  import type { AuditItem, ParamValue, SessionInfo } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  // Dibaca lewat `$derived`: prop bisa berubah (mis. navigasi ulang) dan pembacaan langsung di
  // scope komponen hanya menangkap nilai awal (Svelte 5 memperingatkan hal itu).
  const session: SessionInfo = $derived(data.session);
  const canSubmit = $derived(session.permissions.includes("platform.param.submit"));
  const canApprove = $derived(session.permissions.includes("platform.param.approve"));

  let active = $state<ParamValue[]>([]);
  let pending = $state<ParamValue[]>([]);
  let audit = $state<AuditItem[]>([]);
  let loading = $state(true);
  let errorMessage = $state("");
  let notice = $state("");
  let realtimeState = $state<RealtimeState>("connecting");
  let updatedAt = $state<Date | null>(null);

  // Form ajukan perubahan.
  let formKey = $state("");
  let formValue = $state("");
  let formReason = $state("");
  let formEffectiveFrom = $state("");
  let sending = $state(false);
  /**
   * Kunci idempotensi pengajuan parameter. Dibuat sekali per percobaan dan dipertahankan saat
   * gagal 5xx/jaringan supaya klik ulang tidak membuat pengajuan ganda; dibersihkan setelah
   * sukses atau kegagalan 4xx (isi permintaan berubah / tidak akan pernah valid).
   */
  let submitIdempotencyKey = $state("");
  /** Sidik isi form yang memiliki kunci di atas; isi berubah → kunci baru (hindari 409 palsu). */
  let submitKeyIdentity = $state("");
  let approvingId = $state("");

  /** Kunci yang bisa diajukan = kunci yang sedang punya nilai aktif (urutan dari server). */
  const selectableKeys = $derived([...new Set(active.map((row) => row.key))]);

  let searchFilter = $state("");
  const filteredActive = $derived.by(() => {
    const q = searchFilter.trim().toLowerCase();
    if (!q) return active;
    return active.filter(
      (row) => row.key.toLowerCase().includes(q) || String(row.value).toLowerCase().includes(q),
    );
  });

  function statusText(status: string): string {
    if (status === "ACTIVE") return m.param_status_active();
    if (status === "PENDING") return m.param_status_pending();
    if (status === "SUPERSEDED") return m.param_status_superseded();
    if (status === "REJECTED") return m.param_status_rejected();
    return m.param_status_draft();
  }

  /** Status = teks + ikon + warna, tidak pernah warna saja (spec §15.4). */
  function statusClass(status: string): string {
    if (status === "ACTIVE") return "kran-status kran-status--ok";
    if (status === "PENDING") return "kran-status kran-status--warning";
    if (status === "REJECTED") return "kran-status kran-status--danger";
    return "kran-status";
  }

  function statusIcon(status: string): string {
    if (status === "ACTIVE") return "✔";
    if (status === "PENDING") return "▲";
    if (status === "SUPERSEDED") return "○";
    if (status === "REJECTED") return "✖";
    return "✎";
  }

  function displayValue(value: unknown): string {
    return typeof value === "string" ? value : JSON.stringify(value);
  }

  function errorFrom(problem: unknown): string {
    return api.isProblem(problem) ? paramProblemMessage(problem as Problem) : m.error_generic();
  }

  async function refresh(): Promise<void> {
    // Kegagalan jaringan (bukan amplop `problem` dari server) ditangkap di sini: pesannya
    // "gagal memuat data" + tombol coba lagi, bukan galat aksi.
    const responses = await Promise.all([
      api.GET("/api/v1/params", { params: { query: { status: "ACTIVE" } } }),
      api.GET("/api/v1/params", { params: { query: { status: "PENDING" } } }),
      api.GET("/api/v1/audit", { params: { query: { limit: 20 } } }),
    ]).catch(() => null);
    if (responses === null) {
      errorMessage = m.app_error();
      return;
    }
    const [activeRes, pendingRes, auditRes] = responses;
    const firstProblem = activeRes.error ?? pendingRes.error ?? auditRes.error ?? null;
    if (firstProblem) {
      errorMessage = errorFrom(firstProblem);
      return;
    }
    active = activeRes.data?.items ?? [];
    pending = pendingRes.data?.items ?? [];
    audit = auditRes.data?.items ?? [];
    errorMessage = "";
    updatedAt = new Date();
    const firstKey = selectableKeys[0];
    if (!formKey && firstKey !== undefined) formKey = firstKey;
  }

  onMount(() => {
    void refresh().finally(() => {
      loading = false;
    });

    const realtime: RealtimeClient = connectRealtime(["param.changed"], {
      onEvent: () => {
        void refresh();
      },
      onState: (state) => {
        realtimeState = state;
      },
      onResync: () => {
        void refresh();
      },
      onUnauthorized: () => {
        void goto("/login");
      },
    });

    return () => realtime.stop();
  });

  /** Nilai form mengikuti tipe nilai aktif: angka → number, array/objek → JSON, sisanya teks. */
  function coerceValue(raw: string, current: unknown): unknown {
    const text = raw.trim();
    if (typeof current === "number") return Number(text);
    if (typeof current === "object" && current !== null) return JSON.parse(text);
    return text;
  }

  async function submitChange(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (sending) return;

    // Scope diambil dari baris parameter yang dipilih (kontrak mewajibkan `scopeType`), bukan
    // ditanam sebagai konstanta: begitu ada parameter INSTITUTION/cabang, form ini ikut benar.
    const currentRow = active.find((row) => row.key === formKey);
    if (currentRow === undefined) {
      errorMessage = m.app_error();
      return;
    }

    sending = true;
    errorMessage = "";
    notice = "";

    let value: unknown;
    try {
      value = coerceValue(formValue, currentRow.value);
    } catch {
      sending = false;
      errorMessage = m.error_bad_request();
      return;
    }

    const body: {
      value: unknown;
      reason: string;
      scopeType: ParamValue["scopeType"];
      effectiveFrom?: string;
    } = {
      value,
      reason: formReason.trim(),
      scopeType: currentRow.scopeType,
    };
    if (formEffectiveFrom) body.effectiveFrom = formEffectiveFrom;

    // Kunci terikat pada isi yang diajukan: mengganti parameter/nilai/alasan setelah kegagalan
    // 5xx harus memulai permintaan baru, bukan memakai ulang kunci dengan sidik jari berbeda.
    const identity = JSON.stringify([
      currentRow.key,
      value,
      formReason.trim(),
      formEffectiveFrom,
    ]);
    if (submitIdempotencyKey === "" || submitKeyIdentity !== identity) {
      submitIdempotencyKey = crypto.randomUUID();
      submitKeyIdentity = identity;
    }

    try {
      const { response, error } = await api.POST("/api/v1/params/{key}/changes", {
        params: {
          path: { key: currentRow.key },
          header: { "Idempotency-Key": submitIdempotencyKey },
        },
        body,
      });

      if (!response.ok) {
        if (response.status < 500) {
          submitIdempotencyKey = "";
          submitKeyIdentity = "";
        }
        errorMessage = errorFrom(error);
        return;
      }

      submitIdempotencyKey = "";
      submitKeyIdentity = "";
      notice = m.params_submit_success();
      formValue = "";
      formReason = "";
      formEffectiveFrom = "";
      await refresh();
    } catch {
      // Jaringan gagal: kunci dan `sending` harus pulih supaya operator bisa mencoba lagi.
      errorMessage = m.app_error();
    } finally {
      sending = false;
    }
  }

  async function approve(paramValueId: string): Promise<void> {
    approvingId = paramValueId;
    errorMessage = "";
    notice = "";

    // Tanpa badan permintaan: kontrak tidak mendefinisikannya untuk operasi ini.
    const { response, error } = await api.POST(
      "/api/v1/params/changes/{paramValueId}/approve",
      { params: { path: { paramValueId } } },
    );
    approvingId = "";

    if (!response.ok) {
      errorMessage = errorFrom(error);
      return;
    }
    await refresh();
  }

  async function logout(): Promise<void> {
    await api.POST("/api/v1/auth/logout");
    await goto("/login");
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.app_title()}</title>
</svelte:head>

<div class="kran-toolbar app-toolbar">
  <div>
    <h1 class="app-title">{m.app_title()}</h1>
    <!-- Denyut realtime (spec §19.2): status + kapan data terakhir disegarkan, diumumkan halus. -->
    <p class="app-realtime" role="status" aria-live="polite">
      <span class="kran-muted">{m.realtime_label()}:</span>
      {#if realtimeState === "connected"}
        <span class="kran-badge kran-badge--ok">
          <span class="kran-status-dot" aria-hidden="true"></span>
          <span>{m.realtime_connected()}</span>
        </span>
      {:else if realtimeState === "reconnecting"}
        <span class="kran-badge kran-badge--warning">
          <span aria-hidden="true">▲</span>
          <span>{m.realtime_reconnecting()}</span>
        </span>
      {:else}
        <span class="kran-badge">
          <span>{m.realtime_connecting()}</span>
        </span>
      {/if}
      {#if updatedAt}
        <span class="kran-muted">{m.realtime_updated({ time: formatClock(updatedAt) })}</span>
      {/if}
    </p>
  </div>

  <div class="app-session-actions">
    <span class="kran-badge kran-badge--primary">{m.app_signed_in_as({ name: session.fullName })}</span>
    <a class="kran-button" href="/app/password">{m.app_change_password()}</a>
    <button class="kran-button" type="button" onclick={logout}>{m.app_logout()}</button>
  </div>
</div>

{#if loading}
  <p role="status">{m.app_loading()}</p>
{:else}
  {#if errorMessage}
    <p class="kran-alert" role="alert">{errorMessage}</p>
    <p><button class="kran-button" type="button" onclick={() => void refresh()}>{m.app_retry()}</button></p>
  {/if}
  {#if notice}
    <p role="status">{notice}</p>
  {/if}

  <!-- Strip ringkasan parameter & audit -->
  <div class="kran-metric-strip">
    <div class="kran-metric-card">
      <span class="kran-metric-card__label">{m.params_active_heading()}</span>
      <span class="kran-metric-card__value kran-num">{active.length}</span>
      <span class="kran-metric-card__sub">{m.app_metric_active_sub()}</span>
    </div>

    <div class="kran-metric-card">
      <span class="kran-metric-card__label">{m.params_pending_heading()}</span>
      <span class="kran-metric-card__value kran-num">{pending.length}</span>
      <div class="kran-metric-card__sub">
        {#if pending.length > 0}
          <span class="kran-badge kran-badge--warning">{m.app_metric_pending_action()}</span>
        {:else}
          <span class="kran-badge kran-badge--ok">{m.app_metric_pending_none()}</span>
        {/if}
      </div>
    </div>

    <div class="kran-metric-card">
      <span class="kran-metric-card__label">{m.audit_heading()}</span>
      <span class="kran-metric-card__value kran-num">{audit.length}</span>
      <span class="kran-metric-card__sub">{m.app_metric_audit_sub()}</span>
    </div>
  </div>

  {#if canSubmit}
    <section class="kran-card" aria-labelledby="submit-heading">
      <h2 id="submit-heading">{m.params_submit_heading()}</h2>
      <p class="kran-muted">{m.params_submit_effective_from_hint()}</p>

      <form class="kran-form" onsubmit={submitChange} novalidate>
        <div class="kran-field">
          <label class="kran-label" for="param-key">{m.params_submit_key_label()}</label>
          <select class="kran-select" id="param-key" bind:value={formKey}>
            {#each selectableKeys as key (key)}
              <option value={key}>{key}</option>
            {/each}
          </select>
        </div>

        <div class="kran-field">
          <label class="kran-label" for="param-value">{m.params_submit_value_label()}</label>
          <input class="kran-input" id="param-value" name="value" bind:value={formValue} required />
        </div>

        <div class="kran-field">
          <label class="kran-label" for="param-reason">{m.params_submit_reason_label()}</label>
          <input
            class="kran-input"
            id="param-reason"
            name="reason"
            bind:value={formReason}
            required
          />
        </div>

        <div class="kran-field">
          <label class="kran-label" for="param-effective-from"
            >{m.params_submit_effective_from_label()}</label
          >
          <input
            class="kran-input"
            id="param-effective-from"
            name="effectiveFrom"
            type="date"
            bind:value={formEffectiveFrom}
          />
        </div>

        <p>
          <button
            class="kran-button kran-button--primary"
            type="submit"
            disabled={sending || formKey === ""}
          >
            {sending ? m.params_submit_sending() : m.params_submit_submit()}
          </button>
        </p>
      </form>
    </section>
  {/if}

  <section class="kran-card" aria-labelledby="pending-heading">
    <h2 id="pending-heading">{m.params_pending_heading()}</h2>
    {#if pending.length === 0}
      <p class="kran-muted">{m.params_pending_empty()}</p>
    {:else}
      <div class="kran-table-wrap">
        <table class="kran-table">
          <thead>
            <tr>
              <th scope="col">{m.params_col_key()}</th>
              <th scope="col">{m.params_col_value()}</th>
              <th scope="col">{m.params_col_effective_from()}</th>
              <th scope="col">{m.params_col_maker()}</th>
              <th scope="col">{m.params_col_status()}</th>
              {#if canApprove}<th scope="col">{m.params_col_action()}</th>{/if}
            </tr>
          </thead>
          <tbody>
            {#each pending as row (row.paramValueId)}
              <tr>
                <th scope="row">{row.key}</th>
                <td>{displayValue(row.value)}</td>
                <td>{formatDate(row.effectiveFrom)}</td>
                <td>{row.maker}</td>
                <td>
                  <span class={statusClass(row.status)}>
                    <span class="kran-status__icon" aria-hidden="true">{statusIcon(row.status)}</span
                    >
                    {statusText(row.status)}
                  </span>
                </td>
                {#if canApprove}
                  <td>
                    <button
                      class="kran-button kran-button--primary"
                      type="button"
                      disabled={approvingId === row.paramValueId}
                      onclick={() => void approve(row.paramValueId)}
                    >
                      {approvingId === row.paramValueId ? m.params_approving() : m.params_approve()}
                    </button>
                  </td>
                {/if}
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>

  <section class="kran-card" aria-labelledby="active-heading">
    <div style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: var(--space-3); margin-block-end: var(--space-3);">
      <h2 id="active-heading" style="margin: 0;">{m.params_active_heading()}</h2>
      <input
        class="kran-input"
        type="search"
        placeholder="Cari parameter..."
        aria-label="Cari parameter aktif"
        bind:value={searchFilter}
        style="min-inline-size: 14rem;"
      />
    </div>
    {#if active.length === 0}
      <p class="kran-muted">{m.params_active_empty()}</p>
    {:else}
      <div class="kran-table-wrap">
        <table class="kran-table">
          <thead>
            <tr>
              <th scope="col">{m.params_col_key()}</th>
              <th scope="col">{m.params_col_value()}</th>
              <th scope="col">{m.params_col_effective_from()}</th>
              <th scope="col">{m.params_col_status()}</th>
            </tr>
          </thead>
          <tbody>
            {#each filteredActive as row (row.paramValueId)}
              <tr>
                <th scope="row">{row.key}</th>
                <td>{displayValue(row.value)}</td>
                <td>{formatDate(row.effectiveFrom)}</td>
                <td>
                  <span class={statusClass(row.status)}>
                    <span class="kran-status__icon" aria-hidden="true">{statusIcon(row.status)}</span>
                    {statusText(row.status)}
                  </span>
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>

  <section class="kran-card" aria-labelledby="audit-heading">
    <h2 id="audit-heading">{m.audit_heading()}</h2>
    {#if audit.length === 0}
      <p class="kran-muted">{m.audit_empty()}</p>
    {:else}
      <div class="kran-table-wrap">
        <table class="kran-table">
          <thead>
            <tr>
              <th scope="col">{m.audit_col_time()}</th>
              <th scope="col">{m.audit_col_action()}</th>
              <th scope="col">{m.audit_col_actor()}</th>
              <th scope="col">{m.audit_col_reason()}</th>
            </tr>
          </thead>
          <tbody>
            {#each audit as entry (entry.seq)}
              <tr>
                <th scope="row">{formatDateTime(entry.recordedAt)}</th>
                <td>{entry.action}</td>
                <td>{entry.actorUserId}</td>
                <td>{entry.reason}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>
{/if}

<style>
  .app-toolbar {
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    margin-block-end: var(--space-4);
  }

  .app-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .app-realtime {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
    margin-block-start: var(--space-1);
    margin-block-end: 0;
    font-size: var(--text-xs);
  }

  .app-session-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
  }
</style>
