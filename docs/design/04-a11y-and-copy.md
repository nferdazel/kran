# 04: Accessibility contract and operator copy (KRAN)

Status: proposed, Wave 3 (P-03), 5 Nov 2026. Read-only on source; nothing was run.
Companions: `01-ia-flows.md` (screens, states), `02-design-system.md` (components, tokens),
`DESIGN.md` §7-§10 and §13 (binding). Every rule below carries a one-line reason (R-31).
Where this file and `02-design-system.md` disagree, the conflict is listed in §11 and not silently resolved.

**What the audits already prove.** The axe gate is real (moderate+, 12 specs) but `/app/params` has no
screen-level assertion (FE-ISO-14). 43 raw inputs against `Field` on one screen means each screen
re-derives error wiring, and `ledger/admin` sets `aria-invalid` with no `aria-describedby` (FE-PRAC-06).
Three hand-rolled focus traps exist (FE-PRAC-05); eleven field errors carry `role="alert"`; loading is a
`<p role="status">` with no `aria-busy`; `DataTable` hard-codes `id-ID` (FE-ISO-04); business dates come
from UTC (FE-ISO-05/06); i18ncheck never looks for hardcoded text (FE-PRAC-13); copy leaks `party`,
`UUID`, `vault`. The work is contracts that are cheap to assert, not a longer checklist.

## 1. Accessibility contract per component

Rules for every row: native element first (it already has the role, keyboard and announcement), and
**no component reachable twice in the tab order**. Forbidden ARIA is a hard review fail, not a preference.

| Component | Role and accessible name | Keyboard | Focus | Required ARIA | Forbidden | Announce / error |
|---|---|---|---|---|---|---|
| Button | native `<button>`; name = visible text; icon-only requires `aria-label` and is limited to close/copy | Enter, Space native | ring per §2 | `type`; `aria-busy` while posting; `disabled` while posting | `aria-disabled` alone; `role="button"` on `div`; `title` as name | none; the result is announced by the caller |
| Input | `<input>` + `<label for>`; name = label text, never placeholder | native | ring | `id`; `aria-describedby` = hint id then error id; `aria-invalid="true"` only when invalid | placeholder-only label; `aria-errormessage` (uneven AT support); `role="textbox"` | error text via `aria-describedby`; summary announces once |
| Select | native `<select>` + label | native arrows | ring | `aria-describedby` for hint/error | `role="combobox"` on a native select; `aria-expanded` | same as Input |
| MoneyInput | text input, `inputmode="decimal"`; label carries currency once ("Nominal (IDR)") | digits, one separator, Enter submits | ring | `aria-describedby`; `aria-invalid` | live preview as live region; thousand separators in the editable value | parse error on submit only; no per-keystroke announcement |
| DataTable | `role="region"` + `tabindex="0"` + `aria-label` = caption; inner `<table>`; `th scope` | one stop on region; Tab → sort button → active row control; arrows scroll | ring on region, then on control | `<caption>`; `aria-sort` on exactly one `th`; `aria-busy` while reloading with old rows visible | focusable `<tr>`; `role="grid"` (no cell editing); `aria-rowindex` | sort change: polite "Diurutkan menurut {column}, {asc/desc}" |
| FilterBar | `role="search"` + `aria-label`; each control labelled | Enter applies; Tab in visual order | ring | result count in a debounced `role="status"` | live region on the search input; `aria-busy` on the form | count announced 500 ms after typing stops |
| Pagination | `<nav aria-label="Halaman">`; text buttons "Sebelumnya"/"Berikutnya" | native | ring | `aria-current="page"` on the active page; readable "1-50 dari 1.204" in the nav label | icon-only arrows; `aria-label="<"` | page change: polite "Halaman 2, 51-100 dari 1.204" |
| Dialog / ConfirmDialog | native `<dialog>` + `showModal()`; name = `<h2>` via `aria-labelledby` | Esc closes unless busy; focus cycles | auto-trap; restore to trigger, else `#main`; initial focus Cancel for destructive | `aria-labelledby`; `aria-describedby` = consequence sentence; `<h2>` inside | `aria-modal` on anything but the native dialog; `role="dialog"` on a `div`; stacked modal | title is announced on open; errors inside are `role="alert"` |
| ApprovalPanel | `<section aria-labelledby>`; queue is a DataTable | queue = one roving stop; Enter selects; "Tolak" moves focus to reason | detail heading `tabindex="-1"` on selection | `aria-describedby` on disabled Approve explaining self-approval; `role="status"` on the result | hidden Approve with no reason; `title` for the reason; `aria-live` on the queue | decision result polite; failure assertive |
| ReviewPanel | `<section aria-labelledby>`; facts as `<dl>`; amount as labelled value | Enter submits, Esc = back only when idle | heading `tabindex="-1"` on open; focus returns to form on back | `aria-busy` while posting; reference copy button labelled "Salin rujukan" | amount buried in prose; UUID anywhere; per-second announcements | submit result: polite; failure: assertive, reference preserved |
| SessionLock | modal `dialog`; name = "Sesi berakhir" | Esc does nothing; re-auth field is first stop | moves in at warning; returns to prior control after extend | `aria-labelledby`/`describedby`; `role="status"` at warning, `role="alert"` at expiry | per-second live timer; dismissing without re-auth | exactly two announcements per lock (60 s, expired) |
| Alert | `role="alert"` for failure, `role="status"` otherwise; title is `<p>` | none (not a control) | not focusable | `role`, `aria-live` implied by the role | `<h2>` as title; two live regions in one alert | one message per alert; reference + copy button |
| Toast | fixed live region, not a dialog | close button reachable by Tab | focus stays where it was | `role="status"` success, `role="alert"` error; close labelled "Tutup pemberitahuan" | auto-dismiss on error; covering save/print; a second toast stack | never used to confirm money; money uses ReviewPanel result |
| EmptyState | static content, no role | optional action is a real link/button | none | none required | `role="status"`; `aria-live`; announcing on every render | silent; `kind` (no-data / no-match / denied) changes copy only |
| ErrorState | block replacing the region; `role="alert"` after an action, `role="status"` on load | Retry is the only control | focus stays unless the user submitted | heading + body + reference + retry | toast form; `aria-live` duplicated with the alert role | announced once; reference copyable |
| StatusBadge | static text + shape + colour; the text is the meaning | none | none | none | `role="status"` (re-renders announce every poll); colour-only variants; glyph stand-ins | silent; change is announced by the owning panel |
| MemberRef | text or link; name = "{name}, anggota {memberNo}" | link: Enter | ring if link | `aria-label` only when the visible text omits the number | UUID, `partyId`, "CIF" in the name | none |
| AccountRef | text or link; name = "{accountNo}, {product}, {holder}" (holder masked per policy) | link: Enter | ring if link | `aria-label` only when the visible text is ambiguous | full account number when policy masks it; UUID | none |
| ReportHeader | `<h1>` document title, `<h2>` for institution/period | none | none | heading order h1 → h2; timestamp + zone as text | heading inside the table; zone implied | none |
| CloseCertificate | facts table + signature block | none (print) | none | `<th scope="row">` on fact labels | status by colour; totals orphaned from the block | none |

