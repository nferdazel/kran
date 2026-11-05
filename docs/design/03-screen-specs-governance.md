# 03 · Screen specs - administration, lists, reports, oversight

Status: Wave 3 draft, 5 Nov 2026 · read-only on source · IDs, routes, permission codes from
`01-ia-flows.md`; component and token names from `02-design-system.md`; visual direction D-160.
Scope: **18 of the 24 target screens** - entity administration, lists, reports, oversight.
Out of scope, owned by the transaction spec: K-01 teller station, K-03 close console, K-11 loan
portfolio list, K-22 login, K-23 slip, K-24 statement.

Rules this file adds:
- **R-31** - every layout choice carries a one-line reason. `02-decisions-log.md` ends at R-30, so
  R-31 is a design-wave rule raised here, not an owner ruling; it becomes `D-xxx` only on approval.
- **R-27** - all seven states (`E L X P S R N`) are specified per screen; `-` means the state
  cannot occur there and the adjacent state carries its failure (01 §7).
- **R-17 / R-29** - separation is per action: *permission absent* removes the control; *permission
  present but blocked* (own submission, closed period) shows the control disabled **with the reason**.
- **R-22** - every printed artefact carries institution, actor, timestamp with zone.
- Copy: UI Indonesian, i18n keys English, both catalogues. Banned words in UI: "vault" → *Kas besar*,
  "run" → *proses*, "batch", "uuid", table names (DESIGN §9).
- `DEPENDS:` marks a field the API cannot supply today (01 §3.8). The field renders a labelled
  absence plus the operation needed; it never renders `0,00` or a guessed value.
- Placeholders are bracketed (`[NAMA ANGGOTA]`, `[NOMOR ANGGOTA]`, `[PERIODE]`), never sample data.

## 1 · Screen index

| ID | Screen | Route | Actor | Permission | The one decision |
|---|---|---|---|---|---|
| K-02 | Kas besar | `/app/vault` | A, M | `teller.vault.read/submit/approve` | Approve this cash movement? |
| K-06 | Daftar anggota | `/app/members` | A, L, T® | `party.party.read`, `coop.member.read` [DEP-1] | Which member is this? |
| K-07 | Anggota baru | `/app/members/new` | A | `party.party.create`, `party.kyc.manage`, `coop.member.create` [DEP-1,2] | Admit this person, or reject the duplicate? |
| K-08 | Berkas anggota | `/app/members/[memberId]` | A, L, T | `party.party.read`, `deposit.account.read`, `lending.loan.read`, `coop.member.read` | Is this member in good standing? |
| K-09 | Keluar anggota | `/app/members/[memberId]/exit` | M, A | `coop.member.manage` [DEP-1], `lending.loan.read` | May this member leave, and what is refunded? |
| K-10 | Kewajiban pokok & wajib | `/app/savings/obligations` | A | `deposit.account.read`, `coop.obligation.*` [DEP-1] | Who still owes this period, and what do we do? |
| K-12 | Pengajuan pinjaman | `/app/loans/new` | L | `lending.loan.submit`, `party.party.read` | Is this loan admissible? |
| K-13 | Persetujuan pinjaman | `/app/loans/approvals` | M | `lending.loan.approve` | Do I approve someone else's application? |
| K-14 | Berkas pinjaman | `/app/loans/[loanId]` | L, T, M | `lending.loan.read/disburse/pay/restructure/write_off/recovery` | Post this movement against this akad? |
| K-15 | Tunggakan | `/app/loans/arrears` | L, M | `lending.loan.read` | Who do we contact today? |
| K-16 | Laporan (9 dokumen) | `/app/reports`, `/app/reports/[reportKey]` | M, P, A | `report.*` [DEP-3] | Is this period's pack complete and signed? |
| K-04 | Neraca saldo | `/app/ledger` | A, M, P | `ledger.journal.read`, `ledger.period.read` | Does the trial balance balance? |
| K-05 | Jurnal & COA | `/app/ledger/admin` | A | `ledger.coa.manage`, `ledger.journal.reverse` | Reverse which entry, with what reason? |
| K-17 | Audit | `/app/audit` | A, M, P* | `platform.audit.read` | Who did this, and when? |
| K-18 | Pengguna | `/app/users` | A | `platform.user.manage`, `platform.branch.read` [DEP-4] | Does this person get access, and to what? |
| K-19 | Parameter | `/app/params` | M, A | `platform.param.read/submit/approve` | What value does the business run on? |
| K-20 | Produk | `/app/products` | A, M | `product.catalog.read/manage/approve` | Which products may exist? |
| K-21 | Ganti sandi | `/app/password` | all | self only | Did I type it correctly? |

® read-only · \* pengurus only with an explicit grant.

## 2 · The list-page contract (one pattern, eleven screens)

Vertical order, top to bottom: `PageHeader` (one `h1`, at most one action) → `FilterBar` (search +
≤3 selects + date range) → result count in `role="status"` → `DataTable` inside a labelled scroll
region → `TotalsRow` in `<tfoot>` → `Pagination`. Reason: identical bands mean an operator learns
one list and reads the other ten; the one screen that broke the order (`vault`: balance above a
differently-filtered queue) produced decisions on the wrong branch's cash (FE-LOGIC-07/08).

1. Filters live in the URL query; `Hapus filter` resets them; changing a filter **clears** rows and
   shows `LoadingState` - old rows must never sit under a new filter label (FE-LOGIC-08).
2. Server paging, 50 per page, text "1-50 dari 1.204". No infinite scroll, no silent cap
   (FE-EFF-05, FE-LOGIC-04).
3. **Two totals always**: `TotalsRow` = visible rows; a scope line above the table = the whole
   filter, labelled. A verdict word ("Seimbang") is computed on the scope set only (FE-LOGIC-02).
4. Sorting: ≤2 sortable columns, `aria-sort` on exactly one `th`, sort kept in the URL; the sort
   control is a real `<button>` inside the `th`.
5. No row selection, no bulk action in MVP. Reason: the only bulk operation is generating a period
   (K-10), a scope action, not a selection; a checkbox column without an action is a lie.
6. Row actions: one link to the record + at most two 24 px `Button`s. No overflow menu - a hidden
   action is an untested action.
