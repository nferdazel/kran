# 03 - Screen specs: money-moving & transaction screens

Status: Wave 3, 5 Nov 2026 · read-only on source · feeds the `docs/` rebuild, not ratified.
Basis: `01-ia-flows.md` (IDs, flows, states), `02-design-system.md` (component names), DESIGN.md
(D-160), `fe-logic.md`, `fe-effectiveness.md`, R-15…R-30. Currency examples are placeholders:
`[NOMOR REKENING]`, `[NAMA ANGGOTA]`, `0,00`. No regulation is asserted.

**ID mapping.** The brief's K-numbers are not the IA's; this file uses the IA IDs.
| Brief | Used here | Route | Note |
|---|---|---|---|
| K-01 login | **K-22** | `/login` | only screen outside the transaction shell |
| K-02 kas/teller | **K-01** | `/app/teller` | deposit, withdrawal, transfer, session, session ledger |
| K-03 transfer | **K-01** mode PB | `/app/teller?mode=transfer` | same station, different decision |
| K-04 deposit/withdrawal | **K-01** modes | `/app/teller` | |
| K-05 loan installment | **K-14** modes | `/app/loans/[loanId]?tab=pay` | payment lives on the loan file (01 §5 F6) |
| K-06 close console | **K-03** | `/app/close` | EOD/EOM/EOY + certificate |
| K-07 slip/statement | **K-23 / K-24** | `/app/print/slip/[transactionId]`, `/app/print/statement/[accountId]` | two documents, two paper contracts |
| - (added) | **K-02** | `/app/vault` | cash movement approval is money-moving; in scope by the "transaction entry" test |

## 1. Screen index

| ID | Name | Route | Actor | Primary decision |
|---|---|---|---|---|
| K-22 | Masuk | `/login` | all | Is this me, on this terminal? |
| K-01 | Kas teller | `/app/teller` | T | Is this the right member and the right amount? |
| K-02 | Kas besar | `/app/vault` | M, A | Approve this cash movement? |
| K-14 | Berkas pinjaman (bayar) | `/app/loans/[loanId]` | L, T, M | Post this payment against this akad? |
| K-03 | Tutup buku | `/app/close` | M | Is this day/month/year closed, and may it be? |
| K-23 | Slip transaksi | `/app/print/slip/[transactionId]` | T, A | Is this the document I hand over? |
| K-24 | Rekening koran | `/app/print/statement/[accountId]` | T, A | Send or print this statement? |

## 2. Shared transaction shell (T-Shell)

The frame is designed once; screens add title, toolbar and work area. Reason: six screens repeating
business date, branch and cash state is six places to drift.

| Region | Fixed / scrolls | Source | Rule | When unknown |
|---|---|---|---|---|
| Top bar, 34 px, sticky | fixed | session | product name as text, branch name + code, business date, cash indicator, operator name + role, lock timer | never blank; a blank shell is a bug |
| Business date | fixed | `SessionInfo.businessDate` | server date, `DD Mon YYYY`; never `toISOString()` (FE-LOGIC-11) | "Tanggal buku belum tersedia" strip; cash posting blocked, PB allowed |
| Branch | fixed | session + `GET /branches` | name + code, never a UUID | "Cabang tidak dikenal" + "Muat ulang" |
| Cash session | fixed | `GET /teller/sessions/current` | "Kas dibuka 08:12 · float 500.000,00" or "Kas belum dibuka" | "Status kas belum diketahui" + "Muat ulang status"; cash blocked (fail-closed) |
| Session date check | fixed | session vs business date | mismatch → red strip, only "Tutup kas" and PB remain | treated as mismatch |
| Operator identity | fixed | `SessionInfo` | name, role, branch; **no balances** (lock screen leaks) | re-auth |
| Idle lock | overlay | `SessionLock`, R-21 | warning at 14 min, overlay at 15; form + key survive [DEP-7]; `/app/print/*` exempt | re-auth returns to the same step |
| Content | scrolls | page | one `h1` per page, `#main` after the skip link | - |