Reason: the audit failures are wiring, not components, so the contract must name the attribute, the
focus target and the announcement; otherwise each screen re-decides.

## 2. Keyboard and focus model

- Global order: skip link → header (no controls before content except the account menu) → nav →
  `main` → footer/settings, so a teller pressing Tab lands in the work area, not in a theme switch
  (DESIGN §10). The skip link is the first focusable element, visible on focus, targeting
  `<main id="main" tabindex="-1">`; without it a grouped sidebar makes keyboard-only use impractical.
- Theme and language controls live after `main` in DOM order and are never tab stops before content.
  Reason: they are set once per shift, not per transaction.
- Focus ring: `outline: 2px solid var(--color-focus-ring); outline-offset: 2px; border-radius: 4px`.
  Never `outline: none`, never `box-shadow` as the only ring (invisible in forced-colors). Reason: the
  ring must survive Windows high-contrast and be visible on `surface-raised`, `selected`, `row-hover`,
  the four status tints and a filled primary button (2 px of surface shows through the offset).
- Focus must not be obscured (2.4.11): sticky header 34 px + toolbar 48 px → `scroll-margin-block:
  96px` on every focusable inside `main`, `scroll-padding-top: 96px` on `main`. Reason: a toast or the
  sticky toolbar covering the focused field is the most common 2.4.11 failure in dense tables.
- Roving tabindex, one implementation for every composite: DataTable row controls, ApprovalPanel
  queue, command-palette results. Exactly one item has `tabindex="0"`; the rest `-1`; Up/Down move DOM
  focus, Home/End jump, Enter/Space activate, Tab leaves the widget. Reason: 50 rows × one action
  button is 50 tab stops, which the teller pays on every close-cash reconciliation.
- DataTable entry: Tab focuses the labelled region (ring around the region), then the sort button, then
  the active row control. Reason: a screen-reader user needs the caption and direction before the rows.
- Command palette: `<dialog>` + input with `aria-activedescendant` over `role="listbox"` results; focus
  stays in the input. Reason: DESIGN §10 names the pattern and the palette currently moves DOM focus
  instead (FE-ISO-15); one story, not two.
- Tab-like panels inside a record (K-08) are links with `aria-current="page"`, each its own tab stop.
  Reason: they change what is read, not a widget state; `role="tablist"` would add arrow-key rules for
  no gain.
- Tab order equals DOM order everywhere; never `tabindex > 0`, because a positive tabindex reorders
  the page for every later element and cannot be repaired locally. No focus trap except modal dialog and
  the session lock; trapping a non-modal region strands keyboard users with no Escape route.
- Initial focus: dialogs focus Cancel (destructive) or the first field (reason required); pages focus
  nothing; search inputs are never autofocused. Reason: autofocus on load skips the page title and
  steals typing from a teller already on the keyboard.
