<script lang="ts">
  /**
   * Layar kerja teller (T-088d): setor, tarik, dan pemindahbukuan (PB) pada satu rekening simpanan.
   *
   * Arah visual (DESIGN §1/§4): satu bidang kerja, bukan dashboard. Kiri = rekening (nomor, status,
   * saldo saat dimuat); kanan = transaksi. Bidang kanan turun ke bawah di layar < 1100 px, bukan jadi
   * modal (DESIGN §4). Angka memakai `formatMoney` 2 desimal + `tabular-nums`; simbol mata uang ada di
   * label/kolom, bukan di sel (DESIGN §6).
   *
   * Konfirmasi transaksi finansial memakai **tinjauan inline satu lapisan**, bukan modal (keputusan
   * pemilik pada brief §8/Q3; menyimpang dari DESIGN §7 yang melarang konfirmasi untuk aksi rutin).
   *
   * Panel sesi kas (T-108) memakai pola tinjauan yang sama: buka/tutup sesi dikonfirmasi satu
   * lapisan sebelum dikirim, karena keduanya memindahkan uang fisik. Cabang sesi = cabang rekening
   * yang sedang dimuat (tidak ada pemilih cabang dan `SessionInfo` tidak membawa cabang), jadi panel
   * menunggu rekening termuat dan form transaksi ditutup selama sesi belum pasti (fail-closed).
   *
   * TODO(T-105): `accountId` masih diisi UUID manual karena endpoint cari-nomor-rekening belum ada.
   * Ganti input ini dengan pencarian nomor rekening begitu backend menyediakannya.
   */
  import { goto } from "$app/navigation";
  import { page } from "$app/state";
  import { onMount, tick } from "svelte";

  import type { Problem } from "@kran/api-client";

  import * as m from "#lib/paraglide/messages.js";
  import { api } from "#lib/app/api.js";
  import { formatClock, formatDate, formatDateTime, formatMoney } from "#lib/app/format.js";
  import {
    SESSION_NOTE_MAX_LENGTH,
    closeTellerSession,
    currentSessionOutcome,
    loadCurrentTellerSession,
    openTellerSession,
    sessionCloseIdentity,
    sessionNoteError,
    sessionOpenIdentity,
    sessionPostingGate,
    tellerSessionProblemMessage,
    validateCountedCash,
    validateOpeningFloat,
    varianceSummary,
    type TellerSession,
    type TellerSessionClose,
    type TellerSessionFormError,
  } from "#lib/app/teller-session.js";
  import {
    NARRATION_MAX_LENGTH,
    SHORTCUT_PARAM_KEYS,
    cashIdentity,
    ACCOUNT_NO_MAX_LENGTH,
    loadDepositAccountByNo,
    newIdempotencyKey,
    postCashTransaction,
    postTransfer,
    previewAmount,
    savingsKindLabel,
    shortcutModeForKey,
    tellerProblemMessage,
    transferIdentity,
    validateCashForm,
    validateTransferForm,
    type CashDirection,
    type CashTransaction,
    type DepositAccount,
    type TellerField,
    type TellerFormError,
    type TellerMode,
    type Transfer,
  } from "#lib/app/teller.js";
  import type { PageProps } from "./$types";

  type PendingCash = {
    kind: "cash";
    direction: CashDirection;
    accountId: string;
    amount: string;
    narration: string;
  };

  type PendingTransfer = {
    kind: "transfer";
    sourceAccountId: string;
    destinationAccountId: string;
    amount: string;
    narration: string;
  };

  type Pending = PendingCash | PendingTransfer;

  type TellerResult =
    | { kind: "cash"; transaction: CashTransaction }
    | { kind: "transfer"; transfer: Transfer };

  /** Hasil `GET /teller/sessions/current`. `idle` = rekening belum dimuat, jadi cabang belum ada. */
  type SessionState =
    | { kind: "idle" }
    | { kind: "loading" }
    | { kind: "failed"; message: string }
    | { kind: "missing" }
    | { kind: "open"; session: TellerSession };

  type PendingSession =
    | { kind: "open"; openingFloat: string; note: string }
    | { kind: "close"; sessionId: string; countedCash: string; note: string };

  type SessionPhase = "idle" | "open" | "open_review" | "close" | "close_review";

  let { data }: PageProps = $props();

  const canPost = $derived(data.session.permissions.includes("teller.transaction.post"));

  // Rekening.
  let accountNoInput = $state("");
  let account = $state<DepositAccount | null>(null);
  let accountLoading = $state(false);
  let accountError = $state("");
  let loadedAtMs = $state<number | null>(null);

  // Pintasan papan tunai (T-095), dibaca dari parameter; kosong = tidak aktif.
  let shortcuts = $state<Partial<Record<TellerMode, string>>>({});

  // Form transaksi.
  let mode = $state<TellerMode>("DEPOSIT");
  let destinationInput = $state("");
  let amountRaw = $state("");
  let narration = $state("");

  // Alur: form → tinjauan → hasil. Galat tidak memindahkan halaman (DESIGN §7/§8).
  let phase = $state<"edit" | "review" | "done">("edit");
  let pending = $state<Pending | null>(null);
  let result = $state<TellerResult | null>(null);
  let saving = $state(false);
  let fieldError = $state<TellerFormError | null>(null);
  let transactionError = $state("");
  let errorTrace = $state("");
  let errorKind = $state<"none" | "failed" | "unknown">("none");
  let announcement = $state("");

  /**
   * Kunci idempotensi per sidik isi form. Dipertahankan saat gagal 5xx/jaringan supaya "Coba lagi"
   * jadi replay 200, bukan transaksi kedua (D-098/D-117); dibuang setelah sukses atau setelah 4xx.
   */
  let idempotencyKey = $state("");
  let idempotencyIdentity = $state("");

  // Sesi kas (T-108).
  let sessionState = $state<SessionState>({ kind: "idle" });
  let sessionPhase = $state<SessionPhase>("idle");
  let pendingSession = $state<PendingSession | null>(null);
  /** Dinyalakan 409 `session_business_date_mismatch`: sesi OPEN milik tanggal bisnis lain. */
  let sessionStale = $state(false);
  let closeResult = $state<TellerSessionClose | null>(null);
  let openingFloatRaw = $state("");
  let countedCashRaw = $state("");
  let sessionNote = $state("");
  let sessionWorking = $state(false);
  let sessionFormError = $state<TellerSessionFormError | null>(null);
  let sessionError = $state("");
  let sessionErrorTrace = $state("");
  let sessionErrorUnknown = $state(false);
  let sessionKey = $state("");
  let sessionKeyIdentity = $state("");

  let accountInputEl = $state<HTMLInputElement | undefined>(undefined);
  let destinationEl = $state<HTMLInputElement | undefined>(undefined);
  let amountEl = $state<HTMLInputElement | undefined>(undefined);
  let narrationEl = $state<HTMLInputElement | undefined>(undefined);
  let reviewHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let successHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let errorAlertEl = $state<HTMLParagraphElement | undefined>(undefined);
  let sessionHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let sessionFormHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let sessionReviewHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let sessionClosedHeadingEl = $state<HTMLHeadingElement | undefined>(undefined);
  let sessionFloatEl = $state<HTMLInputElement | undefined>(undefined);
  let sessionCountedEl = $state<HTMLInputElement | undefined>(undefined);
  let sessionNoteEl = $state<HTMLInputElement | undefined>(undefined);
  let sessionAlertEl = $state<HTMLParagraphElement | undefined>(undefined);

  const modeOptions = $derived<{ value: TellerMode; label: string }[]>([
    { value: "DEPOSIT", label: m.teller_direction_deposit() },
    { value: "WITHDRAWAL", label: m.teller_direction_withdrawal() },
    { value: "TRANSFER", label: m.teller_direction_transfer() },
  ]);

  const amountPreview = $derived(previewAmount(amountRaw));
  const amountPreviewText = $derived(
    amountPreview === "" ? "" : formatMoney(amountPreview, { decimals: 2 }),
  );
  const loadedAtText = $derived(loadedAtMs === null ? "" : formatClock(new Date(loadedAtMs)));
  const accountBalanceText = $derived(
    account === null ? "" : formatMoney(account.balance, { decimals: 2 }),
  );

  // Cabang sesi = cabang rekening yang sedang dimuat, sama dengan cabang transaksi tunai.
  const branchId = $derived(account?.branchId ?? "");
  const session = $derived(sessionState.kind === "open" ? sessionState.session : null);

  /**
   * Gerbang form transaksi: hanya sesi OPEN yang bisa dipastikan membuka form. Status sesi yang
   * belum pasti, sesi bertanggal lain, dan sesi yang belum dibuka menutup form, masing-masing dengan
   * jalan keluarnya sendiri.
   */
  const sessionGate = $derived(
    sessionPostingGate({
      branchKnown: branchId !== "",
      loading: sessionState.kind === "loading",
      failed: sessionState.kind === "failed",
      missing: sessionState.kind === "missing",
      stale: sessionStale,
    }),
  );

  /** PB tidak menggerakkan uang fisik: gerbang sesi hanya menutup setor/tarik (D-125). */
  const postingBlocked = $derived(sessionGate.blocked && mode !== "TRANSFER");

  const closeResultText = $derived(closeResult === null ? "" : varianceSummary(closeResult.variance));

  function modeLabel(value: TellerMode): string {
    if (value === "DEPOSIT") return m.teller_direction_deposit();
    if (value === "WITHDRAWAL") return m.teller_direction_withdrawal();
    return m.teller_direction_transfer();
  }

  /** Tanda arah ditulis sebagai tanda + kata, bukan warna saja (DESIGN §6, spec §15.4). */
  function amountWithSign(direction: CashDirection, amount: string): string {
    return `${direction === "DEPOSIT" ? "+" : "-"}${formatMoney(amount, { decimals: 2 })}`;
  }

  function cashIdentityOf(value: PendingCash): string {
    return cashIdentity({
      accountId: value.accountId,
      direction: value.direction,
      amount: value.amount,
      narration: value.narration,
    });
  }

  function transferIdentityOf(value: PendingTransfer): string {
    return transferIdentity({
      sourceAccountId: value.sourceAccountId,
      destinationAccountId: value.destinationAccountId,
      amount: value.amount,
      narration: value.narration,
    });
  }

  /** Kunci baru hanya bila sidik isi berubah, sehingga "Ubah" lalu "Tinjau" tidak membuat isu baru. */
  function ensureIdempotencyKey(value: Pending): void {
    const identity = value.kind === "cash" ? cashIdentityOf(value) : transferIdentityOf(value);
    if (idempotencyKey === "" || idempotencyIdentity !== identity) {
      idempotencyKey = newIdempotencyKey();
      idempotencyIdentity = identity;
    }
  }

  /** Bersihkan hasil/kesalahan dan kunci, tanpa menyentuh isian yang sedang diketik. */
  function resetOutcome(): void {
    phase = "edit";
    pending = null;
    result = null;
    fieldError = null;
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    idempotencyKey = "";
    idempotencyIdentity = "";
  }

  async function loadShortcuts(): Promise<void> {
    try {
      const { data, response } = await api.GET("/api/v1/params");
      if (!response.ok || !data) return;
      const next: Partial<Record<TellerMode, string>> = {};
      for (const item of data.items) {
        const mode = (Object.keys(SHORTCUT_PARAM_KEYS) as TellerMode[]).find(
          (candidate) => SHORTCUT_PARAM_KEYS[candidate] === item.key,
        );
        if (mode !== undefined && typeof item.value === "string") next[mode] = item.value;
      }
      shortcuts = next;
    } catch {
      // Pintasan opsional: tanpa parameter yang terbaca, tombol biasa tetap bekerja.
    }
  }

  async function focusField(field: TellerField): Promise<void> {
    await tick();
    if (field === "accountId") accountInputEl?.focus();
    else if (field === "destinationAccountId") destinationEl?.focus();
    else if (field === "narration") narrationEl?.focus();
    else amountEl?.focus();
  }

  async function loadAccount(): Promise<void> {
    if (accountLoading) return;
    accountError = "";
    announcement = "";
    const accountNo = accountNoInput.trim();
    if (accountNo === "") {
      accountError = m.teller_error_account_no_required();
      await focusField("accountId");
      return;
    }
    if (accountNo.length > ACCOUNT_NO_MAX_LENGTH) {
      accountError = m.teller_error_account_no_invalid();
      await focusField("accountId");
      return;
    }

    accountLoading = true;
    try {
      const { data: body, response, error } = await loadDepositAccountByNo(accountNo);
      if (response.status === 401) {
        await goto("/login");
        return;
      }
      if (!response.ok || !body) {
        account = null;
        loadedAtMs = null;
        accountError = api.isProblem(error) ? tellerProblemMessage(error as Problem) : m.teller_not_found();
        resetOutcome();
        resetSession();
        return;
      }
      const found = body.items[0];
      if (found === undefined) {
        // Nomor tidak ada dan "cabang lain" sengaja sama (D-126): jangan membedakan pesannya.
        account = null;
        loadedAtMs = null;
        accountError = m.teller_account_lookup_not_found();
        resetOutcome();
        resetSession();
        return;
      }
      account = found;
      loadedAtMs = Date.now();
      resetOutcome();
      resetSession();
      await loadSession();
    } catch {
      account = null;
      loadedAtMs = null;
      accountError = m.error_generic();
      resetSession();
    } finally {
      accountLoading = false;
    }
  }

  /** Buang sesi yang dimuat: dipakai saat rekening gagal dimuat atau dimuat ulang. */
  function resetSession(): void {
    sessionState = { kind: "idle" };
    sessionPhase = "idle";
    pendingSession = null;
    sessionStale = false;
    closeResult = null;
    sessionFormError = null;
    sessionError = "";
    sessionErrorTrace = "";
    sessionErrorUnknown = false;
    sessionKey = "";
    sessionKeyIdentity = "";
  }

  /**
   * Muat sesi OPEN pemanggil di cabang rekening. 404 `session_not_open` = keadaan awal hari (tombol
   * "Buka sesi"), bukan galat; galat lain menutup form transaksi sampai berhasil dimuat ulang.
   */
  async function loadSession(): Promise<void> {
    if (branchId === "") {
      sessionState = { kind: "idle" };
      return;
    }
    sessionState = { kind: "loading" };
    closeResult = null;
    try {
      const outcome = await loadCurrentTellerSession(branchId);
      if (outcome.response.status === 401) {
        await goto("/login");
        return;
      }
      const reason = api.isProblem(outcome.error) ? (outcome.error as Problem).params?.reason : undefined;
      if (outcome.response.ok && outcome.data) {
        sessionState = { kind: "open", session: outcome.data };
        closeResult = null;
        return;
      }
      if (currentSessionOutcome(outcome.response.status, reason) === "missing") {
        sessionState = { kind: "missing" };
        sessionStale = false;
        return;
      }
      sessionState = {
        kind: "failed",
        message: api.isProblem(outcome.error)
          ? tellerSessionProblemMessage(outcome.error as Problem)
          : m.error_generic(),
      };
    } catch {
      sessionState = { kind: "failed", message: m.error_generic() };
    }
  }

  /** Kunci baru hanya bila sidik isi sesi berubah (pola `ensureIdempotencyKey` transaksi). */
  function ensureSessionKey(identity: string): void {
    if (sessionKey === "" || sessionKeyIdentity !== identity) {
      sessionKey = newIdempotencyKey();
      sessionKeyIdentity = identity;
    }
  }

  function clearSessionError(): void {
    sessionFormError = null;
    sessionError = "";
    sessionErrorTrace = "";
    sessionErrorUnknown = false;
  }

  async function startOpenSession(): Promise<void> {
    clearSessionError();
    closeResult = null;
    openingFloatRaw = "";
    sessionNote = "";
    sessionPhase = "open";
    await tick();
    sessionFormHeadingEl?.focus();
  }

  async function startCloseSession(): Promise<void> {
    if (session === null) return;
    clearSessionError();
    countedCashRaw = "";
    sessionNote = "";
    sessionPhase = "close";
    await tick();
    sessionFormHeadingEl?.focus();
  }

  /** Kembali dari form buka/tutup ke keadaan panel sebelumnya, fokus ke judul panel. */
  async function cancelSessionForm(): Promise<void> {
    sessionPhase = "idle";
    pendingSession = null;
    openingFloatRaw = "";
    countedCashRaw = "";
    sessionNote = "";
    clearSessionError();
    await tick();
    sessionHeadingEl?.focus();
  }

  async function reviewSessionOpen(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    clearSessionError();
    const float = validateOpeningFloat(openingFloatRaw);
    if (!float.ok) {
      sessionFormError = float.error;
      await tick();
      sessionFloatEl?.focus();
      return;
    }
    const note = sessionNoteError(sessionNote);
    if (note !== null) {
      sessionFormError = note;
      await tick();
      sessionNoteEl?.focus();
      return;
    }
    const trimmed = sessionNote.trim();
    pendingSession = { kind: "open", openingFloat: float.amount, note: trimmed };
    ensureSessionKey(sessionOpenIdentity({ branchId, openingFloat: float.amount, note: trimmed }));
    sessionPhase = "open_review";
    await tick();
    sessionReviewHeadingEl?.focus();
  }

  async function reviewSessionClose(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    clearSessionError();
    if (session === null) return;
    const counted = validateCountedCash(countedCashRaw);
    if (!counted.ok) {
      sessionFormError = counted.error;
      await tick();
      sessionCountedEl?.focus();
      return;
    }
    const note = sessionNoteError(sessionNote);
    if (note !== null) {
      sessionFormError = note;
      await tick();
      sessionNoteEl?.focus();
      return;
    }
    const trimmed = sessionNote.trim();
    pendingSession = {
      kind: "close",
      sessionId: session.sessionId,
      countedCash: counted.amount,
      note: trimmed,
    };
    ensureSessionKey(
      sessionCloseIdentity({ sessionId: session.sessionId, countedCash: counted.amount, note: trimmed }),
    );
    sessionPhase = "close_review";
    await tick();
    sessionReviewHeadingEl?.focus();
  }

  /** Esc pada tinjauan sesi: kembali ke form, isian dipertahankan, fokus ke field pertama. */
  async function cancelSessionReview(): Promise<void> {
    if (sessionPhase !== "open_review" && sessionPhase !== "close_review") return;
    const opened = sessionPhase === "open_review";
    // Kunci tidak dibuang: isi yang sama memakai kunci yang sama saat ditinjau ulang.
    pendingSession = null;
    sessionPhase = opened ? "open" : "close";
    clearSessionError();
    await tick();
    if (opened) sessionFloatEl?.focus();
    else sessionCountedEl?.focus();
  }

  async function submitSession(): Promise<void> {
    if (sessionWorking || sessionKey === "" || pendingSession === null) return;
    if (sessionPhase !== "open_review" && sessionPhase !== "close_review") return;
    const reviewed = pendingSession;
    sessionWorking = true;
    sessionError = "";
    sessionErrorTrace = "";
    sessionErrorUnknown = false;
    announcement = "";

    try {
      const outcome =
        reviewed.kind === "open"
          ? await openTellerSession(
              {
                branchId,
                openingFloat: reviewed.openingFloat,
                ...(reviewed.note === "" ? {} : { note: reviewed.note }),
              },
              sessionKey,
            )
          : await closeTellerSession(
              reviewed.sessionId,
              {
                countedCash: reviewed.countedCash,
                ...(reviewed.note === "" ? {} : { note: reviewed.note }),
              },
              sessionKey,
            );

      if (outcome.response.status === 401) {
        await goto("/login");
        return;
      }

      if (!outcome.response.ok || !outcome.data) {
        const problem = outcome.error;
        sessionErrorTrace = api.isProblem(problem) ? (problem as Problem).traceId : "";
        sessionError = api.isProblem(problem)
          ? tellerSessionProblemMessage(problem as Problem)
          : m.error_generic();
        if (outcome.response.status < 500) {
          // Isi permintaan tidak akan pernah valid tanpa perubahan: kunci dibuang, kembali ke form.
          sessionKey = "";
          sessionKeyIdentity = "";
          pendingSession = null;
          sessionPhase = reviewed.kind === "open" ? "open" : "close";
        } else {
          // Status belum pasti (permintaan bisa saja tersimpan): kunci dipertahankan untuk replay,
          // dan pesan yang tampil adalah pesan "status belum pasti", bukan pesan galat 5xx.
          sessionErrorUnknown = true;
          sessionError = "";
        }
        await tick();
        sessionAlertEl?.focus();
        return;
      }

      if (reviewed.kind === "open") {
        const opened = outcome.data as TellerSession;
        sessionState = { kind: "open", session: opened };
        sessionStale = false;
        closeResult = null;
        announcement = m.teller_session_open_announcement({ date: formatDate(opened.businessDate) });
      } else {
        const closed = outcome.data as TellerSessionClose;
        closeResult = closed;
        // Sesi sudah CLOSED: transaksi tunai menunggu sesi baru dibuka.
        sessionState = { kind: "missing" };
        sessionStale = false;
        announcement = m.teller_session_closed_announcement({ summary: varianceSummary(closed.variance) });
      }
      sessionPhase = "idle";
      pendingSession = null;
      sessionKey = "";
      sessionKeyIdentity = "";
      await tick();
      if (closeResult === null) sessionHeadingEl?.focus();
      else sessionClosedHeadingEl?.focus();
    } catch {
      // Jaringan/gangguan: status sesi belum pasti. Kunci dipertahankan; "Coba lagi" = replay.
      sessionErrorUnknown = true;
      sessionError = "";
      await tick();
      sessionAlertEl?.focus();
    } finally {
      sessionWorking = false;
    }
  }

  async function reviewTransaction(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (account === null) return;
    fieldError = null;
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    announcement = "";

    if (mode === "TRANSFER") {
      const check = validateTransferForm({
        sourceAccountId: account.accountId,
        destinationAccountId: destinationInput,
        amountRaw,
        narration,
      });
      if (!check.ok) {
        fieldError = check.error;
        await focusField(check.error.field);
        return;
      }
      pending = {
        kind: "transfer",
        sourceAccountId: check.sourceAccountId,
        destinationAccountId: check.destinationAccountId,
        amount: check.amount,
        narration: check.narration,
      };
    } else {
      const check = validateCashForm({ accountId: account.accountId, amountRaw, narration });
      if (!check.ok) {
        fieldError = check.error;
        await focusField(check.error.field);
        return;
      }
      pending = {
        kind: "cash",
        direction: mode,
        accountId: check.accountId,
        amount: check.amount,
        narration: check.narration,
      };
    }

    ensureIdempotencyKey(pending);
    phase = "review";
    await tick();
    reviewHeadingEl?.focus();
  }

  async function saveTransaction(): Promise<void> {
    if (saving || pending === null || idempotencyKey === "") return;
    if (pending.kind === "cash" && sessionGate.blocked) return;
    const reviewed = pending;
    saving = true;
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    announcement = "";

    try {
      const outcome =
        reviewed.kind === "cash"
          ? await postCashTransaction(
              {
                accountId: reviewed.accountId,
                direction: reviewed.direction,
                amount: reviewed.amount,
                ...(reviewed.narration === "" ? {} : { narration: reviewed.narration }),
              },
              idempotencyKey,
            )
          : await postTransfer(
              {
                sourceAccountId: reviewed.sourceAccountId,
                destinationAccountId: reviewed.destinationAccountId,
                amount: reviewed.amount,
                ...(reviewed.narration === "" ? {} : { narration: reviewed.narration }),
              },
              idempotencyKey,
            );

      if (outcome.response.status === 401) {
        await goto("/login");
        return;
      }

      if (!outcome.response.ok || !outcome.data) {
        const problem = outcome.error;
        errorTrace = api.isProblem(problem) ? (problem as Problem).traceId : "";
        transactionError = api.isProblem(problem) ? tellerProblemMessage(problem as Problem) : m.error_generic();
        errorKind = "failed";
        // Penolakan gerbang sesi: muat ulang sesi supaya panel menampilkan keadaan sebenarnya
        // (sesi sudah ditutup, atau sesi OPEN bertanggal bisnis lain), bukan hanya pesan di form.
        if (api.isProblem(problem)) {
          const reason = (problem as Problem).params?.reason;
          if (reason === "session_business_date_mismatch") sessionStale = true;
          if (reason === "no_open_session" || reason === "session_business_date_mismatch") {
            void loadSession();
          }
        }
        if (outcome.response.status < 500) {
          // Isi permintaan tidak akan pernah valid tanpa perubahan: kunci dibuang, kembali ke form.
          idempotencyKey = "";
          idempotencyIdentity = "";
          pending = null;
          phase = "edit";
        }
        await tick();
        errorAlertEl?.focus();
        return;
      }

      // Sukses (201, atau 200 replay): saldo dari respons, bukan hitungan lokal (brief §3.4).
      if (reviewed.kind === "cash") {
        const transaction = outcome.data as CashTransaction;
        result = { kind: "cash", transaction };
        announcement = m.teller_success_status({
          balance: formatMoney(transaction.balanceAfter, { decimals: 2 }),
        });
      } else {
        const transfer = outcome.data as Transfer;
        result = { kind: "transfer", transfer };
        announcement = m.teller_success_status({
          balance: formatMoney(transfer.sourceBalanceAfter, { decimals: 2 }),
        });
      }
      idempotencyKey = "";
      idempotencyIdentity = "";
      pending = null;
      phase = "done";
      await tick();
      successHeadingEl?.focus();
    } catch {
      // Jaringan/gangguan: status belum pasti. Kunci dipertahankan; "Coba lagi" = replay.
      errorKind = "unknown";
      transactionError = "";
      announcement = "";
      await tick();
      errorAlertEl?.focus();
    } finally {
      saving = false;
    }
  }

  async function cancelReview(): Promise<void> {
    if (phase !== "review") return;
    // Kunci tidak dibuang: bila isi form tidak berubah, "Tinjau" lagi memakai kunci yang sama.
    pending = null;
    phase = "edit";
    transactionError = "";
    errorTrace = "";
    errorKind = "none";
    await tick();
    amountEl?.focus();
  }

  async function startNext(): Promise<void> {
    resetOutcome();
    amountRaw = "";
    narration = "";
    announcement = "";
    await tick();
    amountEl?.focus();
  }

  async function copyText(value: string): Promise<void> {
    try {
      await navigator.clipboard.writeText(value);
      announcement = m.teller_copied();
    } catch {
      announcement = "";
    }
  }

  function saveFromReview(event: SubmitEvent): void {
    event.preventDefault();
    void saveTransaction();
  }

  function onWindowKeydown(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      // Esc = batal pada tinjauan sesi kas (T-108) atau tinjauan transaksi (brief §2.2), bukan saat
      // status transaksi belum pasti.
      if (sessionPhase === "open_review" || sessionPhase === "close_review") {
        event.preventDefault();
        void cancelSessionReview();
        return;
      }
      if (phase === "review" && errorKind !== "unknown") {
        event.preventDefault();
        void cancelReview();
        return;
      }
    }
    // Pintasan papan tunai (T-095): hanya di form, tanpa modifier, dan hanya bila parameternya
    // terbaca. F2 (cari anggota) belum ada karena pencarian anggota belum ada.
    if (phase !== "edit" || account === null || event.metaKey || event.ctrlKey || event.altKey) return;
    const shortcut = shortcutModeForKey(shortcuts, event.key);
    if (shortcut !== null) {
      event.preventDefault();
      mode = shortcut;
      void focusField("amount");
    }
  }

  onMount(() => {
    if (!canPost) return;
    void loadShortcuts();
    // Deep link `?accountNo=` (brief §2.4): layar bisa dibuka dari tautan rekening.
    const deepLinkNo = page.url.searchParams.get("accountNo");
    if (deepLinkNo !== null && deepLinkNo.trim() !== "") {
      accountNoInput = deepLinkNo.trim();
      void loadAccount();
    }
  });
