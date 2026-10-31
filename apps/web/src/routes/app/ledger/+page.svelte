<script lang="ts">
  /**
   * Layar kerja utama Fase 2: saldo buku besar per periode (T-082).
   *
   * Arah visual: tabel adalah bintang layar, bukan kartu. Satu bidang kerja per layar; kontrol
   * periode menempel di kanan judul, bukan panel terpisah. Angka memakai `formatMoney` (tanpa
   * float) dan `tabular-nums`; simbol mata uang hanya di judul kolom (DESIGN §6).
   *
   * Di luar dua aturan layar-saja (cincin sel aktif, kolom kode sticky), aturan visual milik
   * `packages/ui`: berkas ini tidak menulis ulang tipografi judul, tabel, kontrol, atau tombol.
   */
  import { goto } from "$app/navigation";
  import { resolve } from "$app/paths";
  import { onMount } from "svelte";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import StatusBadge from "@kran/ui/components/StatusBadge.svelte";

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
    // Totals must follow the visible rows. Using all `balances.lines` would show figures that do
    // not match the table while a category filter is active.
    const lines = filteredLines;
    let openingDebit = "0.00";
    let openingCredit = "0.00";
    let periodDebit = "0.00";
    let periodCredit = "0.00";
    let closingDebit = "0.00";
    let closingCredit = "0.00";
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
      await goto(resolve("/login"));
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
      await goto(resolve("/login"));
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

  // Navigasi keyboard tabel (DESIGN §10: satu tab-stop per komponen komposit — Tab masuk, panah
  // pindah sel). Fokus DOM tetap di `<table role="grid" tabindex="0">`; sel aktif ditunjuk
  // `aria-activedescendant` + kelas visual. Pola ini dipilih daripada roving tabindex supaya tiap
  // `td`/`th` tidak menjadi tab-stop sendiri (dan `svelte-check` tetap 0 warning), serta semantik
  // tabel native (`th scope`, `<caption>`) tidak diganti. Enter/Space sengaja tidak ditangani:
  // tabel ini hanya membaca, jadi tidak ada aksi destruktif yang bisa tersulut dari sel.
  const LEDGER_COLUMNS = 8;

  let activeRow = $state(0);
  let activeColumn = $state(0);

  // Baris aktif yang benar-benar tampak; filter kategori bisa memangkas daftar di bawah `activeRow`.
  const visibleRow = $derived(
    filteredLines.length === 0 ? 0 : Math.min(activeRow, filteredLines.length - 1),
  );

  function ledgerCellId(row: number, column: number): string {
    return `ledger-cell-${row}-${column}`;
  }

  const activeDescendant = $derived(
    filteredLines.length === 0 ? undefined : ledgerCellId(visibleRow, activeColumn),
  );

  function moveActiveCell(row: number, column: number): void {
    const rows = filteredLines.length;
    if (rows === 0) return;
    activeRow = Math.min(Math.max(row, 0), rows - 1);
    activeColumn = Math.min(Math.max(column, 0), LEDGER_COLUMNS - 1);
    // Sel aktif harus benar-benar terlihat: gulirkan region mendatar/vertikal ke sel baru
    // (WCAG 2.1.1 — menggantikan tabindex region ala D-116).
    document
      .getElementById(ledgerCellId(activeRow, activeColumn))
      ?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  function onTableKeydown(event: KeyboardEvent): void {
    if (filteredLines.length === 0) return;
    const row = visibleRow;
    const column = activeColumn;
    switch (event.key) {
      case "ArrowRight":
        moveActiveCell(row, column + 1);
        break;
      case "ArrowLeft":
        moveActiveCell(row, column - 1);
        break;
      case "ArrowDown":
        moveActiveCell(row + 1, column);
        break;
      case "ArrowUp":
        moveActiveCell(row - 1, column);
        break;
      case "Home":
        moveActiveCell(event.ctrlKey ? 0 : row, 0);
        break;
      case "End":
        moveActiveCell(event.ctrlKey ? filteredLines.length - 1 : row, LEDGER_COLUMNS - 1);
        break;
      default:
        return;
    }
    event.preventDefault();
  }
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.ledger_title()}</title>
</svelte:head>

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.ledger_title()}</h1>
    <p class="kran-page-header__intro">{m.ledger_intro()}</p>
    {#if balances}
      <!-- Periode, status, dan sumber saldo: satu baris meta di bawah judul, bukan panel sendiri. -->
      <div class="kran-actions">
        <span class="kran-muted">{formatDate(balances.startsOn)} – {formatDate(balances.endsOn)}</span>
        {#if selectedPeriod}
          <StatusBadge tone={selectedPeriod.status === "OPEN" ? "positive" : "neutral"}>
            {selectedPeriod.status === "OPEN" ? m.ledger_status_open() : m.ledger_status_closed()}
          </StatusBadge>
        {/if}
        <span class="kran-muted">
          {balances.source === "snapshot"
            ? m.ledger_source_snapshot()
            : m.ledger_source_ledger()}
        </span>
        <span class="kran-muted">{m.ledger_computed({ time: formatDateTime(balances.computedAt) })}</span>
      </div>
    {/if}
  </div>

  <!-- Kontrol periode menempel di judul (DESIGN §11). `.kran-toolbar` juga yang menyembunyikan
       kontrol ini saat dicetak lewat aturan cetak bersama. -->
  <div class="kran-toolbar">
    <div class="kran-actions">
      <div class="kran-field">
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
      <Button type="button" onclick={reload} disabled={loading}>{m.ledger_reload()}</Button>
      <Button type="button" onclick={printPage} disabled={!balances}>{m.ledger_print()}</Button>
    </div>
  </div>
</div>

{#if !canRead}
  <Alert tone="negative" title={m.ledger_denied()} />
{:else if loading}
  <p role="status">{m.ledger_loading()}</p>
{:else if errorMessage}
  <Alert tone="negative" title={errorMessage}>
    <Button type="button" onclick={reload}>{m.app_retry()}</Button>
  </Alert>
{:else if periods.length === 0}
  <EmptyState title={m.ledger_no_period()} />
{:else if balances && balances.lines.length === 0}
  <EmptyState title={m.ledger_empty()} description={m.ledger_empty_hint()} />
{:else if balances}
  <!-- Ringkasan buku besar: tiga fakta yang dibaca auditor dalam satu pandangan. Daftar fakta,
       bukan strip kartu metrik (DESIGN §11/§13). -->
  <dl class="kran-facts">
    <dt>{m.ledger_group_movement()} {m.ledger_debit()} (IDR)</dt>
    <dd class="kran-num">{formatMoney(totals.periodDebit)}</dd>

    <dt>{m.ledger_group_movement()} {m.ledger_credit()} (IDR)</dt>
    <dd class="kran-num">{formatMoney(totals.periodCredit)}</dd>

    <dt>{m.ledger_group_closing()} (IDR)</dt>
    <dd>
      <span class="kran-num">{formatMoney(totals.closingDebit)}</span>
      {#if totals.periodDebit === totals.periodCredit}
        <StatusBadge tone="positive">{m.ledger_balanced()}</StatusBadge>
      {:else}
        <StatusBadge tone="warning">{m.ledger_unbalanced()}</StatusBadge>
      {/if}
    </dd>
  </dl>

  <!-- Filter Kategori Akun COA -->
  <div class="kran-filter-bar">
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "ALL"}
      onclick={() => (activeCategory = "ALL")}
    >
      <span>{m.ledger_filter_all()}</span>
      <StatusBadge tone="neutral">{balances.lines.length}</StatusBadge>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "1"}
      onclick={() => (activeCategory = "1")}
    >
      <span>{m.ledger_filter_assets()}</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "2"}
      onclick={() => (activeCategory = "2")}
    >
      <span>{m.ledger_filter_liabilities()}</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "3"}
      onclick={() => (activeCategory = "3")}
    >
      <span>{m.ledger_filter_equity()}</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "4"}
      onclick={() => (activeCategory = "4")}
    >
      <span>{m.ledger_filter_revenue()}</span>
    </button>
    <button
      class="kran-filter-button"
      type="button"
      aria-pressed={activeCategory === "5"}
      onclick={() => (activeCategory = "5")}
    >
      <span>{m.ledger_filter_expense()}</span>
    </button>
  </div>

  <!-- Area bergulir tetap region berlabel; tab-stop tunggal ada di `<table role="grid">` di dalamnya
       (D-116 diamandemen di T-079). Instruksi tombol untuk pengguna keyboard diumumkan lewat
       `aria-describedby` (teks tersembunyi secara visual, tetap terbaca pembaca layar). -->
  <div class="kran-table-wrap ledger-region" role="region" aria-label={m.ledger_title()}>
    <p class="kran-visually-hidden" id="ledger-table-help">{m.ledger_table_help()}</p>
    <table
      class="kran-table ledger-table"
      role="grid"
      tabindex="0"
      aria-describedby="ledger-table-help"
      aria-activedescendant={activeDescendant}
      onkeydown={onTableKeydown}
    >
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
          <th scope="col" class="kran-num">{m.ledger_debit()}</th>
          <th scope="col" class="kran-num">{m.ledger_credit()}</th>
          <th scope="col" class="kran-num">{m.ledger_debit()}</th>
          <th scope="col" class="kran-num">{m.ledger_credit()}</th>
          <th scope="col" class="kran-num">{m.ledger_debit()}</th>
          <th scope="col" class="kran-num">{m.ledger_credit()}</th>
        </tr>
      </thead>
      <tbody>
        {#each filteredLines as line, rowIndex (line.accountCode)}
          {@const rowActive = rowIndex === visibleRow}
          <tr>
            <th
              scope="row"
              id={ledgerCellId(rowIndex, 0)}
              class="ledger-code"
              class:ledger-cell--active={rowActive && activeColumn === 0}>{line.accountCode}</th
            >
            <td
              id={ledgerCellId(rowIndex, 1)}
              class="ledger-account"
              class:ledger-cell--active={rowActive && activeColumn === 1}>{line.accountName}</td
            >
            <td
              id={ledgerCellId(rowIndex, 2)}
              class="kran-money"
              class:ledger-cell--active={rowActive && activeColumn === 2}
              >{formatMoney(line.openingDebit)}</td
            >
            <td
              id={ledgerCellId(rowIndex, 3)}
              class="kran-money"
              class:ledger-cell--active={rowActive && activeColumn === 3}
              >{formatMoney(line.openingCredit)}</td
            >
            <td
              id={ledgerCellId(rowIndex, 4)}
              class="kran-money"
              class:ledger-cell--active={rowActive && activeColumn === 4}
              >{formatMoney(line.periodDebit)}</td
            >
            <td
              id={ledgerCellId(rowIndex, 5)}
              class="kran-money"
              class:ledger-cell--active={rowActive && activeColumn === 5}
              >{formatMoney(line.periodCredit)}</td
            >
            <td
              id={ledgerCellId(rowIndex, 6)}
              class="kran-money"
              class:ledger-cell--active={rowActive && activeColumn === 6}
              >{formatMoney(line.closingDebit)}</td
            >
            <td
              id={ledgerCellId(rowIndex, 7)}
              class="kran-money"
              class:ledger-cell--active={rowActive && activeColumn === 7}
              >{formatMoney(line.closingCredit)}</td
            >
          </tr>
        {/each}
        {#if filteredLines.length === 0}
          <tr>
            <td colspan="8" class="kran-muted">{m.ledger_filter_empty()}</td>
          </tr>
        {/if}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colspan="2">{m.ledger_total()}</th>
          <td class="kran-money">{formatMoney(totals.openingDebit)}</td>
          <td class="kran-money">{formatMoney(totals.openingCredit)}</td>
          <td class="kran-money">{formatMoney(totals.periodDebit)}</td>
          <td class="kran-money">{formatMoney(totals.periodCredit)}</td>
          <td class="kran-money">{formatMoney(totals.closingDebit)}</td>
          <td class="kran-money">{formatMoney(totals.closingCredit)}</td>
        </tr>
      </tfoot>
    </table>
  </div>
{/if}

<style>
  /* Layar-saja: cincin sel aktif pola `aria-activedescendant` dan kolom kode yang tetap
   * terlihat saat region digulir mendatar (DESIGN §10); sisanya milik lapisan bersama. */
  .ledger-account {
    min-inline-size: 12rem;
  }

  .ledger-table:focus .ledger-cell--active {
    outline: 2px solid var(--color-focus-ring);
    outline-offset: -2px;
  }
  @media screen {
    .ledger-table thead tr:first-child th:first-child,
    .ledger-table tbody th:first-child {
      position: sticky;
      inset-inline-start: 0;
      background: var(--color-surface);
    }
  }
</style>
