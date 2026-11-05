# 02 - Design system: defined, used, target

Status: proposed, Wave 3 (P-03). Baseline `main` @ `29d36c4`; design direction fixed by DESIGN.md
(D-160). Scope: tokens, components, patterns, adoption. Evidence is file:line; nothing was run.

**Verdict.** The direction is coherent; the system is not installed. `packages/ui` defines 25 colour
tokens per theme and 54 contrast pairs, but the app paints with classes copied into pages: 43 raw
`<input>`, 14 raw `<table>`, 40 raw `<button>`, `Money.svelte` with zero call sites, `Field` on one of
thirteen screens. Unused, it is documentation, not a system. The rebuild is an adoption problem -
34 target components, 7 existing - not an invention problem.

## 1. Audit - what is defined vs what is used

| Thing | Defined | Adopted in app | Problem |
|---|---|---|---|
| Colour tokens | 25 per theme (`tokens.css:92-148`), 54 pairs tested (`tests/tokens.contrast.test.ts:18-78`) | only through `components.css`; two pages use tokens directly (`teller:1913-1969`, `ledger:490`) | 5 are aliases: `accent`=`primary`, `text-2`=`text-muted`, `positive`=`success`, `negative`=`danger`; no hover/pressed/row/scrim token |
| Type, space, radius, shadow | 7 sizes, 2 line-heights, 8 spaces, 4 radii, 2 shadows, 3 motion (`tokens.css:40-88`) | `--space-*` and `--text-*` in two local `<style>` blocks | weights 400/500/600 hardcoded ~15×; `60ch`, `16rem`, `42rem`, `2px`, `z-index:100` are raw |
| `components.css` | 104 `.kran-*` selectors, 1,384 lines | 94 referenced somewhere | dead: `.kran-badge--primary`, `.kran-table--compact`, `.kran-table--two-line`, `.kran-header__badge`; two orphan comments where "Trial balance bar" and "Quick amounts" rules were removed |
| Button | 4 variants, 32/44 px, loading (`Button.svelte`) | 12 screens, 41 instances | no size for 24 px row action; no `:active`; `variant="row"` used 2×, everything else is `primary` or default |
| Alert | 5 tones, title, reference, children (`Alert.svelte`) | 12 screens, 44 instances | retry buttons inside a tinted alert (`vault:322,331`, `dayclose:457,470`) - focus ring and border on a tint are untested pairs |
| EmptyState | title, description, optional action | 9 screens | dashed frame is decoration; no distinction between "none yet" and "none match" |
| StatusBadge | 5 tones, text from caller | 6 screens | no non-colour cue beyond the border; `neutral` is used as decoration. `.kran-status__icon` is a font glyph and `.kran-status-dot` a 6 px colour dot - both violate "text + shape + colour" (DESIGN §8, §9) |
| Field | label + hint + error, snippet-parameter API | **1 screen**, 5 instances (`loans/[loanId]`) | the API forces callers to spread 4 props; that is why 43 inputs bypass it |
| DataTable | caption, `th scope`, `aria-sort` prop, money columns | 4 screens (`teller`, `loans`, `loans/[loanId]`, `products`) | `DataRow = Record<string, unknown>` and `String(value)` (FE-PRAC-07); `locale = "id-ID"` default and **no caller passes `locale`** (FE-ISO-04); no sort, paging, totals or density |
| Money | 2-decimal, locale, screen-reader currency (`Money.svelte`) | **0 imports** | the same formatting lives in `lib/app/format.ts:17-22`; 4 screens use the `.kran-money` class by hand |
| Money input | `parseMoneyInput` (pure) | teller, session, open-account | no control: raw `<input inputmode="decimal">`, non-digits accepted until submit (FE-ISO-19) |
| Dialog | native `<dialog>`, one-layer rule | 4 dialogs | focus trap and restore implemented **3×** (`app/+layout:66-91`, `dayclose:347-407`, `loans/[loanId]:462-525`) with different fallbacks |