</script>

<svelte:window onkeydown={onWindowKeydown} />

<svelte:head>
  <title>{m.common_app_title()} — {m.teller_title()}</title>
</svelte:head>

<div class="teller-head">
  <h1 class="teller-title">{m.teller_title()}</h1>
  <p class="teller-intro">{m.teller_intro()}</p>
</div>

{#if !canPost}
  <p class="kran-alert" role="alert">{m.teller_denied()}</p>
{:else}
  <div class="teller-work">
    <section class="teller-panel" aria-labelledby="teller-account-heading">
      <h2 id="teller-account-heading">{m.teller_account_heading()}</h2>

      <div class="kran-field">
        <label class="kran-label" for="teller-account-no">{m.teller_account_no_input_label()}</label>
        <input
          class="kran-input"
          id="teller-account-no"
          name="accountNo"
          bind:this={accountInputEl}
          bind:value={accountNoInput}
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          aria-describedby="teller-account-no-hint"
        />
        <p class="kran-muted" id="teller-account-no-hint">{m.teller_account_no_input_hint()}</p>
      </div>

      <p>
        <button
          class="kran-button"
          type="button"
          onclick={() => void loadAccount()}
          disabled={accountLoading}
        >
          {m.teller_account_load()}
        </button>
      </p>

      {#if accountLoading}
        <p role="status">{m.teller_account_loading()}</p>
      {:else if accountError !== ""}
        <p class="kran-alert" role="alert">{accountError}</p>
      {:else if account !== null}
        {@const loaded = account}
        <dl class="teller-facts">
          <dt>{m.teller_account_no_label()}</dt>
          <dd class="teller-id">{loaded.accountNo}</dd>
          <dt>{m.teller_account_status_label()}</dt>
          <dd>
            <span class={loaded.status === "ACTIVE" ? "kran-status kran-status--ok" : "kran-status"}>
              <span class="kran-status__icon" aria-hidden="true"
                >{loaded.status === "ACTIVE" ? "✔" : "○"}</span
              >
              {loaded.status === "ACTIVE"
                ? m.teller_account_status_active()
                : m.teller_account_status_closed()}
            </span>
          </dd>
          <dt>{m.teller_account_kind_label()}</dt>
          <dd>{savingsKindLabel(loaded.savingsKind)}</dd>
          <dt>{m.teller_account_balance_label()}</dt>
          <dd class="kran-money">{accountBalanceText}</dd>
        </dl>
        {#if loadedAtText !== ""}
          <p class="kran-muted">{m.teller_account_balance_at({ time: loadedAtText })}</p>
        {/if}
      {:else}
        <p>{m.teller_account_none()}</p>
        <p class="kran-muted">{m.teller_account_none_hint()}</p>
      {/if}
    </section>

    <div class="teller-column">
      <!--
        Sesi kas (T-108) di atas form transaksi: transaksi tunai ditolak server tanpa sesi OPEN
        (`no_open_session`), jadi keadaannya harus terlihat sebelum teller mengetik.
      -->
      <section class="teller-panel" aria-labelledby="teller-session-heading">
        <h2 id="teller-session-heading" tabindex="-1" bind:this={sessionHeadingEl}>
          {m.teller_session_heading()}
        </h2>

        {#if branchId === ""}
          <p class="kran-muted">{m.teller_session_need_account()}</p>
        {:else if closeResult !== null && sessionPhase === "idle"}
          {@const closed = closeResult}
          <!-- Fokus dipindah ke judul hasil tutup sesi (pola brief §2.1). -->
          <h3
            id="teller-session-closed-heading"
            class="teller-subheading"
            tabindex="-1"
            bind:this={sessionClosedHeadingEl}
          >
            {m.teller_session_closed_heading()}
          </h3>

          <dl class="teller-facts">
            <dt>{m.teller_session_status_label()}</dt>
            <dd>
              <span class="kran-status kran-status--ok">
                <span class="kran-status__icon" aria-hidden="true">✔</span>
                {m.teller_session_status_closed()}
              </span>
            </dd>
            <dt>{m.teller_business_date()}</dt>
            <dd>{formatDate(closed.businessDate)}</dd>
            <dt>{m.teller_session_opening_float()}</dt>
            <dd class="kran-money">{formatMoney(closed.openingFloat, { decimals: 2 })}</dd>
            <dt>{m.teller_session_expected_cash()}</dt>
            <dd class="kran-money">{formatMoney(closed.expectedCash, { decimals: 2 })}</dd>
            <dt>{m.teller_session_counted_cash()}</dt>
            <dd class="kran-money">{formatMoney(closed.countedCash, { decimals: 2 })}</dd>
            <dt>{m.teller_session_variance_label()}</dt>
            <dd class="kran-money">{closeResultText}</dd>
            <dt>{m.teller_session_closed_at()}</dt>
            <dd>{formatDateTime(closed.closedAt)}</dd>
            {#if closed.note !== ""}
              <dt>{m.teller_session_note()}</dt>
              <dd>{closed.note}</dd>
            {/if}
          </dl>

          {#if sessionError !== ""}
            <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
              {sessionError}
              {#if sessionErrorTrace !== ""}<span>{m.teller_error_with_trace({ trace: sessionErrorTrace })}</span>{/if}
            </p>
          {/if}

          <p>
            <button
              class="kran-button kran-button--primary"
              type="button"
              disabled={sessionWorking}
              onclick={() => void startOpenSession()}
            >
              {m.teller_session_open()}
            </button>
          </p>
        {:else if pendingSession !== null && pendingSession.kind === "open"}
          {@const review = pendingSession}
          <h3
            id="teller-session-open-review-heading"
            class="teller-subheading"
            tabindex="-1"
            bind:this={sessionReviewHeadingEl}
          >
            {m.teller_session_open_review_heading()}
          </h3>

          <dl class="teller-facts">
            <dt>{m.teller_session_opening_float()}</dt>
            <dd class="kran-money">{formatMoney(review.openingFloat, { decimals: 2 })}</dd>
            {#if review.note !== ""}
              <dt>{m.teller_session_note()}</dt>
              <dd>{review.note}</dd>
            {/if}
          </dl>

          <p class="kran-muted teller-reference">
            <span>{m.teller_reference_label()}:</span>
            <span class="teller-id">{sessionKey}</span>
            <button class="kran-button" type="button" onclick={() => void copyText(sessionKey)}>
              {m.teller_copy()}
            </button>
          </p>
          <p class="kran-muted">{m.teller_reference_hint()}</p>

          {#if sessionErrorUnknown}
            <!-- Status sesi belum pasti: jangan tawarkan "Ubah" supaya float tidak diubah. -->
            <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
              {m.teller_session_error_unknown_state()}
            </p>
            <p>
              <button
                class="kran-button kran-button--primary"
                type="button"
                disabled={sessionWorking}
                onclick={() => void submitSession()}
              >
                {sessionWorking ? m.teller_saving() : m.teller_retry()}
              </button>
            </p>
          {:else}
            {#if sessionError !== ""}
              <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
                {sessionError}
                {#if sessionErrorTrace !== ""}<span>{m.teller_error_with_trace({ trace: sessionErrorTrace })}</span>{/if}
              </p>
            {/if}
            <form
              class="teller-actions"
              onsubmit={(event) => {
                event.preventDefault();
                void submitSession();
              }}
            >
              <button class="kran-button kran-button--primary" type="submit" disabled={sessionWorking}>
                {sessionWorking ? m.teller_saving() : m.teller_session_open()}
              </button>
              <button class="kran-button" type="button" onclick={() => void cancelSessionReview()}>
                {m.teller_change()}
              </button>
            </form>
          {/if}
        {:else if pendingSession !== null && pendingSession.kind === "close"}
          {@const review = pendingSession}
          <h3
            id="teller-session-close-review-heading"
            class="teller-subheading"
            tabindex="-1"
            bind:this={sessionReviewHeadingEl}
          >
            {m.teller_session_close_review_heading()}
          </h3>

          <dl class="teller-facts">
            {#if session !== null}
              <dt>{m.teller_business_date()}</dt>
              <dd>{formatDate(session.businessDate)}</dd>
              <dt>{m.teller_session_opening_float()}</dt>
              <dd class="kran-money">{formatMoney(session.openingFloat, { decimals: 2 })}</dd>
            {/if}
            <dt>{m.teller_session_counted_cash()}</dt>
            <dd class="kran-money">{formatMoney(review.countedCash, { decimals: 2 })}</dd>
            {#if review.note !== ""}
              <dt>{m.teller_session_note()}</dt>
              <dd>{review.note}</dd>
            {/if}
          </dl>
          <p class="kran-muted">{m.teller_session_close_review_hint()}</p>

          <p class="kran-muted teller-reference">
            <span>{m.teller_reference_label()}:</span>
            <span class="teller-id">{sessionKey}</span>
            <button class="kran-button" type="button" onclick={() => void copyText(sessionKey)}>
              {m.teller_copy()}
            </button>
          </p>
          <p class="kran-muted">{m.teller_reference_hint()}</p>

          {#if sessionErrorUnknown}
            <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
              {m.teller_session_error_unknown_state()}
            </p>
            <p>
              <button
                class="kran-button kran-button--primary"
                type="button"
                disabled={sessionWorking}
                onclick={() => void submitSession()}
              >
                {sessionWorking ? m.teller_saving() : m.teller_retry()}
              </button>
            </p>
          {:else}
            {#if sessionError !== ""}
              <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
                {sessionError}
                {#if sessionErrorTrace !== ""}<span>{m.teller_error_with_trace({ trace: sessionErrorTrace })}</span>{/if}
              </p>
            {/if}
            <form
              class="teller-actions"
              onsubmit={(event) => {
                event.preventDefault();
                void submitSession();
              }}
            >
              <button class="kran-button kran-button--primary" type="submit" disabled={sessionWorking}>
                {sessionWorking ? m.teller_saving() : m.teller_session_close()}
              </button>
              <button class="kran-button" type="button" onclick={() => void cancelSessionReview()}>
                {m.teller_change()}
              </button>
            </form>
          {/if}
        {:else if sessionPhase === "open"}
          <h3
            id="teller-session-open-heading"
            class="teller-subheading"
            tabindex="-1"
            bind:this={sessionFormHeadingEl}
          >
            {m.teller_session_open_heading()}
          </h3>

          {#if sessionFormError !== null}
            <p class="kran-alert" id="teller-session-open-error" role="alert">
              {sessionFormError.message}
            </p>
          {/if}
          {#if sessionError !== ""}
            <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
              {sessionError}
              {#if sessionErrorTrace !== ""}<span>{m.teller_error_with_trace({ trace: sessionErrorTrace })}</span>{/if}
            </p>
          {/if}

          <form class="kran-form" onsubmit={(event) => void reviewSessionOpen(event)} novalidate>
            <div class="kran-field">
              <label class="kran-label" for="teller-session-float">{m.teller_session_opening_float()}</label>
              <input
                class="kran-input teller-money-input"
                id="teller-session-float"
                name="openingFloat"
                inputmode="decimal"
                bind:this={sessionFloatEl}
                bind:value={openingFloatRaw}
                autocomplete="off"
                aria-invalid={sessionFormError?.field === "openingFloat" ? "true" : undefined}
                aria-describedby={sessionFormError?.field === "openingFloat"
                  ? "teller-session-float-hint teller-session-open-error"
                  : "teller-session-float-hint"}
              />
              <p class="kran-muted" id="teller-session-float-hint">
                {m.teller_session_opening_float_hint()}
              </p>
            </div>
            <div class="kran-field">
              <label class="kran-label" for="teller-session-open-note">{m.teller_session_note()}</label>
              <input
                class="kran-input"
                id="teller-session-open-note"
                name="note"
                maxlength={SESSION_NOTE_MAX_LENGTH}
                bind:this={sessionNoteEl}
                bind:value={sessionNote}
                autocomplete="off"
                aria-invalid={sessionFormError?.field === "sessionNote" ? "true" : undefined}
                aria-describedby={sessionFormError?.field === "sessionNote"
                  ? "teller-session-open-error"
                  : undefined}
              />
            </div>
            <div class="teller-actions">
              <button class="kran-button kran-button--primary" type="submit">{m.teller_review()}</button>
              <button class="kran-button" type="button" onclick={() => void cancelSessionForm()}>
                {m.teller_session_cancel()}
              </button>
            </div>
          </form>
        {:else if sessionPhase === "close" && session !== null}
          <h3
            id="teller-session-close-heading"
            class="teller-subheading"
            tabindex="-1"
            bind:this={sessionFormHeadingEl}
          >
            {m.teller_session_close_heading()}
          </h3>

          {#if sessionFormError !== null}
            <p class="kran-alert" id="teller-session-close-error" role="alert">
              {sessionFormError.message}
            </p>
          {/if}
          {#if sessionError !== ""}
            <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
              {sessionError}
              {#if sessionErrorTrace !== ""}<span>{m.teller_error_with_trace({ trace: sessionErrorTrace })}</span>{/if}
            </p>
          {/if}

          <form class="kran-form" onsubmit={(event) => void reviewSessionClose(event)} novalidate>
            <div class="kran-field">
              <label class="kran-label" for="teller-session-counted">{m.teller_session_counted_cash()}</label>
              <input
                class="kran-input teller-money-input"
                id="teller-session-counted"
                name="countedCash"
                inputmode="decimal"
                bind:this={sessionCountedEl}
                bind:value={countedCashRaw}
                autocomplete="off"
                aria-invalid={sessionFormError?.field === "countedCash" ? "true" : undefined}
                aria-describedby={sessionFormError?.field === "countedCash"
                  ? "teller-session-counted-hint teller-session-close-error"
                  : "teller-session-counted-hint"}
              />
              <p class="kran-muted" id="teller-session-counted-hint">
                {m.teller_session_counted_cash_hint()}
              </p>
            </div>
            <div class="kran-field">
              <label class="kran-label" for="teller-session-close-note">{m.teller_session_note()}</label>
              <input
                class="kran-input"
                id="teller-session-close-note"
                name="note"
                maxlength={SESSION_NOTE_MAX_LENGTH}
                bind:this={sessionNoteEl}
                bind:value={sessionNote}
                autocomplete="off"
                aria-invalid={sessionFormError?.field === "sessionNote" ? "true" : undefined}
                aria-describedby={sessionFormError?.field === "sessionNote"
                  ? "teller-session-close-error"
                  : undefined}
              />
            </div>
            <div class="teller-actions">
              <button class="kran-button kran-button--primary" type="submit">{m.teller_review()}</button>
              <button class="kran-button" type="button" onclick={() => void cancelSessionForm()}>
                {m.teller_session_cancel()}
              </button>
            </div>
          </form>
        {:else if sessionState.kind === "loading"}
          <p role="status">{m.teller_session_loading()}</p>
        {:else if sessionState.kind === "failed"}
          <p class="kran-alert" role="alert" tabindex="-1" bind:this={sessionAlertEl}>
            {sessionState.message}
          </p>
          <p>
            <button
              class="kran-button"
              type="button"
              disabled={sessionWorking}
              onclick={() => void loadSession()}
            >
              {m.teller_session_reload()}
            </button>
          </p>
        {:else if session !== null}
          {@const active = session}
          <dl class="teller-facts">
            <dt>{m.teller_session_status_label()}</dt>
            <dd>
              <span class="kran-status kran-status--ok">
                <span class="kran-status__icon" aria-hidden="true">✔</span>
                {m.teller_session_status_open()}
              </span>
            </dd>
            <dt>{m.teller_business_date()}</dt>
            <dd>{formatDate(active.businessDate)}</dd>
            <dt>{m.teller_session_opening_float()}</dt>
            <dd class="kran-money">{formatMoney(active.openingFloat, { decimals: 2 })}</dd>
            {#if active.note !== ""}
              <dt>{m.teller_session_note()}</dt>
              <dd>{active.note}</dd>
            {/if}
          </dl>

          {#if sessionStale}
            <!-- Tanggal bisnis hari ini tidak bisa dibaca UI; peringatan ini datang dari penolakan
                 server `session_business_date_mismatch`, bukan dari jam browser. -->
            <p class="kran-alert" role="status">
              {m.teller_error_session_business_date_mismatch()}
            </p>
          {/if}

          <p>
            <button
              class="kran-button kran-button--primary"
              type="button"
              disabled={sessionWorking}
              onclick={() => void startCloseSession()}
            >
              {m.teller_session_close()}
            </button>
          </p>
        {:else}
          <p>{m.teller_session_none()}</p>
          <p>
            <button
              class="kran-button kran-button--primary"
              type="button"
              onclick={() => void startOpenSession()}
            >
              {m.teller_session_open()}
            </button>
          </p>
        {/if}
      </section>

      <section class="teller-panel" aria-labelledby="teller-transaction-heading">
        <h2 id="teller-transaction-heading">{m.teller_transaction_heading()}</h2>

        {#if account === null}
          <p class="kran-muted">{m.teller_transaction_need_account()}</p>
        {:else if phase === "done" && result !== null}
          {@const done = result}
          <section aria-labelledby="teller-result-heading">
            <!-- Fokus dipindah ke judul hasil setelah simpan (brief §2.1). -->
            <h3
              id="teller-result-heading"
              class="teller-subheading"
              tabindex="-1"
              bind:this={successHeadingEl}
            >
              {m.teller_success_heading()}
            </h3>

            {#if done.kind === "cash"}
              {@const transaction = done.transaction}
              <dl class="teller-facts">
                <dt>{m.teller_direction_label()}</dt>
                <dd>{modeLabel(transaction.direction)}</dd>
                <dt>{m.teller_amount_label()}</dt>
                <dd class="kran-money">{amountWithSign(transaction.direction, transaction.amount)}</dd>
                <dt>{m.teller_balance_after()}</dt>
                <dd class="kran-money">{formatMoney(transaction.balanceAfter, { decimals: 2 })}</dd>
                <dt>{m.teller_transaction_id()}</dt>
                <dd class="teller-copyable">
                  <span class="teller-id">{transaction.transactionId}</span>
                  <button
                    class="kran-button"
                    type="button"
                    onclick={() => void copyText(transaction.transactionId)}
                  >
                    {m.teller_copy()}
                  </button>
                </dd>
                <dt>{m.teller_journal_id()}</dt>
                <dd class="teller-copyable">
                  <span class="teller-id">{transaction.journalId}</span>
                  <button
                    class="kran-button"
                    type="button"
                    onclick={() => void copyText(transaction.journalId)}
                  >
                    {m.teller_copy()}
                  </button>
                </dd>
                <dt>{m.teller_business_date()}</dt>
                <dd>{formatDate(transaction.businessDate)}</dd>
              </dl>
            {:else}
              {@const transfer = done.transfer}
              <dl class="teller-facts">
                <dt>{m.teller_direction_label()}</dt>
                <dd>{modeLabel("TRANSFER")}</dd>
                <dt>{m.teller_amount_label()}</dt>
                <dd class="kran-money">{formatMoney(transfer.amount, { decimals: 2 })}</dd>
                <dt>{m.teller_balance_after()}</dt>
                <dd class="kran-money">{formatMoney(transfer.sourceBalanceAfter, { decimals: 2 })}</dd>
                <dt>{m.teller_destination_balance_after()}</dt>
                <dd class="kran-money">
                  {formatMoney(transfer.destinationBalanceAfter, { decimals: 2 })}
                </dd>
                <dt>{m.teller_transaction_id()}</dt>
                <dd class="teller-copyable">
                  <span class="teller-id">{transfer.transferId}</span>
                  <button
                    class="kran-button"
                    type="button"
                    onclick={() => void copyText(transfer.transferId)}
                  >
                    {m.teller_copy()}
                  </button>
                </dd>
                <dt>{m.teller_journal_id()}</dt>
                <dd class="teller-copyable">
                  <span class="teller-id">{transfer.journalId}</span>
                  <button
                    class="kran-button"
                    type="button"
                    onclick={() => void copyText(transfer.journalId)}
                  >
                    {m.teller_copy()}
                  </button>
                </dd>
                <dt>{m.teller_business_date()}</dt>
                <dd>{formatDate(transfer.businessDate)}</dd>
              </dl>
            {/if}

            <p>
              <button class="kran-button kran-button--primary" type="button" onclick={() => void startNext()}>
                {m.teller_next()}
              </button>
            </p>
          </section>
        {:else if phase === "review" && pending !== null}
          {@const review = pending}
          {@const gate = sessionGate}
          <section aria-labelledby="teller-review-heading">
            <!-- Fokus dipindah ke judul tinjauan setelah "Tinjau" (brief §2.1). -->
            <h3
              id="teller-review-heading"
              class="teller-subheading"
              tabindex="-1"
              bind:this={reviewHeadingEl}
            >
              {m.teller_review_heading()}
            </h3>

            <dl class="teller-facts">
              <dt>{m.teller_direction_label()}</dt>
              <dd>{review.kind === "cash" ? modeLabel(review.direction) : modeLabel("TRANSFER")}</dd>
              <dt>{m.teller_account_heading()}</dt>
              <dd class="teller-id">{account.accountNo}</dd>
              {#if review.kind === "transfer"}
                <dt>{m.teller_destination_label()}</dt>
                <dd class="teller-id">{review.destinationAccountId}</dd>
              {/if}
              <dt>{m.teller_amount_label()}</dt>
              <dd class="kran-money">{formatMoney(review.amount, { decimals: 2 })}</dd>
              {#if review.narration !== ""}
                <dt>{m.teller_narration_label()}</dt>
                <dd>{review.narration}</dd>
              {/if}
            </dl>

            {#if loadedAtText !== ""}
              <p class="kran-muted">
                {m.teller_review_balance({ time: loadedAtText, balance: accountBalanceText })}
              </p>
            {/if}

            <p class="kran-muted teller-reference">
              <span>{m.teller_reference_label()}:</span>
              <span class="teller-id">{idempotencyKey}</span>
              <button class="kran-button" type="button" onclick={() => void copyText(idempotencyKey)}>
                {m.teller_copy()}
              </button>
            </p>
            <p class="kran-muted">{m.teller_reference_hint()}</p>

            {#if gate.blocked && pending.kind === "cash"}
              <p class={gate.tone === "alert" ? "kran-alert" : "kran-muted"} role="status">
                {gate.message}
              </p>
            {/if}

            {#if errorKind === "unknown"}
              <!-- Status belum pasti: jangan tawarkan "Ubah" supaya nominal tidak diubah (brief §3.5). -->
              <p class="kran-alert" role="alert" tabindex="-1" bind:this={errorAlertEl}>
                {m.teller_error_unknown_state()}
              </p>
              <p>
                <button
                  class="kran-button kran-button--primary"
                  type="button"
                  disabled={saving || (pending.kind === "cash" && gate.blocked)}
                  onclick={() => void saveTransaction()}
                >
                  {saving ? m.teller_saving() : m.teller_retry()}
                </button>
              </p>
            {:else}
              {#if transactionError !== ""}
                <p class="kran-alert" role="alert" tabindex="-1" bind:this={errorAlertEl}>
                  {transactionError}
                  {#if errorTrace !== ""}<span> {m.teller_error_with_trace({ trace: errorTrace })}</span>{/if}
                </p>
              {/if}
              <form class="teller-actions" onsubmit={(event) => void saveFromReview(event)}>
                <button
                  class="kran-button kran-button--primary"
                  type="submit"
                  disabled={saving || (pending.kind === "cash" && gate.blocked)}
                >
                  {saving ? m.teller_saving() : m.teller_save()}
                </button>
                <button class="kran-button" type="button" onclick={() => void cancelReview()}>
                  {m.teller_change()}
                </button>
              </form>
            {/if}
          </section>
        {:else}
          {@const gate = sessionGate}
          {#if gate.blocked && mode !== "TRANSFER"}
            <!-- Gerbang sesi kas: alasan + jalan keluar, bukan kalimat "terjadi kesalahan". -->
            <p class={gate.tone === "alert" ? "kran-alert" : "kran-muted"} role="status">
              {gate.message}
            </p>
          {/if}

          {#if fieldError !== null}
            <p class="kran-alert" id="teller-field-error" role="alert">{fieldError.message}</p>
          {/if}

          {#if transactionError !== ""}
            <p class="kran-alert" role="alert" tabindex="-1" bind:this={errorAlertEl}>
              {transactionError}
              {#if errorTrace !== ""}<span> {m.teller_error_with_trace({ trace: errorTrace })}</span>{/if}
            </p>
          {/if}

          <form class="kran-form teller-form" onsubmit={(event) => void reviewTransaction(event)} novalidate>
            <fieldset class="teller-gate" disabled={postingBlocked}>
              <fieldset class="teller-fieldset">
                <legend class="kran-label">{m.teller_direction_label()}</legend>
                <div class="kran-radio-group">
                  {#each modeOptions as option (option.value)}
                    <label class="kran-radio">
                      <input type="radio" name="teller-mode" value={option.value} bind:group={mode} />
                      <span>{option.label}</span>
                    </label>
                  {/each}
                </div>
              </fieldset>

              {#if mode === "TRANSFER"}
                <div class="kran-field">
                  <label class="kran-label" for="teller-destination">{m.teller_destination_label()}</label>
                  <input
                    class="kran-input teller-uuid"
                    id="teller-destination"
                    name="destinationAccountId"
                    bind:this={destinationEl}
                    bind:value={destinationInput}
                    autocomplete="off"
                    autocapitalize="off"
                    spellcheck="false"
                    aria-invalid={fieldError?.field === "destinationAccountId" ? "true" : undefined}
                    aria-describedby={fieldError?.field === "destinationAccountId"
                      ? "teller-destination-hint teller-field-error"
                      : "teller-destination-hint"}
                  />
                  <p class="kran-muted" id="teller-destination-hint">{m.teller_account_id_hint()}</p>
                </div>
              {/if}

              <div class="kran-field">
                <label class="kran-label" for="teller-amount">{m.teller_amount_label()}</label>
                <input
                  class="kran-input teller-money-input"
                  id="teller-amount"
                  name="amount"
                  inputmode="decimal"
                  bind:this={amountEl}
                  bind:value={amountRaw}
                  autocomplete="off"
                  aria-invalid={fieldError?.field === "amount" ? "true" : undefined}
                  aria-describedby={fieldError?.field === "amount"
                    ? "teller-amount-hint teller-field-error"
                    : "teller-amount-hint"}
                />
                <p class="kran-muted" id="teller-amount-hint">{m.teller_amount_hint()}</p>
                {#if amountPreviewText !== ""}
                  <p class="teller-preview">{m.teller_amount_preview({ amount: amountPreviewText })}</p>
                {/if}
              </div>

              <div class="kran-field">
                <label class="kran-label" for="teller-narration">{m.teller_narration_label()}</label>
                <input
                  class="kran-input"
                  id="teller-narration"
                  name="narration"
                  maxlength={NARRATION_MAX_LENGTH}
                  bind:this={narrationEl}
                  bind:value={narration}
                  autocomplete="off"
                  aria-invalid={fieldError?.field === "narration" ? "true" : undefined}
                  aria-describedby={fieldError?.field === "narration" ? "teller-field-error" : undefined}
                />
              </div>

              <p>
                <button class="kran-button kran-button--primary" type="submit">{m.teller_review()}</button>
              </p>
            </fieldset>
          </form>
        {/if}
      </section>
    </div>
  </div>
{/if}

<p class="kran-visually-hidden" role="status" aria-live="polite">{announcement}</p>

<style>
  .teller-head {
    padding-block-end: var(--space-3);
    border-block-end: 1px solid var(--color-hairline);
    margin-block-end: var(--space-4);
  }

  .teller-title {
    margin: 0;
    font-size: var(--text-xl);
    line-height: var(--line-height-tight);
    font-weight: 600;
  }

  .teller-intro {
    margin: var(--space-1) 0 0;
    max-inline-size: 56ch;
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  /* Kiri = rekening, kanan = transaksi; di bawah 1100 px panel kanan turun (DESIGN §4). */
  .teller-work {
    display: grid;
    grid-template-columns: minmax(0, 1fr) 22rem;
    gap: var(--space-5);
    align-items: start;
  }

  .teller-panel {
    min-inline-size: 0;
  }

  /* Kolom kanan: sesi kas di atas form transaksi, urutan DOM = urutan visual (DESIGN §10). */
  .teller-column {
    display: grid;
    gap: var(--space-5);
    align-content: start;
    min-inline-size: 0;
  }

  /* Gerbang sesi: fieldset tanpa bingkai. `disabled` bawaan browser mengeluarkan kontrol dari urutan
   * tab sekaligus menahan pengiriman selama sesi kas belum pasti (fail-closed). */
  .teller-gate {
    display: grid;
    gap: var(--space-4);
    margin: 0;
    padding: 0;
    border: 0;
    min-inline-size: 0;
  }

  .teller-panel h2 {
    margin-block-end: var(--space-3);
    font-size: var(--text-md);
    font-weight: 600;
  }

  .teller-subheading {
    margin: 0 0 var(--space-3);
    font-size: var(--text-md);
    font-weight: 600;
  }

  /* Pasangan kunci/nilai: garis rambut antar baris, tanpa zebra atau kartu (DESIGN §6). */
  .teller-facts {
    display: grid;
    grid-template-columns: minmax(0, 12rem) minmax(0, 1fr);
    gap: var(--space-2) var(--space-4);
    margin: 0 0 var(--space-3);
  }

  .teller-facts dt {
    color: var(--color-text-muted);
    font-size: var(--text-sm);
  }

  .teller-facts dd {
    margin: 0;
    min-inline-size: 0;
    overflow-wrap: anywhere;
  }

  .teller-fieldset {
    margin: 0;
    padding: 0;
    border: 0;
    display: grid;
    gap: var(--space-2);
  }

  .teller-fieldset legend {
    padding: 0;
    margin-block-end: var(--space-1);
  }

  .teller-uuid {
    font-family: var(--font-mono);
    font-size: var(--text-sm);
  }

  /* Penanda tambahan saat field salah; sinyal utamanya tetap pesan teks di ringkasan (DESIGN §7). */
  .kran-input[aria-invalid="true"] {
    border-color: var(--color-danger);
  }

  /* Nomor rekening, ID transaksi/jurnal, dan referensi: mono, tabular, boleh patah. Nilainya
   * 36 karakter atau lebih, jadi `nowrap` (seperti angka uang) akan membuat overflow mendatar. */
  .teller-id {
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }

  .teller-copyable .teller-id,
  .teller-reference .teller-id {
    min-inline-size: 0;
  }

  .teller-money-input {
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums slashed-zero;
  }

  .teller-preview {
    margin: 0;
    color: var(--color-text);
    font-size: var(--text-sm);
    font-variant-numeric: tabular-nums slashed-zero;
  }

  .teller-copyable {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
  }

  .teller-reference {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
    align-items: center;
  }

  .teller-actions {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-2);
  }

  @media (max-width: 1100px) {
    .teller-work {
      grid-template-columns: minmax(0, 1fr);
    }
  }
</style>
