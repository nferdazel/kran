<script lang="ts">
  /**
   * Layar kerja teller (T-088d): setor, tarik, dan pemindahbukuan (PB) pada satu rekening simpanan.
   *
   * Arah visual (DESIGN §1/§4): satu bidang kerja, bukan dashboard. Kiri = rekening (nomor, status,
   * saldo saat dimuat); kanan = transaksi. Bidang kanan turun ke bawah di layar < 1100 px, bukan jadi
   * modal (DESIGN §4). Angka memakai `formatMoney` 2 desimal + `tabular-nums`; simbol mata uang ada di
   * label/kolom, bukan di sel (DESIGN §6).
   *
   * Konfirmasi transaksi finansial memakai **tinjauan inline satu lapisan**, bukan modal (keputusan
   * pemilik pada brief §8/Q3; menyimpang dari DESIGN §7 yang melarang konfirmasi untuk aksi rutin).
   *
   * TODO(T-105): `accountId` masih diisi UUID manual karena endpoint cari-nomor-rekening belum ada.
   * Ganti input ini dengan pencarian nomor rekening begitu backend menyediakannya.
   */
  import { goto } from "$app/navigation";
  import { page } from "$app/state";
  import { onMount, tick } from "svelte";

  import type { Problem } from "@kran/api-client";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatClock, formatDate, formatMoney } from "#lib/app/format.js";
  import {
    NARRATION_MAX_LENGTH,
    cashIdentity,
    isAccountId,
    loadDepositAccount,
    newIdempotencyKey,
    postCashTransaction,
    postTransfer,
    previewAmount,
    tellerProblemMessage,
    transferIdentity,
    validateCashForm,
    validateTransferForm,
    type CashDirection,
    type CashTransaction,
    type DepositAccount,
    type TellerField,
    type TellerFormError,
    type TellerMode,
    type Transfer,
  } from "#lib/app/teller.js";
  import type { PageProps } from "./$types";

  type PendingCash = {
    kind: "cash";
    direction: CashDirection;
    accountId: string;
    amount: string;
    narration: string;
  };

  type PendingTransfer = {
    kind: "transfer";
    sourceAccountId: string;
    destinationAccountId: string;
    amount: string;
    narration: string;
  };

  type Pending = PendingCash | PendingTransfer;

  type TellerResult =
    | { kind: "cash"; transaction: CashTransaction }
    | { kind: "transfer"; transfer: Transfer };

  let { data }: PageProps = $props();

  const canPost = $derived(data.session.permissions.includes("teller.transaction.post"));

  // Rekening.
  let accountIdInput = $state("");
  let account = $state<DepositAccount | null>(null);
  let accountLoading = $state(false);
  let accountError = $state("");
  let loadedAtMs = $state<number | null>(null);

  // Form transaksi.
  let mode = $state<TellerMode>("DEPOSIT");
  let destinationInput = $state("");
  let amountRaw = $state("");
  let narration = $state("");

  // Alur: form → tinjauan → hasil. Galat tidak memindahkan halaman (DESIGN §7/§8).
  let phase = $state<"edit" | "review" | "done">("edit");
  let pending = $state<Pending | null>(null);
  let result = $state<TellerResult | null>(null);
  let saving = $state(false);
  let fieldError = $state<TellerFormError | null>(null);
  let transactionError = $state("");
  let errorTrace = $state("");
  let errorKind = $state<"none" | "failed" | "unknown">("none");
  let announcement = $state("");

  /**
   * Kunci idempotensi per sidik isi form. Dipertahankan saat gagal 5xx/jaringan supaya "Coba lagi"
   * jadi replay 200, bukan transaksi kedua (D-098/D-117); dibuang setelah sukses atau setelah 4xx.
   */
  let idempotencyKey = $state("");
  let idempotencyIdentity = $state("");

  let accountInputEl = $state<HTMLInputElement | undefined>(undefined);
  let destinationEl = $state<HTMLInputElement | undefined>(undefined);
  let amountEl = $state<HTMLInputElement | undefined>(undefined);
  let narrationEl = $state<HTMLInputElement | undefined>(undefined);
  let reviewHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let successHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let errorAlertEl = $state<HTMLParagraphElement | undefined>(undefined);

  const modeOptions = $derived<{ value: TellerMode; label: string }[]>([
    { value: "DEPOSIT", label: m.teller_direction_deposit() },
    { value: "WITHDRAWAL", label: m.teller_direction_withdrawal() },
    { value: "TRANSFER", label: m.teller_direction_transfer() },
  ]);

  const amountPreview = $derived(previewAmount(amountRaw));
  const amountPreviewText = $derived(
    amountPreview === "" ? "" : formatMoney(amountPreview, { decimals: 2 }),
  );
  const loadedAtText = $derived(loadedAtMs === null ? "" : formatClock(new Date(loadedAtMs)));
  const accountBalanceText = $derived(
    account === null ? "" : formatMoney(account.balance, { decimals: 2 }),
  );

  function modeLabel(value: TellerMode): string {
    if (value === "DEPOSIT") return m.teller_direction_deposit();
    if (value === "WITHDRAWAL") return m.teller_direction_withdrawal();
    return m.teller_direction_transfer();
  }

  /** Tanda arah ditulis sebagai tanda + kata, bukan warna saja (DESIGN §6, spec §15.4). */
  function amountWithSign(direction: CashDirection, amount: string): string {
    return `${direction === "DEPOSIT" ? "+" : "-"}${formatMoney(amount, { decimals: 2 })}`;
  }

  function cashIdentityOf(value: PendingCash): string {
    return cashIdentity({
      accountId: value.accountId,
      direction: value.direction,
      amount: value.amount,
      narration: value.narration,
    });
  }

  function transferIdentityOf(value: PendingTransfer): string {
    return transferIdentity({
      sourceAccountId: value.sourceAccountId,
      destinationAccountId: value.destinationAccountId,
      amount: value.amount,
      narration: value.narration,
    });
  }

  /** Kunci baru hanya bila sidik isi berubah, sehingga "Ubah" lalu "Tinjau" tidak membuat isu baru. */
  function ensureIdempotencyKey(value: Pending): void {
    const identity = value.kind === "cash" ? cashIdentityOf(value) : transferIdentityOf(value);
    if (idempotencyKey === "" || idempotencyIdentity !== identity) {
      idempotencyKey = newIdempotencyKey();
      idempotencyIdentity = identity;
    }
  }

  /** Bersihkan hasil/kesalahan dan kunci, tanpa menyentuh isian yang sedang diketik. */
  function resetOutcome(): void {
    phase = "edit";
    pending = null;
    result = null;
    fieldError = null;
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    idempotencyKey = "";
    idempotencyIdentity = "";
  }

  async function focusField(field: TellerField): Promise<void> {
    await tick();
    if (field === "accountId") accountInputEl?.focus();
    else if (field === "destinationAccountId") destinationEl?.focus();
    else if (field === "narration") narrationEl?.focus();
    else amountEl?.focus();
  }

  async function loadAccount(): Promise<void> {
    if (accountLoading) return;
    accountError = "";
    announcement = "";
    const id = accountIdInput.trim();
    if (id === "") {
      accountError = m.teller_error_account_required();
      await focusField("accountId");
      return;
    }
    if (!isAccountId(id)) {
      accountError = m.teller_error_account_invalid();
      await focusField("accountId");
      return;
    }

    accountLoading = true;
    try {
      const { data: body, response, error } = await loadDepositAccount(id);
      if (response.status === 401) {
        await goto("/login");
        return;
      }
      if (!response.ok || !body) {
        account = null;
        loadedAtMs = null;
        accountError = api.isProblem(error) ? tellerProblemMessage(error as Problem) : m.teller_not_found();
        resetOutcome();
        return;
      }
      account = body;
      loadedAtMs = Date.now();
      resetOutcome();
    } catch {
      account = null;
      loadedAtMs = null;
      accountError = m.error_generic();
    } finally {
      accountLoading = false;
    }
  }

  async function reviewTransaction(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (account === null) return;
    fieldError = null;
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    announcement = "";

    if (mode === "TRANSFER") {
      const check = validateTransferForm({
        sourceAccountId: account.accountId,
        destinationAccountId: destinationInput,
        amountRaw,
        narration,
      });
      if (!check.ok) {
        fieldError = check.error;
        await focusField(check.error.field);
        return;
      }
      pending = {
        kind: "transfer",
        sourceAccountId: check.sourceAccountId,
        destinationAccountId: check.destinationAccountId,
        amount: check.amount,
        narration: check.narration,
      };
    } else {
      const check = validateCashForm({ accountId: account.accountId, amountRaw, narration });
      if (!check.ok) {
        fieldError = check.error;
        await focusField(check.error.field);
        return;
      }
      pending = {
        kind: "cash",
        direction: mode,
        accountId: check.accountId,
        amount: check.amount,
        narration: check.narration,
      };
    }

    ensureIdempotencyKey(pending);
    phase = "review";
    await tick();
    reviewHeadingEl?.focus();
  }

  async function saveTransaction(): Promise<void> {
    if (saving || pending === null || idempotencyKey === "") return;
    const reviewed = pending;
    saving = true;
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    announcement = "";

    try {
      const outcome =
        reviewed.kind === "cash"
          ? await postCashTransaction(
              {
                accountId: reviewed.accountId,
                direction: reviewed.direction,
                amount: reviewed.amount,
                ...(reviewed.narration === "" ? {} : { narration: reviewed.narration }),
              },
              idempotencyKey,
            )
          : await postTransfer(
              {
                sourceAccountId: reviewed.sourceAccountId,
                destinationAccountId: reviewed.destinationAccountId,
                amount: reviewed.amount,
                ...(reviewed.narration === "" ? {} : { narration: reviewed.narration }),
              },
              idempotencyKey,
            );

      if (outcome.response.status === 401) {
        await goto("/login");
        return;
      }

      if (!outcome.response.ok || !outcome.data) {
        const problem = outcome.error;
        errorTrace = api.isProblem(problem) ? (problem as Problem).traceId : "";
        transactionError = api.isProblem(problem) ? tellerProblemMessage(problem as Problem) : m.error_generic();
        errorKind = "failed";
        if (outcome.response.status < 500) {
          // Isi permintaan tidak akan pernah valid tanpa perubahan: kunci dibuang, kembali ke form.
          idempotencyKey = "";
          idempotencyIdentity = "";
          pending = null;
          phase = "edit";
        }
        await tick();
        errorAlertEl?.focus();
        return;
      }

      // Sukses (201, atau 200 replay): saldo dari respons, bukan hitungan lokal (brief §3.4).
      if (reviewed.kind === "cash") {
        const transaction = outcome.data as CashTransaction;
        result = { kind: "cash", transaction };
        announcement = m.teller_success_status({
          balance: formatMoney(transaction.balanceAfter, { decimals: 2 }),
        });
      } else {
        const transfer = outcome.data as Transfer;
        result = { kind: "transfer", transfer };
        announcement = m.teller_success_status({
          balance: formatMoney(transfer.sourceBalanceAfter, { decimals: 2 }),
        });
      }
      idempotencyKey = "";
      idempotencyIdentity = "";
      pending = null;
      phase = "done";
      await tick();
      successHeadingEl?.focus();
    } catch {
      // Jaringan/gangguan: status belum pasti. Kunci dipertahankan; "Coba lagi" = replay.
      errorKind = "unknown";
      transactionError = "";
      announcement = "";
      await tick();
      errorAlertEl?.focus();
    } finally {
      saving = false;
    }
  }

  async function cancelReview(): Promise<void> {
    if (phase !== "review") return;
    // Kunci tidak dibuang: bila isi form tidak berubah, "Tinjau" lagi memakai kunci yang sama.
    pending = null;
    phase = "edit";
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    await tick();
    amountEl?.focus();
  }

  async function startNext(): Promise<void> {
    resetOutcome();
    amountRaw = "";
    narration = "";
    announcement = "";
    await tick();
    amountEl?.focus();
  }

  async function copyText(value: string): Promise<void> {
    try {
      await navigator.clipboard.writeText(value);
      announcement = m.teller_copied();
    } catch {
      announcement = "";
    }
  }

  function saveFromReview(event: SubmitEvent): void {
    event.preventDefault();
    void saveTransaction();
  }

  function onWindowKeydown(event: KeyboardEvent): void {
    // Esc = batal pada tinjauan (brief §2.2), bukan saat status transaksi belum pasti.
    if (event.key === "Escape" && phase === "review" && errorKind !== "unknown") {
      event.preventDefault();
      void cancelReview();
      return;
    }
    // TODO(T-095): pintasan papan tunai (F2 cari anggota, F4 setor, F5 tarik, F9 PB) akan dibaca dari
    // parameter `platform.ui.shortcut.<action>`. Belum diikat di sini: role teller belum boleh membaca
    // parameter platform, dan tombol tidak boleh dikarang sebagai konstanta yang mengaku terkonfigurasi.
  }

  onMount(() => {
    if (!canPost) return;
    // Deep link `?accountId=` (brief §2.4): layar bisa dibuka dari tautan rekening.
    const deepLinkId = page.url.searchParams.get("accountId");
    if (deepLinkId !== null && deepLinkId.trim() !== "") {
      accountIdInput = deepLinkId.trim();
      void loadAccount();
    }
  });
