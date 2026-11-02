<script lang="ts">
  /**
   * Detail pinjaman (T-170) + empat aksi tulis (T-173): akad, saldo, **jadwal aktif**, riwayat
   * versi jadwal, pencairan, pembayaran angsuran, restrukturisasi, dan hapus buku.
   *
   * `installments` dari API hanya memuat jadwal aktif (T-169); jadwal yang diarsipkan
   * restrukturisasi tetap terlihat sebagai versi, bukan sebagai baris kewajiban. Saldo ditampilkan
   * apa adanya dari server — `null` berarti "belum ada" (pinjaman belum dicairkan), dan ditampilkan
   * "—" alih-alih `0,00`.
   *
   * Keputusan yang mengikat untuk aksi tulis (T-173):
   *  - Server otoritas terakhir. Tombol hanya tampil bila izinnya dipegang, dan hanya untuk status
   *    yang pasti menerimanya; sebab lain (mis. `not_loss`) dipetakan dari `params.reason`.
   *  - Pratinjau = dialog konfirmasi berisi angka yang **akan dikirim**, bukan hitungan ulang di
   *    peramban. Uang tetap string desimal — `formatMoney` hanya menampilkan, tidak mengubah nilai.
   *  - `Idempotency-Key` dibuat saat dialog dibuka; `5xx`/jaringan mempertahankannya supaya "Kirim"
   *    ulang menjadi replay, sedangkan sukses atau `4xx` (final) membuangnya.
   *  - Setelah sukses detail dimuat ulang dan `Alert` sukses menyebut nomor jurnal atau jumlah
   *    angsuran + jatuh tempo.
   *
   * Dialog memakai elemen native + focus trap eksplisit, pola yang sama dengan monitor penutupan
   * buku. Berkas ini tidak punya CSS lokal; tata letak memakai kelas bersama `packages/ui`.
   */
  import { onMount, tick } from "svelte";
  import { resolve } from "$app/paths";

  import type { Problem } from "@kran/api-client";

  import Alert from "@kran/ui/components/Alert.svelte";
  import Button from "@kran/ui/components/Button.svelte";
  import DataTable, { type DataColumn, type DataRow } from "@kran/ui/components/DataTable.svelte";
  import EmptyState from "@kran/ui/components/EmptyState.svelte";
  import Field from "@kran/ui/components/Field.svelte";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatDate, formatMoney } from "#lib/app/format.js";
  import {
    LOAN_REASON_MAX_LENGTH,
    activePartyAccounts,
    collectibilityLabel,
    loadPartyAccounts,
    loanActionProblemMessage,
    loanDisburse,
    loanPay,
    loanProblemMessage,
    loanRestructure,
    loanStatusLabel,
    loanWriteOff,
    paymentAmountPreview,
    validateLoanReason,
    validatePaymentAmount,
    validateTenor,
    type LoanAction,
  } from "#lib/app/loans.js";
  import { newIdempotencyKey } from "#lib/app/teller.js";
  import type { DepositAccount, LoanDetail, SessionInfo } from "#lib/app/types.js";
  import type { PageProps } from "./$types";

  let { data, params }: PageProps = $props();
  const session: SessionInfo = $derived(data.session);
  const canRead = $derived(session.permissions.includes("lending.loan.read"));
  const canDisburse = $derived(session.permissions.includes("lending.loan.disburse"));
  const canPay = $derived(session.permissions.includes("lending.loan.pay"));
  const canRestructure = $derived(session.permissions.includes("lending.loan.restructure"));
  const canWriteOff = $derived(session.permissions.includes("lending.loan.write_off"));
  const canWrite = $derived(canDisburse || canPay || canRestructure || canWriteOff);
  /** Hanya dua aksi ini yang butuh rekening; aksi lain tidak memuat daftar rekening. */
  const needsAccounts = $derived(canDisburse || canPay);

  let loan = $state<LoanDetail | null>(null);
  let loading = $state(true);
  let errorMessage = $state("");

  /** Rekening anggota akad; hanya `ACTIVE` yang ditawarkan (server tetap memvalidasi). */
  let accounts = $state<DepositAccount[]>([]);
  let accountsLoading = $state(false);
  let accountsError = $state("");

  let panelAction = $state<LoanAction | null>(null);
  let selectedAccountId = $state("");
  let amountRaw = $state("");
  let tenorRaw = $state("");
  let reasonRaw = $state("");
  let accountError = $state("");
  let amountError = $state("");
  let tenorError = $state("");
  let reasonError = $state("");

  interface PendingAction {
    kind: LoanAction;
    /** Rekening sumber/tujuan; `null` untuk aksi tanpa rekening. */
    account: DepositAccount | null;
    /** Desimal polos 2 desimal yang dikirim apa adanya (`""` bila aksi tidak memakai nominal). */
    amount: string;
    tenorMonths: number;
    reason: string;
  }

  let pending = $state<PendingAction | null>(null);
  let actionError = $state("");
  let busy = $state(false);
  let notice = $state<{ title: string; reference: string } | null>(null);
  /**
   * Kunci idempotensi dialog yang sedang terbuka (D-098): dibuat saat dialog dibuka, dipakai ulang
   * selama pengiriman, dan hanya dibuang setelah sukses atau penolakan final (4xx).
   */
  let idempotencyKey = $state("");

  /**
   * Kunci yang dipertahankan setelah hasil kiriman **tidak pasti** (5xx/jaringan/Esc saat
   * mengirim). Dibuka lagi dengan isian yang sama = replay, bukan operasi baru (D-098).
   */
  let retry = $state<{ key: string; fingerprint: string } | null>(null);

  let dialogEl = $state<HTMLDialogElement | undefined>(undefined);
  /** Elemen pemegang fokus sebelum dialog dibuka; dikembalikan saat dialog ditutup. */
  let restoreFocusTo: HTMLElement | null = null;

  /** Sidik isian: kunci hanya dipakai ulang bila body yang dikirim identik. */
  function actionFingerprint(value: PendingAction): string {
    if (value.kind === "disburse") {
      return value.account === null ? "" : `disburse|${value.account.accountId}`;
    }
    if (value.kind === "payment") {
      return value.account === null
        ? ""
        : `payment|${value.account.accountId}|${value.amount}`;
    }
    if (value.kind === "restructure") return `restructure|${value.tenorMonths}|${value.reason}`;
    return `write-off|${value.reason}`;
  }

  /**
   * Fokus ke kontrol tidak sah pertama. `Field` hanya mengaitkan galat lewat `aria-describedby`,
   * jadi tanpa ini pengguna keyboard tidak tahu apa yang menahan pratinjau (spec §17.1).
   */
  function focusFirstError(): void {
    const entries: Array<[string, string]> = [
      [accountError, "loans-action-account"],
      [amountError, "loans-action-amount"],
      [tenorError, "loans-action-tenor"],
      [reasonError, "loans-action-reason"],
    ];
    const hit = entries.find(([message]) => message !== "");
    if (hit === undefined) return;
    document.getElementById(hit[1])?.focus();
  }

  const FEEDBACK_FOCUSABLE =
    "button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), a[href]";

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
        accounts = [];
        errorMessage = api.isProblem(error) ? loanProblemMessage(error) : m.loans_detail_error();
        return;
      }
      loan = body;
      if (needsAccounts) await loadAccounts(body.partyId);
    } catch {
      loan = null;
      accounts = [];
      errorMessage = m.loans_detail_error();
    } finally {
      loading = false;
    }
  }

  async function loadAccounts(partyId: string): Promise<void> {
    accountsLoading = true;
    accountsError = "";
    try {
      const { data: body, error, response } = await loadPartyAccounts(partyId);
      if (!response.ok || !body) {
        accounts = [];
        accountsError = api.isProblem(error)
          ? loanActionProblemMessage(error)
          : m.loans_accounts_error();
        return;
      }
      accounts = body.items;
      // Pilihan lama yang tidak lagi aktif/sah dibuang, bukan dikirim lalu ditolak server.
      const chosen = activePartyAccounts(body.items).some(
        (account) => account.accountId === selectedAccountId,
      );
      if (!chosen) selectedAccountId = "";
    } catch {
      accounts = [];
      accountsError = m.loans_accounts_error();
    } finally {
      accountsLoading = false;
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

  const activeAccounts = $derived(activePartyAccounts(accounts, loan?.branchId));
  const selectedAccount = $derived(
    activeAccounts.find((account) => account.accountId === selectedAccountId) ?? null,
  );
  const amountPreview = $derived(paymentAmountPreview(amountRaw));

  interface ActionItem {
    kind: LoanAction;
    label: string;
  }

  /**
   * Aksi yang ditawarkan: izin dipegang **dan** status akad adalah status yang pasti diterima.
   * Sebab lain yang tidak bisa dipastikan dari data (mis. `not_loss` untuk hapus buku) dibiarkan
   * ke server dan dipetakan ke pesan.
   */
  const actionItems: ActionItem[] = $derived.by(() => {
    const status = loan?.status ?? "";
    const items: ActionItem[] = [];
    if (canDisburse && status === "APPROVED") {
      items.push({ kind: "disburse", label: m.loans_action_disburse() });
    }
    if (canPay && status === "ACTIVE") {
      items.push({ kind: "payment", label: m.loans_action_payment() });
    }
    if (canRestructure && status === "ACTIVE") {
      items.push({ kind: "restructure", label: m.loans_action_restructure() });
    }
    if (canWriteOff && status === "ACTIVE") {
      items.push({ kind: "write-off", label: m.loans_action_write_off() });
    }
    return items;
  });

  /** Panel yang benar-benar dirender; aksi yang izinnya/statusnya berubah menghilang, bukan basi. */
  const panel = $derived(
    panelAction !== null && actionItems.some((item) => item.kind === panelAction)
      ? panelAction
      : null,
  );
  /** Aksi berlaci rekening tidak bisa ditinjau selama daftar rekening belum siap/kosong. */
  const accountStepBlocked = $derived(
    (panel === "disburse" || panel === "payment") &&
      (accountsLoading || accountsError !== "" || activeAccounts.length === 0),
  );

  function selectAction(kind: LoanAction): void {
    if (busy) return;
    panelAction = panelAction === kind ? null : kind;
    accountError = "";
    amountError = "";
    tenorError = "";
    reasonError = "";
    actionError = "";
  }

  function confirmTitle(kind: LoanAction): string {
    if (kind === "disburse") return m.loans_confirm_disburse_title();
    if (kind === "payment") return m.loans_confirm_payment_title();
    if (kind === "restructure") return m.loans_confirm_restructure_title();
    return m.loans_confirm_write_off_title();
  }

  /** Konsekuensi dari data yang ada; jumlah angsuran & jatuh tempo hasilnya datang dari server. */
  function consequenceText(value: PendingAction): string {
    if (value.kind === "disburse") {
      return m.loans_confirm_consequence_disburse({ status: loanStatusLabel("ACTIVE") });
    }
    if (value.kind === "payment") return m.loans_confirm_consequence_payment();
    if (value.kind === "restructure") {
      return m.loans_confirm_consequence_restructure({
        status: loanStatusLabel("ACTIVE"),
        count: value.tenorMonths,
      });
    }
    return m.loans_confirm_consequence_write_off({ status: loanStatusLabel("WRITTEN_OFF") });
  }

  /**
   * Isi pratinjau dari form; `false` berarti ada field yang belum sah dan dialog tidak dibuka.
   * Tidak ada aritmetika uang di sini: disburse memakai `loan.principal` apa adanya, pembayaran
   * memakai hasil parser uang (`@kran/ui/money`).
   */
  function buildPending(kind: LoanAction): boolean {
    accountError = "";
    amountError = "";
    tenorError = "";
    reasonError = "";
    if (loan === null) return false;

    if ((kind === "disburse" || kind === "payment") && selectedAccount === null) {
      accountError = m.loans_error_account_required();
      return false;
    }

    let amount = "";
    if (kind === "payment") {
      const check = validatePaymentAmount(amountRaw);
      if (!check.ok) {
        amountError = check.message;
        return false;
      }
      amount = check.amount;
    } else if (kind === "disburse") {
      amount = loan.principal;
    }

    let tenorMonths = 0;
    if (kind === "restructure") {
      const check = validateTenor(tenorRaw);
      if (!check.ok) {
        tenorError = check.message;
        return false;
      }
      tenorMonths = check.tenorMonths;
    }

    let reason = "";
    if (kind === "restructure" || kind === "write-off") {
      const check = validateLoanReason(reasonRaw);
      if (!check.ok) {
        reasonError = check.message;
        return false;
      }
      reason = check.reason;
    }

    pending = {
      kind,
      account: selectedAccount,
      amount,
      tenorMonths,
      reason,
    };
    return true;
  }

  async function openPreview(kind: LoanAction): Promise<void> {
    if (busy) return;
    if (!buildPending(kind)) {
      focusFirstError();
      return;
    }
    const value = pending;
    if (value === null) return;
    actionError = "";
    notice = null;
    const fingerprint = actionFingerprint(value);
    retry = retry !== null && retry.fingerprint !== fingerprint ? null : retry;
    idempotencyKey = retry !== null ? retry.key : newIdempotencyKey();
    restoreFocusTo =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    await tick();
    const dialog = dialogEl;
    if (dialog !== undefined && !dialog.open) dialog.showModal();
    document.getElementById("loans-confirm-dismiss")?.focus();
  }

  function closeDialog(): void {
    dialogEl?.close();
  }

  /** `close` datang dari Esc, tombol batal, atau `closeDialog()`: satu jalur pemulihan fokus. */
  function onDialogClose(): void {
    // Kunci belum dipakai bila kiriman tidak pernah jalan; menyimpannya tidak berbahaya, dan
    // dibutuhkan saat hasil kiriman tidak pasti (timeout/jaringan) supaya "Kirim" berikutnya replay.
    if (pending !== null && idempotencyKey !== "") {
      retry = { key: idempotencyKey, fingerprint: actionFingerprint(pending) };
    }
    pending = null;
    actionError = "";
    idempotencyKey = "";
    const target = restoreFocusTo;
    restoreFocusTo = null;
    // Pemicu bisa sudah tidak ada karena daftar aksi berubah setelah muat ulang; jatuh ke landmark.
    if (target !== null && target.isConnected) {
      target.focus();
      return;
    }
    document.getElementById("main")?.focus();
  }

  function trapTab(event: KeyboardEvent): void {
    const dialog = dialogEl;
    if (dialog === undefined) return;
    const focusables = [...dialog.querySelectorAll<HTMLElement>(FEEDBACK_FOCUSABLE)];
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    if (first === undefined || last === undefined) return;
    const active = document.activeElement;
    if (event.shiftKey) {
      const inside = active instanceof Node && dialog.contains(active);
      if (!inside || active === first) {
        event.preventDefault();
        last.focus();
      }
      return;
    }
    if (active === last) {
      event.preventDefault();
      first.focus();
    }
  }

  /** `cancel` (Esc bawaan peramban) juga tidak boleh menutup dialog saat permintaan berjalan. */
  function onDialogCancel(event: Event): void {
    if (busy) event.preventDefault();
  }

  function onDialogKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      event.preventDefault();
      // Esc saat permintaan berjalan: jangan tutup. Hasilnya belum pasti, dan kunci replay hilang
      // bila dialog dibuang (pola yang sama dengan teller: `errorKind === "unknown"`).
      if (busy) return;
      closeDialog();
      return;
    }
    if (event.key === "Tab") trapTab(event);
  }

  /**
   * 4xx = penolakan final: kunci dibuang supaya kiriman berikutnya adalah permintaan baru.
   * 5xx/jaringan bukan final: kunci dipertahankan supaya "Kirim" ulang menjadi replay.
   */
  function failAction(problem: Problem | undefined, status: number): void {
    actionError = problem === undefined ? m.error_generic() : loanActionProblemMessage(problem);
    if (status < 500) {
      // Penolakan final: kiriman berikutnya adalah permintaan baru, bukan replay.
      idempotencyKey = "";
      retry = null;
    }
  }

  async function succeed(title: string, reference: string): Promise<void> {
    idempotencyKey = "";
    retry = null;
    pending = null;
    // Pemicu (tombol "Tinjau") ikut hilang saat panel ditutup; fokus jatuh ke landmark utama.
    restoreFocusTo = null;
    closeDialog();
    panelAction = null;
    notice = { title, reference };
    await load();
  }

  async function submit(): Promise<void> {
    const value = pending;
    if (value === null || busy) return;
    busy = true;
    actionError = "";
    if (idempotencyKey === "") idempotencyKey = newIdempotencyKey();
    const key = idempotencyKey;
    try {
      if (value.kind === "disburse") {
        const account = value.account;
        if (account === null) return;
        const { data: body, error, response } = await loanDisburse(
          params.loanId,
          { accountId: account.accountId },
          key,
        );
        if (!response.ok || body === undefined) {
          failAction(api.isProblem(error) ? error : undefined, response.status);
          return;
        }
        await succeed(
          m.loans_notice_disbursed({
            count: body.installmentCount,
            date: formatDate(body.maturityOn),
          }),
          body.journalId,
        );
        return;
      }
      if (value.kind === "payment") {
        const account = value.account;
        if (account === null) return;
        const { data: body, error, response } = await loanPay(
          params.loanId,
          { accountId: account.accountId, amount: value.amount },
          key,
        );
        if (!response.ok || body === undefined) {
          failAction(api.isProblem(error) ? error : undefined, response.status);
          return;
        }
        await succeed(
          m.loans_notice_paid({ outstanding: formatMoney(body.principalOutstanding) }),
          body.journalIds[0] ?? "",
        );
        return;
      }
      if (value.kind === "restructure") {
        const { data: body, error, response } = await loanRestructure(
          params.loanId,
          { tenorMonths: value.tenorMonths, reason: value.reason },
          key,
        );
        if (!response.ok || body === undefined) {
          failAction(api.isProblem(error) ? error : undefined, response.status);
          return;
        }
        await succeed(
          m.loans_notice_restructured({
            count: body.installmentCount,
            date: formatDate(body.maturityOn),
          }),
          "",
        );
        return;
      }
      const { data: body, error, response } = await loanWriteOff(
        params.loanId,
        { reason: value.reason },
        key,
      );
      if (!response.ok || body === undefined) {
        failAction(api.isProblem(error) ? error : undefined, response.status);
        return;
      }
      await succeed(
        m.loans_notice_written_off({ total: formatMoney(body.total) }),
        body.journalIds[0] ?? "",
      );
    } catch {
      // Batas waktu/jaringan putus: hasilnya tidak diketahui. Kunci dipertahankan (replay), aksi
      // tidak diulang otomatis.
      actionError = m.loans_error_unknown();
    } finally {
      busy = false;
    }
  }

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

