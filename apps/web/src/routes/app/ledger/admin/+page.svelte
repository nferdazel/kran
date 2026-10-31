<script lang="ts">
  /**
   * Layar admin buku besar (T-116): buka/tutup periode, kelola COA, dan jurnal pembalik.
   *
   * Keputusan yang mengikat:
   *  - Satu tautan nav (`ledger.period.manage`); seksi di dalam disaring izin sendiri
   *    (`ledger.period.manage`, `ledger.coa.manage`, `ledger.journal.reverse`). Server tetap
   *    otoritas terakhir — seksi yang tampil bisa ditolak 403 dan ditampilkan apa adanya.
   *  - Buku besar immutable: layar ini **tidak** menawarkan edit/hapus jurnal, hanya pembalik.
   *  - Konfirmasi tutup periode = **satu lapisan inline** (DESIGN §7), bukan `window.confirm`.
   *  - Galat field difokuskan ke input pertama yang gagal dan pesannya terikat `aria-describedby`.
   *
   * Aturan visual milik `packages/ui`: judul layar, seksi, field, tombol, badge status, dan peringatan
   * memakai kelas/komponen bersama. CSS lokal hanya untuk digit kode dan ukuran target checkbox.
   */
  import { goto } from "$app/navigation";
  import { resolve } from "$app/paths";
  import { onMount } from "svelte";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import StatusBadge from "@kran/ui/components/StatusBadge.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatDate, formatDateTime } from "#lib/app/format.js";
  import {
    ACCOUNT_TYPES,
    COA_CODE_MAX_LENGTH,
    COA_NAME_MAX_LENGTH,
    REASON_MAX_LENGTH,
    canClosePeriod,
    coaAccountTypeLabel,
    ledgerAdminProblemMessage,
    validateCoaForm,
    validatePeriodForm,
    validateReason,
    validateReverseForm,
    type CoaAccount,
    type CoaField,
    type FormError,
    type JournalHeader,
    type LedgerAdminAction,
    type Period,
    type ReverseField,
  } from "#lib/app/ledger-admin.js";
  import type { SessionInfo } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  const session: SessionInfo = $derived(data.session);
  const canManagePeriod = $derived(session.permissions.includes("ledger.period.manage"));
  const canManageCoa = $derived(session.permissions.includes("ledger.coa.manage"));
  const canReverse = $derived(session.permissions.includes("ledger.journal.reverse"));
  const canReadJournals = $derived(session.permissions.includes("ledger.journal.read"));
  const anySection = $derived(canManagePeriod || canManageCoa || canReverse);

  let periods = $state<Period[]>([]);
  let accounts = $state<CoaAccount[]>([]);
  let journals = $state<JournalHeader[]>([]);
  let loading = $state(true);
  let loadError = $state("");
  let actionError = $state("");
  let notice = $state("");

  // Buka periode
  let openStarts = $state("");
  let openEnds = $state("");
  let openError = $state<FormError<"startsOn" | "endsOn"> | null>(null);
  let opening = $state(false);

  // Tutup periode (konfirmasi inline). `confirmingId` = baris yang membuka form; `closingId` =
  // baris yang sedang POST, supaya tombolnya bisa dinonaktifkan tanpa menutup form.
  let confirmingId = $state("");
  let closingId = $state("");
  let closeReason = $state("");
  let closeError = $state<FormError<"reason"> | null>(null);

  // Buat COA
  let coaCode = $state("");
  let coaName = $state("");
  let coaType = $state("");
  let coaPostable = $state(true);
  let coaError = $state<FormError<CoaField> | null>(null);
  let creating = $state(false);

  // Jurnal pembalik
  let reverseJournalId = $state("");
  let reverseReason = $state("");
  let reverseError = $state<FormError<ReverseField> | null>(null);
  let reversing = $state(false);
  /** Kunci idempotensi: dipertahankan saat retry, dibuat ulang bila isi form berubah. */
  let reverseKey = $state("");

  function focusField(id: string): void {
    const element = document.getElementById(id);
    if (element instanceof HTMLElement) element.focus();
  }

  function problemFrom(problem: unknown, action: LedgerAdminAction): string {
    return api.isProblem(problem)
      ? ledgerAdminProblemMessage(problem, action)
      : m.ledger_admin_error();
  }

  function listError(status: number): string {
    return status === 403 ? m.ledger_admin_error_denied() : m.ledger_admin_error();
  }

  async function loadPeriods(): Promise<void> {
    const { data: body, response } = await api.GET("/api/v1/ledger/periods");
    if (response.status === 401) {
      await goto(resolve("/login"));
      return;
    }
    if (!response.ok || !body) {
      if (loadError === "") loadError = listError(response.status);
      return;
    }
    periods = (body.items ?? []) as Period[];
  }

  async function loadCoa(): Promise<void> {
    const { data: body, response } = await api.GET("/api/v1/ledger/coa");
    if (response.status === 401) {
      await goto(resolve("/login"));
      return;
    }
    if (!response.ok || !body) {
      if (loadError === "") loadError = listError(response.status);
      return;
    }
    accounts = (body.items ?? []) as CoaAccount[];
  }

  async function loadJournals(): Promise<void> {
    const { data: body, response } = await api.GET("/api/v1/ledger/journals");
    if (response.status === 401) {
      await goto(resolve("/login"));
      return;
    }
    if (!response.ok || !body) {
      if (loadError === "") loadError = listError(response.status);
      return;
    }
    journals = (body.items ?? []) as JournalHeader[];
  }

  async function loadAll(showLoading = true): Promise<void> {
    if (showLoading) loading = true;
    loadError = "";
    try {
      const jobs: Promise<void>[] = [];
      if (canManagePeriod) jobs.push(loadPeriods());
      if (canManageCoa) jobs.push(loadCoa());
      if (canReverse && canReadJournals) jobs.push(loadJournals());
      await Promise.all(jobs);
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    if (!anySection) {
      loading = false;
      return;
    }
    void loadAll();
  });

  async function submitOpen(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    actionError = "";
    notice = "";
    const result = validatePeriodForm({ startsOn: openStarts, endsOn: openEnds }, periods);
    if (!result.ok) {
      openError = result.error;
      focusField(result.error.field === "startsOn" ? "ledger-open-starts" : "ledger-open-ends");
      return;
    }
    openError = null;
    opening = true;
    try {
      const { response, error } = await api.POST("/api/v1/ledger/periods", {
        body: { startsOn: result.startsOn, endsOn: result.endsOn },
      });
      if (!response.ok) {
        actionError = problemFrom(error, "open_period");
        return;
      }
      notice = m.ledger_admin_open_success();
      openStarts = "";
      openEnds = "";
      await loadPeriods();
    } catch {
      actionError = m.ledger_admin_error();
    } finally {
      opening = false;
    }
  }

  function startClose(period: Period): void {
    actionError = "";
    notice = "";
    closeReason = "";
    closeError = null;
    confirmingId = period.periodId;
  }

  function cancelClose(): void {
    confirmingId = "";
    closingId = "";
    closeReason = "";
    closeError = null;
  }

  async function submitClose(event: SubmitEvent, period: Period): Promise<void> {
    event.preventDefault();
    actionError = "";
    notice = "";
    const reason = validateReason(closeReason);
    if (!reason.ok) {
      closeError = reason.error;
      focusField(`ledger-close-reason-${period.periodId}`);
      return;
    }
    closeError = null;
    closingId = period.periodId;
    try {
      const { response, error } = await api.POST("/api/v1/ledger/periods/{periodId}/close", {
        params: { path: { periodId: period.periodId } },
        body: { reason: reason.reason },
      });
      if (!response.ok) {
        actionError = problemFrom(error, "close_period");
        return;
      }
      notice = m.ledger_admin_close_success();
      confirmingId = "";
      closeReason = "";
      await loadPeriods();
    } catch {
      actionError = m.ledger_admin_error();
    } finally {
      closingId = "";
    }
  }

  async function submitCoa(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    actionError = "";
    notice = "";
    const result = validateCoaForm({
      code: coaCode,
      name: coaName,
      accountType: coaType,
      postable: coaPostable,
    });
    if (!result.ok) {
      coaError = result.error;
      const id =
        result.error.field === "code"
          ? "ledger-coa-code"
          : result.error.field === "name"
            ? "ledger-coa-name"
            : "ledger-coa-type";
      focusField(id);
      return;
    }
    coaError = null;
    creating = true;
    try {
      const { response, error } = await api.POST("/api/v1/ledger/coa", {
        body: {
          code: result.code,
          name: result.name,
          accountType: result.accountType,
          postable: result.postable,
        },
      });
      if (!response.ok) {
        actionError = problemFrom(error, "create_coa");
        return;
      }
      notice = m.ledger_admin_coa_success();
      coaCode = "";
      coaName = "";
      coaType = "";
      coaPostable = true;
      await loadCoa();
    } catch {
      actionError = m.ledger_admin_error();
    } finally {
      creating = false;
    }
  }

  function resetReverseKey(): void {
    reverseKey = "";
  }

  function pickJournal(journalId: string): void {
    reverseJournalId = journalId;
    resetReverseKey();
  }

  async function submitReverse(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    actionError = "";
    notice = "";
    const result = validateReverseForm({ journalId: reverseJournalId, reason: reverseReason });
    if (!result.ok) {
      reverseError = result.error;
      focusField(result.error.field === "journalId" ? "ledger-reverse-journal" : "ledger-reverse-reason");
      return;
    }
    reverseError = null;
    if (reverseKey === "") reverseKey = crypto.randomUUID();
    reversing = true;
    try {
      const { data: body, response, error } = await api.POST(
        "/api/v1/ledger/journals/{journalId}/reversal",
        {
          params: {
            path: { journalId: result.journalId },
            header: { "Idempotency-Key": reverseKey },
          },
          body: { reason: result.reason },
        },
      );
      if (!response.ok || !body) {
        actionError = problemFrom(error, "reverse_journal");
        return;
      }
      notice = m.ledger_admin_reverse_success({ journalId: body.journalId });
      reverseJournalId = "";
      reverseReason = "";
      reverseKey = "";
      if (canReadJournals) await loadJournals();
    } catch {
      actionError = m.ledger_admin_error();
    } finally {
      reversing = false;
    }
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.ledger_admin_title()}</title>
</svelte:head>

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.ledger_admin_title()}</h1>
    <p class="kran-page-header__intro">{m.ledger_admin_intro()}</p>
  </div>
  <Button type="button" onclick={() => void loadAll()} disabled={loading || !anySection}>
    {m.ledger_admin_reload()}
  </Button>
