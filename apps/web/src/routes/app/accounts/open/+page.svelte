<script lang="ts">
  /**
   * Buka rekening simpanan (T-115): satu alur vertikal — cari pemilik rekening, pilih produk
   * simpanan, kirim. Cabang **mengikuti party** (tidak ada pemilih cabang): server menolak party
   * yang tidak aktif atau beda cabang, dan galatnya dipetakan ke pesan yang menunjuk sebabnya.
   *
   * Keputusan yang mengikat:
   *  - Pencarian party memakai endpoint `?query=` dengan jeda (debounce) 300 ms dan minimal 2
   *    karakter (batas kontrak); hasilnya ringkas (CIF + nama + status), tanpa KYC.
   *  - Produk disaring (`savingsProducts`): hanya `SAVINGS` berversi `ACTIVE` berlaku.
   *  - `Idempotency-Key` dibuat per sidik isi form (D-098): gagal 5xx/jaringan mempertahankannya
   *    supaya "Buka rekening" ulang jadi replay, bukan rekening kedua; sukses/4xx membuang kunci.
   */
  import { onMount, tick } from "svelte";

  import type { Problem } from "@kran/api-client";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import {
    MIN_PARTY_QUERY_LENGTH,
    accountOpenProblemMessage,
    openDepositAccount,
    partyStatusLabel,
    savingsProducts,
    searchParties,
    type DepositAccount,
    type PartySummary,
    type ProductSummary,
  } from "#lib/app/accounts.js";
  import { problemMessage } from "#lib/app/errors.js";
  import { formatMoney } from "#lib/app/format.js";
  import { newIdempotencyKey, savingsKindLabel } from "#lib/app/teller.js";
  import type { PageProps } from "./$types";

  /** Jeda pencarian (ms): nilai teknis UX, bukan aturan bisnis. */
  const SEARCH_DEBOUNCE_MS = 300;

  let { data }: PageProps = $props();
  const canManage = $derived(data.session.permissions.includes("deposit.account.manage"));

  // Pencarian pemilik rekening.
  let query = $state("");
  let results = $state<PartySummary[]>([]);
  let searching = $state(false);
  let searchError = $state("");
  let selected = $state<PartySummary | null>(null);
  let searchTimer: ReturnType<typeof setTimeout> | undefined;
  /** Permintaan pencarian yang sedang berjalan; dibatalkan saat ada ketikan baru (T-133/UI-10). */
  let searchController: AbortController | undefined;
  /**
   * Nomor urut permintaan: jawaban yang datang terlambat (mis. jaringan lambat) tidak boleh
   * menimpa hasil pencarian yang lebih baru. Abort saja tidak cukup — respons yang sudah di jalan
   * bisa tetap tiba lebih dulu daripada pembatalannya.
   */
  let searchSeq = 0;

  // Produk simpanan.
  let products = $state<ProductSummary[]>([]);
  let productsLoading = $state(true);
  let productsError = $state("");
  let productCode = $state("");

  // Kirim & hasil.
  let submitting = $state(false);
  let submitError = $state("");
  let opened = $state<DepositAccount | null>(null);
  let idempotencyKey = $state("");
  let idempotencyIdentity = $state("");

  let searchInputEl = $state<HTMLInputElement | undefined>(undefined);
  let productSelectEl = $state<HTMLSelectElement | undefined>(undefined);
  let successHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);

  const trimmedQuery = $derived(query.trim());
  const productOptions = $derived(savingsProducts(products));

  function scheduleSearch(): void {
    if (searchTimer !== undefined) clearTimeout(searchTimer);
    const term = trimmedQuery;
    if (term.length < MIN_PARTY_QUERY_LENGTH) {
      results = [];
      searchError = "";
      searching = false;
      return;
    }
    searchTimer = setTimeout(() => void runSearch(term), SEARCH_DEBOUNCE_MS);
  }

  async function runSearch(term: string): Promise<void> {
    searchController?.abort();
    const controller = new AbortController();
    searchController = controller;
    searchSeq += 1;
    const seq = searchSeq;
    searching = true;
    searchError = "";
    try {
      const { data: body, response, error } = await searchParties(term, undefined, controller.signal);
      if (seq !== searchSeq) return;
      if (!response.ok || !body) {
        results = [];
        searchError = api.isProblem(error)
          ? accountOpenProblemMessage(error as Problem)
          : m.accounts_member_error();
        return;
      }
      results = body.items;
    } catch {
      // Dibatalkan = bukan kegagalan: pengguna sudah mengetik sesuatu yang lebih baru.
      if (seq !== searchSeq || controller.signal.aborted) return;
      results = [];
      searchError = m.accounts_member_error();
    } finally {
      if (seq === searchSeq) searching = false;
    }
  }

  async function selectParty(row: PartySummary): Promise<void> {
    selected = row;
    results = [];
    searchError = "";
    idempotencyKey = "";
    idempotencyIdentity = "";
    await tick();
    productSelectEl?.focus();
  }

  async function changeMember(): Promise<void> {
    selected = null;
    query = "";
    productCode = "";
    results = [];
    searchError = "";
    await tick();
    searchInputEl?.focus();
  }

  async function loadProducts(): Promise<void> {
    productsLoading = true;
    productsError = "";
    try {
      const { data: body, response, error } = await api.GET("/api/v1/products");
      if (!response.ok || !body) {
        productsError = api.isProblem(error) ? problemMessage(error as Problem) : m.accounts_product_error();
        return;
      }
      products = body.items;
    } catch {
      productsError = m.accounts_product_error();
    } finally {
      productsLoading = false;
    }
  }

  /** Kunci baru hanya bila sidik isi (party + produk + cabang) berubah (D-098). */
  function ensureIdempotencyKey(identity: string): string {
    if (idempotencyKey === "" || idempotencyIdentity !== identity) {
      idempotencyKey = newIdempotencyKey();
      idempotencyIdentity = identity;
    }
    return idempotencyKey;
  }

  async function submit(): Promise<void> {
    if (submitting) return;
    submitError = "";
    if (selected === null) {
      submitError = m.accounts_error_member_required();
      searchInputEl?.focus();
      return;
    }
    if (productCode === "") {
      submitError = m.accounts_error_product_required();
      productSelectEl?.focus();
      return;
    }

    const party = selected;
    const identity = JSON.stringify(["account-open", party.partyId, productCode, party.branchId]);
    const key = ensureIdempotencyKey(identity);
    submitting = true;
    try {
      const { data: body, response, error } = await openDepositAccount(
        { partyId: party.partyId, productCode, branchId: party.branchId },
        key,
      );
      if (!response.ok || !body) {
        // 4xx = isi tidak akan pernah valid: kunci dibuang supaya perbaikan memulai permintaan baru.
        if (response.status >= 400 && response.status < 500) {
          idempotencyKey = "";
          idempotencyIdentity = "";
        }
        submitError = api.isProblem(error)
          ? accountOpenProblemMessage(error as Problem)
          : m.accounts_error();
        return;
      }
      opened = body;
      idempotencyKey = "";
      idempotencyIdentity = "";
      await tick();
      successHeadingEl?.focus();
    } catch {
      // Galat jaringan: kunci dipertahankan supaya mencoba ulang jadi replay, bukan rekening kedua.
      submitError = m.accounts_error();
    } finally {
      submitting = false;
    }
  }

  async function openAnother(): Promise<void> {
    opened = null;
    selected = null;
    query = "";
    productCode = "";
    results = [];
    submitError = "";
    await tick();
    searchInputEl?.focus();
  }

  onMount(() => {
    if (canManage) void loadProducts();
    // Bersihkan timer & permintaan yang masih berjalan saat layar ditinggalkan (T-133/UI-10):
    // tanpa ini, timer yatim tetap menembak setelah komponen hilang.
    return () => {
      if (searchTimer !== undefined) clearTimeout(searchTimer);
      searchController?.abort();
    };
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.accounts_title()}</title>
</svelte:head>

<div class="accounts-head">
  <div>
    <h1 class="accounts-title">{m.accounts_title()}</h1>
    <p class="accounts-intro">{m.accounts_intro()}</p>
  </div>
</div>

{#if !canManage}
  <p class="kran-alert" role="alert">{m.accounts_denied()}</p>
{:else if opened !== null}
  <section class="kran-card" aria-labelledby="accounts-success-heading">
    <h2
      id="accounts-success-heading"
      class="accounts-title"
      tabindex="-1"
      bind:this={successHeadingEl}
    >
      {m.accounts_success_heading()}
    </h2>
    <dl class="accounts-detail">
      <dt>{m.accounts_success_account_no()}</dt>
      <dd class="kran-num">{opened.accountNo}</dd>
      <dt>{m.accounts_success_balance()}</dt>
      <dd class="kran-num">{formatMoney(opened.balance, { decimals: 2 })}</dd>
    </dl>
    <div class="accounts-actions">
      <a class="kran-button" href={`/app/print/statement/${opened.accountId}`}>
        {m.accounts_success_statement()}
      </a>
      <button class="kran-button" type="button" onclick={() => void openAnother()}>
        {m.accounts_success_again()}
      </button>
    </div>
  </section>
{:else}
  <section class="kran-card" aria-labelledby="accounts-member-heading">
    <h2 id="accounts-member-heading" class="accounts-section-title">{m.accounts_member_heading()}</h2>
    {#if selected === null}
      <label class="kran-label" for="accounts-search">{m.accounts_member_search_label()}</label>
      <p class="accounts-hint" id="accounts-search-hint">{m.accounts_member_search_hint()}</p>
      <input
        class="kran-input"
        id="accounts-search"
        type="search"
        autocomplete="off"
        bind:this={searchInputEl}
        bind:value={query}
        oninput={scheduleSearch}
        aria-describedby="accounts-search-hint"
      />
      {#if searching}
        <p role="status">{m.accounts_member_searching()}</p>
      {/if}
      {#if searchError}
        <p class="kran-alert" role="alert">{searchError}</p>
      {/if}
      {#if !searching && searchError === "" && trimmedQuery.length >= MIN_PARTY_QUERY_LENGTH && results.length === 0}
        <p class="kran-muted">{m.accounts_member_empty()}</p>
      {/if}
      {#if results.length > 0}
        <ul class="accounts-results" aria-label={m.accounts_member_heading()}>
          {#each results as row (row.partyId)}
            <li>
              <button class="accounts-result" type="button" onclick={() => void selectParty(row)}>
                <span class="accounts-result-name">{row.displayName}</span>
                <span class="accounts-result-meta kran-muted">
                  {row.cif} · {partyStatusLabel(row.status)}
                </span>
              </button>
            </li>
          {/each}
        </ul>
      {/if}
    {:else}
      <p class="accounts-selected">
        {m.accounts_member_selected({ name: selected.displayName, cif: selected.cif })}
      </p>
      <dl class="accounts-detail">
        <dt>{m.accounts_branch_label()}</dt>
        <dd class="kran-num">{selected.branchId}</dd>
      </dl>
      <button class="kran-button" type="button" onclick={() => void changeMember()}>
        {m.accounts_member_change()}
      </button>
    {/if}
  </section>

  <section class="kran-card" aria-labelledby="accounts-product-heading">
    <h2 id="accounts-product-heading" class="accounts-section-title">
      {m.accounts_product_heading()}
    </h2>
    {#if productsLoading}
      <p role="status">{m.accounts_product_loading()}</p>
    {:else if productsError}
      <p class="kran-alert" role="alert">{productsError}</p>
      <button class="kran-button" type="button" onclick={() => void loadProducts()}>
        {m.app_retry()}
      </button>
    {:else if productOptions.length === 0}
      <p class="kran-muted">{m.accounts_product_empty()}</p>
    {:else}
      <label class="kran-label" for="accounts-product">{m.accounts_product_label()}</label>
      <select
        class="kran-input"
        id="accounts-product"
        bind:this={productSelectEl}
        bind:value={productCode}
      >
        <option value="">{m.accounts_product_placeholder()}</option>
        {#each productOptions as product (product.productId)}
          <option value={product.code}>
            {product.code} — {product.name}{product.savingsKind
              ? ` (${savingsKindLabel(product.savingsKind)})`
              : ""}
          </option>
        {/each}
      </select>
    {/if}
  </section>

  {#if submitError}
    <p class="kran-alert" role="alert">{submitError}</p>
  {/if}

  <button
    class="kran-button kran-button--primary"
    type="button"
    disabled={submitting || selected === null || productCode === "" || productOptions.length === 0}
    onclick={() => void submit()}
  >
    {submitting ? m.accounts_submitting() : m.accounts_submit()}
  </button>
{/if}

<style>
  .accounts-head {
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    margin-block-end: var(--space-4);
  }

  .accounts-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .accounts-intro {
    margin: var(--space-1) 0 0;
    max-inline-size: 52ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .accounts-section-title {
    margin: 0 0 var(--space-3);
    font-size: var(--text-lg);
    font-weight: 600;
  }

  .accounts-hint {
    margin: 0 0 var(--space-2);
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .accounts-results {
    list-style: none;
    margin: var(--space-3) 0 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-1);
    max-block-size: 22rem;
    overflow-y: auto;
  }

  .accounts-result {
    display: flex;
    flex-direction: column;
    inline-size: 100%;
    text-align: start;
    gap: var(--space-1);
    padding: var(--space-2) var(--space-3);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
    color: inherit;
    cursor: pointer;
  }

  .accounts-result:hover,
  .accounts-result:focus-visible {
    border-color: var(--color-accent);
  }

  .accounts-result-name {
    font-weight: 600;
  }

  .accounts-result-meta {
    font-size: var(--text-sm);
  }

  .accounts-selected {
    margin: 0 0 var(--space-3);
    font-weight: 600;
  }

  .accounts-detail {
    margin: 0 0 var(--space-3);
    display: grid;
    grid-template-columns: auto 1fr;
    gap: var(--space-1) var(--space-3);
  }

  .accounts-detail dt {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .accounts-detail dd {
    margin: 0;
  }

  .accounts-actions {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
  }
</style>