Rules that follow: **no new token without a matrix row** (DESIGN §3), **no component without an
adoption call site**, and **no page CSS that re-declares a component** (`teller` 75 lines, `ledger`
20, `ledger/admin` 12 re-state table/field rules).

## 2. Token completeness

Naming rule: `--<group>-<role>[-<state>]`, groups fixed to `color, text, space, radius, border,
shadow, motion, layer, table, print, layout`. Values exist **only** in `tokens.css`; a component may
write `0`, `100%`, `1fr`, `auto`, `none` and nothing else - no hex, px, rgb(), z-index, weight or
duration. Review checks by grep, not by eye.

| Group | Exists | Add | Why (one line each) |
|---|---|---|---|
| colour | 25 tokens/theme | `surface-sunken`, `row-hover`, `text-disabled`, `scrim`, `border-strong` | inset block currently paints `--color-bg` (`components.css:835`); hover and selected share `--color-selected` (`:1140` vs `:1172`) so a selected row looks unselected under the pointer; disabled text is `text-muted` on `surface-disabled`, one token cannot carry both meanings; backdrop is raw `rgb(0 0 0 / 45%)` twice (`:498`, `:1210`); tfoot rule and sticky edge need a boundary that is not the control border |
| colour (collapse) | 5 alias pairs | delete `accent`, `text-2` | two names for one value is two places to drift; roles keep `positive/negative` (money direction) and `success/danger` (status) because they may legitimately diverge |
| text | 7 sizes, 2 line-heights | `font-weight-regular/medium/semibold`, `measure-prose` | 600 is the documented ceiling (DESIGN §2) and is hardcoded 15×; the only line-length cap is a raw `60ch` (`components.css:402`) |
| space | 8 steps (4-48) | `space-05` (2px) | 2 px gaps appear in `.kran-segmented`, `.kran-badge`, `.kran-kbd` and cannot be expressed today |
| radius | chip 2 / 4 / 6 / 8 | - | complete and enforced; adding a 5th radius would be slop |
| border | none | `border-width`, `border-width-strong`, `focus-width`, `focus-offset` | `1px`/`2px` in ~20 rules, and `ledger:490` re-declares the focus outline with raw `2px` |
| elevation | `shadow-1`, `shadow-2` | `layer-sticky/dropdown/dialog/toast/skip` | skip link uses raw `z-index:100`; a second overlay will collide without a scale. No new shadow: cards stay flat |
| motion | fast 150, base 200, ease | `motion-instant` (0), `motion-reduced` (1ms) | both values are written in the reduced-motion block (`:1379-1381`) and in DESIGN §8's `transitionend` exception |
| table | `row-height*`, `control-height*` | `table-cell-block`, `table-cell-inline`, `table-cell-first`, `table-money-pad`, `table-header-height` | DESIGN §6 fixes 8×12/first 16/optical +4; today it is `--space-3` plus a `calc()` (`:1102-1115`, `:1157-1159`) |
| print | `@page 12mm` only | `print-margin`, `print-body-size`, `print-table-size`, `print-block-gap` | print inherits the 13 px screen scale, so a statement that fits one sheet on screen runs long on paper; sizes reuse the scale (`text-xs`, `text-2xs`), not new numbers |
| layout | `layout-max-width` | `layout-sidebar-width` (16rem), `layout-reading-width` (42rem) | both are raw in `components.css:57` and `:378` |
| density | 32/34/40 rows, 32/44 controls | `control-height-sm` (24) | the only 24 px control is the min target, not a declared size; row actions must not be 32 px inside a 34 px row |

Explicitly **not** added: filled status surfaces (a filled chip is a decorative badge, DESIGN §13.3),
shadow tokens, a mono family, chart palettes. A colour token that cannot pass its row is removed,
never nudged.

## 3. Contrast matrix plan

No ratio is proposed here; thresholds stay WCAG 2.2 AA (4.5 text, 3 non-text), enforced by
`tests/tokens.contrast.test.ts`. Every pair is tested in **both** themes; `prefers-contrast: more`
inherits because it overrides the same tokens.