7. Empty has three copies (`no-data` / `no-match` / `denied`) from `EmptyState.kind`, each naming
   its next step (01 §6).
8. Print exists only where 01 §8 declares a document (K-15, K-16). No Export button until an
   endpoint exists; an Export that does nothing is banned (FE-EFF-10, DESIGN §13.13).

Column labels are a fixed vocabulary reused verbatim, so one field never acquires two names:
Nomor anggota · Nama · Status · Cabang · Tanggal gabung · Nominal (IDR) · Dibayar · Sisa ·
Jatuh tempo · DPD · Waktu · Pelaku · Aksi. A column whose label is not on this list has to
justify the new noun in review - two labels for one amount is how a total gets misread.

| Screen | Filters | Sortable | Foot | Print |
|---|---|---|---|---|
| K-06 anggota | cari, status, cabang | nama, nomor | jumlah | - |
| K-10 kewajiban | periode, status, produk | anggota | jatuh/terbayar/sisa | - |
| K-13 persetujuan | produk, petugas, tanggal | diajukan | pokok | - |
| K-15 tunggakan | DPD, petugas, produk | DPD, sisa | sisa + jumlah | ✓ |
| K-17 audit | pelaku, aksi, objek, tanggal | waktu | - | - |
| K-18 pengguna | cari, status | nama | jumlah | - |
| K-19 parameter | grup, status | kunci | - | - |
| K-20 produk | jenis, status | kode | - | - |
| K-02 kas besar | cabang, status | diajukan | nominal | - |
| K-04 neraca saldo | periode, kategori | kode akun | debet/kredit/saldo | ✓ |
| K-05 jurnal | tanggal, sumber | tanggal | debet/kredit | - |

## 3 · Report apparatus - K-16

**Recommendation: one apparatus, two routes** - `/app/reports` (checklist) and
`/app/reports/[reportKey]` (document). Not eight routes, and not a dashboard.

Why one apparatus: the header, period, branch, business date, generated-at, source line, watermark,
control lines and print rules are identical across all documents (01 §3 counts them as one); eight
routes copy that shell eight times and drift. Permission is one family (`report.read` per key), so a
route per key multiplies nav entries and turns the group into an empty grid when one key is
ungranted. Absence of a query is a first-class state, so a missing document renders "Belum tersedia"
in the same place - a 404 route looks like a bug instead (DEP-3).

Why the doubt in 01 does not change that: the objection is about **count** (eight documents on one
route), not about routing. Deep links are satisfied by `reportKey` typed as a closed union; an
unknown key renders the not-found panel, never a blank page.

Guard against the index becoming a dashboard: `/app/reports` is a **checklist table** - Dokumen |
Periode | Sumber | Dihitung | Status | Aksi. No cards, no KPI strip, no sparkline; the only numbers
are each document's control result, printed as text ("Seimbang" / "Selisih 0,00").

Shared header (`ReportHeader`): institution + branch names (from parameters and the branch master,
never a UUID - FE-ISO-08), document title, period ("1 Nov - 30 Nov 2026"), business date, generated
at **with zone** ("5 Nov 2026 14:12 WIB"), source line ("Dihitung dari jurnal · [N] baris"),
"BELUM DITUTUP" watermark when the period is open, page x/y.

Control lines: every document ends with `TotalsRow` labelled *Kontrol* plus a verdict sentence. A
control compares the document to its own source of truth at render time; a failed control is text
first, colour second (DESIGN §8).

Export/print: print only in MVP; no CSV/XLSX endpoint exists. Print forces light theme, repeats
`thead`, keeps totals and signature blocks `break-inside: avoid` (01 §8).

| Key | Document | Period | Control line | Source |
|---|---|---|---|---|
| `bs` | Neraca | as of date | Aset = Liabilitas + Ekuitas, selisih as text | TB |
| `is` | Laba rugi | range | Pendapatan − Beban = Surplus; basis (akrual/kas) printed | journal by class |
| `equity` | Perubahan ekuitas | range | saldo awal + mutasi = saldo akhir | journal |
| `member-register` | Daftar anggota | as of date | count per status = table foot | coop [DEP-1] |
| `savings-arrears` | Tunggakan simpanan | period | Σ sisa = unpaid obligations | obligations [DEP-1] |
| `loan-exposure` | Pinjaman & tunggakan | as of date | outstanding per DPD bucket; disbursed = piutang | schedule |
| `cash-recap` | Rekap kas | business date | expected vs counted vs variance per session | teller |
| `close-certificate` | Bukti tutup buku | business date | tasks, gates, TB zero, actor, signature | daycloser |
| `shu-member` | SHU per anggota | fiscal year | Σ alokasi = distributable; rounding residue named | EOY [DEP-1] |

Nine keys, not the eight named in 01 §3: savings arrears and loan arrears have different readers and
different control lines, so they are two documents. Recorded as a deviation (§6).

## 4 · Governance seats and no-write surfaces

Pengurus reads K-06, K-08 (read), K-04, K-16; K-17 only if `platform.audit.read` is granted.

Three rules, applied on every screen in this file:
1. **Permission absent ⇒ the element is not rendered**, not disabled. Reason: a greyed "Setujui"
   still advertises a capability the seat does not have (the fail-closed reasoning of `nav.ts`
   extended from links to actions).
2. **Permission present but the action is blocked** (own submission, closed period, exited member)
   ⇒ rendered, `disabled`, with the reason in the label's `aria-describedby`, never a 409 after the
   click (FE-LOGIC-17).
3. **Server is authoritative**: a 403 on a write renders the in-place "Tidak berizin" panel with the
   permission needed and a way back, and refreshes the session; it never redirects (01 §6).

Read-only seats keep the print path: the RAT pack is printed from K-16 with no write affordance
anywhere on the page. Audit (K-17) has no action buttons at all, by nature; its only affordances are
filters, open-detail and copy-reference.

## 5 · Screens