{#if notice}
  <Alert tone="positive" title={notice.title} reference={notice.reference} />
{/if}

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

  {#if canWrite}
    <section class="kran-section" aria-labelledby="loans-actions-heading">
      <h2 class="kran-section__title" id="loans-actions-heading">
        {m.loans_actions_heading()}
      </h2>
      <p class="kran-muted">{m.loans_actions_intro()}</p>

      {#if actionItems.length === 0}
        <p class="kran-muted">{m.loans_actions_none()}</p>
      {:else}
        <div class="kran-actions">
          {#each actionItems as item (item.kind)}
            <Button
              type="button"
              onclick={() => selectAction(item.kind)}
              disabled={busy}
              aria-expanded={panel === item.kind}
              aria-controls={panel === item.kind ? "loans-action-form" : undefined}
            >
              {item.label}
            </Button>
          {/each}
        </div>
      {/if}

      {#if panel !== null}
        <div class="kran-stack" id="loans-action-form">
          {#if panel === "disburse" || panel === "payment"}
            {#if accountsLoading}
              <p class="kran-muted" role="status">{m.loans_accounts_loading()}</p>
            {:else if accountsError !== ""}
              <Alert tone="negative" title={accountsError} />
            {:else}
              <Field
                label={m.loans_field_source_account()}
                id="loans-action-account"
                error={accountError}
                hint={m.loans_field_source_account_hint()}
                required
              >
                {#snippet children(control)}
                  <select
                    class="kran-select"
                    id={control.id}
                    aria-describedby={control.describedby}
                    aria-invalid={control.invalid}
                    required={control.required}
                    bind:value={selectedAccountId}
                    onchange={() => (accountError = "")}
                  >
                    <option value="">{m.loans_field_source_account_choose()}</option>
                    {#each activeAccounts as account (account.accountId)}
                      <option value={account.accountId}>{account.accountNo}</option>
                    {/each}
                  </select>
                {/snippet}
              </Field>
              {#if activeAccounts.length === 0}
                <p class="kran-muted">{m.loans_field_source_account_empty()}</p>
              {/if}
            {/if}
          {/if}

          {#if panel === "payment"}
            <Field
              label={m.loans_field_amount()}
              id="loans-action-amount"
              error={amountError}
              hint={m.loans_field_amount_hint()}
              required
            >
              {#snippet children(control)}
                <input
                  class="kran-input"
                  id={control.id}
                  aria-describedby={control.describedby}
                  aria-invalid={control.invalid}
                  required={control.required}
                  inputmode="decimal"
                  autocomplete="off"
                  bind:value={amountRaw}
                  oninput={() => (amountError = "")}
                />
              {/snippet}
            </Field>
            {#if amountPreview !== ""}
              <p class="kran-muted">
                <span class="kran-num">{formatMoney(amountPreview)}</span>
              </p>
            {/if}
          {/if}

          {#if panel === "restructure"}
            <Field
              label={m.loans_field_tenor()}
              id="loans-action-tenor"
              error={tenorError}
              required
            >
              {#snippet children(control)}
                <input
                  class="kran-input"
                  id={control.id}
                  aria-describedby={control.describedby}
                  aria-invalid={control.invalid}
                  required={control.required}
                  inputmode="numeric"
                  autocomplete="off"
                  bind:value={tenorRaw}
                  oninput={() => (tenorError = "")}
                />
              {/snippet}
            </Field>
          {/if}

          {#if panel === "restructure" || panel === "write-off"}
            <Field
              label={m.loans_field_reason()}
              id="loans-action-reason"
              error={reasonError}
              hint={m.loans_field_reason_hint()}
              required
            >
              {#snippet children(control)}
                <textarea
                  class="kran-input"
                  id={control.id}
                  aria-describedby={control.describedby}
                  aria-invalid={control.invalid}
                  required={control.required}
                  rows="3"
                  maxlength={LOAN_REASON_MAX_LENGTH}
                  bind:value={reasonRaw}
                  oninput={() => (reasonError = "")}
                ></textarea>
              {/snippet}
            </Field>
          {/if}

          <div class="kran-actions">
            <Button
              variant="primary"
              type="button"
              onclick={() => void openPreview(panel)}
              disabled={busy || accountStepBlocked}
            >
              {m.loans_review_submit()}
            </Button>
          </div>
        </div>
      {/if}
    </section>
  {/if}

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

<dialog
  bind:this={dialogEl}
  class="kran-dialog"
  aria-labelledby="loans-confirm-title"
  aria-describedby="loans-confirm-body"
  onkeydown={onDialogKeydown}
  oncancel={onDialogCancel}
  onclose={onDialogClose}
>
  {#if pending !== null}
    <div class="kran-stack">
      <h2 class="kran-section__title" id="loans-confirm-title">
        {confirmTitle(pending.kind)}
      </h2>

      <dl class="kran-facts">
        {#if pending.kind === "disburse"}
          <dt class="kran-muted">{m.loans_confirm_principal()}</dt>
          <dd><span class="kran-num">{formatMoney(pending.amount)}</span></dd>
        {:else if pending.kind === "payment"}
          <dt class="kran-muted">{m.loans_field_amount()}</dt>
          <dd><span class="kran-num">{formatMoney(pending.amount)}</span></dd>
        {/if}

        {#if pending.account !== null}
          <dt class="kran-muted">{m.loans_confirm_account()}</dt>
          <dd>{pending.account.accountNo}</dd>

          <dt class="kran-muted">{m.loans_confirm_balance()}</dt>
          <dd><span class="kran-num">{formatMoney(pending.account.balance)}</span></dd>
        {/if}

        {#if pending.kind === "restructure"}
          <dt class="kran-muted">{m.loans_field_tenor()}</dt>
          <dd>{pending.tenorMonths}</dd>
        {/if}

        {#if pending.reason !== ""}
          <dt class="kran-muted">{m.loans_field_reason()}</dt>
          <dd>{pending.reason}</dd>
        {/if}
      </dl>

      <div>
        <p class="kran-muted">{m.loans_confirm_consequence()}</p>
        <p id="loans-confirm-body">{consequenceText(pending)}</p>
      </div>

      <p class="kran-muted">{m.loans_confirm_note()}</p>

      {#if actionError}
        <Alert tone="negative" title={actionError} />
      {/if}

      {#if busy}
        <p class="kran-muted" role="status">{m.loans_confirm_sending()}</p>
      {/if}

      <div class="kran-actions">
        <Button
          id="loans-confirm-dismiss"
          type="button"
          onclick={closeDialog}
          disabled={busy}
        >
          {m.loans_confirm_cancel()}
        </Button>
        <Button
          variant={pending.kind === "write-off" ? "destructive" : "primary"}
          type="button"
          onclick={() => void submit()}
          loading={busy}
        >
          {m.loans_confirm_send()}
        </Button>
      </div>
    </div>
  {/if}
</dialog>
