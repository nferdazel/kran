<script lang="ts">
  /**
   * Statement rekening A4 (T-094b, D-127): halaman cetak dokumen, bukan layar kerja.
   *
   * Rentang tanggal datang dari query (`?from=&to=`) atau diisi di form kecil yang tidak ikut
   * tercetak. Isi dokumen adalah **subledger**: baris transaksi tunai (masuk/keluar) dan PB
   * (sumber/tujuan) dengan arah relatif ke rekening ini. Tidak ada saldo berjalan per baris dan
   * total di kaki tabel hanya jumlah baris, bukan rekonsiliasi GL.
   *
   * PII minimal: nomor rekening, nominal, narasi, cabang. Tanpa nama/NIK/alamat.
   */
  import { goto } from "$app/navigation";
  import { page } from "$app/state";
  import { onMount } from "svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { formatDate, formatMoney } from "#lib/app/format.js";
  import {
    loadAccountStatement,
    printProblemMessage,
    rangeError,
    signedAmount,
    sortStatementRows,
    statementDirectionLabel,
    statementKindLabel,
    statementReference,
    statementStatusLabel,
    statementTotals,
    validateRange,
    type AccountStatement,
    type StatementRow,
    type StatementTotals,
  } from "#lib/app/print.js";
  import type { PageProps } from "./$types";

  let { params }: PageProps = $props();

  let fromInput = $state("");
  let toInput = $state("");
  let statement = $state<AccountStatement | null>(null);
  let rows = $state<StatementRow[]>([]);
  let totals = $state<StatementTotals>({ inflow: "0.00", outflow: "0.00", net: "0.00" });
  let loading = $state(false);
  let error = $state("");
  let rangeErrorText = $state("");

  async function load(fromText: string, toText: string): Promise<void> {
    const range = validateRange(fromText, toText);
    if (!range.ok) {
      rangeErrorText = rangeError(range.reason);
      return;
    }
    rangeErrorText = "";
    loading = true;
    error = "";
    try {
      const { data, response } = await loadAccountStatement(params.accountId, range.from, range.to);
      if (response.status === 401) {
        await goto("/login");
        return;
      }
      if (!response.ok || !data) {
        statement = null;
        rows = [];
        // 400 = rentang melebihi batas baris teknis server (format sudah divalidasi di klien).
        error =
          response.status === 400 ? m.print_range_limited() : printProblemMessage(response.status);
        return;
      }
      statement = data;
      rows = sortStatementRows(data.rows);
      totals = statementTotals(rows);
    } catch {
      statement = null;
      rows = [];
      error = m.print_error();
    } finally {
      loading = false;
    }
  }

  function submitRange(event: SubmitEvent): void {
    event.preventDefault();
    void load(fromInput, toInput);
  }

  function printDocument(): void {
    window.print();
  }

  onMount(() => {
    // Rentang boleh datang dari query; tanpa itu form yang menentukan (tanpa tebakan tanggal).
    const from = page.url.searchParams.get("from") ?? "";
    const to = page.url.searchParams.get("to") ?? "";
    if (from !== "" && to !== "") {
      fromInput = from;
      toInput = to;
      void load(from, to);
    }
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.print_title_statement()}</title>
</svelte:head>

<div class="kran-print-toolbar">
  <button
    class="kran-button kran-button--primary"
    type="button"
    onclick={printDocument}
    disabled={statement === null}
  >
    {m.print_button()}
  </button>
  <p class="kran-muted">{m.print_hint()}</p>
</div>

<form class="kran-form" aria-label={m.print_range_heading()} onsubmit={submitRange} novalidate>
  <div class="kran-print-range">
    <div class="kran-field">
      <label class="kran-label" for="statement-from">{m.print_range_from()}</label>
      <input
        class="kran-input"
        id="statement-from"
        name="from"
        type="date"
        bind:value={fromInput}
      />
    </div>
    <div class="kran-field">
      <label class="kran-label" for="statement-to">{m.print_range_to()}</label>
      <input class="kran-input" id="statement-to" name="to" type="date" bind:value={toInput} />
    </div>
  </div>
  {#if rangeErrorText !== ""}
    <p class="kran-alert" role="alert">{rangeErrorText}</p>
  {/if}
  <p>
    <button class="kran-button kran-button--primary" type="submit" disabled={loading}>
      {m.print_range_submit()}
    </button>
  </p>
</form>

{#if loading}
  <p role="status">{m.print_loading()}</p>
{:else if error !== ""}
  <p class="kran-alert" role="alert">{error}</p>
  <p>
    <button class="kran-button" type="button" onclick={() => void load(fromInput, toInput)}>
      {m.print_retry()}
    </button>
  </p>
{:else if statement !== null}
  {@const doc = statement}
  <article class="kran-print-doc" aria-labelledby="statement-heading">
    <h1 id="statement-heading" class="kran-print-title">{m.statement_heading()}</h1>

    <dl class="kran-print-meta">
      <dt>{m.statement_account_no()}</dt>
      <dd class="kran-print-ref">{doc.accountNo}</dd>
      <dt>{m.statement_status()}</dt>
      <dd>{statementStatusLabel(doc.status)}</dd>
      <dt>{m.statement_branch()}</dt>
      <dd class="kran-print-ref">{doc.branchId}</dd>
      <dt>{m.statement_period_label()}</dt>
      <dd>{m.statement_period({ from: formatDate(doc.from), to: formatDate(doc.to) })}</dd>
    </dl>

    <div class="kran-table-wrap">
      <table class="kran-table">
        <caption class="kran-visually-hidden">{m.statement_heading()}</caption>
        <thead>
          <tr>
            <th scope="col">{m.statement_col_date()}</th>
            <th scope="col">{m.statement_col_kind()}</th>
            <th scope="col">{m.statement_col_direction()}</th>
            <th scope="col">{m.statement_col_reference()}</th>
            <th scope="col">{m.statement_col_narration()}</th>
            <th scope="col" class="kran-num">{m.statement_col_amount()}</th>
          </tr>
        </thead>
        <tbody>
          {#if rows.length === 0}
            <tr>
              <td colspan="6">{m.statement_empty()}</td>
            </tr>
          {:else}
            {#each rows as row (`${row.businessDate}-${statementReference(row)}`)}
              <tr>
                <td>{formatDate(row.businessDate)}</td>
                <td>{statementKindLabel(row.kind)}</td>
                <td>{statementDirectionLabel(row.direction)}</td>
                <td class="kran-print-ref">{statementReference(row)}</td>
                <td>{row.narration}</td>
                <td class="kran-money">{signedAmount(row.direction, row.amount)}</td>
              </tr>
            {/each}
          {/if}
        </tbody>
        <tfoot>
          <tr>
            <th scope="row" colspan="5" class="kran-print-total">
              {m.statement_total_in()}<br />
              {m.statement_total_out()}<br />
              {m.statement_total_net()}
            </th>
            <td class="kran-money kran-print-total">
              {formatMoney(totals.inflow, { decimals: 2 })}<br />
              {formatMoney(totals.outflow, { decimals: 2 })}<br />
              {formatMoney(totals.net, { decimals: 2 })}
            </td>
          </tr>
        </tfoot>
      </table>
    </div>

    <p class="kran-muted kran-print-note">{m.statement_no_running_balance()}</p>
  </article>
{/if}