### K-02 · Kas besar - `/app/vault`
**1 Decision** - approve this cash movement?
**2 Layout** - cabang select + `AmountSummary` above, request table below, one column at every width. Reason: the balance is the fact being judged and the queue is the action; side-by-side let a row sit next to the wrong branch's balance.
**3 Hierarchy** - focal: saldo (text-lg 600, `text` not `text-muted`); secondary: pending rows and their nominal; muted: decided history.
**4 Content** - `vault_branch` select (branch **name**, `GET /branches`) · `vault_balance` money 2dp · `vault_col_kind` (isi/kurangi) · `vault_col_amount` money 2dp, foot total · `vault_col_requested_by` name+role [DEPENDS: actor display name] · `vault_col_requested_at` datetime+zone · `vault_col_status` (MENUNGGU/DISETUJUI/DITOLAK, unknown prints as-is - FE-LOGIC-18) · `vault_col_decided_by` · `vault_col_reason`.
**5 Components** - PageHeader, FilterBar, AmountSummary, DataTable, TotalsRow, ApprovalPanel, MoneyInput, ReviewPanel, ConfirmDialog, Alert, Pagination.
**6 States** - E "Belum ada pengajuan kas besar" + Ajukan · L balance skeleton with blank numerals (never `0,00`) · X banner + ref + Ulangi · P balance ok, queue failed · S "dimuat <time>" + reload, request-sequence guard on branch switch (FE-LOGIC-07) · R checker without grant: submit form absent · N panel.
**7 Interaction** - branch switch clears rows before load; maker submits through `ReviewPanel` + key; checker rejects with required reason and a key on reject too (FE-LOGIC-19); self-approval disabled with reason, never hidden.
**8 Failure** - 403 panel; approve timeout → status check before retry, never a second approve; mismatched branch responses discarded.
**9 Copy** - `vault_title` "Kas besar"; `vault_action_submit` "Ajukan"; `vault_empty_none` "Belum ada pengajuan kas besar."; `vault_self_approval` "Anda mengajukan ini. Persetujuan harus oleh orang lain."; `vault_error_load` "Saldo kas besar gagal dimuat."
**10 Accept** - balance is labelled with the branch actually rendered; no raw id anywhere; self-approval cannot be clicked; unknown status prints verbatim; footer total covers visible rows only.

### K-06 · Daftar anggota - `/app/members`
**1 Decision** - which member is this? (identity before any money or file action)
**2 Layout** - FilterBar over a full-width table; no side panel. Reason: the register is searched, not judged, so nothing competes with the rows; only the table region scrolls.
**3 Hierarchy** - focal: Nomor anggota + Nama (number at 600, name at 400); secondary: status badge + cabang; muted: telepon, tanggal.
**4 Content** - `members_col_no` immutable text, sort ✓ · `members_col_name` text, sort ✓ · `members_col_ktp` masked `•••• 1234` · `members_col_phone` · `members_col_branch` · `members_col_status` text+shape · `members_col_joined` date · `members_col_ended` date (EXITED only). DEPENDS: member list read [DEP-1].
**5 Components** - PageHeader, FilterBar, DataTable, Pagination, EmptyState, ErrorState, LoadingState, MemberRef, PartyBadge, Button.
**6 States** - E "Belum ada anggota" + Anggota baru · L 34 px skeleton rows · X banner + ref + Ulangi · P count ok, rows failed · S "dimuat <time>" + reload · R exited rows marked, no write action · N panel naming `coop.member.read`.
**7 Interaction** - search applies on Enter (name, member number, last 4 KTP digits); row opens K-08; `Ctrl/Cmd+K` searches members; active filters shown as chips with `Hapus filter`.
**8 Failure** - 403 panel; a member exited in another tab leaves a stale row → timestamp + reload; no export here (the register *document* is K-16 `member-register`).
**9 Copy** - `members_title` "Anggota"; `members_action_new` "Anggota baru"; `members_empty_none` "Belum ada anggota."; `members_empty_filter` "Tidak ada anggota yang cocok dengan filter ini."; `members_error_load` "Daftar anggota gagal dimuat."
**10 Accept** - rows show number and name, never an id; search by three keys; filtered-empty copy differs from no-data; footer count equals server total; exited state readable without colour; keyboard order = visual order.

### K-07 · Anggota baru - `/app/members/new`
**1 Decision** - admit this person, or reject the duplicate?
**2 Layout** - two zones at ≥1100 px: form (reading width 42rem) + `SidePanel` 22rem carrying the duplicate-check result and the admission consequences; single column below. Reason: the duplicate decision arrives mid-form and must be visible without leaving it.
**3 Hierarchy** - focal: identity fields; secondary: duplicate-check verdict; muted: consent and KYC references.
**4 Content** - `member_new_name` (as on KTP) · `member_new_nik` 16 digits, masked after save · `member_new_birth` date · `member_new_address` · `member_new_phone` · `member_new_doc_type` select · `member_new_doc_ref` text (reference only, no upload [DEP-2]) · `member_new_verifier` (session user, read-only) · `member_new_consent` checkbox + notice version · `member_new_branch` select · `member_new_joined` date, backdate requires reason · `member_new_number` server-proposed, "diberikan saat simpan" · `member_new_pokok` money from parameter `P.pokok.amount`, never typed.
**5 Components** - PageHeader, Input, Select, Checkbox, MoneyInput, Alert, ReviewPanel, SidePanel, EmptyState, ErrorState.
**6 States** - E blank form, no sample values · L duplicate check running, Save disabled · X field + summary + ref · P member created, pokok failed → banner + "Bayar pokok" · S duplicate check older than the NIK field · R save disabled after submit while the number is issued · N panel.
**7 Interaction** - NIK blur triggers duplicate check; 409 renders a link to the existing member, not a bare conflict; Enter submits; unsaved form is draft-protected by the session lock (R-21).
**8 Failure** - duplicate 409 → existing-member path; KYC storage 501 → "Penyimpanan dokumen belum aktif" and the reference fields stay optional; number service down → number promised at save, never fabricated; permission 403 → panel.
**9 Copy** - `member_new_title` "Anggota baru"; `member_new_action_save` "Simpan anggota"; `member_new_dup_found` "Data ini mirip anggota [NAMA ANGGOTA] ([NOMOR ANGGOTA])."; `member_new_error_save` "Anggota belum tersimpan."
**10 Accept** - no sample data on first render; NIK never re-displayed in clear after save; pokok comes from a parameter; duplicate path links to the member; created-but-unpaid pokok is a visible partial state.