</div>

{#if !anySection}
  <Alert tone="negative" title={m.ledger_admin_no_sections()} />
{:else if loading}
  <p role="status">{m.ledger_admin_loading()}</p>
{:else}
  {#if loadError}
    <Alert tone="negative" title={loadError} />
  {/if}
  {#if actionError}
    <Alert tone="negative" title={actionError} />
  {/if}
  {#if notice}
    <Alert tone="positive" title={notice} />
  {/if}

  <p class="kran-muted">{m.ledger_admin_immutable_hint()}</p>

  {#if canManagePeriod}
    <section class="kran-section" aria-labelledby="ledger-admin-periods-heading">
      <h2 class="kran-section__title" id="ledger-admin-periods-heading">
        {m.ledger_admin_periods_heading()}
      </h2>
      <p class="kran-muted">{m.ledger_admin_periods_intro()}</p>

      {#if periods.length === 0}
        <EmptyState title={m.ledger_admin_periods_empty()} />
      {:else}
        <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
        <div
          class="kran-table-wrap"
          role="region"
          tabindex="0"
          aria-label={m.common_table_region({ name: m.ledger_admin_periods_heading() })}
        >
          <table class="kran-table">
            <caption class="kran-visually-hidden">{m.ledger_admin_periods_caption()}</caption>
            <thead>
              <tr>
                <th scope="col">{m.ledger_admin_col_period_id()}</th>
                <th scope="col">{m.ledger_admin_col_starts()}</th>
                <th scope="col">{m.ledger_admin_col_ends()}</th>
                <th scope="col">{m.ledger_admin_col_status()}</th>
                <th scope="col">{m.ledger_admin_col_closed_at()}</th>
                <th scope="col">{m.ledger_admin_col_action()}</th>
              </tr>
            </thead>
            <tbody>
              {#each periods as period (period.periodId)}
                <tr>
                  <th scope="row" class="ledger-admin-id">{period.periodId}</th>
                  <td>{formatDate(period.startsOn)}</td>
                  <td>{formatDate(period.endsOn)}</td>
                  <td>
                    <StatusBadge tone={period.status === "OPEN" ? "positive" : "neutral"}>
                      {period.status === "OPEN"
                        ? m.ledger_status_open()
                        : m.ledger_status_closed()}
                    </StatusBadge>
                  </td>
                  <td>
                    {#if period.closedAt}
                      {formatDateTime(period.closedAt)}
                    {:else}
                      <span class="kran-muted">—</span>
                    {/if}
                  </td>
                  <td>
                    {#if !canClosePeriod(period)}
                      <span class="kran-muted">{m.ledger_admin_close_disabled()}</span>
                    {:else if confirmingId === period.periodId}
                      <form
                        class="kran-stack"
                        onsubmit={(event) => void submitClose(event, period)}
                        novalidate
                      >
                        <p class="kran-muted" id={`close-hint-${period.periodId}`}>
                          {m.ledger_admin_close_confirm({
                            range: `${formatDate(period.startsOn)} – ${formatDate(period.endsOn)}`,
                          })}
                        </p>
                        <label class="kran-label" for={`ledger-close-reason-${period.periodId}`}>
                          {m.ledger_admin_close_reason_label()}
                        </label>
                        <input
                          class="kran-input"
                          id={`ledger-close-reason-${period.periodId}`}
                          bind:value={closeReason}
                          maxlength={REASON_MAX_LENGTH}
                          aria-describedby={closeError === null
                            ? `close-hint-${period.periodId}`
                            : `close-hint-${period.periodId} close-error-${period.periodId}`}
                          aria-invalid={closeError !== null ? "true" : undefined}
                        />
                        {#if closeError}
                          <p class="kran-alert" id={`close-error-${period.periodId}`} role="alert">
                            {closeError.message}
                          </p>
                        {/if}
                        <div class="kran-actions">
                          <Button
                            variant="primary"
                            type="submit"
                            disabled={closingId === period.periodId}
                          >
                            {closingId === period.periodId
                              ? m.ledger_admin_closing()
                              : m.ledger_admin_close_submit()}
                          </Button>
                          <Button type="button" onclick={cancelClose}>
                            {m.ledger_admin_cancel()}
                          </Button>
                        </div>
                      </form>
                    {:else}
                      <Button type="button" onclick={() => startClose(period)}>
                        {m.ledger_admin_close()}
                      </Button>
                    {/if}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}

      <form class="kran-form" onsubmit={submitOpen} novalidate>
        <h3 class="kran-section__title">{m.ledger_admin_open_legend()}</h3>
        <div class="kran-field">
          <label class="kran-label" for="ledger-open-starts">
            {m.ledger_admin_open_starts_label()}
          </label>
          <input
            class="kran-input"
            id="ledger-open-starts"
            type="date"
            bind:value={openStarts}
            aria-invalid={openError?.field === "startsOn" ? "true" : undefined}
            aria-describedby={openError?.field === "startsOn" ? "ledger-open-starts-error" : undefined}
          />
          {#if openError?.field === "startsOn"}
            <p class="kran-alert" id="ledger-open-starts-error" role="alert">
              {openError.message}
            </p>
          {/if}
        </div>
        <div class="kran-field">
          <label class="kran-label" for="ledger-open-ends">
            {m.ledger_admin_open_ends_label()}
          </label>
          <input
            class="kran-input"
            id="ledger-open-ends"
            type="date"
            bind:value={openEnds}
            aria-invalid={openError?.field === "endsOn" ? "true" : undefined}
            aria-describedby={openError?.field === "endsOn" ? "ledger-open-ends-error" : undefined}
          />
          {#if openError?.field === "endsOn"}
            <p class="kran-alert" id="ledger-open-ends-error" role="alert">
              {openError.message}
            </p>
          {/if}
        </div>
        <div class="kran-actions">
          <Button variant="primary" type="submit" disabled={opening}>
            {opening ? m.ledger_admin_opening() : m.ledger_admin_open_submit()}
          </Button>
        </div>
      </form>
    </section>
  {/if}

  {#if canManageCoa}
    <section class="kran-section" aria-labelledby="ledger-admin-coa-heading">
      <h2 class="kran-section__title" id="ledger-admin-coa-heading">
        {m.ledger_admin_coa_heading()}
      </h2>
      <p class="kran-muted">{m.ledger_admin_coa_intro()}</p>

      {#if accounts.length === 0}
        <EmptyState title={m.ledger_admin_coa_empty()} />
      {:else}
        <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
        <div
          class="kran-table-wrap"
          role="region"
          tabindex="0"
          aria-label={m.common_table_region({ name: m.ledger_admin_coa_heading() })}
        >
          <table class="kran-table">
            <caption class="kran-visually-hidden">{m.ledger_admin_coa_caption()}</caption>
            <thead>
              <tr>
                <th scope="col">{m.ledger_admin_coa_col_code()}</th>
                <th scope="col">{m.ledger_admin_coa_col_name()}</th>
                <th scope="col">{m.ledger_admin_coa_col_type()}</th>
                <th scope="col">{m.ledger_admin_coa_col_normal_side()}</th>
                <th scope="col">{m.ledger_admin_coa_col_postable()}</th>
              </tr>
            </thead>
            <tbody>
              {#each accounts as account (account.accountId)}
                <tr>
                  <th scope="row" class="ledger-admin-id">{account.code}</th>
                  <td>{account.name}</td>
                  <td>{coaAccountTypeLabel(account.accountType)}</td>
                  <td>
                    {account.normalSide === "DEBIT" ? m.ledger_debit() : m.ledger_credit()}
                  </td>
                  <td>
                    {account.postable
                      ? m.ledger_admin_coa_postable_yes()
                      : m.ledger_admin_coa_postable_no()}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}

      <form class="kran-form" onsubmit={submitCoa} novalidate>
        <h3 class="kran-section__title">{m.ledger_admin_coa_create_legend()}</h3>
        <div class="kran-field">
          <label class="kran-label" for="ledger-coa-code">{m.ledger_admin_coa_code_label()}</label>
          <input
            class="kran-input"
            id="ledger-coa-code"
            type="text"
            bind:value={coaCode}
            maxlength={COA_CODE_MAX_LENGTH}
            aria-invalid={coaError?.field === "code" ? "true" : undefined}
            aria-describedby={coaError?.field === "code"
              ? "ledger-coa-code-hint ledger-coa-code-error"
              : "ledger-coa-code-hint"}
          />
          <p class="kran-muted" id="ledger-coa-code-hint">{m.ledger_admin_coa_code_hint()}</p>
          {#if coaError?.field === "code"}
            <p class="kran-alert" id="ledger-coa-code-error" role="alert">
              {coaError.message}
            </p>
          {/if}
        </div>
        <div class="kran-field">
          <label class="kran-label" for="ledger-coa-name">{m.ledger_admin_coa_name_label()}</label>
          <input
            class="kran-input"
            id="ledger-coa-name"
            type="text"
            bind:value={coaName}
            maxlength={COA_NAME_MAX_LENGTH}
            aria-invalid={coaError?.field === "name" ? "true" : undefined}
            aria-describedby={coaError?.field === "name" ? "ledger-coa-name-error" : undefined}
          />
          {#if coaError?.field === "name"}
            <p class="kran-alert" id="ledger-coa-name-error" role="alert">
              {coaError.message}
            </p>
          {/if}
        </div>
        <div class="kran-field">
          <label class="kran-label" for="ledger-coa-type">{m.ledger_admin_coa_type_label()}</label>
          <select
            class="kran-select"
            id="ledger-coa-type"
            bind:value={coaType}
            aria-invalid={coaError?.field === "accountType" ? "true" : undefined}
            aria-describedby={coaError?.field === "accountType" ? "ledger-coa-type-error" : undefined}
          >
            <option value="">{m.ledger_admin_coa_type_placeholder()}</option>
            {#each ACCOUNT_TYPES as type (type)}
              <option value={type}>{coaAccountTypeLabel(type)}</option>
            {/each}
          </select>
          {#if coaError?.field === "accountType"}
            <p class="kran-alert" id="ledger-coa-type-error" role="alert">
              {coaError.message}
            </p>
          {/if}
        </div>
        <div class="kran-field">
          <div class="kran-actions">
            <input
              class="ledger-admin-checkbox"
              id="ledger-coa-postable"
              type="checkbox"
              bind:checked={coaPostable}
              aria-describedby="ledger-coa-postable-hint"
            />
            <label class="kran-label" for="ledger-coa-postable">
              {m.ledger_admin_coa_postable_label()}
            </label>
          </div>
          <p class="kran-muted" id="ledger-coa-postable-hint">
            {m.ledger_admin_coa_postable_hint()}
          </p>
        </div>
        <div class="kran-actions">
          <Button variant="primary" type="submit" disabled={creating}>
            {creating ? m.ledger_admin_coa_creating() : m.ledger_admin_coa_submit()}
          </Button>
        </div>
      </form>
    </section>
  {/if}

  {#if canReverse}
    <section class="kran-section" aria-labelledby="ledger-admin-reverse-heading">
      <h2 class="kran-section__title" id="ledger-admin-reverse-heading">
        {m.ledger_admin_reverse_heading()}
      </h2>
      <p class="kran-muted">{m.ledger_admin_reverse_intro()}</p>

      <form class="kran-form" onsubmit={submitReverse} novalidate>
        <div class="kran-field">
          <label class="kran-label" for="ledger-reverse-journal">
            {m.ledger_admin_reverse_journal_label()}
          </label>
          <input
            class="kran-input"
            id="ledger-reverse-journal"
            type="text"
            bind:value={reverseJournalId}
            oninput={resetReverseKey}
            aria-invalid={reverseError?.field === "journalId" ? "true" : undefined}
            aria-describedby={reverseError?.field === "journalId"
              ? "ledger-reverse-journal-hint ledger-reverse-journal-error"
              : "ledger-reverse-journal-hint"}
          />
          <p class="kran-muted" id="ledger-reverse-journal-hint">
            {m.ledger_admin_reverse_journal_hint()}
          </p>
          {#if reverseError?.field === "journalId"}
            <p class="kran-alert" id="ledger-reverse-journal-error" role="alert">
              {reverseError.message}
            </p>
          {/if}
        </div>

        {#if canReadJournals}
          {#if journals.length === 0}
            <p class="kran-muted">{m.ledger_admin_reverse_empty()}</p>
          {:else}
            <div class="kran-field">
              <label class="kran-label" for="ledger-reverse-pick">
                {m.ledger_admin_reverse_pick_label()}
              </label>
              <select
                class="kran-select"
                id="ledger-reverse-pick"
                value={reverseJournalId}
                onchange={(event) => pickJournal(event.currentTarget.value)}
              >
                <option value="">{m.ledger_admin_reverse_pick_placeholder()}</option>
                {#each journals as journal (journal.journalId)}
                  <option value={journal.journalId}>
                    {formatDate(journal.businessDate)} · {journal.sourceEvent} · {journal.journalId}
                  </option>
                {/each}
              </select>
            </div>
          {/if}
        {/if}

        <div class="kran-field">
          <label class="kran-label" for="ledger-reverse-reason">
            {m.ledger_admin_reverse_reason_label()}
          </label>
          <input
            class="kran-input"
            id="ledger-reverse-reason"
            type="text"
            bind:value={reverseReason}
            oninput={resetReverseKey}
            maxlength={REASON_MAX_LENGTH}
            aria-invalid={reverseError?.field === "reason" ? "true" : undefined}
            aria-describedby={reverseError?.field === "reason" ? "ledger-reverse-reason-error" : undefined}
          />
          {#if reverseError?.field === "reason"}
            <p class="kran-alert" id="ledger-reverse-reason-error" role="alert">
              {reverseError.message}
            </p>
          {/if}
        </div>

        <div class="kran-actions">
          <Button variant="primary" type="submit" disabled={reversing}>
            {reversing ? m.ledger_admin_reversing() : m.ledger_admin_reverse_submit()}
          </Button>
        </div>
      </form>
    </section>
  {/if}
{/if}

<style>
  /* Layar-saja: kolom kode memakai digit tetap agar kode akun sejajar, dan target checkbox
   * minimal 24 px (DESIGN §4). Aturan visual lain milik lapisan bersama. */
  .ledger-admin-id {
    font-variant-numeric: tabular-nums slashed-zero;
  }

  .ledger-admin-checkbox {
    inline-size: var(--control-min-size);
    block-size: var(--control-min-size);
  }
</style>