| Class | Pairs (token roles) | Rule |
|---|---|---|
| Body text | `text` × bg, surface, surface-raised, surface-sunken, selected, row-hover, surface-disabled | 4.5 |
| Secondary text | `text-muted` × the same seven | 4.5 |
| Disabled text | `text-disabled` × surface-disabled (and × bg for disabled-on-page) | 4.5 - WCAG exempts disabled, the product does not |
| Accent text | `primary` × bg, surface, surface-raised, selected, row-hover; `primary-hover` × bg, surface | 4.5 |
| On accent | `text-on-primary` × primary, primary-hover | 4.5 |
| Status on tint | success, danger, warning, info × own tint | 4.5 |
| Status on neutral | each of the four × bg, surface, surface-raised | 4.5 |
| Money | positive, negative × surface, selected, surface-sunken | 4.5 - DESIGN §3 forbids muted money, including dark mode |
| Control boundary | `border` × bg, surface, surface-raised, surface-disabled, selected, all four tints | 3 |
| Focus ring | `focus-ring` × bg, surface, surface-raised, surface-sunken, selected, row-hover, surface-disabled, all four tints, primary | 3 |
| Print | text, border, positive, negative × white; hairline × white | 4.5 / 3, measured on the print palette |
| Hairline | not tested | by role it is a separator, never a control boundary; DESIGN §3 says so and §10 gates controls on `border` |

Gaps to close **before** new tokens land: `focus-ring` and `border` on tints are untested yet real -
retry `Button`s sit inside negative `Alert`s (`vault:322,331`, `dayclose:457,470,706`); no
`row-hover`, `text-disabled` or print pair exists. Row state is **not** a contrast gate: selection
also carries a non-colour marker (`aria-selected` + 2 px inset); colour alone is forbidden.

## 4. Typography

| Context | Size / weight / line-height | Rules |
|---|---|---|
| Page title (`h1`, one per screen) | text-xl 28 / 600 / tight | no letter-spacing, no tracking-up, no display weight |
| Section title (`h2`) | text-md 16 / 500 / base | sections are separated by space + title, not by a card |
| Table header | text-xs 12 / 500 / tight | muted colour, sentence case, `th scope="col"`, never uppercase |
| Table cell | text-sm 13 / 400 / base | 34 px row, 32 compact, 40 two-line |
| Money in a cell | text-sm 13 / 400, 600 only where the value *changes* a balance | tabular-nums slashed-zero, right aligned, nowrap, selectable |
| Amount summary | text-lg 20 / 600 / tight | one per screen block; the sign is text (`+` / `−`), not colour |
| Label / helper | label text-sm 13 / 400; hint text-xs 12, muted | permanent label, never placeholder-only; hint referenced by `aria-describedby` |
| Error | text-sm 13 / 500, danger | message names the rule and the fix; never a bare colour change |
| Print | body text-xs 12, table text-2xs 11, title text-md 16 | tabular figures, theme forced light, `thead` repeats |

Numeric rules: all digits use `.kran-num`; currency in the column/label, never per cell; always 2
decimals (D-136); grouping from `Intl` via `formatMoney`; no abbreviation (rb/jt), count-up, centred
money or mono - including reference numbers. Prose caps at `measure-prose`; tables may exceed it.
Forbidden: uppercase with tracking (DESIGN §13.10); weights 700-900; text under 11 px.

## 5. Component inventory (target)

34 components, 8 categories. States: **S1** default, **S2** hover, **S3** focus-visible, **S4**
pressed, **S5** disabled, **S6** loading, **S7** error, **S8** empty, **S9** read-only. Interactive
components support S1-S3 and S5 always; the column lists the rest.