- Validation failure: focus the first invalid field, with the summary announced by `role="alert"` at
  the top of the form; the summary is not focused. Reason: focusing a list of five errors makes the
  operator read them all before reaching the field they can fix.
- After a dialog: focus returns to the trigger; if the trigger no longer exists (row removed, record
  closed), focus goes to `#main`. Reason: focus falling to `<body>` loses the keyboard user's place.
- After a row action (inline panel opens): focus the panel heading with `tabindex="-1"`; when the panel
  closes, focus the row's action button, or the table region if the row is gone. Reason: a review panel
  that appears below the fold without a focus move is invisible to a keyboard user.
- `prefers-reduced-motion`: all transitions 0 ms (1 ms so `transitionend` still fires), final state
  readable; motion is never the carrier of a state change (DESIGN §8).

## 3. Live regions and announcements

- One polite region per screen, mounted at the end of `main`; one toast region in the shell; assertive
  is reserved for transaction failure, session expiry and permission revoked mid-flow. Reason: three
  assertive regions on a cash screen interrupt each other and the operator hears fragments.
- Announced: "Tersimpan. Rujukan {ref}." (polite); the review result line including
  "Saldo setelah {amount}" (polite); form summary on failed submit (assertive, once); filter result
  count (polite, debounced 500 ms); sort change (polite); copy confirmation "Rujukan disalin" (polite);
  session warning at 60 s (polite, once) and expiry (assertive); permission change (assertive).
- Not announced: keystrokes, the money preview, each table cell after a refresh, hover, focus movement,
  StatusBadge re-renders, the clock, every poll tick. Reason: the product already forbids per-keystroke
  announcements (DESIGN §8); a poll that re-announces a table makes the screen unusable with a reader.
- Rate limit: identical text within 10 s is not re-announced; a replaced message clears after 7 s;
  maximum one announcement per second; nothing is announced while `aria-busy` is true on the region.
  Reason: retries fire in bursts, and a repeated "Gagal memuat" buries the next real message.
- Errors are announced exactly once: the field error is read through `aria-describedby` when focus
  arrives, so it must not also live in a `role="alert"`. Reason: eleven per-field alerts on
  `ledger/admin` today read every error twice.
- Loading: the region gets `aria-busy="true"` and a `role="status"` label with a fixed min-height.
  Reason: a layout shift while a reader is mid-sentence moves the virtual cursor.
- `role="status"` is never put on a component that re-renders on a poll (StatusBadge, table rows).
  Reason: it turns a silent refresh into speech.
- A message that removes itself (toast) must be dismissible and must not be the only record of a
  failure. Reason: a disappearing error is the failure class the audits call out (FE-LOGIC-19).

## 4. WCAG 2.2 AA checklist mapped to screens

| SC | Where it bites | Rule |
|---|---|---|
| 2.4.11 Focus Not Obscured (Min) | all screens with sticky header/toolbar; teller, K-01 | `scroll-margin-block: 96px`; toasts never overlap the focused control or the save/print buttons |
| 2.5.7 Dragging Movements | journal and report column widths; no drag reorder anywhere | no drag-only action; column width has a keyboard/menu alternative, or columns are fixed |
| 2.5.8 Target Size (Min) 24×24 | row actions in 34 px rows; pagination; dialog close | 24 px minimum hit area with ≥8 px separation; never a 16 px icon button |
| 3.3.7 Redundant Entry | K-01 review, K-07 onboarding step 2, K-12 application | member, account, amount and reason carry through steps; nothing already given is retyped |
| 1.4.3 Contrast (text) | status on tint, disabled text, money in dark mode | 4.5:1 for text including disabled (product rule, stricter than WCAG); money uses `text`, never `text-muted` |
| 1.4.11 Non-text contrast | control borders, focus ring, checkbox, row selection bar | 3:1 against `surface-raised`, `selected`, `row-hover`, all four tints, `primary` (matrix rows in 02 §3) |
| 1.3.1 Info and relationships | DataTable, forms, ReviewPanel facts | `<caption>`, `th scope`, `<fieldset>/<legend>`, `<dl>` for facts; headings never skip a level |
| 4.1.3 Status messages | save, balance change, filter count, session lock | announced through the regions in §3, never by moving focus |
| 2.2.1 Timing adjustable | SessionLock (15-min idle, R-21) | warn at 60 s with an extend action that needs no typing; draft and idempotency key survive; extend is available for at least 20 s before expiry |
| 2.4.7 / 2.4.3 Focus visible, order | every screen | ring per §2; DOM order = visual order; no `tabindex > 0` |
| 1.4.4 / 1.4.10 Resize and reflow | 200 % zoom on K-01, K-04, K-15, K-24 | **no horizontal page scroll** at 200 %; the only scroller is the labelled table region; ledger/arrears/schedule/report tables are never card-ified and no column is hidden |
| 3.2.1 On focus | filter bars, autocomplete | focus never submits, navigates or loads a different record |
| 3.3.1 / 3.3.3 Error identification and suggestion | all money forms | each message names the rule and the fix, not just "tidak valid" |
| 1.4.1 Use of colour | status, debit/credit, selected row | text + shape + position; "D"/"K"; "(masuk)"/"(keluar)"; `aria-selected` + 2 px inset bar |
| 2.4.1 Bypass blocks | shell | skip link, landmarks (`header`, `nav`, `main`, `aside`), one `h1` per page |
| 3.1.1 / 3.1.2 Language | shell, login | `<html lang>` set to `id-ID` / `en-US` in one place and updated on switch; no mixed `id`/`id-ID` |