</script>

<svelte:window onkeydown={onWindowKeydown} />

<svelte:head>
  <title>{m.common_app_title()} — {m.teller_title()}</title>
</svelte:head>

<div class="teller-head">
  <h1 class="teller-title">{m.teller_title()}</h1>
  <p class="teller-intro">{m.teller_intro()}</p>
</div>

{#if !canPost}
  <p class="kran-alert" role="alert">{m.teller_denied()}</p>
{:else}
  <div class="teller-work">
    <section class="teller-panel" aria-labelledby="teller-account-heading">
      <h2 id="teller-account-heading">{m.teller_account_heading()}</h2>

      <div class="kran-field">
        <label class="kran-label" for="teller-account-id">{m.teller_account_id_label()}</label>
        <input
          class="kran-input teller-uuid"
          id="teller-account-id"
          name="accountId"
          bind:this={accountInputEl}
          bind:value={accountIdInput}
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          aria-describedby="teller-account-id-hint"
        />
        <p class="kran-muted" id="teller-account-id-hint">{m.teller_account_id_hint()}</p>
      </div>

      <p>
        <button
          class="kran-button"
          type="button"
          onclick={() => void loadAccount()}
          disabled={accountLoading}
        >
          {m.teller_account_load()}
        </button>
      </p>

      {#if accountLoading}
        <p role="status">{m.teller_account_loading()}</p>
      {:else if accountError !== ""}
        <p class="kran-alert" role="alert">{accountError}</p>
      {:else if account !== null}
        {@const loaded = account}
        <dl class="teller-facts">
          <dt>{m.teller_account_no_label()}</dt>
          <dd class="teller-id">{loaded.accountNo}</dd>
          <dt>{m.teller_account_status_label()}</dt>
          <dd>
            <span class={loaded.status === "ACTIVE" ? "kran-status kran-status--ok" : "kran-status"}>
              <span class="kran-status__icon" aria-hidden="true"
                >{loaded.status === "ACTIVE" ? "✔" : "○"}</span
              >
              {loaded.status === "ACTIVE"
                ? m.teller_account_status_active()
                : m.teller_account_status_closed()}
            </span>
          </dd>
          <dt>{m.teller_account_balance_label()}</dt>
          <dd class="kran-money">{accountBalanceText}</dd>
        </dl>
        {#if loadedAtText !== ""}
          <p class="kran-muted">{m.teller_account_balance_at({ time: loadedAtText })}</p>
        {/if}
      {:else}
        <p>{m.teller_account_none()}</p>
        <p class="kran-muted">{m.teller_account_none_hint()}</p>
      {/if}
    </section>

    <section class="teller-panel" aria-labelledby="teller-transaction-heading">
      <h2 id="teller-transaction-heading">{m.teller_transaction_heading()}</h2>

      {#if account === null}
        <p class="kran-muted">{m.teller_transaction_need_account()}</p>
      {:else if phase === "done" && result !== null}
        {@const done = result}
        <section aria-labelledby="teller-result-heading">
          <!-- Fokus dipindah ke judul hasil setelah simpan (brief §2.1). -->
          <h3
            id="teller-result-heading"
            class="teller-subheading"
            tabindex="-1"
            bind:this={successHeadingEl}
          >
            {m.teller_success_heading()}
          </h3>

          {#if done.kind === "cash"}
            {@const transaction = done.transaction}
            <dl class="teller-facts">
              <dt>{m.teller_direction_label()}</dt>
              <dd>{modeLabel(transaction.direction)}</dd>
              <dt>{m.teller_amount_label()}</dt>
              <dd class="kran-money">{amountWithSign(transaction.direction, transaction.amount)}</dd>
              <dt>{m.teller_balance_after()}</dt>
              <dd class="kran-money">{formatMoney(transaction.balanceAfter, { decimals: 2 })}</dd>
              <dt>{m.teller_transaction_id()}</dt>
              <dd class="teller-copyable">
                <span class="teller-id">{transaction.transactionId}</span>
                <button
                  class="kran-button"
                  type="button"
                  onclick={() => void copyText(transaction.transactionId)}
                >
                  {m.teller_copy()}
                </button>
              </dd>
              <dt>{m.teller_journal_id()}</dt>
              <dd class="teller-copyable">
                <span class="teller-id">{transaction.journalId}</span>
                <button
                  class="kran-button"
                  type="button"
                  onclick={() => void copyText(transaction.journalId)}
                >
                  {m.teller_copy()}
                </button>
              </dd>
              <dt>{m.teller_business_date()}</dt>
              <dd>{formatDate(transaction.businessDate)}</dd>
            </dl>
          {:else}
            {@const transfer = done.transfer}
            <dl class="teller-facts">
              <dt>{m.teller_direction_label()}</dt>
              <dd>{modeLabel("TRANSFER")}</dd>
              <dt>{m.teller_amount_label()}</dt>
              <dd class="kran-money">{formatMoney(transfer.amount, { decimals: 2 })}</dd>
              <dt>{m.teller_balance_after()}</dt>
              <dd class="kran-money">{formatMoney(transfer.sourceBalanceAfter, { decimals: 2 })}</dd>
              <dt>{m.teller_destination_balance_after()}</dt>
              <dd class="kran-money">
                {formatMoney(transfer.destinationBalanceAfter, { decimals: 2 })}
              </dd>
              <dt>{m.teller_transaction_id()}</dt>
              <dd class="teller-copyable">
                <span class="teller-id">{transfer.transferId}</span>
                <button
                  class="kran-button"
                  type="button"
                  onclick={() => void copyText(transfer.transferId)}
                >
                  {m.teller_copy()}
                </button>
              </dd>
              <dt>{m.teller_journal_id()}</dt>
              <dd class="teller-copyable">
                <span class="teller-id">{transfer.journalId}</span>
                <button
                  class="kran-button"
                  type="button"
                  onclick={() => void copyText(transfer.journalId)}
                >
                  {m.teller_copy()}
                </button>
              </dd>
              <dt>{m.teller_business_date()}</dt>
              <dd>{formatDate(transfer.businessDate)}</dd>
            </dl>
          {/if}

          <p>
            <button class="kran-button kran-button--primary" type="button" onclick={() => void startNext()}>
              {m.teller_next()}
            </button>
          </p>
        </section>
      {:else if phase === "review" && pending !== null}
        {@const review = pending}
        <section aria-labelledby="teller-review-heading">
          <!-- Fokus dipindah ke judul tinjauan setelah "Tinjau" (brief §2.1). -->
          <h3
            id="teller-review-heading"
            class="teller-subheading"
            tabindex="-1"
            bind:this={reviewHeadingEl}
          >
            {m.teller_review_heading()}
          </h3>

          <dl class="teller-facts">
            <dt>{m.teller_direction_label()}</dt>
            <dd>{review.kind === "cash" ? modeLabel(review.direction) : modeLabel("TRANSFER")}</dd>
            <dt>{m.teller_account_heading()}</dt>
            <dd class="teller-id">{account.accountNo}</dd>
            {#if review.kind === "transfer"}
              <dt>{m.teller_destination_label()}</dt>
              <dd class="teller-id">{review.destinationAccountId}</dd>
            {/if}
            <dt>{m.teller_amount_label()}</dt>
            <dd class="kran-money">{formatMoney(review.amount, { decimals: 2 })}</dd>
            {#if review.narration !== ""}
              <dt>{m.teller_narration_label()}</dt>
              <dd>{review.narration}</dd>
            {/if}
          </dl>

          {#if loadedAtText !== ""}
            <p class="kran-muted">
              {m.teller_review_balance({ time: loadedAtText, balance: accountBalanceText })}
            </p>
          {/if}

          <p class="kran-muted teller-reference">
            <span>{m.teller_reference_label()}:</span>
            <span class="teller-id">{idempotencyKey}</span>
            <button class="kran-button" type="button" onclick={() => void copyText(idempotencyKey)}>
              {m.teller_copy()}
            </button>
          </p>
          <p class="kran-muted">{m.teller_reference_hint()}</p>

          {#if errorKind === "unknown"}
            <!-- Status belum pasti: jangan tawarkan "Ubah" supaya nominal tidak diubah (brief §3.5). -->
            <p class="kran-alert" role="alert" tabindex="-1" bind:this={errorAlertEl}>
              {m.teller_error_unknown_state()}
            </p>
            <p>
              <button
                class="kran-button kran-button--primary"
                type="button"
                disabled={saving}
                onclick={() => void saveTransaction()}
              >
                {saving ? m.teller_saving() : m.teller_retry()}
              </button>
            </p>
          {:else}
            {#if transactionError !== ""}
              <p class="kran-alert" role="alert" tabindex="-1" bind:this={errorAlertEl}>
                {transactionError}
                {#if errorTrace !== ""}<span> {m.teller_error_with_trace({ trace: errorTrace })}</span>{/if}
              </p>
            {/if}
            <form class="teller-actions" onsubmit={(event) => void saveFromReview(event)}>
              <button
                class="kran-button kran-button--primary"
                type="submit"
                disabled={saving}
              >
                {saving ? m.teller_saving() : m.teller_save()}
              </button>
              <button class="kran-button" type="button" onclick={() => void cancelReview()}>
                {m.teller_change()}
              </button>
            </form>
          {/if}
        </section>
      {:else}
        {#if fieldError !== null}
          <p class="kran-alert" id="teller-field-error" role="alert">{fieldError.message}</p>
        {/if}

        {#if transactionError !== ""}
          <p class="kran-alert" role="alert" tabindex="-1" bind:this={errorAlertEl}>
            {transactionError}
            {#if errorTrace !== ""}<span> {m.teller_error_with_trace({ trace: errorTrace })}</span>{/if}
          </p>
        {/if}

        <form class="kran-form teller-form" onsubmit={(event) => void reviewTransaction(event)} novalidate>
          <fieldset class="teller-fieldset">
            <legend class="kran-label">{m.teller_direction_label()}</legend>
            <div class="kran-radio-group">
              {#each modeOptions as option (option.value)}
                <label class="kran-radio">
                  <input type="radio" name="teller-mode" value={option.value} bind:group={mode} />
                  <span>{option.label}</span>
                </label>
              {/each}
            </div>
          </fieldset>

          {#if mode === "TRANSFER"}
            <div class="kran-field">
              <label class="kran-label" for="teller-destination">{m.teller_destination_label()}</label>
              <input
                class="kran-input teller-uuid"
                id="teller-destination"
                name="destinationAccountId"
                bind:this={destinationEl}
                bind:value={destinationInput}
                autocomplete="off"
                autocapitalize="off"
                spellcheck="false"
                aria-invalid={fieldError?.field === "destinationAccountId" ? "true" : undefined}
                aria-describedby={fieldError?.field === "destinationAccountId"
                  ? "teller-destination-hint teller-field-error"
                  : "teller-destination-hint"}
              />
              <p class="kran-muted" id="teller-destination-hint">{m.teller_account_id_hint()}</p>
            </div>
          {/if}

          <div class="kran-field">
            <label class="kran-label" for="teller-amount">{m.teller_amount_label()}</label>
            <input
              class="kran-input teller-money-input"
              id="teller-amount"
              name="amount"
              inputmode="decimal"
              bind:this={amountEl}
              bind:value={amountRaw}
              autocomplete="off"
              aria-invalid={fieldError?.field === "amount" ? "true" : undefined}
              aria-describedby={fieldError?.field === "amount"
                ? "teller-amount-hint teller-field-error"
                : "teller-amount-hint"}
            />
            <p class="kran-muted" id="teller-amount-hint">{m.teller_amount_hint()}</p>
            {#if amountPreviewText !== ""}
              <p class="teller-preview">{m.teller_amount_preview({ amount: amountPreviewText })}</p>
            {/if}
          </div>

          <div class="kran-field">
            <label class="kran-label" for="teller-narration">{m.teller_narration_label()}</label>
            <input
              class="kran-input"
              id="teller-narration"
              name="narration"
              maxlength={NARRATION_MAX_LENGTH}
              bind:this={narrationEl}
              bind:value={narration}
              autocomplete="off"
              aria-invalid={fieldError?.field === "narration" ? "true" : undefined}
              aria-describedby={fieldError?.field === "narration" ? "teller-field-error" : undefined}
            />
          </div>

          <p>
            <button class="kran-button kran-button--primary" type="submit">{m.teller_review()}</button>
          </p>
        </form>
      {/if}
    </section>
  </div>
{/if}

<p class="kran-visually-hidden" role="status" aria-live="polite">{announcement}</p>

<style>
  .teller-head {
    padding-block-end: var(--space-3);
    border-block-end: 1px solid var(--color-hairline);
    margin-block-end: var(--space-4);
  }

  .teller-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .teller-intro {
    margin: var(--space-1) 0 0;
    max-inline-size: 56ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  /* Kiri = rekening, kanan = transaksi; di bawah 1100 px panel kanan turun (DESIGN §4). */
  .teller-work {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 22rem;
    gap: var(--space-5);
    align-items: start;
  }

  .teller-panel {
    min-inline-size: 0;
  }

  .teller-panel h2 {
    margin-block-end: var(--space-3);
    font-size: var(--text-md);
    font-weight: 600;
  }

  .teller-subheading {
    margin: 0 0 var(--space-3);
    font-size: var(--text-md);
    font-weight: 600;
  }

  /* Pasangan kunci/nilai: garis rambut antar baris, tanpa zebra atau kartu (DESIGN §6). */
  .teller-facts {
    display: grid;
    grid-template-columns: minmax(0, 12rem) minmax(0, 1fr);
    gap: var(--space-2) var(--space-4);
    margin: 0 0 var(--space-3);
  }

  .teller-facts dt {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .teller-facts dd {
    margin: 0;
    min-inline-size: 0;
    overflow-wrap: anywhere;
  }

  .teller-fieldset {
    margin: 0;
    padding: 0;
    border: 0;
    display: grid;
    gap: var(--space-2);
  }

  .teller-fieldset legend {
    padding: 0;
    margin-block-end: var(--space-1);
  }

  .teller-uuid {
    font-family: var(--font-mono);
    font-size: var(--text-sm);
  }

  /* Penanda tambahan saat field salah; sinyal utamanya tetap pesan teks di ringkasan (DESIGN §7). */
  .kran-input[aria-invalid="true"] {
    border-color: var(--color-danger);
  }

  /* Nomor rekening, ID transaksi/jurnal, dan referensi: mono, tabular, boleh patah. Nilainya
   * 36 karakter atau lebih, jadi `nowrap` (seperti angka uang) akan membuat overflow mendatar. */
  .teller-id {
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }

  .teller-copyable .teller-id,
  .teller-reference .teller-id {
    min-inline-size: 0;
  }

  .teller-money-input {
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums slashed-zero;
  }

  .teller-preview {
    margin: 0;
    color: var(--color-text);
    font-size: var(--text-sm);
    font-variant-numeric: tabular-nums slashed-zero;
  }

  .teller-copyable {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
  }

  .teller-reference {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
  }

  .teller-actions {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
  }

  @media (max-width: 1100px) {
    .teller-work {
      grid-template-columns: minmax(0, 1fr);
    }
  }
</style>