### K-08 · Berkas anggota - `/app/members/[memberId]`
**1 Decision** - is this member in good standing?
**2 Layout** - identity header (MemberRef + status + cabang + joined) then one tab row: Ringkasan · Rekening · Kewajiban · Pinjaman · SHU. Reason: four different readers (admin, teller, officer, pengurus) ask four questions about one record; the tab row is depth 3 and keeps one `h1`.
**3 Hierarchy** - focal: status + the one blocking fact (arrears or outstanding loan); secondary: balances per account; muted: KYC metadata, timestamps.
**4 Content** - `member_file_no` · `member_file_name` · `member_file_ktp` masked + unmask action (distinct permission, reason, audited; code to confirm - DEPENDS) · `member_file_status` · `member_file_branch` · `member_file_joined`/`ended` · accounts: `member_file_acc_no`, product, balance money 2dp · obligations: period, due, paid, sisa · loans: akad ref, outstanding, DPD · SHU: year, basis, amount. Holder name on accounts needs DEP-5.
**5 Components** - PageHeader, MemberRef, PartyBadge, AccountRef, DataTable, TotalsRow, AmountSummary, Button, Alert, SidePanel (account opening - the merged `/app/accounts/open`), ErrorState.
**6 States** - E new member, no accounts → "Buka rekening" section · L per-tab skeleton · X banner + ref · P identity ok, loans failed (section-level) · S per-tab stamp · R exited member read-only · N panel.
**7 Interaction** - tab state in URL; "Setor" carries the member to K-01; "Keluar" opens K-09; corrections are reversals, never edits; unmask requires reason and writes an audit row.
**8 Failure** - 403 panel; stale balance after a deposit made in another seat → stamp + reload; an unmasked value is never cached across tabs.
**9 Copy** - `member_file_title` "Berkas anggota"; `member_file_tab_accounts` "Rekening"; `member_file_empty_accounts` "Belum ada rekening. Buka rekening pertama."; `member_file_unmask` "Tampilkan nomor identitas"; `member_file_error_load` "Berkas anggota gagal dimuat."
**10 Accept** - one `h1` for the whole record; every tab states its own freshness; exited member offers no write action; unmask is permissioned, reasoned and audited; no account is created without a visible member context.

### K-09 · Keluar anggota - `/app/members/[memberId]/exit`
**1 Decision** - may this member leave, and what is refunded?
**2 Layout** - eligibility list at top, computation table in the middle, irreversible confirm at the bottom. Reason: the blockers decide whether the number is even meaningful, so they precede it.
**3 Hierarchy** - focal: refund total (AmountSummary, 600); secondary: each deduction line; muted: policy notes and parameter names in words.
**4 Content** - `member_exit_eligibility` list (pinjaman berjalan, saldo rekening, kewajiban belum lunas, status) · `member_exit_pokok` · `member_exit_wajib` · `member_exit_sukarela` · `member_exit_arrears` (−) · `member_exit_loan_offset` (−, only when `P.exit.offset_loans`) · `member_exit_penalty` (−) · `member_exit_refund` (Σ) · `member_exit_reason` · `member_exit_effective` date. NEEDS-COMPLIANCE-REVIEW: offset rule and heir handling.
**5 Components** - PageHeader, AmountSummary, TotalsRow, ConfirmDialog (irreversible), Input (reason), Alert, EmptyState, ErrorState, ReportHeader (exit statement).
**6 States** - E not eligible: blockers listed with links, computation absent (never zeros) · L computation skeleton · X banner + ref · P refund ok, loans failed · S "dihitung <time>" · R approved → locked · N panel.
**7 Interaction** - recompute is explicit; approval is a second person (maker/checker); reason required; print of the exit statement carries institution, actor, timestamp + zone.
**8 Failure** - 403 panel; a loan disbursed after the computation invalidates it → stale banner + recompute; approval timeout → status check, never a second approval.
**9 Copy** - `member_exit_title` "Keluar anggota"; `member_exit_blocked` "Anggota belum bisa keluar: [ALASAN]."; `member_exit_action_approve` "Setujui keluar"; `member_exit_error_compute` "Perhitungan pengembalian gagal dimuat."
**10 Accept** - no number without a successful computation; every deduction names its parameter in words; exit is a state, never a deletion; approved computation is immutable; the printed statement is reproducible.

### K-10 · Kewajiban pokok & wajib - `/app/savings/obligations`
**1 Decision** - who still owes this period, and what do we do?
**2 Layout** - period control in the toolbar (not a filter chip), status filter, table with totals. Reason: the period is the scope of the whole screen, not a narrowing of it.
**3 Hierarchy** - focal: outstanding per row; secondary: paid; muted: due date and last payment.
**4 Content** - `obligations_period` month select, default = session business date (never `toISOString()`, FE-LOGIC-11) · `obligations_col_member` MemberRef · `obligations_col_product` (pokok/wajib) · `obligations_col_due` money · `obligations_col_paid` money · `obligations_col_outstanding` money, foot total · `obligations_col_status` (LUNAS/SEBAGIAN/TUNGGAKAN/DIBEBASKAN) · `obligations_col_last_payment` datetime. DEPENDS: obligation read per period [DEP-1].
**5 Components** - PageHeader, Toolbar, FilterBar, DataTable, TotalsRow, MoneyInput, ReviewPanel, ConfirmDialog (waive), EmptyState, ErrorState, Pagination.
**6 States** - E "Belum dibuat" + Buat kewajiban [PERIODE] · L skeleton, totals blank · X banner + retry · P totals ok, rows failed · S period stamp · R waived rows locked · N panel.
**7 Interaction** - generate is idempotent per period, confirm states the count; pay opens an inline review with member, period, amount, before/after; waive needs reason **and** approver; double payment prevented by row state, not by hope.
**8 Failure** - timeout on pay → status check before retry ("Periode mungkin sudah diproses"); generate twice → no-op with notice; 403 panel.
**9 Copy** - `obligations_title` "Kewajiban pokok & wajib"; `obligations_action_generate` "Buat kewajiban [PERIODE]"; `obligations_empty_none` "Kewajiban [PERIODE] belum dibuat."; `obligations_empty_filter` "Tidak ada kewajiban dengan status ini."; `obligations_error_load`.
**10 Accept** - period cannot silently follow the browser clock; totals equal visible rows and the scope total is labelled; a paid row cannot be paid again; waive requires reason + approver; empty ≠ filtered-empty.