Reason for pinning the two "new" criteria (2.4.11, 2.5.8): both are 2.2 additions that a 2.1-era gate
does not catch, and both regress silently in a 34 px table.

## 5. Terminology glossary (id + en)

One word per thing, used in UI, keys and print. "Must not" is review-enforced.

| Concept | Indonesian UI | English UI | Key | Must not be called | Guidance |
|---|---|---|---|---|---|
| member | Anggota | Member | `member_*` | party, nasabah, customer, CIF | the person, not their account |
| member number | Nomor anggota | Member number | `member_no` | ID anggota, partyId, CIF | stable, printed, searchable; never a UUID |
| principal savings | Simpanan pokok | Principal savings | `savings_principal` | pokok (alone), modal awal | paid once at joining, not withdrawable |
| mandatory savings | Simpanan wajib | Mandatory savings | `savings_mandatory` | wajib (alone) | per-period obligation, per member |
| voluntary savings | Simpanan sukarela | Voluntary savings | `savings_voluntary` | tabungan (if a product is named Tabungan, keep that name), deposito | withdrawable balance |
| deposit (cash in) | Setor (masuk) | Deposit (in) | `cash_deposit` | Debit, kredit, top up | teller language, with "+" |
| withdrawal | Tarik (keluar) | Withdrawal (out) | `cash_withdrawal` | Debit, tarik tunai | teller language, with "−" |
| internal transfer | Pemindahbukuan (PB) | Transfer | `transfer` | transfer bank, "masukkan ID rekening" | between two KRAN accounts |
| instalment | Angsuran | Instalment | `loan_instalment` | cicilan, payment (generic) | one scheduled loan payment |
| arrears | Tunggakan | Arrears | `loan_arrears` | NPL, overdue (as a noun) | amount past due; the list is a work queue |
| collectibility | Kolektibilitas | Collectibility | `loan_collectibility` | grade, bucket, score | `NEEDS-COMPLIANCE-REVIEW`: the category set is regulatory, not a design choice |
| allowance | Penyisihan | Allowance | `loan_allowance` | provision, cadangan | impairment allowance on the loan book |
| write-off | Hapus buku | Write-off | `loan_write_off` | hapus, delete | a ledger event with a reason, never a delete |
| SHU | SHU (Sisa Hasil Usaha) | SHU (surplus) | `shu_*` | profit, dividen, bonus | expand once per document; never translate the acronym away |
| RAT | RAT (Rapat Anggota Tahunan) | RAT (annual members meeting) | `rat_*` | AGM, rapat | expand on first use per document |
| close cash | Tutup kas | Close cash | `cash_close` | finalisasi sesi, end session, logout | counts physical cash; prints a receipt |
| close books | Tutup buku | Close books | `books_close` | EOD, dayclose, batch, run | one console for day/month/year |
| period | Periode | Period | `period` | batch, cycle, cutoff | accounting period, shown with its business date |
| branch | Cabang | Branch | `branch` | branchId, unit, kantor (alone) | human name + code, never an ID |
| cashier | Kasir | Teller | `cashier` | teller (in id), operator | the person at the cash station |
| board | Pengurus | Board | `board` | admin, manajemen, owner | governance role; read/approve, not data entry |
| supervisory board | Pengawas | Supervisory board | `supervisor` | auditor, pengurus | oversight, read-only |
| branch vault | Kas besar | Branch vault | `vault_balance` | vault, safe, treasury | the branch's cash position |
| loan agreement | Akad | Loan agreement | `loan_contract` | kontrak, fasilitas | the object every loan screen hangs from |
| reference | Rujukan | Reference | `reference` | trace ID, request ID, UUID | the one number the operator quotes to support |

Reason: the audits found `party`, `UUID`, `vault`, "ID rekening" and "finalisasi" in shipped copy; a
single vocabulary is the only way a grep can enforce the ban.

## 6. Error message catalogue

Shape (no exception): **what happened** + **what to do** + **reference when one exists**; one or two
sentences, ≤160 characters, no apology, no "sistem", no internal noun, no bare code. An operator under
time pressure acts on the second clause, so without it the message is a dead end.