| Component | Purpose | Variants / sizes | States | a11y contract | Props (key) | Today |
|---|---|---|---|---|---|---|
| **Primitives** | | | | | | |
| Button | the only clickable control | primary 44, secondary 32, row 24, destructive | S4 S6 | native `<button>`, text name, `aria-busy` when loading, never `aria-disabled` alone | `variant`, `size`, `loading`, `disabled`, `type`, `onclick` | exists - change (size, pressed, icon slot) |
| Input | single-line text | 32, 44 | S7 S9 | label `for`/`id`, `aria-describedby` = hint then error, `aria-invalid` only when true | `label, hint, error, required, value, oninput, readOnly` | no (43 raw) |
| Select | option list | 32, 44 | S7 S5 | native `<select>`, label, `aria-describedby`; no custom listbox until needed | `label, options, value, onchange` | no (13 raw) |
| Checkbox | binary choice in a form | 20 box | S5 | native input + label text; `indeterminate` announced via `aria-checked="mixed"` | `checked, indeterminate, label, onchange` | no (6 raw) |
| Radio | one of 2-5 | segmented or stacked | S5 | `fieldset` + `legend` (visually hidden when the group is titled), arrow keys native | `name, options, value, onchange` | partial (`kran-radio` class, no component) |
| Switch | instant-effect setting | 32×20 | S5 | `role="switch"` + `aria-checked`; only where no Save button exists | `checked, label, onchange` | deferred - no screen has an instant-effect setting |
| **Money** | | | | | | |
| Money | render a decimal string | cell, inline, summary | S9 | currency announced once via visually hidden text, never repeated per cell | `value, locale (required), currency?` | exists - 0 call sites, must adopt |
| MoneyInput | type an amount | 32, 44, with quick amounts | S7 S9 | `inputmode="decimal"`, label, describedby, `aria-invalid`; no per-keystroke live region | `value, locale, currencyLabel, error, hint, quickAmounts?, onvalue` | no (parser exists: `parseMoneyInput`) |
| AmountSummary | the one number of a screen | lg 20 | S9 | `<dl>`-based facts or a labelled value; sign as text | `label, value, locale, sign, tone` | no (`kran-stat` class only) |
| **Identity** | | | | | | |
| MemberRef | identify a person | inline, block, link | S1 S3 S5 | visible name + member no in the accessible name; UUID never rendered (DESIGN §9) | `memberNo, name, href?` | no (UUIDs rendered: `loans:101`) |
| AccountRef | identify an account | inline, block | S1 S3 S5 | account no + product + holder; masked when policy says so | `accountNo, product, holder?, href?` | no |
| PartyBadge | member/loan/request status | 5 tones | S5 | text + shape + colour; the text is the meaning | `tone, children` | exists as `StatusBadge` - change (restrict to status) |
| **Data** | | | | | | |
| DataTable | the work surface of a list | default/compact/two-line | S6 S7 S8, selected, sorted | `role="region"` + `tabindex="0"` + `aria-label`; `caption`; `th scope`; `aria-sort`; one tab stop | `columns<T>, rows<T>, rowKey(row), locale, sort, onSort, density, total, empty, loading, error` | exists - change (generic, locale required, sort/paging/totals) |
| FilterBar | narrow a list | 1 search + ≤3 selects + date range | S6 | `role="search"` region; labelled controls; result count in `role="status"` (debounced) | `filters, values, onchange, onreset, resultCount, busy` | no |
| Pagination | move through a long list | page size 50 | S5 S6 | `nav aria-label`, text "1-50 dari 1.204", buttons not icons | `offset, limit, total, onchange` | no (lists silently stop at 50) |
| TotalsRow | the summed line | table foot, report | S9 | `<tfoot>` with `th scope="row"` on each label | `cells, label` | no |
| EmptyState | nothing to show | no-data, no-match, denied | S8 | static text (no role); action is a real link/button | `kind, title, description, action?` | exists - change (kind, no dashed frame) |
| ErrorState | the region failed | inline block, page block | S7 | `role="alert"` when it appears after an action, `status` on load; reference + copy + retry | `title, detail, reference?, onretry` | no (7 copies of fetch→error→retry) |
| LoadingState | the region is pending | block, inline | S6 | `role="status"`, `aria-busy` on the container, fixed height (no layout shift) | `label, minHeight` | no (each screen writes "Memuat…") |
| **Workflow** | | | | | | |
| ReviewPanel | inspect before posting | inline (teller), stacked | S6 S7, stale | `section aria-labelledby`, heading focus on open, `aria-busy`, assertive only on failure | `title, facts, amount, reference, busy, error, onsubmit, oncancel` | no (inline markup in `teller`) |
| ConfirmDialog | one-layer confirmation | routine, destructive, irreversible | S6 S7 | `<dialog>` + `showModal`, `aria-labelledby`/`describedby`, trap, Esc blocked while busy, restore trigger or `#main` | `open, title, body, tone, confirmLabel, requireReason, busy, onconfirm, oncancel` | no (3 hand-rolled traps) |
| ApprovalPanel | maker/checker decision | approve, reject, read-only | S5 S6 S7, stale | selection is a real button; `aria-live="polite"` on the decision result; reason `fieldset` when rejecting | `items, selected, selfApprovalBlocked, reason, ondecide, busy` | no (buttons on every PENDING row) |
| IdempotentSubmit | post money once | button + key owner | S6 S7, unknown | same Button contract; `aria-busy`, key preserved visibly across retry | `fingerprint, onSubmit, onUnknown` | no (4 divergent key lifecycles, FE-PRAC-03) |
| SessionLock | 15-min idle guard (R-21) | warning, expired | S6 S7 | `dialog` + polite warning at 2 min, assertive at expiry; focus moves in; Esc does not dismiss | `expiresAt, warningSeconds, onExtend, onSignOut` | no |
| **Feedback** | | | | | | |
| Alert | message tied to a form or action | 5 tones | S7 | `role="alert"` only for failure, `status` otherwise; title is `<p>` not a heading | `tone, title, reference?, children` | exists - keep |
| Toast | transient confirmation | success, error | S6 S7 | live region + close button; errors never auto-dismiss; never covers save/print | `tone, message, onclose` | no (no toast today - keep it that way for money) |
| InlineError | field-level message | 1 | S7 | referenced by `aria-describedby`, no `role="alert"` (the summary announces) | `id, message` | folded into `Input`/`Field`; not public |
| **Report** | | | | | | |
| ReportHeader | institution + document + period | slip, statement, certificate | S9 | heading order h1→h2; timestamp + zone as text (R-22) | `title, institution, branch, generatedAt, period` | no (statement prints a branch UUID) |
| CloseCertificate | day/cash close evidence | daily, session | S9 | facts table, signature block `break-inside: avoid` | `date, tasks, totals, signatures` | no |
| StatementLayout | statement/ledger print shell | A4, A5 slip | S9 | repeated `thead`, totals not orphaned, status text remains | `meta, rows, total, footer` | partial (two bespoke pages) |
| **Layout** | | | | | | |
| AppShell | page chrome + landmarks | sidebar ≥1024, top bar below | - | skip link → `#main`, one `h1`, settings out of the tab order before content | `nav, session, children` | exists as CSS + layout page - change into a component |
| PageHeader | title + one action | 1 action, 0 actions | - | `h1` + intro ≤60 ch; no metric strip | `title, intro, action?` | CSS only (`.kran-page-header`) |
| Toolbar | row of controls above a table | default, sticky | - | real form/buttons; height ≤48 px | `children, sticky` | CSS only |
| SidePanel | right-hand context (teller) | 22rem, collapses below 1100 px | S6 S7 | `<aside aria-labelledby>`; becomes a block below, never a modal (DESIGN §4) | `title, children` | CSS only |