### K-12 · Pengajuan pinjaman - `/app/loans/new`
**1 Decision** - is this loan admissible?
**2 Layout** - form left, schedule preview + eligibility in a 22rem `SidePanel`; single column below 1100. Reason: the schedule is the thing the officer defends to the member, so it stays visible while typing.
**3 Hierarchy** - focal: pokok + tenor; secondary: eligibility verdict; muted: purpose, collateral note.
**4 Content** - `origination_member` search by name/number → MemberRef (never a UUID) · `origination_product` select, active versions only · `origination_principal` MoneyInput 2dp · `origination_tenor` integer months · `origination_method` read-only text from product · `origination_first_due` date · `origination_purpose` text · `origination_collateral` text · `origination_officer` session user · preview: `origination_preview_instalment`, `origination_preview_last`, `origination_preview_total_interest`. DEPENDS: server schedule preview.
**5 Components** - PageHeader, Input, Select, MoneyInput, AmountSummary, ReviewPanel, SidePanel, Alert, ErrorState, Button.
**6 States** - E blank, no prefill, no sample member · L preview computing, submit disabled · X field + summary + ref · P schedule ok, eligibility failed (reason list) · S eligibility stamp older than the principal field · R submitted → read-only with reference · N panel.
**7 Interaction** - schedule is generated server-side, never in the browser; eligibility runs before submit and blocks with a specific reason + link to arrears; Enter = submit; principal is re-parsed from text, no float.
**8 Failure** - self-approval impossible (maker ≠ checker server-side); 409 duplicate submission returns the existing reference; 403 panel.
**9 Copy** - `origination_title` "Pengajuan pinjaman"; `origination_action_submit` "Ajukan pinjaman"; `origination_ineligible` "Belum memenuhi syarat: [ALASAN]."; `origination_error_schedule` "Jadwal angsuran belum bisa dihitung."
**10 Accept** - member chosen by human key; no instalment figure computed client-side; ineligible submit is blocked with a named reason and a link; submitted application is read-only with a reference; total payable reconciles with the schedule.

### K-13 · Persetujuan pinjaman - `/app/loans/approvals`
**1 Decision** - do I approve someone else's application?
**2 Layout** - `ApprovalPanel`: queue table, selected detail below at <1100 px and beside at ≥1100 px (360 px). Reason: the decision needs the applicant's exposure, which is a different object from the queue row.
**3 Hierarchy** - focal: selected application's principal + applicant standing; secondary: queue; muted: purpose text.
**4 Content** - queue: `approvals_col_member` · `approvals_col_product` · `approvals_col_principal` money, foot total · `approvals_col_tenor` · `approvals_col_maker` (officer name) · `approvals_col_submitted` datetime+zone · `approvals_col_waiting` days. Detail: member status, existing outstanding, arrears, schedule summary, eligibility result at submit, collateral note.
**5 Components** - PageHeader, ApprovalPanel, DataTable, TotalsRow, ReviewPanel, ConfirmDialog (reject reason), Alert, EmptyState, ErrorState, Pagination.
**6 States** - E "Tidak ada yang menunggu" + link to K-11 · L queue skeleton · X banner + ref · P queue ok, detail failed · S "dimuat <time>" · R own submission → approve disabled with reason · N panel.
**7 Interaction** - queue is one tab stop, selection is a real row button; approve is one click with the reference shown before submit; reject moves focus to the required reason; decided rows leave the queue with a live-region notice.
**8 Failure** - another checker decided first → row disappears + "sudah diputuskan oleh [NAMA]" notice, no error tone; 403 panel; timeout → status check before retry.
**9 Copy** - `approvals_title` "Persetujuan pinjaman"; `approvals_action_approve` "Setujui"; `approvals_action_reject` "Tolak"; `approvals_empty_none` "Tidak ada pengajuan yang menunggu."; `approvals_self` "Anda yang mengajukan; persetujuan harus oleh orang lain."
**10 Accept** - approve on one's own submission is unreachable; reject cannot be sent without a reason; the principal total is visible-row only; a decided application never stays in the queue; no counts-as-KPI.

### K-14 · Berkas pinjaman - `/app/loans/[loanId]`
**1 Decision** - post this movement against this akad?
**2 Layout** - facts header, then sections in work order: Jadwal · Pembayaran · Pencairan · Restrukturisasi · Hapus buku · Pemulihan; action forms in `SidePanel`. Reason: the order is the loan's life, so a reader who arrives mid-life still reads downward.
**3 Hierarchy** - focal: outstanding + DPD; secondary: next due instalment; muted: rate basis and product version.
**4 Content** - `loan_detail_member` MemberRef · `loan_detail_ref` akad number · `loan_detail_product` · `loan_detail_status` · `loan_detail_principal` · `loan_detail_rate` (2dp, method named) · `loan_detail_tenor` · `loan_detail_disbursed_at` · `loan_detail_outstanding` money · `loan_detail_dpd` integer · schedule: `loan_detail_col_due`, `loan_detail_col_principal`, `loan_detail_col_interest`, `loan_detail_col_penalty`, `loan_detail_col_paid`, `loan_detail_col_outstanding`. DEPENDS: holder name (DEP-5), arrears/DPD read.
**5 Components** - PageHeader, MemberRef, PartyBadge, AmountSummary, DataTable, TotalsRow, SidePanel, MoneyInput, ReviewPanel, ConfirmDialog, IdempotentSubmit, Alert, ErrorState.
**6 States** - E new loan without schedule · L facts skeleton · X banner + ref · P facts ok, schedule failed · S per-panel stamp · R written off → read-only · N panel.
**7 Interaction** - payment shows allocation preview (penalty → interest → principal) before submit; form fields clear after success (FE-LOGIC-06); disburse destination chosen by account number with holder name; irreversible actions only (write-off) use `ConfirmDialog`.
**8 Failure** - double disburse refused by server + status check after timeout; stale schedule after another seat's payment → stamp + reload; 403 panel; unknown outcome banner blocks repeat.
**9 Copy** - `loan_detail_title` "Berkas pinjaman"; `loan_detail_action_pay` "Catat angsuran"; `loan_detail_action_disburse` "Cairkan"; `loan_detail_unknown` "Status pencairan belum diketahui. Jangan ulangi; periksa status."; `loan_detail_error_load`.
**10 Accept** - borrower identity visible on every action panel; no UUID on screen or in the confirm dialog; allocation sums to the payment; repeated submit with the same key cannot double-post; closed loan offers no write action.