| # | Class (audit) | Indonesian copy | Key | Note |
|---|---|---|---|---|
| 1 | Insufficient balance (FE-LOGIC flow 2) | Saldo tidak cukup untuk penarikan ini. Transaksi tidak disimpan. Periksa saldo, lalu ubah nominal. | `teller_error_insufficient_funds` | exists; keep |
| 2 | Closed period | Periode akuntansi sudah ditutup. Transaksi tidak disimpan. Minta admin membuka periode berjalan. | `teller_error_period_closed` | replaces "Hubungi admin" with a named action |
| 3 | No open session | Kas belum dibuka. Buka kas dulu, lalu ulangi transaksi ini. | `teller_error_no_open_session` | field-level, not a banner |
| 4 | Duplicate submission (409 same key) | Transaksi ini sudah tersimpan dengan rujukan {ref}. Jangan kirim ulang; periksa mutasi rekening. | `teller_error_already_posted` | new; the current screen cannot explain a 409 |
| 5 | Stale decision (another checker acted) | Pengajuan ini sudah diputuskan orang lain. Muat ulang daftar untuk melihat hasilnya. | `vault_error_not_pending` | replaces "sudah diputuskan" without a next step |
| 6 | Session expired mid-form | Sesi berakhir karena tidak ada aktivitas. Masuk lagi; isian dan nomor rujukan Anda masih tersimpan. | `session_expired_signin` | new; R-21 depends on this sentence being true |
| 7 | Permission denied (action) | Akun Anda tidak punya izin untuk tindakan ini. Minta admin menambah izin {permission}, lalu coba lagi. | `error_forbidden` | permission is a label, not a code |
| 8 | Unknown state after timeout | Status transaksi belum pasti. Jangan ulangi dengan nominal berbeda. Simpan rujukan {ref}, lalu periksa mutasi. | `teller_error_unknown_state` | exists; the best sentence in the product, keep |
| 9 | Money format | Nominal hanya boleh angka dengan satu koma desimal. Contoh: 150000 atau 150000,50. | `teller_error_amount_format` | example beats a rule name |
| 10 | Money precision | Nominal maksimal dua angka di belakang koma. | `teller_error_amount_precision` | exists |
| 11 | Money zero | Nominal harus lebih dari 0,00. | `teller_error_amount_zero` | exists; 2 decimals per D-136 |
| 12 | Duplicate member (409) | Anggota dengan NIK ini sudah terdaftar: {name}, nomor {memberNo}. Buka anggota itu, atau simpan sebagai orang berbeda dengan alasan. | `members_error_duplicate` | new; a link, not a bare conflict |
| 13 | Self-approval (SoD) | Pengajuan ini tidak bisa Anda setujui sendiri. Minta checker lain memutuskan. | `common_error_self_approval` | one key for vault, params, products |
| 14 | Account not found in lookup | Rekening tidak ditemukan. Cari dengan nomor rekening atau nomor anggota, lalu pilih dari daftar. | `teller_error_account_not_found` | replaces "ID rekening tidak sah" |
| 15 | Branch mismatch | Rekening ini di luar cabang Anda. Transaksi tidak disimpan. Pilih rekening cabang {branch}. | `teller_error_branch_not_allowed` | names the branch |
| 16 | KYC storage inactive (501) | Penyimpanan dokumen belum aktif. Simpan data anggota tanpa dokumen, lalu unggah dokumen setelah admin mengaktifkannya. | `members_error_kyc_storage_inactive` | no server noun |
| 17 | Write-off not eligible | Hapus buku hanya untuk pinjaman yang sudah macet. Periksa kolektibilitas akad ini. | `loans_error_not_loss` | removes the internal category token |
| 18 | Amount above outstanding | Nominal melebihi sisa kewajiban. Sisa saat ini {amount}; ubah nominal atau periksa jadwal angsuran. | `loans_error_amount_exceeds_outstanding` | states the number |
| 19 | Server failure with reference | Permintaan gagal diproses. Coba lagi; kalau tetap gagal, kirim rujukan {ref} ke admin. | `error_internal_error` | reference is always copyable |
| 20 | Lockout with window | Akun terkunci sementara karena percobaan masuk berulang. Coba lagi dalam {minutes} menit, atau minta admin membuka kunci. | `login_error_locked` | FE-ISO-12: the parameter value is known |

Reason: the audit shows messages already name the rule; the missing half is the fix and the reference,
and one shape is cheaper to review than twenty individual judgements.

## 7. Empty, loading, error copy per screen

Keys: `<screen>_empty_<kind>`, `<screen>_loading`, `<screen>_error`, `<screen>_locked`, `<screen>_denied`.
Three empties are never one string: "Belum ada data" under an active filter is a false statement about
the cooperative.

