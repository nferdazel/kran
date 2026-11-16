# T-241 (screens) — design direction: vault, ledger, params, password

State: Design (2). Author: Fajar. Consumer: Nadia. Approver: Raka.
Repo: `/Users/sachiel/Projects/cbs` at `origin/main` `2ee13a5`. All file:line facts below were read
from that tree on 2026-11-16, not from memory.

Precedent: `docs/tasks/T-241-login.md` (approved 2026-11-11) covers the sign-in screen only. This
file covers the other four and follows its shape. It is the artifact the task owes; no diff.

## Design read

Reading these as: four repair screens inside the existing `/app` shell, for tellers, supervisors and
auditors at a 1366x768 desk, in KRAN's calm-work-tool language (DESIGN §1), dial
**ENERGY 2 / RHYTHM 2 / MOTION 2** inherited from `DESIGN.md`, not re-declared per screen.

The common failure is not styling. All four screens already use `packages/ui` components and
`DESIGN.md` tokens. What they lack is **a named job**: each page stacks everything it can do, in the
order it was built, so the operator has to read the whole page to find the one thing they came for.
The repair is hierarchy and states, not a new visual language. Do not restyle; reorder, then fill
the missing states.

Rules that bind all four, from `DESIGN.md`:

- One focal point per screen (§11). One `h1` per page (§10). No metric card strips (§13.4).
- 40 px controls, 40 px table rows, 4 px grid, radius 2/4/6/8 (§4, §5). Cards flat, shadow only for
  overlays (§5).
- Status is text + shape + colour, never colour alone (§8). Empty states honest, no dummy rows (§9).
- Error = what failed + the next step, never "Terjadi kesalahan sistem" alone (§7).
- Below 1100 px a right panel drops under the content, it does not become a modal (§4).

---

## 1. Vault — "Kas besar" (`apps/web/src/routes/app/vault/+page.svelte`, 589 lines)

**One image:** a cash drawer with an approval tray beside it. The number on the drawer is the
reference; the tray is where the work waits.

**Job.** A teller moves cash into or out of the vault; a supervisor approves or rejects. One decision
on this screen: *does the queue still match the drawer?*

**What is wrong today (measured).**

1. Order is balance → submit form → request queue (`:360`, `:381`, `:437`). The supervisor, whose
   only work here is the queue, scrolls past a form they never fill. The queue is the time-sensitive
   half and it sits last.
2. The read-only state is a paragraph *under* the balance value (`:377`), so a read-only role sees a
   normal-looking form first and learns it cannot submit by trying.
3. Branch selection is a `Select` in the page header (`:317-330`) whose empty option is the string
   "pilih cabang" (`:324`); when nothing is chosen the body answers with the same muted sentence
   (`:343`). The same words appear as a prompt and as a state, and neither tells you what to do next.

**Composition.** Above 1100 px: two columns on one axis, 480 px form left, queue right, balance as a
single figure above both (it is a reference number, not a metric strip, so `kran-stat` stays and is
the only one on the page). Below 1100 px: balance, then **queue**, then form. Queue first when
stacked because it has a deadline and the form does not.

The read-only state moves to a `StatusBadge` next to the `h2` of the submit section ("Hanya baca"),
and the submit control renders `disabled` with `aria-describedby` pointing at that badge's text. A
form that cannot be submitted must look like one (DESIGN §7, §13.13).

Branch prompt: when no branch is chosen, the body is an `EmptyState` with one action that focuses the
branch `Select` — not a muted sentence repeating the option label.

**States.**

| State | What the operator sees |
|---|---|
| no permission | `Alert tone="negative"` "Kas besar tidak tersedia untuk peran Anda" (exists, `:334`) |
| branches loading | reserved 40 px line, `role="status"`, no layout jump |
| branches empty | `EmptyState` + "Muat ulang" (`:341`, `:333`) |
| no branch chosen | `EmptyState` naming the select above, one action focusing it |
| balance loading | 28 px line reserved for the value, `role="status"` |
| balance missing | muted line "Saldo kas belum tersedia untuk cabang ini" + the reason (open day, closed period) |
| balance error, form OK | `Alert` with retry above the balance; **submit stays enabled** — a transfer request does not move money, it queues for a human, so blocking it would stop work without making anything safer |
| queue empty | `EmptyState` "Belum ada permintaan menunggu" + what creates one |
| queue error | `Alert` + "Muat ulang" scoped to the queue, balance still readable |
| submit success | positive `Alert` with the request reference, copyable, queue reloaded |
| submit conflict (409) | negative `Alert` naming the conflicting request id |
| dependency down (API 5xx) | both panels show their own error + retry; never one page-level banner that hides which half is dead |

**Out of scope.** Realtime push for the queue. Multi-branch comparison. Any change to approval
permissions or the posting path.

---

## 2. Ledger — "Saldo buku besar" (`apps/web/src/routes/app/ledger/+page.svelte`, 498 lines)