### K-15 · Tunggakan - `/app/loans/arrears`
**1 Decision** - who do we contact today?
**2 Layout** - a fixed scope line above the table (business date + "dihitung <time>"), FilterBar, full-width table, print. Reason: a DPD list is only true for one business date, so that date is chrome, not a filter.
**3 Hierarchy** - focal: DPD + outstanding; secondary: member and phone (the contact action); muted: product and officer.
**4 Content** - `arrears_col_member` · `arrears_col_no` · `arrears_col_phone` · `arrears_col_loan` akad ref · `arrears_col_due_date` · `arrears_col_dpd` integer, default sort desc · `arrears_col_outstanding` money, foot total · `arrears_col_last_payment` date+amount · `arrears_col_officer`. DEPENDS: arrears read model with DPD + last payment (`/lending/reports/arrears` exists; fields to confirm).
**5 Components** - PageHeader, Toolbar, FilterBar, DataTable, TotalsRow, Pagination, EmptyState, ErrorState, LoadingState, Button (Cetak).
**6 States** - E "Tidak ada tunggakan" (a good outcome, stated as one) · L skeleton with date blank · X banner + retry · P total ok, rows failed · S stamp + reload after a payment · R - (screen is read-only) · N panel.
**7 Interaction** - DPD buckets are parameters (`P.arrears.bucket.*`, NEEDS-COMPLIANCE-REVIEW), shown as selects; row opens K-14; print carries business date, filter line, total row and page x/y; no contact log (non-goal).
**8 Failure** - a payment posted elsewhere leaves a stale row → timestamp + reload, never silent removal; 403 panel; print failure → browser print failure message with "cetak ulang", no re-computation.
**9 Copy** - `arrears_title` "Tunggakan"; `arrears_scope` "Per [TANGGAL BUKU], dihitung [WAKTU]"; `arrears_empty_none` "Tidak ada tunggakan pada tanggal ini."; `arrears_empty_filter` "Tidak ada tunggakan untuk filter ini."; `arrears_error_load`.
**10 Accept** - the business date is visible without opening a filter; totals equal visible rows and are labelled; filtered-empty ≠ no-arrears; print repeats the header per page; no contact-log affordance that does nothing.

### K-16 · Laporan - `/app/reports` and `/app/reports/[reportKey]`
**1 Decision** - is this period's pack complete and signed?
**2 Layout** - index = checklist table (§3); document = `ReportHeader` → control line → data table → `TotalsRow` → signature block. Reason: the pack question is "what is missing", answered by a list, not by eight cards.
**3 Hierarchy** - focal: the document's control verdict; secondary: the table; muted: source and generated-at.
**4 Content** - index: `reports_col_doc`, `reports_col_period`, `reports_col_source`, `reports_col_computed`, `reports_col_status`, `reports_col_action`. Document: header fields per §3; columns per document (member register: nomor, nama, status, cabang, gabung, keluar; savings arrears: anggota, periode, jatuh, bayar, sisa; loan exposure: akad, anggota, outstanding, DPD, bucket; cash recap: sesi, kasir, expected, counted, selisih; SHU: anggota, basis simpanan, basis jasa usaha, alokasi).
**5 Components** - PageHeader, DataTable, TotalsRow, ReportHeader, StatementLayout, CloseCertificate, FilterBar (period + branch), EmptyState, ErrorState, Button (Cetak).
**6 States** - E period without data: "Belum ada jurnal pada [PERIODE]" + no figures · L "Menghitung [DOKUMEN]…" with fixed height · X document error + ref + Ulangi · P header ok, table failed · S "Dihitung <time>" · R closed period, no recompute · N key not granted → document absent from the index.
**7 Interaction** - period and branch in the URL; a document that is not available is listed with "Belum tersedia" and no numbers (DEP-3); print is the only output; keyboard reaches the table as one tab stop.
**8 Failure** - print failure → retry print, figures unchanged; stale after a posting → recompute or reload, never silent; 403 → panel; open period prints with the watermark, never blocks printing.
**9 Copy** - `reports_title` "Laporan"; `reports_status_missing` "Belum tersedia"; `reports_status_open` "Periode belum ditutup"; `reports_empty_period` "Belum ada data untuk [PERIODE]."; `reports_error_doc` "Dokumen gagal dihitung."
**10 Accept** - every document shows period, branch, generated-at and source; a missing document shows no number; control lines are text, not badges; watermark appears whenever the period is open; the index contains no chart, card or KPI.

### K-04 · Neraca saldo - `/app/ledger`
**1 Decision** - does the trial balance balance?
**2 Layout** - period in the toolbar (default = session business date), category filter, table, verdict line directly above the table foot. Reason: the verdict is the answer, so it sits with the numbers it judges.
**3 Hierarchy** - focal: the verdict + saldo akhir column; secondary: debet/kredit; muted: category.
**4 Content** - `ledger_period` · `ledger_col_code` · `ledger_col_name` · `ledger_col_category` · `ledger_col_opening` money · `ledger_col_debit` money, foot · `ledger_col_credit` money, foot · `ledger_col_closing` money, foot. Scope totals (all lines) drive the verdict; footer totals cover visible rows (FE-LOGIC-02).
**5 Components** - PageHeader, Toolbar, FilterBar, DataTable, TotalsRow, AmountSummary (verdict), EmptyState, ErrorState, Button (Cetak).
**6 States** - E no period selected: "Pilih periode" (never an implicit current period) · L skeleton, totals blank · X banner + retry (every load wrapped, FE-LOGIC-03) · P totals ok, lines failed · S period stamp · R closed period, no edit · N panel.
**7 Interaction** - category filter never changes the verdict; print with period, branch, generated-at; zoom 200 % keeps a horizontal scroll region, columns never collapse to cards (DESIGN §10).
**8 Failure** - period closed → read-only strip; stale period after EOM → stamp + reload; 403 panel; no recalculation on the client.
**9 Copy** - `ledger_title` "Neraca saldo"; `ledger_balanced` "Seimbang"; `ledger_unbalanced` "Tidak seimbang: selisih [NOMINAL]"; `ledger_empty_period` "Belum ada jurnal pada periode ini."; `ledger_error_load`.
**10 Accept** - verdict computed on all lines; two totals always labelled; no period derived from the browser clock; numbers selectable and right-aligned 2dp; print carries identity and time.