Survive unchanged: **Alert, EmptyState, StatusBadge** (3). Changed API: **Button, DataTable, Money**
(3). Dies: **Field** (1) - its wiring moves inside `Input`/`Select`/`MoneyInput`, the only way the 43
raw inputs adopt it. `InlineError` is not public; `TotalsRow` is one implementation used in both
`DataTable` and reports.

## 6. Specs for the eight that matter

**DataTable.** Anatomy: labelled scroll region → `<table>` → `<caption>` → `<thead>` (`th scope="col"`,
sort button inside the `th`) → `<tbody>` (`th scope="row"` on the key column) → `<tfoot>` (TotalsRow).
States: S6 region `aria-busy` with previous rows visible, S7 body replaced by ErrorState, S8 table
replaced by EmptyState, selected row, sorted column. Keyboard: one tab stop on the region, arrows
scroll, Tab reaches the sort button and the row action - rows are not focusable. ARIA: `aria-sort` on
exactly one `th`, caption is the accessible name, totals are a table foot. Props as in §5, with
`columns: Column<T>` and `cell(row)` a snippet. Do: pass `locale` explicitly. Don't: `String(value)`
a typed field, or let a filtered footer call the ledger unbalanced (FE-LOGIC-02).

**MoneyInput.** Anatomy: label → input (`text`, `inputmode="decimal"`, `autocomplete="off"`) → hint →
error → optional preview. States S1-S5, S7, S9. Keyboard: digits and one separator; non-digits are
rejected on input (DESIGN §7; today accepted until submit, FE-ISO-19); Enter submits the form. ARIA:
`for`/`id`, `aria-describedby` = hint id then error id, `aria-invalid` only when true; the preview is
**not** a live region (DESIGN §8 forbids announcing keystrokes). Content: parse with `parseMoneyInput`;
errors name the rule ("Nominal harus lebih besar dari 0,00"). Do: 44 px when it is the screen's
primary action. Don't: insert thousand separators into the editable value - the caret jumps and the
parser rejects them.

