<script lang="ts">
  /**
   * Slip transaksi tunai (T-094a, D-127): halaman cetak dokumen, bukan layar kerja.
   *
   * Dibuka ulang dari id transaksi — bukan dari respons POST — supaya cetak ulang setelah printer
   * macet tidak mengulang transaksi. Rute berada di bawah `/app`, jadi guard sesi layout induk
   * berlaku. Dokumen tetap tampil di layar (mode terang saat print dipaksa token `@media print`);
   * tombol Cetak hilang saat dicetak lewat `@media print` di `packages/ui`.
   *
   * PII minimal: nomor rekening, nominal, narasi. Tanpa nama/NIK/alamat. Tidak ada saldo berjalan
   * (tidak disimpan) dan bukan PDF resmi/arsip.
   */
  import { goto } from "$app/navigation";
  import { resolve } from "$app/paths";
  import { onMount } from "svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { formatDate, formatMoney } from "#lib/app/format.js";
  import {
    loadCashTransactionSlip,
    printProblemMessage,
    slipDirectionLabel,
    type CashTransactionSlip,
  } from "#lib/app/print.js";
  import type { PageProps } from "./$types";

  let { params }: PageProps = $props();

  let slip = $state<CashTransactionSlip | null>(null);
  let loading = $state(true);
  let error = $state("");

  async function load(): Promise<void> {
    loading = true;
    error = "";
    try {
      const { data, response } = await loadCashTransactionSlip(params.transactionId);
      if (response.status === 401) {
        await goto(resolve("/login"));
        return;
      }
      if (!response.ok || !data) {
        slip = null;
        error = printProblemMessage(response.status);
        return;
      }
      slip = data;
    } catch {
      slip = null;
      error = m.print_error();
    } finally {
      loading = false;
    }
  }

  function printDocument(): void {
    window.print();
  }

  onMount(() => {
    void load();
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.print_title_slip()}</title>
</svelte:head>

<div class="kran-print-toolbar">
  <button
    class="kran-button kran-button--primary"
    type="button"
    onclick={printDocument}
    disabled={slip === null}
  >
    {m.print_button()}
  </button>
  <p class="kran-muted">{m.print_hint()}</p>
</div>

{#if loading}
  <p role="status">{m.print_loading()}</p>
{:else if error !== ""}
  <p class="kran-alert" role="alert">{error}</p>
  <p>
    <button class="kran-button" type="button" onclick={() => void load()}>
      {m.print_retry()}
    </button>
  </p>
{:else if slip !== null}
  {@const doc = slip}
  <article class="kran-print-doc" aria-labelledby="slip-heading">
    <h1 id="slip-heading" class="kran-print-title">{m.slip_heading()}</h1>

    <dl class="kran-print-meta">
      <dt>{m.slip_account_no()}</dt>
      <dd class="kran-print-ref">{doc.accountNo}</dd>
      <dt>{m.slip_direction()}</dt>
      <dd>{slipDirectionLabel(doc.direction)}</dd>
      <dt>{m.slip_amount()}</dt>
      <dd class="kran-money">{formatMoney(doc.amount, { decimals: 2 })}</dd>
      <dt>{m.slip_business_date()}</dt>
      <dd>{formatDate(doc.businessDate)}</dd>
      <dt>{m.slip_transaction_id()}</dt>
      <dd class="kran-print-ref">{doc.transactionId}</dd>
      <dt>{m.slip_journal_id()}</dt>
      <dd class="kran-print-ref">{doc.journalId}</dd>
      {#if doc.narration !== ""}
        <dt>{m.slip_narration()}</dt>
        <dd>{doc.narration}</dd>
      {/if}
    </dl>
  </article>
{/if}