### K-05 · Jurnal & COA - `/app/ledger/admin`
**1 Decision** - reverse which entry, with what reason?
**2 Layout** - two stacked sections (Jurnal with date/source filters, COA), period close moved to K-03. Reason: one screen, two jobs that share a permission; splitting them would add a fourth nav level.
**3 Hierarchy** - focal: the journal row to reverse; secondary: COA list; muted: source and reversal marker.
**4 Content** - `ledger_admin_col_date` · `ledger_admin_col_source` · `ledger_admin_col_ref` copyable · `ledger_admin_col_desc` · `ledger_admin_col_debit`/`credit` money, foot · `ledger_admin_col_reversed` (ya/tidak) · COA: `coa_col_code`, `coa_col_name`, `coa_col_category`, `coa_col_normal` (D/K).
**5 Components** - PageHeader, FilterBar (date range + source), DataTable, TotalsRow, ConfirmDialog (reversal, reason), Input, Select, Alert, ErrorState.
**6 States** - E "Belum ada jurnal" for the range · L section skeletons · X section-level error with its own retry · P one section failed · S journal stamp · R closed period blocks reversal · N section hidden without grant.
**7 Interaction** - reversal requires reason and shows the entry's facts before confirm; a reversed row stays visible and links to its reversal; COA creation validates code uniqueness inline.
**8 Failure** - 403 panel; reversal timeout → status check before retry; period closed between load and submit → server reason rendered in the panel, form kept.
**9 Copy** - `ledger_admin_title` "Jurnal & COA"; `ledger_admin_action_reverse` "Balik jurnal"; `ledger_admin_empty` "Belum ada jurnal pada rentang ini."; `ledger_admin_error` "Jurnal gagal dimuat."
**10 Accept** - no delete or edit path; reversal shows reason + actor; closed period refuses with a named reason; section failure does not blank the other section; totals cover visible rows only.

### K-17 · Audit - `/app/audit`
**1 Decision** - who did this, and when?
**2 Layout** - FilterBar, table, expandable row detail (before → after), no panel. Reason: the question is a search, and one row must not hide the others while it is read.
**3 Hierarchy** - focal: waktu + pelaku; secondary: aksi; muted: objek and reference.
**4 Content** - `audit_col_time` datetime **with zone label** · `audit_col_actor` name + role [DEPENDS: actor display join] · `audit_col_action` human label, unknown codes verbatim · `audit_col_object` human ref (member number, akad, kunci parameter) · `audit_col_branch` · `audit_col_ref` copyable. DEPENDS: filterable, cursor-paged audit query (API-7: no cursor today; otherwise list is capped).
**5 Components** - PageHeader, FilterBar (pelaku, aksi, objek, tanggal), DataTable, Pagination, EmptyState, ErrorState, Alert, Button (Salin rujukan).
**6 States** - E "Belum ada aktivitas untuk filter ini" (never "no data" globally) · L skeleton · X banner + retry · P count ok, rows failed · S stamp · R - read-only by nature · N panel.
**7 Interaction** - date range defaults to today and is capped by a parameter; deep link `?object=[ref]` from K-08/K-14/K-19; Enter applies; expand is a button, not a hover.
**8 Failure** - 403 panel with the permission name; an expired cursor restarts at the newest row with a notice; no write affordance exists.
**9 Copy** - `audit_title` "Audit"; `audit_empty` "Belum ada aktivitas pada rentang ini."; `audit_action_show_detail` "Lihat rincian"; `audit_error_load` "Riwayat aktivitas gagal dimuat."
**10 Accept** - actor shown by name, never a raw id; time carries a zone; unknown action codes print verbatim; deep link filters one object; the screen has zero action buttons.

### K-18 · Pengguna - `/app/users`
**1 Decision** - does this person get access, and to what?
**2 Layout** - list + `SidePanel` for role/branch editing. Reason: role and branch are attributes of the selected row, and a modal would hide the list the admin is comparing against.
**3 Hierarchy** - focal: name + role + branch; secondary: status; muted: last login.
**4 Content** - `users_col_name` · `users_col_username` · `users_col_role` · `users_col_branch` (name via `GET /branches`, never typed - FE-EFF-14) · `users_col_status` (aktif/nonaktif/terkunci) · `users_col_mfa` (belum/aktif; never a claim of enforcement, R-19) · `users_col_last_login`. DEPENDS: create/reset [DEP-4].
**5 Components** - PageHeader, DataTable, SidePanel, Select, Input, ConfirmDialog (disable/reset), Alert, EmptyState, ErrorState, Pagination.
**6 States** - E "Belum ada pengguna" + Buat pengguna (absent until DEP-4 lands) · L skeleton · X banner + retry · P list ok, roles failed · S stamp + reload · R own row: no disable, no self-lockout · N panel.
**7 Interaction** - temp password shown once, never emailed; reset revokes sessions; disable, never delete; a user cannot remove their own last admin role.
**8 Failure** - 409 username inline; reset timeout → reload list before retry; self-action blocked with reason; 403 panel (BE-SEC-03 note: revoke privilege-bounded server-side).
**9 Copy** - `users_title` "Pengguna"; `users_action_create` "Buat pengguna"; `users_temp_password_once` "Sandi sementara hanya tampil sekali. Serahkan langsung."; `users_empty` "Belum ada pengguna."; `users_error_load`.
**10 Accept** - branch chosen from a list; no UUID typed or shown; own row cannot lock itself out; temp password never retrievable twice; status actions match state.

