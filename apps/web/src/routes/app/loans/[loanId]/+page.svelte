<script lang="ts">
  /**
   * Detail pinjaman (T-170): akad, saldo, **jadwal aktif**, dan riwayat versi jadwal.
   *
   * `installments` dari API hanya memuat jadwal aktif (T-169); jadwal yang diarsipkan
   * restrukturisasi tetap terlihat sebagai versi, bukan sebagai baris kewajiban. Saldo ditampilkan
   * apa adanya dari server — `null` berarti "belum ada" (pinjaman belum dicairkan), dan ditampilkan
   * "—" alih-alih `0,00`.
   */
  import { onMount } from "svelte";
  import { resolve } from "$app/paths";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import DataTable, { type DataColumn, type DataRow } from "@kran/ui/components/DataTable.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatDate, formatMoney } from "#lib/app/format.js";
  import { collectibilityLabel, loanProblemMessage, loanStatusLabel } from "#lib/app/loans.js";
  import type { LoanDetail, SessionInfo } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  let { data, params }: PageProps = $props();
  const session: SessionInfo = $derived(data.session);
  const canRead = $derived(session.permissions.includes("lending.loan.read"));

  let loan = $state<LoanDetail | null>(null);
  let loading = $state(true);
  let errorMessage = $state("");

  async function load(): Promise<void> {
    if (!canRead) {
      loading = false;
      return;
    }
    loading = true;
    errorMessage = "";
    try {
      const { data: body, error, response } = await api.GET("/api/v1/lending/loans/{loanId}", {
        params: { path: { loanId: params.loanId } },
      });
      if (!response.ok || !body) {
        loan = null;
        errorMessage = api.isProblem(error) ? loanProblemMessage(error) : m.loans_detail_error();
        return;
      }
      loan = body;
    } catch {
      loan = null;
      errorMessage = m.loans_detail_error();
    } finally {
      loading = false;
    }
  }

  function money(value: string | null): string {
    return value === null ? m.loans_value_none() : formatMoney(value);
  }

  const scheduleColumns: DataColumn[] = $derived([
    { key: "no", label: m.loans_schedule_no(), rowHeader: true },
    { key: "dueOn", label: m.loans_schedule_due() },
    { key: "principalDue", label: m.loans_schedule_principal(), numerics: true, align: "end" },
    { key: "interestDue", label: m.loans_schedule_interest(), numerics: true, align: "end" },
    { key: "penaltyDue", label: m.loans_schedule_penalty(), numerics: true, align: "end" },
    { key: "paidPrincipal", label: m.loans_schedule_paid(), numerics: true, align: "end" },
  ]);

  const scheduleRows: DataRow[] = $derived(
    (loan?.installments ?? []).map((item) => ({
      no: item.no,
      dueOn: formatDate(item.dueOn),
      principalDue: item.principalDue,
      interestDue: item.interestDue,
      penaltyDue: item.penaltyDue,
      paidPrincipal: item.paidPrincipal,
    })),
  );

  const versionColumns: DataColumn[] = $derived([
    { key: "versionNo", label: m.loans_version_no(), rowHeader: true },
    { key: "createdOn", label: m.loans_version_created() },
    { key: "reason", label: m.loans_version_reason() },
  ]);

  const versionRows: DataRow[] = $derived(
    (loan?.scheduleVersions ?? []).map((item) => ({
      versionNo: item.versionNo,
      createdOn: formatDate(item.createdOn),
      reason: item.reason,
    })),
  );

  const backHref = $derived(resolve("/app/loans"));

  onMount(() => {
    void load();
  });
</script>

<svelte:head>
  <title>{m.common_app_title()} — {m.loans_detail_title()}</title>
</svelte:head>

<div class="kran-page-header">
  <div>
    <h1 class="kran-page-header__title">{m.loans_detail_title()}</h1>
    <p class="kran-page-header__intro">{params.loanId}</p>
  </div>
</div>

<p>
  <a class="kran-link" href={backHref}>{m.loans_detail_back()}</a>
</p>

{#if !canRead}
  <Alert tone="negative" title={m.loans_denied()} />
{:else if loading}
  <p role="status">{m.loans_detail_loading()}</p>
{:else if errorMessage}
  <Alert tone="negative" title={errorMessage}>
    <Button type="button" onclick={() => void load()}>{m.app_retry()}</Button>
  </Alert>
{:else if loan === null}
  <EmptyState title={m.loans_detail_not_found()} />
{:else}
  <section class="kran-section" aria-labelledby="loans-facts-heading">
    <h2 class="kran-section__title" id="loans-facts-heading">{m.loans_detail_title()}</h2>
    <dl class="kran-facts">
      <dt class="kran-muted">{m.loans_col_loan()}</dt>
      <dd>{loan.loanId}</dd>

      <dt class="kran-muted">{m.loans_col_party()}</dt>
      <dd>{loan.partyId}</dd>

      <dt class="kran-muted">{m.loans_col_status()}</dt>
      <dd>{loanStatusLabel(loan.status)}</dd>

      <dt class="kran-muted">{m.loans_detail_principal()}</dt>
      <dd><span class="kran-num">{formatMoney(loan.principal)}</span></dd>

      <dt class="kran-muted">{m.loans_detail_disbursed()}</dt>
      <dd>
        {loan.disbursedOn === null
          ? m.loans_not_disbursed()
          : formatDate(loan.disbursedOn)}
      </dd>

      <dt class="kran-muted">{m.loans_detail_maturity()}</dt>
      <dd>{loan.maturityOn === null ? m.loans_value_none() : formatDate(loan.maturityOn)}</dd>

      <dt class="kran-muted">{m.loans_detail_collectibility()}</dt>
      <dd>{collectibilityLabel(loan.collectibility)}</dd>

      <dt class="kran-muted">{m.loans_detail_outstanding()}</dt>
      <dd><span class="kran-num">{money(loan.principalOutstanding)}</span></dd>

      <dt class="kran-muted">{m.loans_detail_interest_overdue()}</dt>
      <dd><span class="kran-num">{money(loan.interestOverdue)}</span></dd>

      <dt class="kran-muted">{m.loans_detail_penalty()}</dt>
      <dd><span class="kran-num">{money(loan.penaltyOutstanding)}</span></dd>
    </dl>
  </section>

  <section class="kran-section" aria-labelledby="loans-schedule-heading">
    <h2 class="kran-section__title" id="loans-schedule-heading">{m.loans_detail_schedule()}</h2>
    {#if scheduleRows.length === 0}
      <EmptyState title={m.loans_detail_schedule_empty()} />
    {:else}
      <DataTable
        caption={m.loans_detail_schedule()}
        ariaLabel={m.common_table_region({ name: m.loans_detail_schedule() })}
        captionHidden
        columns={scheduleColumns}
        rows={scheduleRows}
        rowKey="no"
      />
    {/if}
  </section>

  <section class="kran-section" aria-labelledby="loans-versions-heading">
    <h2 class="kran-section__title" id="loans-versions-heading">{m.loans_detail_versions()}</h2>
    {#if versionRows.length === 0}
      <EmptyState title={m.loans_detail_versions_empty()} />
    {:else}
      <DataTable
        caption={m.loans_detail_versions()}
        ariaLabel={m.common_table_region({ name: m.loans_detail_versions() })}
        captionHidden
        columns={versionColumns}
        rows={versionRows}
        rowKey="versionNo"
      />
    {/if}
  </section>
{/if}
