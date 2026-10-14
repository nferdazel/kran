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

  import type { Problem } from "@cbs/api-client";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { problemMessage } from "#lib/app/errors.js";
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
  let approvingId = $state("");

  /** Kunci yang bisa diajukan = kunci yang sedang punya nilai aktif (urutan dari server). */
  const selectableKeys = $derived([...new Set(active.map((row) => row.key))]);

  function statusText(status: string): string {
    if (status === "ACTIVE") return m.param_status_active();
    if (status === "PENDING") return m.param_status_pending();
    if (status === "SUPERSEDED") return m.param_status_superseded();
    if (status === "REJECTED") return m.param_status_rejected();
    return m.param_status_draft();
  }

  /** Status = teks + ikon + warna, tidak pernah warna saja (spec §15.4). */
  function statusClass(status: string): string {
    if (status === "ACTIVE") return "cbs-status cbs-status--ok";
    if (status === "PENDING") return "cbs-status cbs-status--warning";
    if (status === "REJECTED") return "cbs-status cbs-status--danger";
    return "cbs-status";
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
    return api.isProblem(problem) ? problemMessage(problem as Problem) : m.error_generic();
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

    const { response, error } = await api.POST("/api/v1/params/{key}/changes", {
      params: { path: { key: currentRow.key } },
      body,
    });
    sending = false;

    if (!response.ok) {
      errorMessage = errorFrom(error);
      return;
    }
    notice = m.params_submit_success();
    formValue = "";
    formReason = "";
    formEffectiveFrom = "";
    await refresh();
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

<div class="cbs-toolbar">
  <h1>{m.app_title()}</h1>
  <p>
    <span class="cbs-muted">{m.app_signed_in_as({ name: session.fullName })}</span>
    <button class="cbs-button" type="button" onclick={logout}>{m.app_logout()}</button>
  </p>
</div>

<!-- Denyut realtime (spec §19.2): status + kapan data terakhir disegarkan, diumumkan halus. -->
<p role="status" aria-live="polite">
  <span class="cbs-muted">{m.realtime_label()}:</span>
  {#if realtimeState === "connected"}
    <span class="cbs-status cbs-status--ok">
      <span class="cbs-status__icon" aria-hidden="true">✔</span>
      {m.realtime_connected()}
    </span>
  {:else if realtimeState === "reconnecting"}
    <span class="cbs-status cbs-status--warning">
      <span class="cbs-status__icon" aria-hidden="true">▲</span>
      {m.realtime_reconnecting()}
    </span>
  {:else}
    <span class="cbs-muted">{m.realtime_connecting()}</span>
  {/if}
  {#if updatedAt}
    <span class="cbs-muted">{m.realtime_updated({ time: formatClock(updatedAt) })}</span>
  {/if}
</p>

{#if loading}
  <p role="status">{m.app_loading()}</p>
{:else}
  {#if errorMessage}
    <p class="cbs-alert" role="alert">{errorMessage}</p>
    <p><button class="cbs-button" type="button" onclick={() => void refresh()}>{m.app_retry()}</button></p>
  {/if}
  {#if notice}
    <p role="status">{notice}</p>
  {/if}

  {#if canSubmit}
    <section class="cbs-card" aria-labelledby="submit-heading">
      <h2 id="submit-heading">{m.params_submit_heading()}</h2>
      <p class="cbs-muted">{m.params_submit_effective_from_hint()}</p>

      <form class="cbs-form" onsubmit={submitChange} novalidate>
        <div class="cbs-field">
          <label class="cbs-label" for="param-key">{m.params_submit_key_label()}</label>
          <select class="cbs-select" id="param-key" bind:value={formKey}>
            {#each selectableKeys as key (key)}
              <option value={key}>{key}</option>
            {/each}
          </select>
        </div>

        <div class="cbs-field">
          <label class="cbs-label" for="param-value">{m.params_submit_value_label()}</label>
          <input class="cbs-input" id="param-value" name="value" bind:value={formValue} required />
        </div>

        <div class="cbs-field">
          <label class="cbs-label" for="param-reason">{m.params_submit_reason_label()}</label>
          <input
            class="cbs-input"
            id="param-reason"
            name="reason"
            bind:value={formReason}
            required
          />
        </div>

        <div class="cbs-field">
          <label class="cbs-label" for="param-effective-from"
            >{m.params_submit_effective_from_label()}</label
          >
          <input
            class="cbs-input"
            id="param-effective-from"
            name="effectiveFrom"
            type="date"
            bind:value={formEffectiveFrom}
          />
        </div>

        <p>
          <button
            class="cbs-button cbs-button--primary"
            type="submit"
            disabled={sending || formKey === ""}
          >
            {sending ? m.params_submit_sending() : m.params_submit_submit()}
          </button>
        </p>
      </form>
    </section>
  {/if}

  <section class="cbs-card" aria-labelledby="pending-heading">
    <h2 id="pending-heading">{m.params_pending_heading()}</h2>
    {#if pending.length === 0}
      <p class="cbs-muted">{m.params_pending_empty()}</p>
    {:else}
      <div class="cbs-table-wrap">
        <table class="cbs-table">
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
                    <span class="cbs-status__icon" aria-hidden="true">{statusIcon(row.status)}</span
                    >
                    {statusText(row.status)}
                  </span>
                </td>
                {#if canApprove}
                  <td>
                    <button
                      class="cbs-button cbs-button--primary"
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

  <section class="cbs-card" aria-labelledby="active-heading">
    <h2 id="active-heading">{m.params_active_heading()}</h2>
    {#if active.length === 0}
      <p class="cbs-muted">{m.params_active_empty()}</p>
    {:else}
      <div class="cbs-table-wrap">
        <table class="cbs-table">
          <thead>
            <tr>
              <th scope="col">{m.params_col_key()}</th>
              <th scope="col">{m.params_col_value()}</th>
              <th scope="col">{m.params_col_effective_from()}</th>
              <th scope="col">{m.params_col_status()}</th>
            </tr>
          </thead>
          <tbody>
            {#each active as row (row.paramValueId)}
              <tr>
                <th scope="row">{row.key}</th>
                <td>{displayValue(row.value)}</td>
                <td>{formatDate(row.effectiveFrom)}</td>
                <td>
                  <span class={statusClass(row.status)}>
                    <span class="cbs-status__icon" aria-hidden="true">{statusIcon(row.status)}</span
                    >
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

  <section class="cbs-card" aria-labelledby="audit-heading">
    <h2 id="audit-heading">{m.audit_heading()}</h2>
    {#if audit.length === 0}
      <p class="cbs-muted">{m.audit_empty()}</p>
    {:else}
      <div class="cbs-table-wrap">
        <table class="cbs-table">
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
