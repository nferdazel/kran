<script lang="ts">
  /**
   * Layar kerja utama Fase 2: saldo buku besar per periode (T-082).
   *
   * Arah visual: tabel adalah bintang layar, bukan kartu. Satu bidang kerja per layar; kontrol
   * periode menempel di kanan judul, bukan panel terpisah. Angka memakai `formatMoney` (tanpa
   * float) dan `tabular-nums`; simbol mata uang hanya di judul kolom (DESIGN §6).
   */
  import { goto } from "$app/navigation";
  import { onMount } from "svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { addMoney } from "@kran/ui/money";
  import { api } from "#lib/app/api.js";
  import { formatDate, formatDateTime, formatMoney } from "#lib/app/format.js";
  import type { PageProps } from "./$types";

  type Period = {
    periodId: string;
    startsOn: string;
    endsOn: string;
    status: "OPEN" | "CLOSED";
    closedAt: string | null;
    closedBy: string | null;
    createdAt: string;
  };

  type BalanceLine = {
    accountCode: string;
    accountName: string;
    accountType: string;
    openingDebit: string;
    openingCredit: string;
    periodDebit: string;
    periodCredit: string;
    closingDebit: string;
    closingCredit: string;
  };

  type LedgerBalances = {
    periodId: string;
    startsOn: string;
    endsOn: string;
    source: "ledger" | "snapshot";
    computedAt: string;
    lines: BalanceLine[];
  };

  let { data }: PageProps = $props();

  const canRead = $derived(data.session.permissions.includes("ledger.journal.read"));

  let periods = $state<Period[]>([]);
  let selectedId = $state("");
  let balances = $state<LedgerBalances | null>(null);
  let loading = $state(true);
  let errorMessage = $state("");

  type AccountCategory = "ALL" | "1" | "2" | "3" | "4" | "5";
  let activeCategory = $state<AccountCategory>("ALL");

  const filteredLines = $derived.by(() => {
    const lines = balances?.lines ?? [];
    if (activeCategory === "ALL") return lines;
    return lines.filter((line) => line.accountCode.startsWith(activeCategory));
  });

  const selectedPeriod = $derived(periods.find((p) => p.periodId === selectedId) ?? null);

  const totals = $derived.by(() => {
    const lines = balances?.lines ?? [];
    let openingDebit = "0.0000";
    let openingCredit = "0.0000";
    let periodDebit = "0.0000";
    let periodCredit = "0.0000";
    let closingDebit = "0.0000";
    let closingCredit = "0.0000";
    for (const line of lines) {
      openingDebit = addMoney(openingDebit, line.openingDebit);
      openingCredit = addMoney(openingCredit, line.openingCredit);
      periodDebit = addMoney(periodDebit, line.periodDebit);
      periodCredit = addMoney(periodCredit, line.periodCredit);
      closingDebit = addMoney(closingDebit, line.closingDebit);
      closingCredit = addMoney(closingCredit, line.closingCredit);
    }
    return { openingDebit, openingCredit, periodDebit, periodCredit, closingDebit, closingCredit };
  });

  async function loadBalances(periodId: string): Promise<void> {
    if (periodId === "") return;
    loading = true;
    errorMessage = "";
    const { data: body, response } = await api.GET("/api/v1/ledger/balances", {
      params: { query: { periodId } },
    });
    if (response.status === 401) {
      await goto("/login");
      return;
    }
    if (!response.ok || !body) {
      balances = null;
      errorMessage = response.status === 403 ? m.ledger_denied() : m.ledger_error();
      loading = false;
      return;
    }
    balances = body as LedgerBalances;
    loading = false;
  }

  async function loadPeriods(): Promise<void> {
    const { data: body, response } = await api.GET("/api/v1/ledger/periods");
    if (response.status === 401) {
      await goto("/login");
      return;
    }
    if (!response.ok || !body) {
      errorMessage = m.ledger_error();
      loading = false;
      return;
    }
    periods = (body.items ?? []) as Period[];
    const today = new Date().toISOString().slice(0, 10);
    const current =
      periods.find((p) => p.startsOn <= today && today <= p.endsOn) ?? periods[0] ?? null;
    selectedId = current?.periodId ?? "";
    if (selectedId === "") {
      loading = false;
      return;
    }
    await loadBalances(selectedId);
  }

  onMount(() => {
    if (!canRead) {
      loading = false;
      return;
    }
    void loadPeriods();
  });

  function onPeriodChange(): void {
    void loadBalances(selectedId);
  }

  function reload(): void {
    if (periods.length === 0) {
      void loadPeriods();
      return;
    }
    void loadBalances(selectedId);
  }

  function printPage(): void {
    window.print();
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.ledger_title()}</title>
</svelte:head>

