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
   *
   * Tata letak mengikuti DESIGN §11: judul layar, bidang kerja, pesan, dan kontrol dari lapisan
   * bersama (`packages/ui`), termasuk `.kran-facts` untuk `<dl>` fakta dan `.kran-list-scroll`
   * untuk hasil pencarian. Berkas ini tidak punya CSS lokal.
   */
  import { onMount, tick } from "svelte";
  import { resolve } from "$app/paths";

  import type { Problem } from "@kran/api-client";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";

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

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.accounts_title()}</h1>
    <p class="kran-page-header__intro">{m.accounts_intro()}</p>
  </div>
</div>

{#if !canManage}
  <Alert tone="negative" title={m.accounts_denied()} />
{:else if opened !== null}
  <section class="kran-section" aria-labelledby="accounts-success-heading">
    <h2
      class="kran-section__title"
      id="accounts-success-heading"
      tabindex="-1"
      bind:this={successHeadingEl}
    >
      {m.accounts_success_heading()}
    </h2>
    <dl class="kran-facts">
      <dt class="kran-muted">{m.accounts_success_account_no()}</dt>
      <dd>{opened.accountNo}</dd>
      <dt class="kran-muted">{m.accounts_success_balance()}</dt>
      <dd>{formatMoney(opened.balance, { decimals: 2 })}</dd>
    </dl>
    <div class="kran-actions">
      <a
        class="kran-button"
        href={resolve("/app/print/statement/[accountId]", { accountId: opened.accountId })}
      >
        {m.accounts_success_statement()}
      </a>
      <Button type="button" onclick={() => void openAnother()}>
        {m.accounts_success_again()}
      </Button>
    </div>
  </section>
{:else}
  <section class="kran-section" aria-labelledby="accounts-member-heading">
    <h2 class="kran-section__title" id="accounts-member-heading">
      {m.accounts_member_heading()}
    </h2>
    {#if selected === null}
      <div class="kran-field">
        <label class="kran-label" for="accounts-search">{m.accounts_member_search_label()}</label>
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
        <p class="kran-muted" id="accounts-search-hint">{m.accounts_member_search_hint()}</p>
      </div>
      {#if searching}
        <p role="status">{m.accounts_member_searching()}</p>
      {/if}
      {#if searchError}
        <Alert tone="negative" title={searchError} />
      {/if}
      {#if !searching && searchError === "" && trimmedQuery.length >= MIN_PARTY_QUERY_LENGTH && results.length === 0}
        <p class="kran-muted">{m.accounts_member_empty()}</p>
      {/if}
      {#if results.length > 0}
        <ul class="kran-list-plain kran-list-scroll" aria-label={m.accounts_member_heading()}>
          {#each results as row (row.partyId)}
            <li>
              <Button variant="row" type="button" onclick={() => void selectParty(row)}>
                {row.displayName}
                <span class="kran-muted">{row.cif} · {partyStatusLabel(row.status)}</span>
              </Button>
            </li>
          {/each}
        </ul>
      {/if}
    {:else}
      <p>{m.accounts_member_selected({ name: selected.displayName, cif: selected.cif })}</p>
      <dl class="kran-facts">
        <dt class="kran-muted">{m.accounts_branch_label()}</dt>
        <dd>{selected.branchId}</dd>
      </dl>
      <Button type="button" onclick={() => void changeMember()}>
        {m.accounts_member_change()}
      </Button>
    {/if}
  </section>

  <section class="kran-section" aria-labelledby="accounts-product-heading">
    <h2 class="kran-section__title" id="accounts-product-heading">
      {m.accounts_product_heading()}
    </h2>
    {#if productsLoading}
      <p role="status">{m.accounts_product_loading()}</p>
    {:else if productsError}
      <Alert tone="negative" title={productsError}>
        <Button type="button" onclick={() => void loadProducts()}>{m.app_retry()}</Button>
      </Alert>
    {:else if productOptions.length === 0}
      <p class="kran-muted">{m.accounts_product_empty()}</p>
    {:else}
      <div class="kran-field">
        <label class="kran-label" for="accounts-product">{m.accounts_product_label()}</label>
        <select
          class="kran-select"
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
      </div>
    {/if}
  </section>

  {#if submitError}
    <Alert tone="negative" title={submitError} />
  {/if}

  <div class="kran-actions">
    <Button
      variant="primary"
      type="button"
      disabled={submitting || selected === null || productCode === "" || productOptions.length === 0}
      onclick={() => void submit()}
    >
      {submitting ? m.accounts_submitting() : m.accounts_submit()}
    </Button>
  </div>
{/if}

