<script lang="ts">
  /**
   * Katalog produk (spec §14.3): daftar produk + versi `ACTIVE`, dan persetujuan/penolakan versi
   * `DRAFT` oleh pemegang `product.catalog.approve` (mis. role `product_checker`).
   *
   * Keputusan yang mengikat:
   *  - `GET /api/v1/products` hanya memuat versi `ACTIVE`; versi `DRAFT`/`REJECTED` tidak pernah
   *    muncul di katalog. Approval karena itu membaca detail per produk (`GET /products/{code}`)
   *    untuk menemukan `DRAFT` — detail yang gagal dimuat dilewati, bukan menggagalkan layar.
   *  - Konfirmasi = **satu lapisan inline** (DESIGN §7), bukan `window.confirm` dan bukan modal
   *    berlapis. Aksi hanya tampil bila izin sesi memegang `product.catalog.approve`; server tetap
   *    otoritas terakhir (self-approval ditolak 409 dan dipetakan ke pesan di `products.ts`).
   *  - Tidak ada form buat/ubah produk di layar ini (di luar lingkup).
   */
  import { onMount } from "svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatDate } from "#lib/app/format.js";
  import {
    draftVersionsOf,
    productProblemMessage,
    productTypeLabel,
    type DraftVersion,
  } from "#lib/app/products.js";
  import { savingsKindLabel } from "#lib/app/teller.js";
  import type { Product, ProductSummary, SessionInfo } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  /** Batas kolom `reason` di kontrak (teknis, bukan aturan bisnis). */
  const REJECT_REASON_MAX = 500;

  let { data }: PageProps = $props();

  const session: SessionInfo = $derived(data.session);
  const canApprove = $derived(session.permissions.includes("product.catalog.approve"));

  let products = $state<ProductSummary[]>([]);
  let drafts = $state<DraftVersion[]>([]);
  let loading = $state(true);
  let errorMessage = $state("");
  let notice = $state("");
  let actionError = $state("");
  let busyId = $state("");
  /** Konfirmasi inline yang sedang terbuka; `null` = tidak ada. */
  let expanded = $state<{ versionId: string; kind: "approve" | "reject" } | null>(null);
  let rejectReason = $state("");

  async function load(showLoading = true): Promise<void> {
    if (showLoading) loading = true;
    errorMessage = "";
    try {
      const list = await api.GET("/api/v1/products");
      if (list.error) {
        errorMessage = productProblemMessage(list.error);
        return;
      }
      const items = list.data?.items ?? [];
      let details: (Product | null)[] = [];
      if (canApprove && items.length > 0) {
        const responses = await Promise.all(
          items.map((product) =>
            api.GET("/api/v1/products/{code}", { params: { path: { code: product.code } } }),
          ),
        );
        details = responses.map((response) => response.data ?? null);
      }
      products = items;
      drafts = canApprove ? draftVersionsOf(items, details) : [];
    } catch {
      errorMessage = m.products_error();
    } finally {
      loading = false;
    }
  }

  function errorFrom(problem: unknown): string {
    return api.isProblem(problem) ? productProblemMessage(problem) : m.products_error();
  }

  function startConfirm(versionId: string, kind: "approve" | "reject"): void {
    actionError = "";
    notice = "";
    rejectReason = "";
    expanded = { versionId, kind };
  }

  function cancelConfirm(): void {
    expanded = null;
    rejectReason = "";
  }

  async function approve(row: DraftVersion): Promise<void> {
    if (busyId !== "") return;
    busyId = row.version.versionId;
    actionError = "";
    notice = "";
    try {
      const { response, error } = await api.POST(
        "/api/v1/products/{code}/versions/{versionId}/approve",
        { params: { path: { code: row.product.code, versionId: row.version.versionId } } },
      );
      if (!response.ok) {
        actionError = errorFrom(error);
        return;
      }
      notice = m.products_approve_success();
      expanded = null;
      await load(false);
    } catch {
      actionError = m.products_error();
    } finally {
      busyId = "";
    }
  }

  async function reject(event: SubmitEvent, row: DraftVersion): Promise<void> {
    event.preventDefault();
    const reason = rejectReason.trim();
    if (busyId !== "" || reason === "") return;
    busyId = row.version.versionId;
    actionError = "";
    notice = "";
    try {
      const { response, error } = await api.POST(
        "/api/v1/products/{code}/versions/{versionId}/reject",
        {
          params: { path: { code: row.product.code, versionId: row.version.versionId } },
          body: { reason },
        },
      );
      if (!response.ok) {
        actionError = errorFrom(error);
        return;
      }
      notice = m.products_reject_success();
      expanded = null;
      rejectReason = "";
      await load(false);
    } catch {
      actionError = m.products_error();
    } finally {
      busyId = "";
    }
  }

  onMount(() => {
    void load();
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.products_title()}</title>
</svelte:head>

<div class="products-head">
  <div>
    <h1 class="products-title">{m.products_title()}</h1>
    <p class="products-intro">{m.products_intro()}</p>
  </div>
</div>

{#if loading}
  <p role="status">{m.products_loading()}</p>
{:else}
  {#if errorMessage}
    <p class="kran-alert" role="alert">{errorMessage}</p>
    <p>
      <button class="kran-button" type="button" onclick={() => void load()}>{m.app_retry()}</button>
    </p>
  {/if}
  {#if actionError}
    <p class="kran-alert" role="alert">{actionError}</p>
  {/if}
  {#if notice}
    <p role="status">{notice}</p>
  {/if}

  {#if canApprove}
    <section class="kran-card" aria-labelledby="products-drafts-heading">
      <h2 id="products-drafts-heading">{m.products_drafts_heading()}</h2>
      {#if drafts.length === 0}
        <p class="kran-muted">{m.products_drafts_empty()}</p>
      {:else}
        <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
        <div
          class="kran-table-wrap"
          role="region"
          tabindex="0"
          aria-label={m.products_drafts_heading()}
        >
          <table class="kran-table">
            <caption class="kran-visually-hidden">{m.products_drafts_caption()}</caption>
            <thead>
              <tr>
                <th scope="col">{m.products_col_code()}</th>
                <th scope="col">{m.products_col_name()}</th>
                <th scope="col">{m.products_col_version()}</th>
                <th scope="col">{m.products_col_effective_from()}</th>
                <th scope="col">{m.products_col_action()}</th>
              </tr>
            </thead>
            <tbody>
              {#each drafts as row (row.version.versionId)}
                <tr>
                  <th scope="row">{row.product.code}</th>
                  <td>{row.product.name}</td>
                  <td class="kran-num">
                    {m.products_version_label({ version: row.version.versionNo })}
                  </td>
                  <td>{formatDate(row.version.effectiveFrom)}</td>
                  <td class="products-actions">
                    {#if expanded?.versionId === row.version.versionId && expanded.kind === "approve"}
                      <p
                        class="products-hint"
                        id={`approve-hint-${row.version.versionId}`}
                      >
                        {m.products_approve_confirm()}
                      </p>
                      <div class="products-buttons">
                        <button
                          class="kran-button kran-button--primary"
                          type="button"
                          disabled={busyId === row.version.versionId}
                          aria-describedby={`approve-hint-${row.version.versionId}`}
                          onclick={() => void approve(row)}
                        >
                          {busyId === row.version.versionId
                            ? m.products_approving()
                            : m.products_approve_yes()}
                        </button>
                        <button
                          class="kran-button"
                          type="button"
                          disabled={busyId === row.version.versionId}
                          onclick={cancelConfirm}
                        >
                          {m.products_cancel()}
                        </button>
                      </div>
                    {:else if expanded?.versionId === row.version.versionId && expanded.kind === "reject"}
                      <form
                        class="products-reject"
                        onsubmit={(event) => void reject(event, row)}
                        novalidate
                      >
                        <label
                          class="kran-label"
                          for={`reject-reason-${row.version.versionId}`}
                        >
                          {m.products_reject_reason_label()}
                        </label>
                        <input
                          class="kran-input"
                          id={`reject-reason-${row.version.versionId}`}
                          bind:value={rejectReason}
                          maxlength={REJECT_REASON_MAX}
                        />
                        <div class="products-buttons">
                          <button
                            class="kran-button kran-button--primary"
                            type="submit"
                            disabled={busyId === row.version.versionId || rejectReason.trim() === ""}
                          >
                            {busyId === row.version.versionId
                              ? m.products_rejecting()
                              : m.products_reject_submit()}
                          </button>
                          <button
                            class="kran-button"
                            type="button"
                            disabled={busyId === row.version.versionId}
                            onclick={cancelConfirm}
                          >
                            {m.products_cancel()}
                          </button>
                        </div>
                      </form>
                    {:else}
                      <div class="products-buttons">
                        <button
                          class="kran-button kran-button--primary"
                          type="button"
                          onclick={() => startConfirm(row.version.versionId, "approve")}
                        >
                          {m.products_approve()}
                        </button>
                        <button
                          class="kran-button"
                          type="button"
                          onclick={() => startConfirm(row.version.versionId, "reject")}
                        >
                          {m.products_reject()}
                        </button>
                      </div>
                    {/if}
                  </td>
                </tr>
              {/each}
            </tbody>
          </table>
        </div>
      {/if}
    </section>
  {/if}

  <section class="kran-card" aria-labelledby="products-heading">
    <h2 id="products-heading">{m.products_catalogue_heading()}</h2>
    {#if products.length === 0}
      <p class="kran-muted">{m.products_empty()}</p>
    {:else}
      <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
      <div class="kran-table-wrap" role="region" tabindex="0" aria-label={m.products_catalogue_heading()}>
        <table class="kran-table">
          <caption class="kran-visually-hidden">{m.products_caption()}</caption>
          <thead>
            <tr>
              <th scope="col">{m.products_col_code()}</th>
              <th scope="col">{m.products_col_name()}</th>
              <th scope="col">{m.products_col_type()}</th>
              <th scope="col">{m.products_col_kind()}</th>
              <th scope="col">{m.products_col_current_version()}</th>
            </tr>
          </thead>
          <tbody>
            {#each products as item (item.productId)}
              <tr>
                <th scope="row">{item.code}</th>
                <td>{item.name}</td>
                <td>{productTypeLabel(item.productType)}</td>
                <td>
                  {#if item.savingsKind}
                    {savingsKindLabel(item.savingsKind)}
                  {:else}
                    <span class="kran-muted">-</span>
                  {/if}
                </td>
                <td>
                  {#if item.currentVersion}
                    <span class="kran-num">
                      {m.products_version_label({ version: item.currentVersion.versionNo })}
                    </span>
                    <span class="kran-muted">
                      {formatDate(item.currentVersion.effectiveFrom)}
                    </span>
                  {:else}
                    <span class="kran-muted">{m.products_no_active_version()}</span>
                  {/if}
                </td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {/if}
  </section>
{/if}

<style>
  .products-head {
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    margin-block-end: var(--space-4);
  }

  .products-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .products-intro {
    margin: var(--space-1) 0 0;
    max-inline-size: 52ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .products-actions {
    min-inline-size: 16rem;
  }

  .products-buttons {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-2);
  }

  .products-hint {
    margin: 0 0 var(--space-2);
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .products-reject {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-inline-size: 14rem;
  }
</style>