<div class="ledger-head">
  <div>
    <h1 class="ledger-title">{m.ledger_title()}</h1>
    <p class="ledger-intro">{m.ledger_intro()}</p>
    {#if balances}
      <p class="ledger-meta">
        <span>{formatDate(balances.startsOn)} – {formatDate(balances.endsOn)}</span>
        {#if selectedPeriod}
          <span class="ledger-sep" aria-hidden="true">·</span>
          <span class="kran-status {selectedPeriod.status === "OPEN" ? "kran-status--ok" : ""}">
            <span class="kran-status__icon" aria-hidden="true"
              >{selectedPeriod.status === "OPEN" ? "○" : "✔"}</span
            >
            {selectedPeriod.status === "OPEN"
              ? m.ledger_status_open()
              : m.ledger_status_closed()}
          </span>
        {/if}
        <span class="ledger-sep" aria-hidden="true">·</span>
        <span>
          {balances.source === "snapshot"
            ? m.ledger_source_snapshot()
            : m.ledger_source_ledger()}
        </span>
        <span class="ledger-sep" aria-hidden="true">·</span>
        <span>{m.ledger_computed({ time: formatDateTime(balances.computedAt) })}</span>
      </p>
    {/if}
  </div>

  <div class="ledger-controls">
    <div class="ledger-field">
      <label class="kran-label" for="ledger-period">{m.ledger_period_label()}</label>
      <select
        class="kran-select"
        id="ledger-period"
        bind:value={selectedId}
        onchange={onPeriodChange}
        disabled={periods.length === 0}
      >
        {#each periods as period (period.periodId)}
          <option value={period.periodId}>
            {formatDate(period.startsOn)} – {formatDate(period.endsOn)}
          </option>
        {/each}
      </select>
    </div>
    <button class="kran-button" type="button" onclick={reload} disabled={loading}>
      {m.ledger_reload()}
    </button>
    <button class="kran-button" type="button" onclick={printPage} disabled={!balances}>
      {m.ledger_print()}
    </button>
  </div>
</div>

{#if !canRead}
  <p class="kran-alert" role="alert">{m.ledger_denied()}</p>
{:else if loading}
  <p role="status">{m.ledger_loading()}</p>
{:else if errorMessage}
  <p class="kran-alert" role="alert">{errorMessage}</p>
  <p><button class="kran-button" type="button" onclick={reload}>{m.app_retry()}</button></p>
{:else if periods.length === 0}
  <p>{m.ledger_no_period()}</p>
{:else if balances && balances.lines.length === 0}
  <div class="ledger-empty">
    <p>{m.ledger_empty()}</p>
    <p class="kran-muted">{m.ledger_empty_hint()}</p>
  </div>
{:else if balances}
  <!-- Ringkasan metrik buku besar: memudahkan auditor & operator melihat total mutasi dan keseimbangan buku besar seketika -->
  <div class="kran-metric-strip">
    <div class="kran-metric-card">
      <span class="kran-metric-card__label">{m.ledger_group_movement()} {m.ledger_debit()} (IDR)</span>
      <span class="kran-metric-card__value kran-money">{formatMoney(totals.periodDebit)}</span>
      <span class="kran-metric-card__sub">{m.ledger_metric_debit_sub()}</span>
    </div>

    <div class="kran-metric-card">
      <span class="kran-metric-card__label">{m.ledger_group_movement()} {m.ledger_credit()} (IDR)</span>
      <span class="kran-metric-card__value kran-money">{formatMoney(totals.periodCredit)}</span>
      <span class="kran-metric-card__sub">{m.ledger_metric_credit_sub()}</span>
    </div>

    <div class="kran-metric-card">
      <span class="kran-metric-card__label">{m.ledger_group_closing()} (IDR)</span>
      <span class="kran-metric-card__value kran-money">{formatMoney(totals.closingDebit)}</span>
      <div class="kran-metric-card__sub">
        {#if totals.periodDebit === totals.periodCredit}
          <span class="kran-badge kran-badge--ok">
            <span aria-hidden="true">✔</span>
            <span>{m.ledger_balanced()}</span>
          </span>
        {:else}
          <span class="kran-badge kran-badge--warning">
            <span aria-hidden="true">▲</span>
            <span>{m.ledger_unbalanced()}</span>
          </span>
        {/if}
      </div>
    </div>
  </div>

  <!-- Filter Kategori Akun COA -->
  <div class="kran-filter-bar">
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "ALL"}
      onclick={() => (activeCategory = "ALL")}
    >
      <span>Semua Akun</span>
      <span class="kran-badge">{balances.lines.length}</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "1"}
      onclick={() => (activeCategory = "1")}
    >
      <span>1 - Aset</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "2"}
      onclick={() => (activeCategory = "2")}
    >
      <span>2 - Liabilitas</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "3"}
      onclick={() => (activeCategory = "3")}
    >
      <span>3 - Ekuitas</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "4"}
      onclick={() => (activeCategory = "4")}
    >
      <span>4 - Pendapatan</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "5"}
      onclick={() => (activeCategory = "5")}
    >
      <span>5 - Beban</span>
    </button>
  </div>

  <!-- Area bergulir harus bisa difokus supaya bisa digeser dengan keyboard (WCAG 2.1.1);
       svelte-check menganggap `region` selalu noninteraktif. Pengecualian ini dicatat di D-116. -->
  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
  <div
    class="kran-table-wrap ledger-region"
    role="region"
    tabindex="0"
    aria-label={m.ledger_title()}
  >
    <table class="kran-table ledger-table">
      <caption class="kran-visually-hidden">
        {m.ledger_caption({
          period: `${formatDate(balances.startsOn)} – ${formatDate(balances.endsOn)}`,
        })}
      </caption>
      <thead>
        <tr>
          <th scope="col" rowspan="2">{m.ledger_col_code()}</th>
          <th scope="col" rowspan="2">{m.ledger_col_account()}</th>
          <th scope="colgroup" colspan="2">{m.ledger_group_opening()} (IDR)</th>
          <th scope="colgroup" colspan="2">{m.ledger_group_movement()} (IDR)</th>
          <th scope="colgroup" colspan="2">{m.ledger_group_closing()} (IDR)</th>
        </tr>
        <tr>
          <th scope="col" class="ledger-num">{m.ledger_debit()}</th>
          <th scope="col" class="ledger-num">{m.ledger_credit()}</th>
          <th scope="col" class="ledger-num">{m.ledger_debit()}</th>
          <th scope="col" class="ledger-num">{m.ledger_credit()}</th>
          <th scope="col" class="ledger-num">{m.ledger_debit()}</th>
          <th scope="col" class="ledger-num">{m.ledger_credit()}</th>
        </tr>
      </thead>
      <tbody>
        {#each filteredLines as line (line.accountCode)}
          <tr>
            <th scope="row" class="ledger-code">{line.accountCode}</th>
            <td class="ledger-account">{line.accountName}</td>
            <td class="ledger-num kran-money">{formatMoney(line.openingDebit)}</td>
            <td class="ledger-num kran-money">{formatMoney(line.openingCredit)}</td>
            <td class="ledger-num kran-money">{formatMoney(line.periodDebit)}</td>
            <td class="ledger-num kran-money">{formatMoney(line.periodCredit)}</td>
            <td class="ledger-num kran-money">{formatMoney(line.closingDebit)}</td>
            <td class="ledger-num kran-money">{formatMoney(line.closingCredit)}</td>
          </tr>
        {/each}
        {#if filteredLines.length === 0}
          <tr>
            <td colspan="8" class="kran-muted" style="text-align: center; padding: var(--space-5);">
              Tidak ada akun pada kategori ini.
            </td>
          </tr>
        {/if}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colspan="2">{m.ledger_total()}</th>
          <td class="ledger-num kran-money">{formatMoney(totals.openingDebit)}</td>
          <td class="ledger-num kran-money">{formatMoney(totals.openingCredit)}</td>
          <td class="ledger-num kran-money">{formatMoney(totals.periodDebit)}</td>
          <td class="ledger-num kran-money">{formatMoney(totals.periodCredit)}</td>
          <td class="ledger-num kran-money">{formatMoney(totals.closingDebit)}</td>
          <td class="ledger-num kran-money">{formatMoney(totals.closingCredit)}</td>
        </tr>
      </tfoot>
    </table>
  </div>
{/if}

<style>
  .ledger-head {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: var(--space-4);
    align-items: center;
    padding-block: var(--space-4);
    padding-inline: var(--space-4);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-md);
    background: var(--color-surface-raised);
    margin-block-end: var(--space-4);
  }

  .ledger-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .ledger-intro {
    margin: var(--space-1) 0 0;
    max-inline-size: 52ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .ledger-meta {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
    margin: var(--space-2) 0 0;
    font-size: var(--text-xs);
    color: var(--color-text-muted);
  }

  .ledger-sep {
    color: var(--color-hairline);
  }

  .ledger-controls {
    min-inline-size: 0;
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: end;
    justify-content: end;
    padding: var(--space-2);
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-sm);
    background: var(--color-bg);
  }

  .ledger-field {
    display: grid;
    gap: var(--space-1);
    min-inline-size: 0;
  }

  .ledger-field select {
    min-inline-size: 16rem;
    max-inline-size: 100%;
  }

  .ledger-region {
    max-inline-size: 100%;
    border: 1px solid var(--color-hairline);
    border-radius: var(--radius-sm);
    background: var(--color-surface);
  }

  .ledger-table thead tr:first-child th {
    block-size: var(--row-height);
    border-block-end: 1px solid var(--color-hairline);
    color: var(--color-text);
    font-weight: 500;
    text-align: start;
  }

  .ledger-table thead tr:first-child th[colspan] {
    text-align: start;
  }

  .ledger-num {
    text-align: end;
  }

  .ledger-table .ledger-num {
    text-align: end;
  }

  .ledger-table th,
  .ledger-table td {
    padding-inline: var(--space-2);
    font-size: var(--text-sm);
  }

  .ledger-table th:first-child,
  .ledger-table td:first-child {
    padding-inline-start: var(--space-3);
  }

  .ledger-code {
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums;
    font-weight: 500;
    white-space: nowrap;
  }

  /* Kolom kode akun tetap terlihat saat tabel digulir mendatar (DESIGN §10). Latar memakai
   * warna surface yang sama dengan region supaya angka yang lewat di bawahnya tidak tembus,
   * dan garis rambut baris tetap utuh, tanpa garis vertikal baru (DESIGN §6).
   * `position: sticky` tidak berefek saat tabel muat penuh, jadi layar lebar tidak berubah.
   * Dibatasi `screen`: perilaku cetak tidak disentuh selama ADR-013 belum diputuskan. */
  @media screen {
    /* Footer sengaja tidak ikut: sel pertamanya `colspan="2"` (label Total), jadi memakunya
     * selebar kolom kode membuat tepi sticky footer tidak sejajar dengan body. Footer sudah
     * sticky bawah lewat components.css. */
    .ledger-table thead tr:first-child th:first-child,
    .ledger-table tbody th:first-child {
      position: sticky;
      inset-inline-start: 0;
      background: var(--color-surface);
    }

    .ledger-table thead tr:first-child th:first-child {
      z-index: 2;
    }

    .ledger-table tbody th:first-child {
      z-index: 1;
    }
  }

  .ledger-account {
    min-inline-size: 12rem;
    max-inline-size: 18rem;
  }

  .ledger-table .kran-money {
    font-size: var(--text-sm);
    padding-inline-end: var(--space-2);
  }

  .ledger-empty {
    padding-block: var(--space-6);
    border-block: 1px solid var(--color-hairline);
  }

  .ledger-empty p {
    margin: 0;
  }

  .ledger-empty p + p {
    margin-block-start: var(--space-1);
  }

  @media (max-width: 1100px) {
    .ledger-head {
      grid-template-columns: minmax(0, 1fr);
    }

    .ledger-controls {
      justify-content: start;
    }

    .ledger-field select {
      min-inline-size: 0;
    }
  }

  @media print {
    .ledger-controls,
    .ledger-intro {
      display: none;
    }

    .ledger-region {
      border: 0;
    }
  }
</style>