### K-19 · Parameter - `/app/params`
**1 Decision** - what value does the business run on?
**2 Layout** - grouped table by key group, pending rows inline with their active row. Reason: a proposed value only means something next to the value it replaces.
**3 Hierarchy** - focal: current value + type; secondary: pending value and its author; muted: audit tail.
**4 Content** - `params_col_group` · `params_col_key` · `params_col_type` (uang/persen/bulat/benar-salah/pilihan/teks) · `params_col_unit` · `params_col_value` rendered per type (money 2dp, rate 2dp) · `params_col_effective` · `params_col_status` (aktif/menunggu/belum ada) · `params_col_changed` actor + time. All defined keys appear, including those without an active value (FE-EFF-13).
**5 Components** - PageHeader, FilterBar, DataTable, MoneyInput, Input, Select, Checkbox, ApprovalPanel, Alert, EmptyState, ErrorState.
**6 States** - E no value for a key → "Belum ditetapkan" + Ajukan (never an empty cell) · L skeleton · X banner + retry · P keys ok, audit failed · S stamp · R pending value locks a second submission · N panel.
**7 Interaction** - input is typed per key; money through `MoneyInput`; numeric params are serialised from the typed string, never through `Number()` (FE-LOGIC-12); reason required; self-approval disabled with reason.
**8 Failure** - 403 panel; approval timeout → status check; a parameter carrying a regulatory number shows "Sumber: belum ditinjau kepatuhan" (NEEDS-COMPLIANCE-REVIEW); no key creation or deletion from the UI.
**9 Copy** - `params_title` "Parameter"; `params_action_submit` "Ajukan perubahan"; `params_empty_value` "Belum ditetapkan"; `params_review_note` "Sumber: belum ditinjau kepatuhan."; `params_error_load`.
**10 Accept** - keys without a value are visible and submittable; exponent/hex input rejected; rate and money formats are per type; changed value requires maker ≠ checker; no key can be deleted.

### K-20 · Produk - `/app/products`
**1 Decision** - which products may exist?
**2 Layout** - two sections (simpanan, pinjaman) with versions nested under each product. Reason: the product is stable and the version is what changes, so the hierarchy mirrors what is approved.
**3 Hierarchy** - focal: active version + status; secondary: draft versions; muted: rates and limits.
**4 Content** - `products_col_code` · `products_col_name` · `products_col_kind` (simpanan/pinjaman; no deposito - R-16) · `products_col_version` · `products_col_status` (draf/menunggu/aktif/ditolak) · `products_col_effective` · `products_col_approved_by`. Version fields: rate, method (flat/annuity/menurun), tenor limits, minimum balance, fees - all parameter-backed.
**5 Components** - PageHeader, DataTable, ApprovalPanel, Input, MoneyInput, Select, ConfirmDialog (approve/reject), Alert, EmptyState, ErrorState.
**6 States** - E "Belum ada produk" + Buat produk (absent until the create endpoint is wired) · L skeleton · X banner + retry · P list ok, versions failed · S stamp · R approved version locked · N panel.
**7 Interaction** - approved version is immutable; a change is a new version; reject requires reason; a product with no consuming screen cannot be published (TIME_DEPOSIT removal, FE-EFF-12).
**8 Failure** - 403 panel; approve timeout → status check; a version approved while open elsewhere → stale banner + reload; 409 code conflict inline.
**9 Copy** - `products_title` "Produk"; `products_action_new` "Buat produk"; `products_empty` "Belum ada produk."; `products_locked` "Versi yang disetujui tidak bisa diubah. Buat versi baru."; `products_error_load`.
**10 Accept** - every product listed is consumable elsewhere; approved versions cannot be edited; reject cannot send without reason; version history is readable; no product type the app cannot use.

### K-21 · Ganti sandi - `/app/password`
**1 Decision** - did I type it correctly?
**2 Layout** - single 42rem form, no panel. Reason: one job, two fields, nothing to compare.
**3 Hierarchy** - focal: the two password fields; secondary: policy text; muted: session consequence note.
**4 Content** - `password_current` · `password_new` · `password_confirm` · `password_reveal` toggle · policy list from `GET /auth/password-policy` (if it fails: "Kebijakan sandi tidak dapat dimuat", never a static guess - FE-ISO-11).
**5 Components** - PageHeader, Input (type=password + reveal), Alert, ErrorState, Button.
**6 States** - E - (form only) · L policy loading, submit disabled · X field + summary · P - · S - · R - · N panel.
**7 Interaction** - Enter submits; confirm must match before POST; on success all other sessions are revoked and the operator is asked to sign in again, stated before submitting; no autocomplete of the new value.
**8 Failure** - wrong current password inline; policy load failure blocks with the reason; 403 panel.
**9 Copy** - `password_title` "Ganti sandi"; `password_action_save` "Simpan sandi"; `password_mismatch` "Ulangi sandi baru tidak sama."; `password_sessions_ended` "Setelah sandi berubah, sesi lain berakhir dan Anda masuk ulang."; `password_error_save`.
**10 Accept** - the two entry fields must match before submit; a typo cannot lock the operator out; policy is read, never assumed; the session consequence is stated before the action.

## 6 · Deviations and dependency register

| # | Deviation / dependency | Reason |
|---|---|---|
| 1 | K-16 has **9** report keys, 01 §3 says 8 | savings arrears and loan arrears have different readers and control lines |
| 2 | K-16 adds `/app/reports` (index) beside `/app/reports/[reportKey]` | a nav group needs a landing that answers "what is missing" |
| 3 | `DEP-1` coop module | K-06-K-10, K-16 member register + SHU |
| 4 | `DEP-2` KYC document storage | K-07 records references only; no upload |
| 5 | `DEP-3` report queries | BS/IS/equity/cash recap/certificate/SHU absent; documents render "Belum tersedia" |
| 6 | `DEP-4` user create/reset/MFA | K-18 actions absent until endpoints exist |
| 7 | `DEP-5` holder name on account read model | K-08, K-14 (and K-01/K-24 outside this file) |
| 8 | `DEP-6` realtime topics beyond `param.changed` | stamp + reload is the honest fallback on every list here |
| 9 | Audit cursor + filters (API-7) | K-17 cannot page past the first window today |
| 10 | Server schedule preview | K-12 preview is server-computed; no client amortisation |
| 11 | Actor display names in audit/vault | every "pelaku" field is a UUID today (FE-EFF-09/11) |
| 12 | Consent record + notice version | K-07 consent has no storage today (O4) |

Not specified here on purpose: the first-run checklist (branch → product → period → user), bulk
import, CSV export, contact log and the complaint register. Each needs an owner decision, not a
screen sketch; they are listed in `docs/OPEN_ITEMS.md` when this file is ratified.
