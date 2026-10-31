<script lang="ts">
  /**
   * Vault kas cabang (T-121): saldo, pengajuan top-up (maker), dan keputusan (checker).
   *
   * Keputusan yang mengikat:
   *  - Server adalah otoritas terakhir. Layar menyaring aksi yang jelas tidak masuk akal (izin,
   *    status `PENDING`), lalu memetakan penolakan server (`params.reason`) ke pesan katalog.
   *  - Pengaju dan penyetuju adalah orang berbeda (D-132); layar tidak menyembunyikan pengajuan
   *    sendiri, tetapi server menolaknya `409 self_approval`.
   *  - Konfirmasi = satu lapisan inline (DESIGN §7), bukan `window.confirm` dan bukan modal.
   *  - Bukti top-up mengikuti format K-4 (D-134); UI hanya menyebut formatnya, tidak memeriksa isi.
   */
  import { onMount } from "svelte";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import StatusBadge from "@kran/ui/components/StatusBadge.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatDateTime, formatMoney } from "#lib/app/format.js";
  import type { SessionInfo } from "#lib/app/types.js";
  import {
    approveTopUp,
    loadBranches,
    loadTopUps,
    loadVault,
    newIdempotencyKey,
    NOTE_MAX_LENGTH,
    rejectTopUp,
    STATUSES,
    statusLabel,
    submitTopUp,
    topUpIdentity,
    validateTopUp,
    vaultProblemMessage,
    type Branch,
    type TopUpRecord,
    type TopUpStatus,
  } from "#lib/app/vault.js";
  import type { PageProps } from "./$types";

  let { data }: PageProps = $props();

  const session: SessionInfo = $derived(data.session);
  const canRead = $derived(session.permissions.includes("teller.vault.read"));
  const canSubmit = $derived(session.permissions.includes("teller.vault.submit"));
  const canDecide = $derived(session.permissions.includes("teller.vault.approve"));

  let branches = $state<Branch[]>([]);
  let branchId = $state("");
  let balance = $state<string | null>(null);

  let loadingBranches = $state(true);
  let loadingVault = $state(true);
  let loadingRequests = $state(true);
  let listError = $state("");
  let notice = $state("");
  let actionError = $state("");

  let requests = $state<TopUpRecord[]>([]);
  let statusFilter = $state<"" | TopUpStatus>("PENDING");

  // Form pengajuan.
  let amountInput = $state("");
  let sourceInput = $state("");
  let noteInput = $state("");
  let formError = $state("");
  let submitting = $state(false);
  let formKey = $state(newIdempotencyKey());
  let formIdentity = $state("");

  /** Baris yang panel keputusannya terbuka. */
  let deciding = $state<{ requestId: string; kind: "approve" | "reject"; key: string } | null>(null);
  let rejectReason = $state("");
  let decisionError = $state("");
  let busy = $state("");

  const selectedBranch = $derived(branches.find((branch) => branch.branchId === branchId));

  /** Warna hanya penguat; makna status tetap dari teksnya (DESIGN §1, §8). */
  function statusTone(status: TopUpStatus): "positive" | "warning" | "negative" {
    if (status === "APPROVED") return "positive";
    if (status === "REJECTED") return "negative";
    return "warning";
  }

  async function loadBranchList(): Promise<void> {
    loadingBranches = true;
    listError = "";
    try {
      const { data: payload, error } = await loadBranches();
      if (error) {
        listError = vaultProblemMessage(error);
        return;
      }
      branches = payload?.items ?? [];
      const only = branches[0];
      if (branches.length === 1 && only !== undefined) {
        branchId = only.branchId;
        await loadBranchData();
      }
    } catch {
      listError = m.error_generic();
    } finally {
      loadingBranches = false;
    }
  }

  async function loadBranchData(): Promise<void> {
    if (branchId === "") return;
    clearOutcome();
    await Promise.all([loadBalance(), loadRequests()]);
  }

  async function loadBalance(): Promise<void> {
    loadingVault = true;
    try {
      const { data: payload, error } = await loadVault(branchId);
      if (error) {
        balance = null;
        listError = vaultProblemMessage(error);
        return;
      }
      listError = "";
      balance = payload?.balance ?? null;
    } catch {
      balance = null;
      listError = m.error_generic();
    } finally {
      loadingVault = false;
    }
  }

  async function loadRequests(): Promise<void> {
    loadingRequests = true;
    try {
      const { data: payload, error } = await loadTopUps(
        branchId,
        statusFilter === "" ? undefined : statusFilter,
      );
      if (error) {
        listError = vaultProblemMessage(error);
        return;
      }
      requests = payload?.items ?? [];
    } catch {
      listError = m.error_generic();
    } finally {
      loadingRequests = false;
    }
  }

  function clearOutcome(): void {
    notice = "";
    actionError = "";
    formError = "";
    decisionError = "";
    deciding = null;
    rejectReason = "";
  }

  function errorFrom(problem: unknown): string {
    return api.isProblem(problem) ? vaultProblemMessage(problem) : m.error_generic();
  }

  async function onBranchChange(): Promise<void> {
    balance = null;
    requests = [];
    await loadBranchData();
  }

  async function onFilterChange(): Promise<void> {
    clearOutcome();
    await loadRequests();
  }

  async function submit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    clearOutcome();
    const checked = validateTopUp({
      amount: amountInput,
      sourceAccount: sourceInput,
      note: noteInput,
    });
    if (!checked.ok) {
      formError = checked.error.message;
      return;
    }
    const body = { branchId, ...checked.value };
    const identity = topUpIdentity(body);
    if (identity !== formIdentity) {
      formKey = newIdempotencyKey();
      formIdentity = identity;
    }
    submitting = true;
    try {
      const { response, error } = await submitTopUp(body, formKey);
      if (!response.ok) {
        actionError = errorFrom(error);
        return;
      }
      formKey = newIdempotencyKey();
      formIdentity = "";
      amountInput = "";
      noteInput = "";
      notice = m.vault_submit_success();
      statusFilter = "PENDING";
      await Promise.all([loadBalance(), loadRequests()]);
    } catch {
      actionError = m.error_generic();
    } finally {
      submitting = false;
    }
  }

  function startDecision(request: TopUpRecord, kind: "approve" | "reject"): void {
    clearOutcome();
    deciding = { requestId: request.requestId, kind, key: newIdempotencyKey() };
    rejectReason = "";
  }

  async function approve(): Promise<void> {
    if (deciding === null) return;
    const { requestId, key } = deciding;
    busy = requestId;
    decisionError = "";
    try {
      const { response, error } = await approveTopUp(requestId, key);
      if (!response.ok) {
        decisionError = errorFrom(error);
        return;
      }
      notice = m.vault_approve_success();
      deciding = null;
      await Promise.all([loadBalance(), loadRequests()]);
    } catch {
      decisionError = m.error_generic();
    } finally {
      busy = "";
    }
  }

  async function reject(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (deciding === null) return;
    const reason = rejectReason.trim();
    if (reason === "") {
      decisionError = m.vault_error_note_required();
      return;
    }
    busy = deciding.requestId;
    decisionError = "";
    try {
      const { response, error } = await rejectTopUp(deciding.requestId, reason);
      if (!response.ok) {
        decisionError = errorFrom(error);
        return;
      }
      notice = m.vault_reject_success();
      deciding = null;
      rejectReason = "";
      await loadRequests();
    } catch {
      decisionError = m.error_generic();
    } finally {
      busy = "";
    }
  }

  function decisionText(request: TopUpRecord): string {
    if (request.decidedAt === "" && request.decisionNote === "") return "";
    const when = request.decidedAt === "" ? "" : formatDateTime(request.decidedAt);
    if (request.decisionNote === "") return when;
    return when === "" ? request.decisionNote : `${when} · ${request.decisionNote}`;
  }

  onMount(() => {
    if (!canRead) {
      loadingBranches = false;
      loadingVault = false;
      loadingRequests = false;
      return;
    }
    void loadBranchList();
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} · {m.vault_title()}</title>
</svelte:head>

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.vault_title()}</h1>
    <p class="kran-page-header__intro">{m.vault_intro()}</p>
  </div>
  {#if canRead && branches.length > 1}
    <div class="kran-field">
      <label class="kran-label" for="vault-branch">{m.vault_branch_label()}</label>
      <select
        class="kran-select"
        id="vault-branch"
        bind:value={branchId}
        onchange={() => void onBranchChange()}
      >
        <option value="">{m.vault_branch_choose()}</option>
        {#each branches as branch (branch.branchId)}
          <option value={branch.branchId}>{branch.code} · {branch.name}</option>
        {/each}
      </select>
    </div>
  {/if}
</div>

{#if !canRead}
  <Alert tone="negative" title={m.vault_denied()} />
{:else if loadingBranches}
  <p role="status">{m.vault_loading()}</p>
{:else if listError && branches.length === 0}
  <Alert tone="negative" title={listError}>
    <Button type="button" onclick={() => void loadBranchList()}>{m.app_retry()}</Button>
  </Alert>
{:else if branches.length === 0}
  <EmptyState title={m.vault_branch_empty()} />
{:else if branchId === ""}
  <p class="kran-muted">{m.vault_branch_choose()}</p>
{:else}
  {#if listError}
    <Alert tone="negative" title={listError}>
      <Button type="button" onclick={() => void loadBranchData()}>{m.app_retry()}</Button>
    </Alert>
  {/if}
  {#if actionError}
    <Alert tone="negative" title={actionError} />
  {/if}
  {#if decisionError}
    <Alert tone="negative" title={decisionError} />
  {/if}
  {#if notice}
    <Alert tone="positive" title={notice} />
  {/if}

  <section class="kran-stat" aria-labelledby="vault-balance-heading">
    <h2 class="kran-stat__label" id="vault-balance-heading">{m.vault_balance_label()}</h2>
    {#if loadingVault}
      <p role="status">{m.vault_loading()}</p>
    {:else if balance === null}
      <p class="kran-muted">{m.vault_balance_missing()}</p>
    {:else}
      <p class="kran-stat__value">{formatMoney(balance)}</p>
    {/if}
    {#if selectedBranch}
      <p class="kran-muted">
        {m.vault_balance_branch({ code: selectedBranch.code, name: selectedBranch.name })}
      </p>
    {/if}
  </section>

  {#if !canSubmit && !canDecide}
    <p class="kran-muted">{m.vault_read_only()}</p>
  {/if}

  {#if canSubmit}
    <section class="kran-section" aria-labelledby="vault-submit-heading">
      <h2 class="kran-section__title" id="vault-submit-heading">{m.vault_submit_title()}</h2>
      <p class="kran-muted">{m.vault_submit_intro()}</p>
      <form class="kran-form" onsubmit={submit}>
        <div class="kran-field">
          <label class="kran-label" for="vault-amount">{m.vault_amount_label()}</label>
          <input
            class="kran-input"
            id="vault-amount"
            name="amount"
            inputmode="decimal"
            autocomplete="off"
            bind:value={amountInput}
            required
          />
        </div>
        <div class="kran-field">
          <label class="kran-label" for="vault-source">{m.vault_source_label()}</label>
          <input
            class="kran-input"
            id="vault-source"
            name="sourceAccount"
            autocomplete="off"
            aria-describedby="vault-source-hint"
            bind:value={sourceInput}
            required
          />
          <p class="kran-muted" id="vault-source-hint">{m.vault_source_hint()}</p>
        </div>
        <div class="kran-field">
          <label class="kran-label" for="vault-note">{m.vault_note_label()}</label>
          <textarea
            class="kran-input"
            id="vault-note"
            name="note"
            rows="2"
            maxlength={NOTE_MAX_LENGTH}
            aria-describedby="vault-note-hint"
            bind:value={noteInput}
            required
          ></textarea>
          <p class="kran-muted" id="vault-note-hint">{m.vault_note_hint()}</p>
        </div>
        {#if formError}
          <Alert tone="negative" title={formError} />
        {/if}
        <div class="kran-actions">
          <Button variant="primary" type="submit" disabled={submitting}>
            {submitting ? m.vault_submitting() : m.vault_submit_action()}
          </Button>
        </div>
      </form>
    </section>
  {/if}

  <section class="kran-section" aria-labelledby="vault-requests-heading">
    <div class="kran-toolbar">
      <h2 class="kran-section__title" id="vault-requests-heading">
        {m.vault_requests_title()}
      </h2>
      <div class="kran-field">
        <label class="kran-label" for="vault-filter">{m.vault_filter_label()}</label>
        <select
          class="kran-select"
          id="vault-filter"
          bind:value={statusFilter}
          onchange={() => void onFilterChange()}
        >
          <option value="">{m.vault_filter_all()}</option>
          {#each STATUSES as status (status)}
            <option value={status}>{statusLabel(status)}</option>
          {/each}
        </select>
      </div>
    </div>

    {#if loadingRequests}
      <p role="status">{m.vault_requests_loading()}</p>
    {:else if requests.length === 0}
      <EmptyState title={m.vault_requests_empty()} />
    {:else}
      <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
      <div
        class="kran-table-wrap"
        role="region"
        tabindex="0"
        aria-label={m.vault_requests_title()}
      >
        <table class="kran-table">
          <caption class="kran-visually-hidden">{m.vault_requests_title()}</caption>
          <thead>
            <tr>
              <th scope="col">{m.vault_col_created()}</th>
              <th scope="col" class="kran-num">{m.vault_col_amount()}</th>
              <th scope="col">{m.vault_col_source()}</th>
              <th scope="col">{m.vault_col_note()}</th>
              <th scope="col">{m.vault_col_status()}</th>
              <th scope="col">{m.vault_col_decision()}</th>
              {#if canDecide}
                <th scope="col">{m.vault_col_actions()}</th>
              {/if}
            </tr>
          </thead>
          <tbody>
            {#each requests as request (request.requestId)}
              <tr>
                <td>{formatDateTime(request.createdAt)}</td>
                <td class="kran-num">{formatMoney(request.amount)}</td>
                <td class="kran-num">{request.sourceAccount}</td>
                <td>{request.note}</td>
                <td>
                  <StatusBadge tone={statusTone(request.status)}>
                    {statusLabel(request.status)}
                  </StatusBadge>
                </td>
                <td>{decisionText(request)}</td>
                {#if canDecide}
                  <td>
                    {#if request.status === "PENDING"}
                      <div class="kran-actions">
                        <Button
                          type="button"
                          onclick={() => startDecision(request, "approve")}
                          disabled={busy !== ""}
                        >
                          {m.vault_approve_action()}
                        </Button>
                        <Button
                          type="button"
                          onclick={() => startDecision(request, "reject")}
                          disabled={busy !== ""}
                        >
                          {m.vault_reject_action()}
                        </Button>
                      </div>
                    {:else}
                      <span class="kran-muted">—</span>
                    {/if}
                  </td>
                {/if}
              </tr>

              {#if canDecide && deciding?.requestId === request.requestId}
                <tr class="kran-table__selected">
                  <td colspan={7}>
                    <div class="kran-stack kran-stack--loose">
                      {#if deciding.kind === "approve"}
                        <div class="kran-stack">
                          <p>
                            {m.vault_approve_confirm({ amount: formatMoney(request.amount) })}
                          </p>
                          <div class="kran-actions">
                            <Button
                              variant="primary"
                              type="button"
                              onclick={() => void approve()}
                              disabled={busy !== ""}
                            >
                              {m.vault_approve_confirm_action()}
                            </Button>
                            <Button
                              type="button"
                              onclick={() => (deciding = null)}
                              disabled={busy !== ""}
                            >
                              {m.vault_cancel()}
                            </Button>
                          </div>
                        </div>
                      {:else}
                        <form class="kran-form" onsubmit={reject}>
                          <label class="kran-label" for="vault-reject-reason">
                            {m.vault_reject_prompt()}
                          </label>
                          <textarea
                            class="kran-input"
                            id="vault-reject-reason"
                            rows="2"
                            bind:value={rejectReason}
                            required
                          ></textarea>
                          <div class="kran-actions">
                            <Button variant="primary" type="submit" disabled={busy !== ""}>
                              {m.vault_reject_confirm_action()}
                            </Button>
                            <Button
                              type="button"
                              onclick={() => (deciding = null)}
                              disabled={busy !== ""}
                            >
                              {m.vault_cancel()}
                            </Button>
                          </div>
                        </form>
                      {/if}
                    </div>
                  </td>
                </tr>
              {/if}
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>
{/if}