| K | First run (none yet) | Filtered empty | Loading | Failure / partial | Locked / read-only | No permission |
|---|---|---|---|---|---|---|
| K-01 | Kas belum dibuka. Buka kas untuk mulai menerima setoran. | - | Memuat sesi kas… | Sesi kas gagal dimuat. Coba lagi; salin rujukan {ref} untuk admin. | Kas sudah ditutup. Layar ini hanya bisa dibaca. | Akun Anda tidak punya izin transaksi kas. Minta admin menambah izin. |
| K-02 | Belum ada pengajuan kas besar. | Tidak ada pengajuan berstatus {status}. Hapus filter. | Memuat kas besar… | Saldo kas besar gagal dimuat. Coba lagi. | Hanya checker yang bisa memutuskan. | Panel ini butuh izin menyetujui kas besar. |
| K-03 | Belum ada penutupan hari ini. Jalankan tutup buku. | - | Memeriksa syarat tutup buku… | Sebagian pemeriksaan gagal dimuat. Coba lagi sebelum menjalankan. | Hari ini sudah ditutup. Tidak ada yang bisa dijalankan. | Hanya manajer yang boleh menutup buku. |
| K-04 | Pilih periode untuk melihat neraca saldo. | Tidak ada akun untuk filter ini. Hapus filter. | Memuat neraca saldo… | Neraca saldo gagal dimuat. Coba lagi; angka di layar mungkin lama. | Periode ini sudah ditutup; hanya baca. | Akun Anda tidak punya izin membaca buku besar. |
| K-05 | Belum ada jurnal pada rentang ini. | Tidak ada jurnal untuk filter ini. | Memuat jurnal… | Jurnal gagal dimuat. Coba lagi. | Periode tertutup: pembalik tidak bisa diposting. | Bagian ini tidak tersedia untuk peran Anda. |
| K-06 | Belum ada anggota. Tambah anggota pertama. | Tidak ada anggota yang cocok. Hapus filter atau cari dengan nomor anggota. | Memuat daftar anggota… | Daftar anggota gagal dimuat. Coba lagi. | Anggota keluar: data hanya bisa dibaca. | Akun Anda tidak punya izin membaca data anggota. |
| K-07 | Formulir kosong: isi identitas anggota. | - | Memeriksa duplikat… | Data anggota tersimpan, simpanan pokok gagal. Bayar pokok dari berkas anggota. | Langkah 2 terbuka setelah identitas lengkap. | Hanya admin yang boleh mendaftarkan anggota. |
| K-08 | Anggota baru: belum ada rekening. Buka rekening pertama. | - | Memuat berkas anggota… | Sebagian berkas gagal dimuat: {panel}. Coba lagi. | Anggota keluar: hanya baca. | Akun Anda tidak punya izin membaca berkas ini. |
| K-09 | Anggota ini belum memenuhi syarat keluar. | - | Menghitung pengembalian… | Perhitungan gagal dimuat. Coba lagi; jangan memutuskan sebelum angkanya lengkap. | Pengajuan keluar sudah disetujui: terkunci. | Hanya manajer yang boleh memproses keluar. |
| K-10 | Kewajiban periode ini belum dibuat. Buat kewajiban {period}. | Tidak ada anggota berstatus {status} pada periode ini. | Memuat kewajiban… | Kewajiban gagal dimuat. Coba lagi; jangan buat ulang. | Baris yang sudah dibayar atau dibebaskan terkunci. | Akun Anda tidak punya izin membaca simpanan wajib. |
| K-11 | Belum ada pinjaman. Ajukan pinjaman pertama. | Tidak ada pinjaman untuk filter ini. Hapus filter. | Memuat pinjaman… | Daftar pinjaman gagal dimuat. Coba lagi. | Akad tidak berjalan: hanya baca. | Akun Anda tidak punya izin membaca pinjaman. |
| K-12 | Formulir kosong: pilih anggota dan produk. | - | Menghitung jadwal angsuran… | Jadwal gagal dihitung. Ubah tenor atau produk, lalu coba lagi. | Pengajuan terkirim: hanya baca sampai diputuskan. | Hanya petugas pinjaman yang boleh mengajukan. |
| K-13 | Tidak ada pengajuan yang menunggu keputusan. | Tidak ada pengajuan berstatus {status}. | Memuat antrean… | Antrean gagal dimuat. Coba lagi; keputusan lama tidak berubah. | Pengajuan Anda sendiri: setujui dinonaktifkan. | Akun Anda tidak punya izin menyetujui pinjaman. |
| K-14 | Pinjaman baru: jadwal belum tersedia. | - | Memuat akad dan jadwal… | Jadwal angsuran gagal dimuat. Coba lagi sebelum menerima pembayaran. | Sudah dihapusbukukan: hanya baca. | Akun Anda tidak punya izin membuka akad ini. |
| K-15 | Tidak ada tunggakan pada tanggal ini. | Tidak ada tunggakan untuk filter ini. Hapus filter. | Memuat tunggakan… | Daftar tunggakan gagal dimuat. Coba lagi. | - (layar baca) | Akun Anda tidak punya izin membaca tunggakan. |
| K-16 | Pilih dokumen laporan. | - | Menghitung {document}… | {Document} gagal dihitung. Coba lagi; angka lama tidak ditampilkan. | Periode tertutup: dokumen hanya bisa dicetak. | Dokumen ini tidak tersedia untuk peran Anda. |
| K-17 | Belum ada aktivitas pada rentang ini. | Tidak ada aktivitas untuk filter ini. | Memuat jejak audit… | Jejak audit gagal dimuat. Coba lagi. | - (layar baca) | Akun Anda tidak punya izin membaca jejak audit. |
| K-18 | Belum ada pengguna. Buat pengguna pertama. | Tidak ada pengguna yang cocok. | Memuat pengguna… | Daftar pengguna gagal dimuat. Coba lagi. | Akun Anda sendiri: aksi terbatas. | Hanya admin yang boleh mengelola pengguna. |
| K-19 | Belum ada nilai parameter. Ajukan nilai pertama. | Tidak ada parameter untuk filter ini. | Memuat parameter… | Parameter gagal dimuat. Coba lagi; jangan mengajukan nilai baru. | Nilai menunggu keputusan: terkunci. | Akun Anda tidak punya izin membaca parameter. |
| K-20 | Belum ada produk. Buat produk pertama. | Tidak ada produk untuk filter ini. | Memuat katalog… | Katalog gagal dimuat. Coba lagi. | Versi disetujui: terkunci. | Akun Anda tidak punya izin membaca katalog. |
| K-21 | - | - | Memeriksa kebijakan sandi… | Kebijakan sandi belum bisa dimuat. Coba lagi sebelum mengganti sandi. | - | Hanya untuk akun Anda sendiri. |
| K-22 | - | - | Memeriksa… | Nama pengguna atau kata sandi salah. Periksa ejaan, lalu coba lagi. | - | - |
| K-23 | Slip tidak ditemukan. Periksa nomor transaksi. | - | Memuat slip… | Slip gagal dimuat. Coba lagi; jangan mencetak ulang sebelum dokumen tampil. | Salinan: diberi tanda SALINAN. | Akun Anda tidak punya izin melihat slip ini. |
| K-24 | Tidak ada mutasi pada rentang ini. | - | Memuat statement… | Statement gagal dimuat. Periksa rentang tanggal, lalu coba lagi. | Rentang tertutup: hanya bisa dicetak. | Akun Anda tidak punya izin melihat rekening ini. |

