<script lang="ts">
  /**
   * Kas besar cabang (T-121, T-241): saldo, antrean pengajuan top-up (maker), dan keputusannya
   * (checker).
   *
   * Susunan mengikuti arah T-241: saldo adalah angka rujukan di atas, lalu **antrean lebih dulu**
   * karena punya tenggat, lalu form pengajuan. Di layar lebar form berdiri di kolom kiri 480 px dan
   * antrean mengisi sisanya; di layar sempit antrean mendahului form (DESIGN §4, §11).
   *
   * Keputusan yang mengikat:
   *  - Server adalah otoritas terakhir. Layar menyaring aksi yang jelas tidak masuk akal (izin,
   *    status `PENDING`), lalu memetakan penolakan server (`params.reason`) ke pesan katalog.
   *  - Pengaju dan penyetuju adalah orang berbeda (D-132); layar tidak menyembunyikan pengajuan
   *    sendiri, tetapi server menolaknya `409 self_approval`.
   *  - Konfirmasi = satu lapisan inline (DESIGN §7), bukan `window.confirm` dan bukan modal.
   *  - Bukti top-up mengikuti format K-4 (D-134); UI hanya menyebut formatnya, tidak memeriksa isi.
   *  - Saldo dan antrean adalah dua permintaan terpisah: satu mati tidak mematikan yang lain, dan
   *    masing-masing membawa jalan pulihnya sendiri (T-241 acceptance 6).
   */
  import { onMount, tick } from "svelte";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import MoneyInput from "@kran/ui/components/MoneyInput.svelte";
  import Select from "@kran/ui/components/Select.svelte";
  import StatusBadge from "@kran/ui/components/StatusBadge.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatDateTime, formatMoney } from "#lib/app/format.js";
  import type { SessionInfo } from "#lib/app/types.js";
  import { loadBranches, type Branch } from "#lib/app/branches.js";
  import {
    approveTopUp,
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
    type TopUpField,
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
  let branchEl = $state<HTMLSelectElement | null>(null);
  let balance = $state<string | null>(null);

  let loadingBranches = $state(true);
  let loadingVault = $state(true);
  let loadingRequests = $state(true);
  /** Tiga kegagalan terpisah: cabang, saldo, antrean. Satu banner tidak boleh menyembunyikan
   *  setengah layar yang masih hidup. */
  let branchError = $state("");
  let balanceError = $state("");
  let queueError = $state("");
  let notice = $state("");
  let submittedRef = $state("");
  let actionError = $state("");

  let requests = $state<TopUpRecord[]>([]);
  let statusFilter = $state<"" | TopUpStatus>("PENDING");
  /** Label status untuk kalimat no-match; kosong berarti "Semua", yang memakai kalimat no-data. */
  const requestFilterLabel = $derived(statusFilter === "" ? "" : statusLabel(statusFilter));

  // Form pengajuan.
  let amountInput = $state("");
  let sourceInput = $state("");
  let noteInput = $state("");
  let formError = $state("");
  /** Field yang memicu `formError`; galat nominal tampil di kontrolnya, bukan di Alert. */
  let formErrorField = $state<TopUpField | null>(null);
  let amountEl = $state<HTMLInputElement | null>(null);
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
    branchError = "";
    try {
      const { data: payload, error } = await loadBranches();
      if (error) {
        branchError = vaultProblemMessage(error);
        return;
      }
      branches = payload?.items ?? [];
      const only = branches[0];
      if (branches.length === 1 && only !== undefined) {
        branchId = only.branchId;
        await loadBranchData();
      }
    } catch {
      branchError = m.error_generic();
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
    balanceError = "";
    try {
      const { data: payload, error } = await loadVault(branchId);
      if (error) {
        balance = null;
        balanceError = vaultProblemMessage(error);
        return;
      }
      balance = payload?.balance ?? null;
    } catch {
      balance = null;
      balanceError = m.error_generic();
    } finally {
      loadingVault = false;
    }
  }

  async function loadRequests(): Promise<void> {
    loadingRequests = true;
    queueError = "";
    try {
      const { data: payload, error } = await loadTopUps(
        branchId,
        statusFilter === "" ? undefined : statusFilter,
      );
      if (error) {
        queueError = vaultProblemMessage(error);
        return;
      }
      requests = payload?.items ?? [];
    } catch {
      queueError = m.error_generic();
    } finally {
      loadingRequests = false;
    }
  }

  function clearOutcome(): void {
    notice = "";
    submittedRef = "";
    actionError = "";
    formError = "";
    formErrorField = null;
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
    balanceError = "";
    queueError = "";
    await loadBranchData();
  }

  /** Keadaan "belum ada cabang dipilih": aksi memindahkan fokus ke pemilih cabang di header. */
  async function focusBranchSelect(): Promise<void> {
    await tick();
    branchEl?.focus();
  }

  async function onFilterChange(): Promise<void> {
    clearOutcome();
    await loadRequests();
  }

  /** "Hapus filter" pada keadaan no-match: kembali ke "Semua" lalu muat ulang. */
  function clearStatusFilter(): void {
    statusFilter = "";
    void onFilterChange();
  }

  async function copyReference(): Promise<void> {
    if (submittedRef === "") return;
    try {
      await navigator.clipboard.writeText(submittedRef);
    } catch {
      // Clipboard ditolak (izin peramban): nomornya tetap terbaca di layar, jadi tidak ada
      // kegagalan yang perlu ditampilkan.
    }
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
      formErrorField = checked.error.field;
      if (checked.error.field === "amount") {
        await tick();
        amountEl?.focus();
      }
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
      const { data: created, response, error } = await submitTopUp(body, formKey);
      if (!response.ok) {
        actionError = errorFrom(error);
        return;
      }
      formKey = newIdempotencyKey();
      formIdentity = "";
      amountInput = "";
      noteInput = "";
      notice = m.vault_submit_success();
      submittedRef = created?.requestId ?? "";
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
    <Select
      label={m.vault_branch_label()}
      bind:value={branchId}
      bind:element={branchEl}
      onchange={() => void onBranchChange()}
    >
      <option value="">{m.vault_branch_choose()}</option>
      {#each branches as branch (branch.branchId)}
        <option value={branch.branchId}>{branch.code} · {branch.name}</option>
      {/each}
    </Select>
  {/if}
</div>

{#if !canRead}
  <Alert tone="negative" title={m.vault_denied()} />
{:else if loadingBranches}
  <div class="vault-reserved" role="status">{m.vault_loading()}</div>
{:else if branchError !== "" && branches.length === 0}
  <Alert tone="negative" title={branchError}>
    <Button type="button" onclick={() => void loadBranchList()}>{m.app_retry()}</Button>
  </Alert>
{:else if branches.length === 0}
  {#snippet reloadBranchesAction()}
    <Button type="button" onclick={() => void loadBranchList()}>{m.app_retry()}</Button>
  {/snippet}
  <EmptyState
    kind="no-data"
    title={m.vault_branch_empty()}
    action={reloadBranchesAction}
  />
{:else if branchId === ""}
  {#snippet focusBranchAction()}
    <Button type="button" onclick={() => void focusBranchSelect()}>
      {m.vault_branch_choose()}
    </Button>
  {/snippet}
  <EmptyState
    kind="no-data"
    title={m.vault_branch_prompt()}
    description={m.vault_branch_prompt_hint()}
    action={focusBranchAction}
  />
{:else}
  {#if actionError}
    <Alert tone="negative" title={actionError} />
  {/if}
  {#if decisionError}
    <Alert tone="negative" title={decisionError} />
  {/if}
  {#if notice}
    <Alert tone="positive" title={notice} reference={submittedRef}>
      {#if submittedRef !== ""}
        <Button type="button" onclick={() => void copyReference()}>{m.vault_reference_copy()}</Button>
      {/if}
    </Alert>
  {/if}

  <!-- Angka rujukan: satu-satunya angka besar di layar ini (DESIGN §11, bukan strip metrik). -->
  <section class="kran-stat" aria-labelledby="vault-balance-heading">
    <h2 class="kran-stat__label" id="vault-balance-heading">{m.vault_balance_label()}</h2>
    <div class="vault-balance">
      {#if loadingVault}
        <p class="vault-balance__value vault-balance__value--reserved" role="status">
          {m.vault_loading()}
        </p>
      {:else if balanceError !== ""}
        <p class="vault-balance__value vault-balance__value--reserved">
          {m.vault_balance_unavailable()}
        </p>
      {:else if balance === null}
        <p class="vault-balance__value vault-balance__value--reserved">
          {m.vault_balance_missing()}
        </p>
      {:else}
        <p class="vault-balance__value">{formatMoney(balance)}</p>
      {/if}
    </div>
    {#if selectedBranch}
      <p class="kran-muted">
        {m.vault_balance_branch({ code: selectedBranch.code, name: selectedBranch.name })}
      </p>
    {/if}
    {#if balanceError !== ""}
      <!-- Saldo mati tidak mengunci pengajuan: pengajuan hanya menaruh permintaan di antrean,
           tidak memindahkan uang, jadi menonaktifkan form tidak menambah keamanan. -->
      <Alert tone="negative" title={balanceError}>
        <Button type="button" onclick={() => void loadBalance()}>{m.app_retry()}</Button>
      </Alert>
    {/if}
  </section>

  <div class="vault-columns">
    <section
      class="kran-section vault-queue-panel"
      aria-labelledby="vault-requests-heading"
    >
      <div class="kran-toolbar">
        <h2 class="kran-section__title" id="vault-requests-heading">
          {m.vault_requests_title()}
        </h2>
        <Select
          label={m.vault_filter_label()}
          bind:value={statusFilter}
          onchange={() => void onFilterChange()}
        >
          <option value="">{m.vault_filter_all()}</option>
          {#each STATUSES as status (status)}
            <option value={status}>{statusLabel(status)}</option>
          {/each}
        </Select>
      </div>

      {#if loadingRequests}
        <div class="vault-reserved" role="status">{m.vault_requests_loading()}</div>
      {:else if queueError !== ""}
        <Alert tone="negative" title={queueError}>
          <Button type="button" onclick={() => void loadRequests()}>{m.app_retry()}</Button>
        </Alert>
      {:else if requests.length === 0 && statusFilter === ""}
        <EmptyState
          kind="no-data"
          title={m.vault_requests_empty()}
          description={m.vault_requests_empty_hint()}
        />
      {:else if requests.length === 0}
        {#snippet clearStatusFilterAction()}
          <Button type="button" onclick={clearStatusFilter}>{m.common_filter_clear()}</Button>
        {/snippet}
        <EmptyState
          kind="no-match"
          title={m.vault_empty_no_match({ status: requestFilterLabel })}
          action={clearStatusFilterAction}
        />
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

    <section class="kran-section vault-form-panel" aria-labelledby="vault-submit-heading">
        <div class="kran-toolbar">
          <h2 class="kran-section__title" id="vault-submit-heading">
            {m.vault_submit_title()}
          </h2>
          {#if !canSubmit}
            <!-- Peran hanya-baca melihat batasnya sebelum mencoba, bukan setelah ditolak server. -->
            <StatusBadge tone="neutral">{m.vault_read_only_badge()}</StatusBadge>
          {/if}
        </div>
        <p class="kran-muted">{m.vault_submit_intro()}</p>
        {#if !canSubmit}
          <p class="kran-muted" id="vault-read-only-reason">{m.vault_read_only()}</p>
        {/if}
        <form class="kran-form" onsubmit={submit}>
          <MoneyInput
            label={m.vault_amount_label()}
            name="amount"
            hint={m.vault_amount_hint()}
            error={formErrorField === "amount" ? formError : ""}
            bind:element={amountEl}
            bind:value={amountInput}
            disabled={!canSubmit}
            required
          />
          <div class="kran-field">
            <label class="kran-label" for="vault-source">{m.vault_source_label()}</label>
            <input
              class="kran-input"
              id="vault-source"
              name="sourceAccount"
              autocomplete="off"
              aria-describedby="vault-source-hint"
              bind:value={sourceInput}
              disabled={!canSubmit}
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
              disabled={!canSubmit}
              required
            ></textarea>
            <p class="kran-muted" id="vault-note-hint">{m.vault_note_hint()}</p>
          </div>
          {#if formError && formErrorField !== "amount"}
            <Alert tone="negative" title={formError} />
          {/if}
          <div class="kran-actions">
            <Button
              variant="primary"
              type="submit"
              disabled={submitting || !canSubmit}
              aria-describedby={!canSubmit ? "vault-read-only-reason" : undefined}
            >
              {submitting ? m.vault_submitting() : m.vault_submit_action()}
            </Button>
          </div>
        </form>
      </section>
  </div>
{/if}

<style>
  /* Dua kolom di layar lebar (form 480 px kiri, antrean kanan); satu kolom di bawah 1100 px
   * dengan antrean tetap di atas form karena punya tenggat (DESIGN §4, arah T-241). */
  .vault-columns {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: var(--space-6);
    align-items: start;
  }

  @media (min-width: 1100px) {
    .vault-columns {
      grid-template-columns: 480px minmax(0, 1fr);
    }

    .vault-form-panel {
      grid-column: 1;
      grid-row: 1;
    }

    .vault-queue-panel {
      grid-column: 2;
      grid-row: 1;
    }
  }

  /* Tinggi dicadangkan supaya keadaan memuat tidak menggeser isi di bawahnya. */
  .vault-reserved {
    min-block-size: 40px;
  }

  .vault-balance {
    display: flex;
    align-items: baseline;
  }

  .vault-balance__value {
    font-size: 20px;
    font-weight: 600;
    font-variant-numeric: tabular-nums slashed-zero;
  }

  .vault-balance__value--reserved {
    min-block-size: 28px;
    font-size: inherit;
    font-weight: inherit;
    font-variant-numeric: normal;
  }
</style>