**One image:** a printed page of a ledger book. The table is the page; everything else is its
masthead.

**Job.** An auditor picks a period, reads opening/movement/closing, and checks that it balances.
One decision: *is this period clean?*

**What is wrong today (measured).**

1. The period range is printed twice about 100 px apart: the meta row at `:245` and the `Select`
   option text at `:271-273`. Same two dates, same format.
2. Six `aria-pressed` filter buttons (`:318-365`) sit in a bare `div` with no group role and no
   label, so a screen reader hears six unrelated toggles. Only the "ALL" chip carries a count
   (`:326`); the other five carry nothing, so the operator cannot tell which category has rows
   without clicking each one.
3. Filtering to an empty category leaves the table with an empty `tbody` and no empty state
   (`filteredLines` at `:72-76`, no zero branch in the markup). The screen says nothing, which reads
   as a failure.
4. Keyboard cell navigation paints `.ledger-cell--active` (`:170-226`), which is a second selection
   language next to the chip's `aria-pressed`. They must not look like the same thing: chips are
   *filters* (persistent), the active cell is *focus* (transient).

**Composition.** Keep the table as the single focal point. Move the period `Select` into the meta
row at `:245` and delete the duplicated date span, so the masthead reads once: period control,
status badge, source, computed-at. The filter row becomes `role="group"` +
`aria-label="Filter kategori akun"`, every chip gets its count, and the row gets a hairline under it
so it reads as a toolbar rather than as content.

**States.**

| State | What the operator sees |
|---|---|
| no permission | `Alert` (exists, `:284`) |
| loading | `role="status"` line, table region height reserved so the page does not jump |
| period list empty | `EmptyState` "Belum ada periode" + where a period is opened (exists, `:292`) |
| period has no lines | `EmptyState` (exists, `:294`) |
| filter matches nothing | **missing today**: in-table `EmptyState` "Tidak ada akun pada kategori ini" + button "Tampilkan semua" that resets to ALL |
| error | `Alert` + retry (exists, `:286-289`) |
| 100+ rows | sticky `thead`, sticky code column, horizontal scroll inside the labelled region (DESIGN §10) |
| dependency down | `Alert` + retry, period `Select` and filter chips `disabled` with the reason, not silently inert |

**Explicitly out of scope.** The keyboard model of the table. Nadia's T-294 part 2 (single tab stop
on `.ledger-region`, `role="region"`, arrow scrolling) is settled under D-203 and must not be
re-opened by this direction. The only interaction I ask for here is the reset action in the new
filter-empty state.

---

## 3. Params — "Parameter & jejak audit" (`apps/web/src/routes/app/params/+page.svelte`, 894 lines)

**One image:** a settings ledger. Each line is one key with its current value; you find a line, then
you change it in place.

**Job.** A supervisor changes one parameter and sees whether a change is already waiting for
approval. One decision: *which key, and what is it set to right now?*

**What is wrong today (measured).**

1. The submit form is the first block on the page (`:497-548`), above every table, even though it is
   the rarer action and it is hidden entirely from readers without `canSubmit` (`:496`).
2. The form picks its target from a `Select` of every selectable key (`:501-505`), while the table
   below already has a search box (`:732-735`). So the operator either finds a key by scrolling the
   table and then finds it *again* in the select, or searches the table and cannot act on the row.
3. Section order is submit → pending → end requests → active → audit (`:497`, `:550`, `:603`, `:727`,
   `:851`). The active list, the thing people come to read, is fourth.
4. The page `h1` is "Parameter & jejak audit" (`:446`) and carries two jobs at once.

**Composition.** Keep one page and one `h1`; do not split the route in this task. Reorder to
**active parameters → pending changes → end requests → audit trail**, and remove the free-floating
form from the top. The edit form moves into the selected row of the active table, reusing the
`kran-table__selected` expansion that already exists at `:661` and `:787` — no new component, no
modal, no drawer. A row action "Ubah" opens it with the key already bound, so the `Select` of all keys
disappears and the search box (`:732`) becomes the only way to find a key.

**States.**

| State | What the operator sees |
|---|---|
| neither permission | one honest explanation (exists, `:490-492`) |
| loading | `role="status"` line, sections keep their place |
| error | `Alert` + retry (exists, `:480-483`) |
| search matches nothing | in-table `EmptyState` naming the query + "Hapus pencarian" |
| active list empty | `EmptyState` + what creates the first parameter |
| row expanded | form inline: value, reason, effective-from, Simpan / Batal; `Esc` closes; focus returns to the row |
| submit success | positive `Alert` + the new row lands in pending, selected |
| submit conflict / validation | field-level message + summary above the form, focus to the first bad field (DESIGN §7) |
| audit empty | `EmptyState` (exists, `:853-854`) |
| realtime disconnected | the header badge already shows it (`:451-459`); see the a11y note below |
| dependency down | per-section error + retry, so a dead audit feed does not blank the parameters |