Reason: the state matrix in 01 is a design statement; without the sentence per state it becomes
"No data" in implementation, which is the defect the audits found in ledger and day-close.

## 8. i18n mechanics

- Key shape: `namespace_object_state[_variant]`, lowercase snake, namespace = module or screen
  (`teller`, `vault`, `members`, `loans`, `ledger`, `params`, `common`, `error`). Enforced by
  i18ncheck rule 1. Reason: a screen owner can grep their own namespace and the orphan check stays
  meaningful.
- Placeholders: `{name}` only, never positional or numeric; i18ncheck already enforces parity across
  locales. Reason: a reordered string in `en` is the one translation bug the gate can catch for free.
- Plurals: `<key>_one` / `<key>_other`, selected by `Intl.PluralRules` on the active locale; every
  count uses the pair even in Indonesian. Reason: English needs it, and FE-PRAC-12 found "1 instalments".
- Never a key: person names, member/account numbers, amounts, dates, narration, status values from the
  server, permission codes, field names, file names. Reason: data in a catalogue cannot be translated
  and breaks the orphan check.
- Unknown server `reason` falls back to the envelope key, never to server `detail` and never to the raw
  key. Reason: KRAN's error mapping is already correct; the fallback must not regress it.
- Dates: a **business date is a calendar date** from the session, rendered in `Asia/Jakarta` and never
  derived from `toISOString()`. A **timestamp** is an instant, stored UTC, rendered in the branch zone
  with the zone named once ("5 Nov 2026 14:32 WIB"). No screen shows a timestamp without a zone.
  Reason: FE-ISO-05/06 and FE-LOGIC-11 are the same bug in three places.
- Numbers: `Intl.NumberFormat(locale)`; currency in the column header, once; 2 decimals always;
  grouping follows the locale; screen-reader currency announced once per value. Reason: D-136 and
  DESIGN §6; `DataTable`'s `id-ID` default is removed.
- Locale switch never destroys form state: either the shell re-renders text without remounting the
  form, or the switch is blocked while the form is dirty with "Menyimpan isian dulu…". Reason: FE-LOGIC-15
  and UI-8 both lose a typed cash amount.
- `<html lang>`: one policy, `id-ID` / `en-US`, set on load and on switch, plus `dir="ltr"`; FE-ISO-10
  mixes `id` and `id-ID` mid-life. Copy budgets: label ≤24 chars, button ≤24, hint ≤90, error ≤160,
  empty ≤120 plus one action, because 32 px controls and a 360 px side panel cannot hold a sentence.
- Tone: sentence case, imperative, no "silakan", no apology, no emoji, no exclamation mark. Reason:
  the operator reads the same sentence 200 times a day.

## 9. Print and slip content

- Slip (K-23, 80 mm, A5 fallback `NEEDS-COMPLIANCE-REVIEW`): institution name, branch name + code,
  title "Slip transaksi tunai", business date, timestamp + zone, member name + member number, account
  number + product, direction as words ("Setor (masuk)" / "Tarik (keluar)") with sign, amount in
  `1.200.000,00` tabular, narration, cashier name, reference, and "SALINAN" when reprinted (R-22).
  Reason: a slip that cannot name the office, the moment and the person is not evidence in a dispute.