```
┌ KRAN · KSP [NAMA KOPERASI] ─ Cabang [CABANG] ─ Buku: 05 Nov 2026 ─ Kas: BUKA 08:12 ─ [NAMA] · Teller ┐
│ skips to #main                                                                        sisa 14:32 │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ [h1 Judul layar]                                          [aksi sekunder]  [aksi primer 44px]     │  toolbar ≤48
├───────────────────────────────────────────────┬──────────────────────────────────────────────────┤
│ WORK AREA (form / table / document)           │ SIDE PANEL 22rem: facts, review, last result      │
│ scrolls independently                         │ collapses below 1100 px, never a modal            │
│                                               │                                                   │
├───────────────────────────────────────────────┴──────────────────────────────────────────────────┤
│ FOOTER / TOTAL ROW (sticky): totals + "dimuat 08:14" + reference                                   │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Rules: the shell never shows money; the side panel never duplicates the form; every read stamps
`dimuat HH:MM`; UUIDs are never rendered (DESIGN §9); a 403 on an action re-reads the session
(fail-closed, FE-LOGIC-16). Reason: the operator's eye must land on one work surface, not a dashboard.

**Review-before-post invariants.** One review surface per screen, inline, never a modal for a routine
save. Reason: a modal hides the facts it asks the operator to check.

| Screen | Facts that must be on the review | Facts that must not be there |
|---|---|---|
| K-01 Setor/Tarik | holder, member no., account no., kind, before, amount, after, cashier, time | destination (there is none), journal ids |
| K-01 PB | both sides: holder, account no., branch, status, before/after | a raw account id, a balance of an unrelated account |
| K-02 approve | amount, source account code, maker, created at, vault balance + its timestamp | the checker's own name as approver |
| K-03 run | business date, level, blocker state | a "success" claim before the run row says so |
| K-14 pay | borrower, loan no., outstanding, source account, amount | an allocation split the server has not computed |

**Keyboard map (shared).** Reason: a teller posts 200 times a day; every pointer round trip is paid.

| Key | Where | Does |
|---|---|---|
| `Ctrl/Cmd+K` | shell | palette over permitted leaves |
| `F2` | K-01 | focus account search |
| `F4` / `F5` / `F9` | K-01 | Setor / Tarik / PB (blocked mid-review) |
| `Enter` | forms | primary action (load, then submit from review) |
| `Esc` | forms, dialogs | back one step; blocked while a POST is in flight |
| `Ctrl+P` | K-01 | reprint the last slip; **not** a save shortcut |

## 3. K-22 - Masuk (`/login`)

1. **Purpose**: get an authenticated operator onto a known terminal. **Decision**: is this me, on this terminal?
2. **Layout**: single column 42rem, vertically centred; form card flat with hairline; no shell, no business date (pre-auth data must not leak). Reason: one task, one column; branding cannot compete with the error line.
3. **Hierarchy**: focal = the form and "Masuk" (44 px, primary, `text-on-primary` on `primary`); secondary = institution name; muted = version + support line (`text-muted`, `text-xs`).
4. **Content**: `login_field_username` text, autocomplete `username`, required, `[NAMA PENGGUNA]`; `login_field_password` password, autocomplete `current-password`, required; `login_field_totp` text 6 digits, only after `mfa_required`, autocomplete `one-time-code`, `000000`; `login_hint_capslock` shown only when Caps Lock is on.
5. **Components**: Input, Button, Alert (field errors ride the Input `error` prop).
6. **States**: loading = button `aria-busy`, fields disabled; error = Alert above the form, focus to the first invalid field; partial/stale/locked = not reachable pre-auth; no-permission = not applicable (a 403 after login lands on the screen's denied panel, not here).
7. **Interaction**: focus username on load; Tab → password → Masuk; Enter submits; MFA step replaces the password block, keeps username visible, focus to the code field; Esc on MFA returns to password. No draft, no password ever in `sessionStorage`.
8. **Failure**: wrong credentials → one generic message (`login_error_invalid`), never "user not found"; `mfa_required` → step 2, code expiry → `login_error_mfa`; 429 → wait copy from the envelope, no invented minutes; network → Alert + retry, form values kept in memory.
9. **Copy**: title `login_title` "Masuk"; action `login_action_submit` "Masuk"; helper `login_hint_operator` "Gunakan akun yang diberikan admin koperasi."; error `login_error_invalid` "Nama pengguna atau kata sandi tidak cocok."; `login_error_mfa` "Kode verifikasi tidak berlaku. Masukkan kode terbaru."; `login_error_locked` "Akun terkunci. Hubungi admin koperasi."
10. **Acceptance**: axe clean both themes; keyboard-only login incl. MFA; Enter submits; focus lands on the failing field; no user enumeration in copy; 200 % zoom keeps the form and button visible; error contrast ≥ 4.5 (`danger` × `surface`).

## 4. K-01 - Kas teller (`/app/teller`)

1. **Purpose**: post and reconcile counter cash against one open session. **Decision**: is this the right member and the right amount?
   Modes: Setor/Tarik (this section), transfer **(K-01b)**, session open/close **(K-01c)**, ledger **(K-01d)**.
2. **Layout**

| Region | Fixed / scrolls | Reason |
|---|---|---|
| T-Shell | fixed | branch/date/session are preconditions, not content |
| Mode row: Setor `F4` · Tarik `F5` · Transfer `F9` · Angsuran (link to K-14) | fixed | three money decisions share one counter; segmenting keeps one screen (DESIGN §11) |
| Left column: identity → account → amount → review | scrolls | read-then-type order matches the counter conversation |
| Right panel 22rem: session float, cash in/out, expected cash, last result | fixed | the teller reconciles while typing; no page change |
| Footer: session ledger (paged 50) | scrolls | the session's own history must be visible without navigation (DESIGN §11) |
| Session panel (open/close) replaces the left column when no session is open | fixed | fail-closed gate must be the first thing seen |

```
[h1 Kas teller]                         [Buka kas] or [Tutup kas]
[ Setor (F4) | Tarik (F5) | Transfer (F9) ]     [F2 Cari anggota]
┌ identity: [NAMA ANGGOTA] · [NOMOR ANGGOTA] · [NOMOR REKENING] ─────────────┬ session ──────────┐
│ Rekening: [NOMOR REKENING] [Muat]   jenis · status · saldo (dimuat 08:14)  │ float 500.000,00  │
│ Nominal:  [0,00]        Keterangan: [____________________]                 │ masuk 1.250.000,00│
│                                     [ Tinjau ]                             │ keluar 300.000,00 │
│ Review: anggota · rekening · jenis · sebelum 0,00 · nominal · sesudah     │ seharusnya …      │
│         [ Kembali ]  [ Simpan 44px ]                                       │ hasil terakhir    │
└────────────────────────────────────────────────────────────────────────────┴───────────────────┘
Sesi ini: 08:12 IN 0,00 · 08:14 IN 0,00 …                        1-50 dari [N]
```

3. **Hierarchy**: focal = the amount + review pair (`AmountSummary` 20/600, `MoneyInput` 44 px); secondary = member and account facts (`text`, 13 px, `Money` 13/600 only for the balance that changes); muted = timestamps, helpers, session ledger (`text-muted`, `text-xs`). The accent appears only on the primary action and focus ring.
4. **Content - Setor / Tarik**

| Label (key) | Type | Source | Req | Format / placeholder | Helper |
|---|---|---|---|---|---|
| Nomor rekening `teller_field_account_no` | text | `GET /deposit/accounts?accountNo=` | yes | 10 digits, `[NOMOR REKENING]` | "Ketik lalu Enter. Nomor ada di passbook." |
| Pemilik `teller_field_holder` | read-only | account + party name - `DEPENDS: DEP-5 holder name on DepositAccount` | - | `[NAMA ANGGOTA]` | identity is required before money moves (FE-EFF-07) |
| Jenis simpanan `teller_field_savings_kind` | read-only | `savingsKind` | - | label; unclassified = "Simpanan" | never guessed from the code |
| Status `teller_field_account_status` | read-only status | `DepositAccount.status` | - | ACTIVE / DORMANT / CLOSED as text | DORMANT still accepts deposits (D-157) |
| Saldo `teller_field_balance` | money | `balance` + load time | - | `0,00`, right, tabular | "dimuat 08:14" |
| Nominal `teller_field_amount` | MoneyInput | operator | yes | `0,00`, `inputmode=decimal`, > 0, 2 dp | "Nominal harus lebih besar dari 0,00" |
| Keterangan `teller_field_narration` | text | operator | no | 200 chars | "Tercetak di slip." |
| Arah `teller_field_direction` | read-only | mode | - | "Setor (masuk)" / "Tarik (keluar)" | colour never carries direction |

### K-01b - Transfer / PB (`?mode=transfer`)

Same shell and column; PB never touches the drawer, so it is allowed with no session (01 §5 F3).
Destination is resolved by **account number**, never a pasted id (FE-LOGIC-01, the one BLOCKER).
States, keyboard and review focus are K-01 items 6-8 with one delta: an unresolved destination keeps
"Simpan" disabled (loading = "Mencari rekening…", empty = field error naming the fix).

| Label (key) | Type | Source | Req | Rule |
|---|---|---|---|---|
| Rekening sumber `teller_field_source_account` | text + load | `GET /deposit/accounts?accountNo=` | yes | must be ACTIVE |
| Rekening tujuan `teller_field_destination_account` | text + resolve on Enter/blur | same endpoint | yes | "Mencari rekening…" while resolving; submit disabled; not found → "Rekening tujuan tidak ditemukan. Periksa nomor atau cari berdasarkan nama." |
| Tujuan terverifikasi | read-only block | resolved account | - | account no, product, kind, branch, status; holder `DEPENDS: DEP-5` |
| Nominal `teller_field_amount` | MoneyInput | operator | yes | > 0, ≤ source balance |
| Keterangan | text | operator | no | 200 chars |

Review shows **both sides** (name, account no, branch, status, before/after) and blocks when source =
destination, destination CLOSED, or kind mismatch (`transfer_kind_mismatch`). Reason: the money leaves
one member and lands in another; one side is not a review. Copy: `transfer_review_title`
"Periksa kedua rekening", `transfer_error_same_account` "Rekening asal dan tujuan sama.",
`transfer_error_not_found` as above, `transfer_success` "Transfer tersimpan. Slip: [NOMOR TRANSAKSI]".
Acceptance: destination cannot be submitted unresolved; account number + branch visible on both
sides; no session required; slip is offered for the transfer, not only cash.

| Reason (`params.reason`) | Copy | Recovery |
|---|---|---|
| `insufficient_funds` | "Saldo sumber tidak cukup." | amount field focused, current balance re-read |
| `transfer_kind_mismatch` | "Jenis simpanan asal dan tujuan tidak cocok untuk PB." | choose another destination |
| `time_deposit_locked` | "Deposito belum jatuh tempo; pencairan dini punya perhitungan sendiri." | switch mode |
| `account_not_active` | "Rekening tujuan tidak aktif." | resolve another account |
| `period_closed` | "Periode sudah ditutup. Hubungi manajer." | no retry |

Unknown after timeout: the review stays open with the reference, the key is kept, "Cek status" re-reads
both accounts, and "Simpan" stays disabled until the state is read.

### K-01c - Buka / Tutup kas (session panel)

States/interaction are K-01 items 6-8; the session panel needs no other pattern.
Open: branch (select only when >1 grant), denomination rows with total (`DEPENDS: denomination list as
a parameter`), note, review, "Buka kas" 44 px. Close: **expected cash before the count**
(`DEPENDS: expectedCash on the current-session read; today only the close response carries it`,
FE-EFF-08), counted cash (MoneyInput), variance preview (`addMoney`, labelled "perkiraan"), note
required when variance ≠ 0, ConfirmDialog (the only routine-adjacent confirmation, because close is
irreversible): "Kas sesi ini akan ditutup; transaksi baru tidak bisa diposting."
States: blocked when branch/date mismatch; unknown after timeout → "Status sesi belum diketahui",
"Cek status" before any retry. Acceptance: variance is shown as words + amount (positive = "Kas lebih"),
never colour alone; count is keyboard-only; slip of opening float printable.

### K-01d - Session ledger (footer of K-01)

| Column | Source | Rule | Why |
|---|---|---|---|
| Jam | `occurredAt` | `HH:MM`, browser zone named in the header | a cash list without time cannot be reconciled against the clock |
| Arah | `direction` | "Masuk" / "Keluar" as words + sign | colour alone is forbidden |
| Rekening | `accountNo` | 10 digits, selectable | the teller matches the passbook, not an id |
| Nominal | `amount` | money, right, 2 dp | cash moved, not always the account amount (early withdrawal) |
| Keterangan | `narration` | truncated with a title, never hidden data | |
| Slip | row action | opens K-23 in a new view | reprint must not re-post |

Paging `1-50 dari N`; no page-level money total, because the endpoint returns a row count and not a
sum, and a visible-row sum would lie about the session (02 §7). The side panel's "kas seharusnya" is
the only session total and it waits for `DEPENDS: expectedCash on the current-session read`; until
then the panel shows float + in/out counts only and labels the closing figure "belum tersedia".

5. **Components**: PageHeader, Toolbar, SidePanel, Input, MoneyInput, Money, AmountSummary, ReviewPanel, IdempotentSubmit, Button, DataTable, Pagination, TotalsRow, Alert, EmptyState, ErrorState, LoadingState, ConfirmDialog (close only), SessionLock.
6. **States**: empty = "Kas belum dibuka" + "Buka kas" (no form); loading = session skeleton, numbers blank, submit disabled; error = banner + reference + "Ulangi", form values kept; partial = account loaded but session read failed → red strip, cash blocked, PB still enabled; stale = account row keeps `dimuat` stamp + "Muat ulang rekening"; locked = session closed → read-only strip + session ledger only; no-permission = in-place panel with the missing permission and "Kembali".
7. **Interaction**: `F2` focus account number, `F4/F5/F9` switch mode (only when the form is clean or after confirm), Enter loads the account then submits the form, Esc steps back from review; review takes focus on its heading; posting needs Enter on "Simpan" only - no dialog for a routine save (DESIGN §7). Key = fingerprint(`mode`,`accountId`,`amount`,`narration`); kept on network/5xx/unknown, dropped on 2xx and business 4xx.
8. **Failure**: field errors inline + summary, focus to the first; `params.reason`: `no_open_session` → "Kas belum dibuka. Buka kas untuk transaksi tunai."; `session_business_date_mismatch` → "Sesi kas bertanggal lain. Tutup sesi lalu buka lagi."; `insufficient_funds` → "Saldo tidak cukup. Saldo saat ini 0,00."; `savings_kind_locked` → "Simpanan pokok/wajib tidak bisa ditarik."; `period_closed` → "Periode sudah ditutup."; `branch_not_allowed`. Unknown state after timeout: persistent panel "Status transaksi belum diketahui", reference, "Jangan ulangi dengan nominal berbeda", "Cek status" (re-read the account/session), key preserved.
9. **Copy**: `teller_action_post` "Simpan"; `teller_action_review` "Tinjau"; `teller_action_back` "Kembali"; `teller_action_load` "Muat"; `teller_empty_no_session` "Kas belum dibuka. Buka kas untuk mulai menerima setoran."; `teller_error_timeout` "Status transaksi belum diketahui. Cek status sebelum mengulang."; `teller_success` "Tersimpan. Slip: [NOMOR TRANSAKSI]". Post-success: ref, balance before → after, "Cetak slip", "Transaksi berikutnya" (clears the form).
10. **Acceptance**: keyboard-only deposit and withdrawal; review shows account number + holder + before/after before submit; balance re-read after every posting (FE-LOGIC-09); amount rejects non-digits on input; no UUID anywhere; axe 2 themes; 1366×768 holds form + review + last result without a page scroll.

## 5. K-02 - Kas besar (`/app/vault`)

1. **Purpose**: move cash between the branch vault and a source account under maker/checker. **Decision**: approve this cash movement?
2. **Layout**: branch context strip (picker only when >1 grant) → vault balance + `dimuat` (one line, not a metric card) → two columns: request list (DataTable, left, scrolls) and selected detail + ApprovalPanel (right 22rem). Reason: a checker reads the request and the balance in one glance; no drill-down.
3. **Hierarchy**: focal = selected request amount + source account (`AmountSummary`); secondary = maker, time, note; muted = history rows and the balance stamp. No accent on the balance.
4. **Content**: form (maker) amount `vault_field_amount` (MoneyInput, > 0, ≤ `teller.vault.limit_topup_per_request`), source account `vault_field_source_account` (Select of postable ASSET accounts, code + name, never UUID; `DEPENDS: COA read grant for the maker, else a narrow account-picker endpoint`), note `vault_field_note` (required, 200); list columns: waktu (`createdAt`), status (text), nominal (money, right), sumber (`sourceAccount`), pengaju (`requestedBy` - `DEPENDS: actor display name`), aksi (row button).
5. **Components**: FilterBar (status), DataTable, Pagination, TotalsRow (pending total, labelled), ApprovalPanel, MoneyInput, Money, Alert, EmptyState, ErrorState, LoadingState.
6. **States**: empty = "Belum ada pengajuan" + "Ajukan top-up" if the maker grant exists; loading = balance and list skeletons separately; error = in-place ErrorState per region; partial = balance ok, list failed; stale = timestamp + reload, plus "Pengajuan baru mungkin belum terlihat" (no realtime topic, DEP-6); locked/read-only = decided request shows who/when and no buttons; no-permission = panel.
7. **Interaction**: queue is one tab stop; row selects; approve → confirm inline in ApprovalPanel; reject → reason field gets focus, required; self-approval disabled with visible reason `vault_self_approval_blocked` (FE-LOGIC-17); Esc leaves the detail, not the screen.
8. **Failure**: branch switch clears rows before loading and discards stale responses (FE-LOGIC-07/08); `topup_exceeds_limit` → names the limit; `vault_not_configured` → "Kas besar cabang ini belum disiapkan. Hubungi admin."; reject gets an idempotency key (FE-LOGIC-19); unknown status after timeout → "Keputusan belum diketahui. Muat ulang daftar."
9. **Copy**: `vault_action_approve` "Setujui", `vault_action_reject` "Tolak", `vault_action_submit` "Ajukan top-up", `vault_empty` "Belum ada pengajuan untuk cabang ini.", `vault_self_approval_blocked` "Anda pengaju permintaan ini. Persetujuan harus oleh orang lain.", `vault_confirm_approve` "Setujui top-up 0,00 dari [KODE AKUN]?"
10. **Acceptance**: approve and reject are keyboard-only; rejecting without a reason is impossible; own request has no enabled approve; branch switch never shows the previous branch's rows; axe 2 themes; amount and source readable at 1280.

## 6. K-14 - Bayar angsuran (`/app/loans/[loanId]`)

1. **Purpose**: post one instalment payment from the borrower's account. **Decision**: post this payment against this akad?
2. **Layout**: loan facts block (borrower, loan no, product, outstanding principal/interest/penalty, `dimuat`) → tab row (Jadwal · Pembayaran · Riwayat) → left schedule table (scrolls) and right payment panel (form → review). Reason: the officer must see what is owed while typing the amount; the schedule is the evidence, the form is the action.
3. **Hierarchy**: focal = `principalOutstanding` + the payment amount; secondary = due rows (oldest first) and the source account; muted = product/tenor metadata and timestamps.
4. **Content**: sumber dana `loan_field_source_account` (Select, accounts of the borrower, ACTIVE, same branch; empty → "Anggota ini belum punya rekening aktif."); nominal `loan_field_amount` (MoneyInput, > 0, ≤ outstanding; quick fill "Isi tagihan berikutnya" from the oldest unpaid row, labelled as a suggestion); no free-text narration - the endpoint has none. Schedule columns: no, jatuh tempo, pokok, bunga, denda, dibayar, status (`DataTable`, money right, totals row = outstanding).
5. **Components**: PageHeader, DataTable, TotalsRow, Money, MoneyInput, AmountSummary, ReviewPanel, IdempotentSubmit, Alert, EmptyState, ErrorState, LoadingState.
6. **States**: empty = "Belum ada jadwal angsuran" (`schedule_missing` blocks payment); loading = facts skeleton, form disabled; error = form error in place with reference; partial = facts ok, schedule failed → payment disabled with reason (POST would need the schedule); stale = facts stamp + reload after any payment; locked = loan WRITTEN_OFF/CLOSED or not disbursed → read-only with the reason; no-permission = panel.
7. **Interaction**: Tab lands on the source account, then amount, then "Tinjau"; review heading takes focus; Enter submits, Esc returns; after success clear amount + key and re-read loan facts (FE-LOGIC-06); key = fingerprint(`loanId`,`accountId`,`amount`).
8. **Failure**: `amount_exceeds_outstanding` → "Nominal melebihi sisa kewajiban 0,00."; `insufficient_balance` → current balance; `account_party_mismatch` → "Rekening bukan milik peminjam."; `not_disbursed`, `loan_inactive`, `allocation_conflict` mapped per `params.reason`; unknown after timeout → block the form, show reference + "Cek status", never re-post.
9. **Copy**: `loan_action_pay` "Bayar angsuran", `loan_action_review` "Tinjau pembayaran", `loan_review_note` "Pembagian pokok, bunga, dan denda dihitung saat disimpan.", `loan_success` "Pembayaran tersimpan. Pokok 0,00 · Bunga 0,00 · Denda 0,00. Sisa pokok 0,00." (`DEPENDS: server allocation preview is absent; the split is shown only from the result`).
10. **Acceptance**: no allocation split is shown as fact before posting; outstanding and source balance visible before submit; success shows the server split and re-reads facts; the form is empty on reopen; keyboard-only payment; axe 2 themes.

## 7. K-03 - Tutup buku (`/app/close`)

1. **Purpose**: close the business date at day/month/year level and prove it. **Decision**: is this day/month/year closed, and may it be?
2. **Layout**: period context (business date, level tabs Harian · Bulanan · Tahunan) → blocker checklist (links) → run control + progress → run history → certificate print. Reason: blockers are the decision; the Run button is meaningless until they are read.
3. **Hierarchy**: focal = the blocker list and its count; secondary = run state and last run time; muted = history and task details. The Run button is primary only when the list is empty.
4. **Content**: business date (read-only, from session; no picker - you close the open date); blockers: open cash sessions (link K-01), unposted journals, trial balance ≠ 0 (link K-04), pending approvals (link K-13/K-02); run state (idle/running/paused/unknown), started by/at, task rows (name, state, error code + hint); history columns: tanggal, level, status, mulai, selesai, pelaku.
**Level content** (the tab is the level, not a second navigation):

| Level | Closes | Data today | Gate |
|---|---|---|---|
| Harian | EOD tasks for the open business date | `dayclose/run` exists | run only when blockers = 0 |
| Bulanan | period close + report pack | only `ledger.period` close; `DEPENDS: EOM as a dayclose task` (F8/F9) | TB zero and subledger = GL before the tab enables |
| Tahunan | EOY + SHU basis | **absent**; `DEPENDS: EOY task + signed SHU basis (R-27)` | tab states the missing input, no fake action |

5. **Components**: PageHeader, Toolbar (level tabs), DataTable, TotalsRow, Alert, EmptyState, ErrorState, LoadingState, ConfirmDialog, CloseCertificate, Print styles.
6. **States**: empty = "Belum ada penutupan hari ini" + "Jalankan tutup buku"; loading = pre-check list skeleton, Run disabled; error = blocker list rendered as the error surface (not a toast); partial = checks ok, history failed; stale/unknown = "Status penutupan tidak diketahui. Jangan ulangi; muat ulang." with Run disabled until state is read; locked = closed date → read-only + certificate; no-permission = panel.
7. **Interaction**: blockers are links with focus return; Run opens one ConfirmDialog ("Tanggal buku 05 Nov 2026 akan ditutup. Transaksi bertanggal ini tidak bisa diposting lagi."); Pause/Resume/Cancel appear only in valid states; polling only while active, stops on unmount; EOM reads period close from `ledger.period` (`DEPENDS: EOM as a dayclose task`); EOY tab renders "Belum tersedia" and names the missing input (R-27) - never a disabled fake button.
8. **Failure**: blocker entries name the offending count and the screen that clears it; task error → code + runbook hint only for known codes; timeout → explicit unknown banner, no auto-retry; cancel requires a reason; certificate must not print while the period is open.
9. **Copy**: `close_action_run` "Jalankan tutup buku", `close_action_pause` "Jeda", `close_action_resume` "Lanjutkan", `close_action_cancel` "Batalkan", `close_empty` "Belum ada penutupan untuk tanggal ini.", `close_unknown` "Status penutupan tidak diketahui. Jangan ulangi; muat ulang status.", `close_blocked` "Tutup buku belum bisa dijalankan: 3 penghalang.", `close_certificate` "Cetak bukti penutupan".
10. **Acceptance**: Run unreachable while a blocker exists or the state is unknown; every blocker links to its fix; certificate carries date, totals, variance, actor, time, signature block and never prints open; EOY absence is stated, not faked; axe 2 themes; certificate prints on A4 without an orphaned total.

## 8. K-23 - Slip transaksi (`/app/print/slip/[transactionId]`)

1. **Purpose**: hand the member a document of the posting. **Decision**: is this the document I hand over?
2. **Layout**: 80 mm thermal (A5 fallback `NEEDS-COMPLIANCE-REVIEW`); ReportHeader → amount → account/member → cashier/time → narration → footer; toolbar with "Cetak" hidden on print. Reason: the amount is the first thing both parties check.
3. **Hierarchy**: amount (20/600, `text`), then member + account no, then cashier/time; everything else 12 px.
4. **Content**: institution, branch, document title, transaction reference, business date + time + zone, account no, member name (`DEPENDS: DEP-5`), direction as words, amount, narration, cashier name (`DEPENDS: cashier on the slip read model`), COPY marker on reprint (`DEPENDS: reprint counter`). No balance after (not stored, D-127).
5. **Components**: ReportHeader, StatementLayout (A5/slip variant), Money, Alert, ErrorState, LoadingState.
6. **States**: not found = reference shown + "Slip tidak ditemukan"; loading = document skeleton; error = "Slip gagal dimuat" + retry; partial n/a (single document); stale = reprint always re-reads; locked = immutable (no edit path); no-permission = panel. Never locks on idle.
7. **Interaction**: print on load only via an explicit button (no auto-dialog); Ctrl+P allowed; Esc returns to the teller; no editable field exists.
8. **Failure**: 404 → reference + back; offline → retry; a reprint must be visually distinguishable, so if the marker cannot be produced the button is absent rather than the marker faked.
9. **Copy**: `slip_title` "Slip transaksi", `slip_action_print` "Cetak", `slip_reprint_marker` "SALINAN", `slip_error_missing` "Slip tidak ditemukan. Periksa nomor transaksi.", `slip_footer` "Simpan slip ini sebagai bukti."
10. **Acceptance**: paper shows member, account, amount, cashier, reference, timestamp + zone; reprint marked; totals/amounts tabular and 2 dp; contrast measured on white; no nav/toolbar in print; one page at 80 mm.

## 9. K-24 - Rekening koran (`/app/print/statement/[accountId]`)

1. **Purpose**: give the member a period statement of one account. **Decision**: send or print this statement?
2. **Layout**: toolbar (period from/to, branch context, "Cetak") → ReportHeader → account identity → rows table → totals → footer with page x/y and "Dihitung HH:MM". Reason: the range is the only variable; everything below it is the document.
3. **Hierarchy**: running balance column and closing balance are the focal facts; rows are dense 13 px; metadata muted.
4. **Content**: period, account no, holder (`DEPENDS: DEP-5`), product/kind, status, rows (date, kind as words, direction IN/OUT, amount, narration, reference), opening balance + running balance (`DEPENDS: opening balance / server-side running balance; the read model has neither and rows are capped at 500`), totals (in, out), generated at, page x/y; footer states "Bukan rekonsiliasi buku besar."
5. **Components**: ReportHeader, StatementLayout, DataTable (print density), TotalsRow, Money, FilterBar (date range), EmptyState, ErrorState, LoadingState.
6. **States**: empty = "Tidak ada mutasi pada rentang ini." + range shown; loading = document skeleton; error = "Rekening koran gagal dimuat" + retry; partial = rows ok, totals failed → totals omitted, not zeroed; stale = "Dihitung HH:MM"; locked = closed account marked; no-permission = panel.
7. **Interaction**: date range applies on Enter, not per keystroke; print is explicit; range lives in the URL (query), so reload reproduces it; no editing of rows.
8. **Failure**: range > cap → "Rentang terlalu panjang. Persempit tanggal." (no silent truncation); invalid range → inline error; 404 → account reference + back; print blocked when totals failed (a statement with no totals is misleading).
9. **Copy**: `statement_title` "Rekening koran", `statement_action_print` "Cetak", `statement_empty` "Tidak ada mutasi pada rentang ini.", `statement_total_in` "Total masuk", `statement_total_out` "Total keluar", `statement_note` "Dokumen ini bukan rekonsiliasi buku besar.", `statement_error_range` "Rentang terlalu panjang. Persempit tanggal."
10. **Acceptance**: running balance column present only when its source exists; totals match the sum of visible rows; period and generated-at printed; `thead` repeats; totals block `break-inside: avoid`; no capped range is presented as complete; axe on the on-screen shell.

## 10. Cross-screen notes

- Print documents never lock and never post; they are the only read-only artifacts that leave the building.
- Every money screen shares one idempotency implementation and one review pattern; a screen that adds a
  modal for a routine save is a review failure (01 §6).
- `DEPENDS` summary: DEP-5 blocks identity on K-01/K-23/K-24; expected cash on session read blocks
  K-01 close; actor names block K-02 list; allocation preview and opening/running balance block
  honest figures on K-14/K-24; EOM/EOY tasks block K-03 non-daily tabs; reprint counter blocks the
  K-23 COPY marker.
