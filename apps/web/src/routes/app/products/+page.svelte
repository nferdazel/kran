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
   *
   * Tata letak mengikuti DESIGN §11: judul layar bersama, satu bidang kerja per bagian, tabel dari
   * komponen bersama. Tidak ada CSS lokal di berkas ini; aturan visual tinggal di `packages/ui`.
   */
  import { onMount } from "svelte";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import DataTable, {
    type DataColumn,
    type DataRow,
  } from "@kran/ui/components/DataTable.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";

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

  function draftOf(versionId: string): DraftVersion | undefined {
    return drafts.find((item) => item.version.versionId === versionId);
  }

  /** Baris tabel memuat teks yang sudah diformat; objek asli tetap dicari lewat `versionId`. */
  const draftColumns: DataColumn[] = $derived([
    // Kode produk menamai baris: pembaca layar membacakannya sebagai header baris (DESIGN §6).
    { key: "code", label: m.products_col_code(), rowHeader: true },
    { key: "name", label: m.products_col_name() },
    { key: "version", label: m.products_col_version() },
    { key: "effectiveFrom", label: m.products_col_effective_from() },
  ]);

  const draftRows = $derived(
    drafts.map((row) => ({
      versionId: row.version.versionId,
      code: row.product.code,
      name: row.product.name,
      version: m.products_version_label({ version: row.version.versionNo }),
      effectiveFrom: formatDate(row.version.effectiveFrom),
    })),
  );

  const productColumns: DataColumn[] = $derived([
    { key: "code", label: m.products_col_code(), rowHeader: true },
    { key: "name", label: m.products_col_name() },
    { key: "type", label: m.products_col_type() },
    { key: "kind", label: m.products_col_kind() },
    { key: "version", label: m.products_col_current_version() },
    { key: "effectiveFrom", label: m.products_col_effective_from() },
  ]);

  const productRows = $derived(
    products.map((item) => ({
      productId: item.productId,
      code: item.code,
      name: item.name,
      type: productTypeLabel(item.productType),
      kind: item.savingsKind ? savingsKindLabel(item.savingsKind) : "-",
      version: item.currentVersion
        ? m.products_version_label({ version: item.currentVersion.versionNo })
        : m.products_no_active_version(),
      effectiveFrom: item.currentVersion ? formatDate(item.currentVersion.effectiveFrom) : "",
    })),
  );

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

  async function approve(versionId: string): Promise<void> {
    const row = draftOf(versionId);
    if (row === undefined || busyId !== "") return;
    busyId = versionId;
    actionError = "";
    notice = "";
    try {
      const { response, error } = await api.POST(
        "/api/v1/products/{code}/versions/{versionId}/approve",
        { params: { path: { code: row.product.code, versionId } } },
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

  async function reject(event: SubmitEvent, versionId: string): Promise<void> {
    event.preventDefault();
    const row = draftOf(versionId);
    const reason = rejectReason.trim();
    if (row === undefined || busyId !== "" || reason === "") return;
    busyId = versionId;
    actionError = "";
    notice = "";
    try {
      const { response, error } = await api.POST(
        "/api/v1/products/{code}/versions/{versionId}/reject",
        {
          params: { path: { code: row.product.code, versionId } },
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

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.products_title()}</h1>
    <p class="kran-page-header__intro">{m.products_intro()}</p>
  </div>
</div>

{#if loading}
  <p role="status">{m.products_loading()}</p>
{:else}
  {#if errorMessage}
    <Alert tone="negative" title={errorMessage}>
      <Button type="button" onclick={() => void load()}>{m.app_retry()}</Button>
    </Alert>
  {/if}

  {#if actionError}
    <Alert tone="negative" title={actionError} />
  {/if}

  {#if notice}
    <Alert tone="positive" title={notice} />
  {/if}

  {#snippet draftActions(row: DataRow)}
    {@const versionId = String(row.versionId)}
    {#if expanded?.versionId === versionId && expanded.kind === "approve"}
      <div class="kran-stack">
        <p class="kran-muted" id={`approve-hint-${versionId}`}>
          {m.products_approve_confirm()}
        </p>
        <div class="kran-actions">
          <Button
            variant="primary"
            type="button"
            disabled={busyId === versionId}
            aria-describedby={`approve-hint-${versionId}`}
            onclick={() => void approve(versionId)}
          >
            {busyId === versionId ? m.products_approving() : m.products_approve_yes()}
          </Button>
          <Button type="button" disabled={busyId === versionId} onclick={cancelConfirm}>
            {m.products_cancel()}
          </Button>
        </div>
      </div>
    {:else if expanded?.versionId === versionId && expanded.kind === "reject"}
      <form class="kran-stack" onsubmit={(event) => void reject(event, versionId)} novalidate>
        <label class="kran-label" for={`reject-reason-${versionId}`}>
          {m.products_reject_reason_label()}
        </label>
        <input
          class="kran-input"
          id={`reject-reason-${versionId}`}
          bind:value={rejectReason}
          maxlength={REJECT_REASON_MAX}
        />
        <div class="kran-actions">
          <Button
            variant="primary"
            type="submit"
            disabled={busyId === versionId || rejectReason.trim() === ""}
          >
            {busyId === versionId ? m.products_rejecting() : m.products_reject_submit()}
          </Button>
          <Button type="button" disabled={busyId === versionId} onclick={cancelConfirm}>
            {m.products_cancel()}
          </Button>
        </div>
      </form>
    {:else}
      <div class="kran-actions">
        <Button
          variant="primary"
          type="button"
          onclick={() => startConfirm(versionId, "approve")}
        >
          {m.products_approve()}
        </Button>
        <Button type="button" onclick={() => startConfirm(versionId, "reject")}>
          {m.products_reject()}
        </Button>
      </div>
    {/if}
  {/snippet}

  {#if canApprove}
    <section class="kran-section" aria-labelledby="products-drafts-heading">
      <h2 class="kran-section__title" id="products-drafts-heading">
        {m.products_drafts_heading()}
      </h2>
      {#if drafts.length === 0}
        <EmptyState title={m.products_drafts_empty()} />
      {:else}
        <DataTable
          caption={m.products_drafts_caption()}
          ariaLabel={m.common_table_region({ name: m.products_drafts_heading() })}
          captionHidden
          columns={draftColumns}
          rows={draftRows}
          rowKey="versionId"
          actions={{ label: m.products_col_action(), cell: draftActions }}
        />
      {/if}
    </section>
  {/if}

  <section class="kran-section" aria-labelledby="products-heading">
    <h2 class="kran-section__title" id="products-heading">{m.products_catalogue_heading()}</h2>
    {#if products.length === 0}
      <EmptyState title={m.products_empty()} />
    {:else}
      <DataTable
        caption={m.products_caption()}
        ariaLabel={m.common_table_region({ name: m.products_catalogue_heading() })}
        captionHidden
        columns={productColumns}
        rows={productRows}
        rowKey="productId"
      />
    {/if}
  </section>
{/if}