- Statement (K-24, A4): institution + branch, period, generated-at + zone, running balance column,
  page x of y, closing balance, and the "not a GL reconciliation" line where applicable.
  Reason: the running balance is the field tellers and members actually check.
- Certificate (K-03) and report pack (K-16): repeated `thead`, control lines, period, "Belum ditutup"
  watermark when the period is open, signature block with role names. Reason: a certificate printed
  while open is a false statement about the books.
- No colour-only status on paper: status is a word, direction is a word plus sign, negative is a
  leading minus. Reason: printers, photocopies and greyscale faxes.
- Tabular numerals everywhere in print, no abbreviation (rb/jt), currency in the header rather than each
  cell (DESIGN §6). Page breaks: `thead` repeats, total rows and signature blocks `break-inside: avoid`,
  no row splits, no total row alone at the top of a page, because an orphaned total reads as a missing row.
- Print palette forced light; hairlines ≥0.5 pt and ≥3:1 on white; `@page { margin: 12mm }`.
  Reason: dark-mode printing wastes toner and loses hairlines.
- Accessible-name equivalents do not exist on paper, so every acronym is expanded once per document
  (SHU, RAT, PB) and the document stands alone with no screen context. Reason: the paper outlives the
  session and is read by someone who was not there.

## 10. Verification

| Layer | Check | Proves |
|---|---|---|
| Automated | `tokens.contrast.test.ts` extended with focus ring × (selected, row-hover, four tints, primary, surface-disabled) and print pairs | the ring and borders are visible where tables actually sit, both themes |
| Automated | axe on every screen × 2 themes × 2 locales, moderate+ unchanged, **plus `/app/params`** (FE-ISO-14) and a harness page rendering empty/error/loading/denied | no new violation in states that a happy-path visit never renders |
| Automated | `svelte-check --fail-on-warnings` for `packages/ui` (FE-PRAC-19) | shared-component a11y warnings block like app warnings |
| Automated | i18ncheck + three additions: banned-term scan of both catalogues (`uuid`, `vault`, `party`, `endpoint`, `run`, `ID rekening`, `finalisasi`), hardcoded-visible-text scan (FE-PRAC-13), plural-suffix parity (FE-PRAC-12) | the copy rules are a gate, not a review habit |
| Automated | Playwright keyboard: skip link, teller deposit + withdrawal + PB, vault approve, close cash, params maker-checker, session lock extend, dialog focus restore, table sort + roving | the flows a non-technical operator performs daily work without a mouse |
| Automated | zoom 125 % and 200 %: no shell horizontal scroll; table region scrolls; ledger not card-ified; print page count on slip and statement | reflow and the "no card-ification" rule |
| Component (DOM) | label/hint/error wiring, `aria-sort`, caption, roving tabindex, live-region text, SessionLock 60 s and expiry, Esc blocked while busy | the contracts in §1 and §3 are testable without a browser |
| Manual | screen reader (NVDA + Firefox, VoiceOver + Safari) on ReviewPanel, SessionLock, DataTable sort/selection, error summary | announcement order and verbosity, which no automated tool judges |
| Manual | forced-colors mode, OS text scaling 200 %, print preview 80 mm and A4, copy review against §5 | the three places CSS and paper still surprise |

Per-screen acceptance, before "done": one `h1` and landmarks; every control labelled; axe green in two
themes × two locales across all seven states; keyboard-only completion with visible focus and focus
restoration; one announcement and focus on the first invalid field; three distinct empties; no page
scroll at 200 %; no `uuid`/`party`/`vault`; print with identity, timestamp, zone and text status.
Axe stays at moderate+ because the gap is coverage (params, states), not severity.

## 11. Conflicts and open items

1. **Session-lock timing.** 01 §4 warns at 14 min (1 min left); 02 §5 says "polite warning at 2 min"
   and §6 prints "Sesi berakhir dalam 04:59". Canonical: 15-min idle (R-21), warning at 60 s
   remaining, extend available for the whole warning. The other two texts are corrected, not both kept.
2. **Two idle timers.** Client lock is 15 min (R-21), server idle 30 min; the client must warn before
   either, or the lock screen promises a session the server already ended. **DataTable keyboard.** 02 §6
   says rows are not focusable while ApprovalPanel says selection is a real row button; §2 resolves it as
   roving focus over row controls, one tab stop in `tbody`.
3. **Inline errors.** `ledger/admin` puts `role="alert"` on each field message; §3 allows it only for
   the form summary. This is a fix, not a preference. **Navigation copy.** `Vault kas` and `Teller`
   contradict §5 ("Kas besar", "Kasir") and DESIGN §9.
4. **`NEEDS-COMPLIANCE-REVIEW`.** Slip and statement minimum fields (R-22), the collectibility category
   set, and whether a staff-facing privacy notice is required. No value is asserted here.