**One accessibility defect to fix while you are in the file.** The realtime strip is
`role="status" aria-live="polite"` on the whole `<p>` (`:448`) and it contains the last-updated clock
(`:458`). Every refresh re-announces the paragraph, including a time the operator does not need read
out. Move `aria-live` onto the badge only, and drop the time out of the live region.

**Out of scope.** Parameter grouping by domain, any change to the approval rules, the audit detail
screen.

---

## 4. Password — "Ganti kata sandi" (`apps/web/src/routes/app/password/+page.svelte`, 164 lines)

**One image:** a form you have to finish before the door opens. Nothing else on the page.

This screen is already the closest to right: shared components, no local CSS, forced-change notice
(`:114-116`), success state with a continue link (`:119-122`). Two repairs, both small.

1. **No repeat field.** `newPassword` (`:138-151`) is a single masked input. A typo here locks the
   operator out of the session they are in, on the one screen where they cannot do anything else.
   Add "Ulangi kata sandi baru" with `autocomplete="new-password"`, validated on submit, message on
   the repeat field only.
2. **No way to see what you typed.** Add one `Tampilkan` toggle controlling both password fields
   (`type="password"` ⇄ `type="text"`), labelled, `aria-pressed`, 32 px toolbar control next to the
   field label. Reason: operators type this on a shared desk keyboard; blind double-entry without a
   reveal costs a support call.

States already covered and to keep: forced notice, submitting (`:158`), error `Alert` (`:154`),
success + continue. Add: mismatch message on the repeat field, and success copy that names what
happened to other sessions (the script comment at `:6-8` says the server revokes them; the screen
must say so, not leave it to a comment).

**Out of scope.** Password policy rules, MFA, session management. Any change to the timing contract
(O-034, O-071) — this is an auth surface and Galih's checklist applies.

---

## Handoff (tokens and sizes, so nothing is guessed)

All values exist in `packages/ui/tokens/tokens.css`; do not add tokens.

- Page padding `22px 28px 36px`, max width 72 rem, two-column breakpoint 1100 px (DESIGN §4).
- Vault columns: form 480 px, gap `var(--space-6)` (32 px), queue fills the rest.
- Balance figure: `font-variant-numeric: tabular-nums slashed-zero`, 20 px / 600 (DESIGN §2).
- Section title: 13 px / 600, hairline `var(--color-hairline)` above, `var(--space-5)` (24 px) of
  air below the header.
- Controls 40 px, toolbar and in-row actions 32 px; radius `var(--radius-sm)` controls,
  `var(--radius-md)` panels; no shadow except the dialog rules in §5.
- Chips: `aria-pressed="true"` = accent-soft fill `var(--color-accent-soft)` + accent border
  `var(--color-accent-line)` + text `var(--color-text)`; count badge neutral, tabular.
- Active table cell (keyboard focus): 2 px accent bar on the left edge of the cell + `surface-2`
  background, plus a real `:focus-visible` ring. Filters never use the bar.
- Focus ring: 2 px accent, 2 px offset, contrast ≥ 3:1 against surface-raised, both themes (§10).
- Motion: 150 ms on expand/hover only; numbers never animate (§8).
- Copy: Indonesian, operator words. "Kas besar", not "vault"; "Saldo kas", not "balance"; no
  sentence that repeats the `h1`.

## Acceptance (each one can fail)

1. `rg -n 'role="grid"|aria-activedescendant' apps/web/src` stays at zero for the ledger table, and
   `.ledger-region` remains the single tab stop (T-294 part 2 unchanged).
2. Ledger: filtering to a category with zero rows shows an empty state with a working reset, and axe
   stays clean in both themes on that state.
3. Ledger: the period range appears exactly once in the DOM (grep the formatted date string).
4. Ledger: filter chips are inside `role="group"` with an accessible name, and every chip renders a
   count.
5. Vault: a read-only role sees a visible "Hanya baca" badge and a `disabled` submit whose reason is
   programmatically associated; no form that looks submittable.
6. Vault: with the balance endpoint failing, the queue still renders and each half shows its own
   retry.
7. Params: no free-floating submit form above the tables; the edit form opens from a row and `Esc`
   closes it with focus back on that row.
8. Params: the realtime clock is outside the live region; screen reader announces the badge, not the
   time.
9. Password: submitting two different new passwords shows the mismatch on the repeat field and posts
   nothing; the reveal toggle flips both fields.
10. All four: `./task check-fast`, `svelte-check --fail-on-warnings`, and the per-screen Playwright
    spec green, plus axe light and dark on every state listed above.
11. Keyboard-only pass per screen at 1366x768 and at 200% zoom, no horizontal scroll on the shell.

## Open

- O-1: whether the vault queue should default to "mine" or "all" for a supervisor. My default:
  "all pending", because the pilot has one supervisor per branch; change it if Sekar says otherwise.
- O-2: params `h1` still names two jobs. Splitting `/app/params` from `/app/audit` is a route change,
  not a repair, so it is out of T-241 and belongs in T-245 or a new task.
