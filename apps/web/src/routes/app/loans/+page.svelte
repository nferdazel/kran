<script lang="ts">
  /**
   * Daftar pinjaman (T-170): pencarian per anggota, saringan status, dan tautan ke detail.
   *
   * Dua aturan yang mengikat:
   *  - **Scoping cabang milik server** (T-169). Layar tidak menyaring sendiri; baris yang tidak
   *    boleh dibaca tidak pernah dikirim, dan menyaring ulang di sini akan menutupi bug otorisasi.
   *  - **Tidak ada aksi tulis** di sini. Pencairan/pembayaran mengharuskan pratinjau sebelum uang
   *    bergerak dan pemilihan rekening; itu T-173, bukan diselipkan sebagai tombol.
   *
   * Nilai uang dibiarkan sebagai string desimal dari API dan hanya diformat saat ditampilkan
   * (kolom `numerics` milik `DataTable`), tanpa aritmetika di peramban.
   */
  import { onMount } from "svelte";
  import { resolve } from "$app/paths";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import DataTable, { type DataColumn, type DataRow } from "@kran/ui/components/DataTable.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import Select from "@kran/ui/components/Select.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatDate } from "#lib/app/format.js";
  import { loanProblemMessage, loanStatusLabel } from "#lib/app/loans.js";
  import type { LoanStatus, LoanSummary, SessionInfo } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  const STATUSES: readonly LoanStatus[] = [
    "APPLIED",
    "APPROVED",
    "ACTIVE",
    "CLOSED",
    "WRITTEN_OFF",
  ];
  /** Batas respons daftar; kontrak memotong nilai yang lebih besar. */
  const LIMIT = 50;

  let { data }: PageProps = $props();
  const session: SessionInfo = $derived(data.session);
  const canRead = $derived(session.permissions.includes("lending.loan.read"));

  let partyId = $state("");
  let status = $state("");
  let loans = $state<LoanSummary[]>([]);
  let loading = $state(true);
  let errorMessage = $state("");

  /** Bentuk UUID yang sama dengan yang diterima server; salah ketik ditolak sebelum permintaan. */
  const UUID_PATTERN =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  async function load(): Promise<void> {
    if (!canRead) {
      loading = false;
      return;
    }
    const wanted = partyId.trim();
    if (wanted.length > 0 && !UUID_PATTERN.test(wanted)) {
      loans = [];
      errorMessage = m.loans_error_party_invalid();
      return;
    }
    loading = true;
    errorMessage = "";
    try {
      const { data: body, error, response } = await api.GET("/api/v1/lending/loans", {
        params: {
          query: {
            partyId: wanted.length === 0 ? undefined : wanted,
            status: status === "" ? undefined : (status as LoanStatus),
            limit: LIMIT,
          },
        },
      });
      if (!response.ok || !body) {
        loans = [];
        errorMessage = api.isProblem(error) ? loanProblemMessage(error) : m.loans_error();
        return;
      }
      loans = body.items;
    } catch {
      loans = [];
      errorMessage = m.loans_error();
    } finally {
      loading = false;
    }
  }

  function submit(event: SubmitEvent): void {
    event.preventDefault();
    void load();
  }

  const columns: DataColumn[] = $derived([
    // Nomor akad menamai baris: pembaca layar membacakannya bersama tiap sel lain.
    { key: "loanId", label: m.loans_col_loan(), rowHeader: true },
    { key: "partyId", label: m.loans_col_party() },
    { key: "principal", label: m.loans_col_principal(), numerics: true, align: "end" },
    { key: "status", label: m.loans_col_status() },
    { key: "disbursedOn", label: m.loans_col_disbursed() },
  ]);

  const rows: DataRow[] = $derived(
    loans.map((loan) => ({
      loanId: loan.loanId,
      partyId: loan.partyId,
      principal: loan.principal,
      status: loanStatusLabel(loan.status),
      disbursedOn: loan.disbursedOn === null ? m.loans_not_disbursed() : formatDate(loan.disbursedOn),
    })),
  );

  onMount(() => {
    void load();
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.loans_title()}</title>
</svelte:head>

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.loans_title()}</h1>
    <p class="kran-page-header__intro">{m.loans_intro()}</p>
  </div>
</div>

{#if !canRead}
  <Alert tone="negative" title={m.loans_denied()} />
{:else}
  <section class="kran-section" aria-labelledby="loans-filter-heading">
    <h2 class="kran-section__title" id="loans-filter-heading">{m.loans_filter_submit()}</h2>
    <form class="kran-actions" onsubmit={submit}>
      <label class="kran-field">
        <span class="kran-field__label">{m.loans_filter_party()}</span>
        <input
          class="kran-input"
          type="text"
          bind:value={partyId}
          aria-describedby="loans-party-hint"
          autocomplete="off"
          spellcheck="false"
        />
        <span class="kran-muted" id="loans-party-hint">{m.loans_filter_party_hint()}</span>
      </label>
      <Select label={m.loans_filter_status()} bind:value={status}>
        <option value="">{m.loans_filter_all()}</option>
        {#each STATUSES as item (item)}
          <option value={item}>{loanStatusLabel(item)}</option>
        {/each}
      </Select>
      <Button variant="primary" type="submit" disabled={loading}>
        {m.loans_filter_submit()}
      </Button>
    </form>
  </section>

  {#snippet rowActions(row: DataRow)}
    {@const loanId = String(row.loanId)}
    <a class="kran-link" href={resolve("/app/loans/[loanId]", { loanId })}>{m.loans_open()}</a>
  {/snippet}

  <section class="kran-section" aria-labelledby="loans-list-heading">
    <h2 class="kran-section__title" id="loans-list-heading">{m.loans_title()}</h2>
    {#if loading}
      <p role="status">{m.loans_loading()}</p>
    {:else if errorMessage}
      <Alert tone="negative" title={errorMessage}>
        <Button type="button" onclick={() => void load()}>{m.app_retry()}</Button>
      </Alert>
    {:else if loans.length === 0}
      <EmptyState title={m.loans_empty()} />
    {:else}
      <DataTable
        caption={m.loans_title()}
        ariaLabel={m.common_table_region({ name: m.loans_title() })}
        captionHidden
        {columns}
        {rows}
        rowKey="loanId"
        actions={{ label: m.loans_open(), cell: rowActions }}
      />
    {/if}
  </section>
{/if}
