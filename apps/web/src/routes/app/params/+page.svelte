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
   *
   * Tata letak mengikuti DESIGN §11: titik fokus layar ini adalah tabel parameter, jadi tidak ada
   * strip kartu metrik di atasnya. Tabel tetap ditulis di sini (bukan `DataTable`) karena tiap
   * baris memakai `<th scope="row">` untuk kuncinya dan tabel pengajuan punya aksi per baris.
   * Tidak ada CSS lokal di berkas ini; aturan visual tinggal di `packages/ui`.
   */
  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import StatusBadge from "@kran/ui/components/StatusBadge.svelte";

  import { goto } from "$app/navigation";
  import { resolve } from "$app/paths";
  import { onMount } from "svelte";

  import type { Problem } from "@kran/api-client";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { paramProblemMessage } from "#lib/app/errors.js";
  import { formatClock, formatDate, formatDateTime } from "#lib/app/format.js";
  import { landingAccess } from "#lib/app/landing.js";
  import { roleLabel } from "#lib/app/roles.js";
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
  // Panel opsional dibaca per izin: pemakai tanpa `platform.param.read`/`platform.audit.read`
  // (mis. teller) tetap mendapat halaman yang utuh, bukan galat 403 dari satu panel.
  const access = $derived(landingAccess(session.permissions));
  const canReadParams = $derived(access.params);
  const canReadAudit = $derived(access.audit);
  const roleLabels = $derived(session.roles.map((code) => roleLabel(code)));

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

  /** Status = teks + bentuk + warna, tidak pernah warna saja (spec §15.4). */
  function statusTone(status: string): "positive" | "warning" | "negative" | "neutral" {
    if (status === "ACTIVE") return "positive";
    if (status === "PENDING") return "warning";
    if (status === "REJECTED") return "negative";
    return "neutral";
  }

  function displayValue(value: unknown): string {
    return typeof value === "string" ? value : JSON.stringify(value);
  }

  function errorFrom(problem: unknown): string {
    return api.isProblem(problem) ? paramProblemMessage(problem as Problem) : m.error_generic();
  }

  async function refresh(): Promise<void> {
    // Kegagalan jaringan (bukan amplop `problem` dari server) ditangkap di sini: pesannya
    // "gagal memuat data" + tombol coba lagi, bukan galat aksi. Panel yang izinnya tidak dipegang
    // tidak diminta sama sekali, jadi 403 bukan lagi kegagalan halaman (spec §13).
    errorMessage = "";
    const results = await Promise.all([
      canReadParams
        ? api.GET("/api/v1/params", { params: { query: { status: "ACTIVE" } } })
        : Promise.resolve(null),
      canReadParams
        ? api.GET("/api/v1/params", { params: { query: { status: "PENDING" } } })
        : Promise.resolve(null),
      canReadAudit
        ? api.GET("/api/v1/audit", { params: { query: { limit: 20 } } })
        : Promise.resolve(null),
    ]).catch(() => null);
    if (results === null) {
      errorMessage = m.app_error();
      return;
    }
    const [activeRes, pendingRes, auditRes] = results;
    const firstProblem = activeRes?.error ?? pendingRes?.error ?? auditRes?.error ?? null;
    if (firstProblem) {
      errorMessage = errorFrom(firstProblem);
      return;
    }
    active = activeRes?.data?.items ?? [];
    pending = pendingRes?.data?.items ?? [];
    audit = auditRes?.data?.items ?? [];
    updatedAt = new Date();
    const firstKey = selectableKeys[0];
    if (!formKey && firstKey !== undefined) formKey = firstKey;
  }

  onMount(() => {
    void refresh().finally(() => {
      loading = false;
    });

    // Tanpa izin baca parameter, langganan `param.changed` hanya akan menyulut refresh yang tidak
    // menghasilkan apa pun (dan bisa ditolak server), jadi hub tidak dibuka.
    if (!canReadParams) return;

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
        void goto(resolve("/login"));
      },
    });

    return () => realtime.stop();
  });

  /** Nilai form mengikuti tipe nilai aktif: angka → number, array/objek → JSON, sisanya teks. */
  function coerceValue(raw: string, current: unknown): unknown {
    const text = raw.trim();
    if (typeof current === "number") {
      const parsed = Number(text);
      // `Number("")` = 0 dan `Number("abc")` = NaN; keduanya berakhir sebagai nilai kosong/NULL di
      // body sehingga server menjawab 400 tanpa menyebut field. Lebih baik ditolak di sini dengan
      // pesan yang terbaca (T-133/UI-12).
      if (!Number.isFinite(parsed)) throw new Error("nilai bukan angka");
      return parsed;
    }
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
      errorMessage = m.param_error_value_invalid();
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

</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.app_title()}</title>
</svelte:head>

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.app_title()}</h1>
    <!-- Denyut realtime (spec §19.2): status + kapan data terakhir disegarkan, diumumkan halus. -->
    <p class="kran-page-header__intro kran-actions" role="status" aria-live="polite">
      <span class="kran-muted">{m.realtime_label()}:</span>
      {#if realtimeState === "connected"}
        <StatusBadge tone="positive">{m.realtime_connected()}</StatusBadge>
      {:else if realtimeState === "reconnecting"}
        <StatusBadge tone="warning">{m.realtime_reconnecting()}</StatusBadge>
      {:else}
        <StatusBadge tone="neutral">{m.realtime_connecting()}</StatusBadge>
      {/if}
      {#if updatedAt}
        <span class="kran-muted">{m.realtime_updated({ time: formatClock(updatedAt) })}</span>
      {/if}
    </p>
  </div>

  <!-- Identitas, tautan ubah sandi, dan tombol keluar tinggal di shell `/app` (T-132/UI-3),
       supaya tersedia di setiap layar kerja, bukan hanya di sini. Peran tetap ditampilkan di
       halaman ini karena ia konteks landing, bukan aksi sesi. -->
  {#if roleLabels.length > 0}
    <div class="kran-actions">
      <span class="kran-muted">{m.app_roles_label()}:</span>
      {#each roleLabels as role (role)}
        <StatusBadge tone="neutral">{role}</StatusBadge>
      {/each}
    </div>
  {/if}
</div>

{#if loading}
  <p role="status">{m.app_loading()}</p>
{:else}
  {#if errorMessage}
    <Alert tone="negative" title={errorMessage}>
      <Button type="button" onclick={() => void refresh()}>{m.app_retry()}</Button>
    </Alert>
  {/if}
  {#if notice}
    <Alert tone="positive" title={notice} />
  {/if}

  {#if !canReadParams && !canReadAudit}
    <!-- Tak ada panel yang boleh dibaca: satu penjelasan jujur, bukan dua daftar kosong. -->
    <section class="kran-section" aria-labelledby="app-denied-heading">
      <h2 class="kran-section__title" id="app-denied-heading">{m.app_denied_heading()}</h2>
      <p class="kran-muted">{m.app_denied_both()}</p>
    </section>
  {:else}
    {#if canReadParams}
      {#if canSubmit}
        <section class="kran-section" aria-labelledby="submit-heading">
          <h2 class="kran-section__title" id="submit-heading">{m.params_submit_heading()}</h2>
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

            <div class="kran-actions">
              <Button
                variant="primary"
                type="submit"
                disabled={sending || formKey === ""}
              >
                {sending ? m.params_submit_sending() : m.params_submit_submit()}
              </Button>
            </div>
          </form>
        </section>
      {/if}

      <section class="kran-section" aria-labelledby="pending-heading">
        <h2 class="kran-section__title" id="pending-heading">{m.params_pending_heading()}</h2>
        {#if pending.length === 0}
          <EmptyState title={m.params_pending_empty()} />
        {:else}
          <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
          <div
            class="kran-table-wrap"
            role="region"
            tabindex="0"
            aria-label={m.common_table_region({ name: m.params_pending_heading() })}
          >
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
                      <StatusBadge tone={statusTone(row.status)}>{statusText(row.status)}</StatusBadge>
                    </td>
                    {#if canApprove}
                      <td>
                        <Button
                          variant="primary"
                          type="button"
                          disabled={approvingId === row.paramValueId}
                          onclick={() => void approve(row.paramValueId)}
                        >
                          {approvingId === row.paramValueId ? m.params_approving() : m.params_approve()}
                        </Button>
                      </td>
                    {/if}
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        {/if}
      </section>

      <section class="kran-section" aria-labelledby="active-heading">
        <div class="kran-toolbar">
          <h2 class="kran-section__title" id="active-heading">{m.params_active_heading()}</h2>
          <input
            class="kran-input"
            type="search"
            placeholder={m.params_search_placeholder()}
            aria-label={m.params_search_label()}
            bind:value={searchFilter}
          />
        </div>
        {#if active.length === 0}
          <EmptyState title={m.params_active_empty()} />
        {:else}
          <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
          <div
            class="kran-table-wrap"
            role="region"
            tabindex="0"
            aria-label={m.common_table_region({ name: m.params_active_heading() })}
          >
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
                {#if filteredActive.length === 0}
                  <tr>
                    <td colspan="4" class="kran-muted">{m.params_search_empty()}</td>
                  </tr>
                {/if}
                {#each filteredActive as row (row.paramValueId)}
                  <tr>
                    <th scope="row">{row.key}</th>
                    <td>{displayValue(row.value)}</td>
                    <td>{formatDate(row.effectiveFrom)}</td>
                    <td>
                      <StatusBadge tone={statusTone(row.status)}>{statusText(row.status)}</StatusBadge>
                    </td>
                  </tr>
                {/each}
              </tbody>
            </table>
          </div>
        {/if}
      </section>
    {:else}
      <!-- Izin baca parameter tidak dipegang: panel parameter diganti penjelasan jujur. -->
      <section class="kran-section" aria-labelledby="app-denied-params-heading">
        <h2 class="kran-section__title" id="app-denied-params-heading">{m.app_denied_heading()}</h2>
        <p class="kran-muted">{m.app_denied_params()}</p>
      </section>
    {/if}

    {#if canReadAudit}
      <section class="kran-section" aria-labelledby="audit-heading">
        <h2 class="kran-section__title" id="audit-heading">{m.audit_heading()}</h2>
        {#if audit.length === 0}
          <EmptyState title={m.audit_empty()} />
        {:else}
          <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
          <div
            class="kran-table-wrap"
            role="region"
            tabindex="0"
            aria-label={m.common_table_region({ name: m.audit_heading() })}
          >
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
    {:else}
      <!-- Izin baca audit tidak dipegang: panel audit diganti penjelasan jujur. -->
      <section class="kran-section" aria-labelledby="app-denied-audit-heading">
        <h2 class="kran-section__title" id="app-denied-audit-heading">{m.app_denied_heading()}</h2>
        <p class="kran-muted">{m.app_denied_audit()}</p>
      </section>
    {/if}
  {/if}
{/if}