**ReviewPanel.** Anatomy: heading → risk facts (account no, holder, branch, product) → amount with
sign → reference (copyable, present **before** submit) → Kembali / Kirim. States: idle, S6 (buttons
disabled, Esc blocked), S7 (error stays in the panel, reference preserved), stale (source changed
since load → submit blocked with a reason). Keyboard: focus to the heading (`tabindex="-1"`) on open;
Esc = back only when not busy. ARIA: `<section aria-labelledby>`, `aria-busy`, `role="alert"` only on
the failure line. Do: show the destination account **number and holder name**, never a UUID
(FE-LOGIC-01). Don't: bury the amount in a sentence - it needs a labelled value.

**ApprovalPanel.** Anatomy: queue (DataTable) → selected detail → maker + created-at → change diff
(before → after) → decision (Setujui / Tolak + reason). States: no selection, S6, decided (read-only
with who/when), self-approval blocked with a visible reason, stale (another checker decided). Keyboard:
queue is one tab stop; selection is a real row button; "Tolak" moves focus to the required reason
field. ARIA: `aria-live="polite"` on the result, `role="alert"` on failure. Do: disable approve on
your own request and say why (FE-LOGIC-17). Don't: hide it - the server refuses anyway.

**FilterBar.** Anatomy: search → 0-3 selects → date range → active-filter summary → "Hapus filter".
States: S1, dirty, S6 (filters stay enabled, `aria-busy` on the results region); never S5 while typing.
Keyboard: Enter applies search; Tab follows visual order; no custom combobox until a filter needs >20
options. ARIA: `role="search"` with an `aria-label`; result count in a debounced `role="status"`;
each control labelled. Content: nouns from the operator's world (Cabang, Status, Tanggal), not field
names. Do: write filters into the URL query. Don't: keep old rows while a new filter loads - clear and
show ErrorState (FE-LOGIC-08).

**ConfirmDialog.** Anatomy: `<dialog>` → title → one consequence sentence → optional required reason
or typed phrase → Cancel (default focus) / Confirm (destructive weight). States: open, closed, S6 (Esc
blocked, both buttons disabled), S7. Keyboard: Esc closes unless busy; `showModal` traps; on close,
focus returns to the trigger or `#main` if it was removed. ARIA: `aria-labelledby` + `aria-describedby`,
`<h2>` inside, no hand-rolled `aria-modal`. Content: the consequence in operator words ("Kas sesi ini
akan ditutup; transaksi baru tidak bisa diposting"). Do: cancel/close-cash only. Don't: confirm routine
saves or stack a second modal.

**SessionLock.** Anatomy: overlay → "Sesi berakhir dalam 04:59" → reason → Lanjutkan (re-auth in place)
/ Keluar; draft and idempotency key survive. States: idle (>2 min), warning (≤2 min, polite once),
expired (blocked, assertive), re-authing, failed. Keyboard: focus moves in at warning; Esc does not
dismiss; the re-auth form is the first tab stop. ARIA: `dialog` with `aria-labelledby`/`describedby`;
the timer is **not** a per-second live region - 2 min and expiry only. Do: keep
`SessionInfo.expiresAt` in state (FE-ISO-01). Don't: let 401 do `window.location.assign` while a cash
form is dirty.

**EmptyState / ErrorState.** EmptyState: title → one-sentence reason → optional action; `kind` changes
the copy, not the layout (no-data ≠ no-match ≠ denied). ErrorState: what failed → what to do →
reference (copyable) → Retry; it replaces the region, it is not a toast. ARIA: EmptyState is static;
ErrorState is `role="alert"` only after an action, `status` on load. Do: "Belum ada jurnal bertanggal
ini. Posting jurnal (F2), atau ubah tanggal." Don't: "No data" / "Terjadi kesalahan sistem" without a
next step.

## 7. Patterns

- **Money entry → review.** Type → parsed preview → ReviewPanel with identity facts → submit once
  with a key → receipt with reference. Key per content fingerprint, kept on 5xx/network, dropped on
  success/4xx - one implementation, not four.
- **Maker/checker.** Queue shows maker, time and diff; the decision is a separate surface from the
  request; self-approval is disabled with the reason visible; unknown status prints as-is
  (FE-LOGIC-18).
- **Destructive/irreversible.** Only cancel, close-cash, reversal and write-off confirm. Irreversible
  actions additionally require a reason; the wording states the consequence, not "Are you sure?".
- **Unknown state after network failure.** Never a disappearing toast: persistent ErrorState or
  ReviewPanel error with the reference, "Jangan ulangi dengan nominal berbeda", Retry, preserved key.
- **List + totals.** Two totals always: visible rows (footer) and scope (badge/label); a verdict
  like "seimbang" is never computed from a filtered set. Paging says "1-50 dari N" whenever the
  server caps results (50 today, `loans:37`, `teller-session.ts:227`).
- **Filter persistence.** URL query for list screens; cleared when the entity changes (branch,
  account). Never sessionStorage - a reload must reproduce the screen.
- **Print.** Light theme forced, chrome hidden, `thead` repeated, totals and signature blocks
  `break-inside: avoid`, identity + timestamp + zone in the header (R-22). Status stays text.
- **Dense table vs form.** Tables use 34/32 px rows and 13 px cells; forms use 32/44 px controls and
  14 px text. Never mix a 44 px control into a 34 px row.
- **Role-filtered navigation.** One source (`nav.ts:81-151`) filters by permission, fail-closed on
  a missing session; screens gate the same permission before fetching, not just the menu (FE-PRAC-11).

## 8. Adoption plan

One component per PR, deleting the aliases it replaces (no dual API); order keeps every later
component landing on a page that already passes axe.

| # | Change | Screens touched | Breaking? | Call sites |
|---|---|---|---|---|
| 1 | Tokens + `components.css` (incl. alias collapse, scrim, table tokens) | none | inside `packages/ui` only | 2 pages reference tokens (`teller`, `ledger`); contrast test grows to all pairs in §3 |
| 2 | `Input`/`Select`/`Checkbox` (Field folded in) | all 13 | Field removed | 43 inputs, 13 selects, 6 checkbox/radio; Field: 5 uses in 1 file |
| 3 | `Button` size + pressed | all | no | 41 Button + 40 raw buttons |
| 4 | `Money` + `MoneyInput` adoption | teller, ledger, loans, print | `locale` required | 4 files use `.kran-money`; 0 `Money` imports |
| 5 | `DataTable<T>` + `Pagination` + `TotalsRow` | teller, loans, products, ledger, admin, params, users, vault, print | props rewritten | 4 DataTable + 14 raw tables in 7 files |
| 6 | `ConfirmDialog` | teller, dayclose, loans, params | replaces 3 traps | 4 dialogs, 3 focus-trap copies |
| 7 | `ReviewPanel` | teller (deposit/withdraw/transfer, session open/close) | no | 2 inline review blocks in a 1,978-line file |
| 8 | `SessionLock` | shell + `api.ts` | changes 401 behaviour | 1 transport, 11 page-level 401 branches to delete |
| 9 | `ApprovalPanel` | vault, params, products | no | 3 screens |
| 10 | `ReportHeader`/`StatementLayout`/`CloseCertificate` | print slip, statement, day-close | no | 2 print pages |
| 11 | `AppShell`/`PageHeader`/`Toolbar`/`SidePanel` | shell + all | layout only | 1 layout, 3 pages with local CSS |

Gate keeping: axe stays at `moderate+` on the migrated screen in the same PR; the contrast suite
grows in PR 1 and never shrinks; `svelte-check --fail-on-warnings` is added to `packages/ui`
(FE-PRAC-19, strengthening); no screen is migrated by deleting its axe run. Pages drop their local
`<style>` in the PR that replaces the last rule.

## 9. Verification

| Layer | What it proves | Where |
|---|---|---|
| Unit | contrast for every pair in §3, both themes; token parity between themes; `formatMoney` for `id-ID` and `en-US`; `parseMoneyInput` edge table; alias collapse leaves no duplicate role | `packages/ui/tests` (extend `tokens.contrast.test.ts`, `money.test.ts`) |
| Component (vitest DOM) | label/hint/error wiring, `aria-sort`, caption, locale, focus move and restore, `aria-busy`, Esc-blocked-while-busy, SessionLock thresholds, self-approval disabled state | new DOM project - needs the ADR in synthesis X8; do not smuggle in tooling |
| axe | each migrated screen in both themes × both locales, plus a pass on `/app/params` (FE-ISO-14); error/empty/loading states rendered in a harness page so they are analysed too | `apps/web/tests/e2e` |
| Manual | keyboard-only: teller deposit, vault approve, close-cash; 200 % zoom on the ledger (no card conversion); print preview of slip, statement, certificate; forced-colors; screen-reader pass on ReviewPanel and SessionLock | recorded in the PR, R-35 |

No gate is weakened: thresholds stay 4.5/3, axe stays `moderate+`, `:focus-visible` never removed.

## 10. Open decisions

1. **Collapse the colour aliases?** (a) delete `accent` and `text-2`, keep `positive/negative` for
   money and `success/danger` for status; (b) keep all five. **Recommend (a)** - two names for one
   value is drift; the split worth keeping is the one with different meaning (money vs status).
2. **A separate `text-disabled` token?** (a) add it with its own 4.5 row; (b) reuse `text-muted`.
   **Recommend (a)** - "secondary" and "unavailable" must be able to diverge; today a change to
   muted text silently changes disabled legibility.
3. **Row hover vs selected.** (a) two tokens plus a 2 px inset bar on the selected row; (b) one
   token and rely on `aria-selected`. **Recommend (a)** - the ambiguity is visible today
   (`components.css:1140` vs `:1172`) and selection must not vanish under the pointer.
4. **Print scale.** (a) tokenise print at 12 px body / 11 px table; (b) keep screen size and accept
   pagination. **Recommend (a)** with a page-count check on the statement, then adjust the token,
   not the document.
5. **Filter persistence.** (a) URL query per list screen; (b) sessionStorage; (c) none. **Recommend
   (a)** - shareable, survives reload, and clears when the entity changes.
