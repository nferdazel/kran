# Manual exploration checklist

Owner: Tio (QA Tester). This is the hands-on pass that sits beside the scripted gate
(`a11y-matrix.mjs`, `keyboard-flows.mjs`): click every element, watch the console, try the edge
cases the scripts do not cover. Scripts prove selectors; this proves the screen is usable.

Two targets, and they prove different things:

- **Mockup** — `.local/redesign/mockup/index.html` (self-contained, `file://`, gitignored).
  Proves layout, keyboard order and markup. Runs today, no session needed.
- **App** — `apps/web` under `/app/*`. Needs a session plus seed fixture. Until that exists every
  item below is **BLOCKED**, not passed.

## Part A - mockup pass

Run: open the mockup file, then work through the list. Record PASS/FAIL and what you saw.

| # | Check | Result 2026-11-10 |
|---|---|---|
| A1 | One nav item is `aria-current="page"`, and it is the current route | PASS - exactly one (`Saldo buku besar`) |
| A2 | Sidebar 240px, links reachable by Tab in DOM order | PASS - 5 links, 184x27 each |
| A3 | The mockup has no skip link; it starts at the width control | NOTE - mockup cannot verify the skip link, app only |
| A4 | 360 width: sidebar off-canvas, no horizontal page overflow | PASS - sidebar `display:none`, 0 overflowing elements, table scrolls inside its own box (1004 vs 324) |
| A5 | Menu button opens the panel at 360 | FAIL - decorative only: no click handler, no `aria-expanded`, panel stays `display:none`. Cannot verify off-canvas behaviour from the mockup at all |
| A6 | Drawer opens from the row button, heading focused | PARTIAL - drawer opens, focus does enter it, but lands on the container, not the heading |
| A7 | Tab stays inside the open drawer | **FAIL** - 3 focusables, 4th Tab lands on a `<summary>` outside the drawer while `aria-modal="true"` is set |
| A8 | Esc closes the drawer and returns focus to the opening row button | **FAIL** - drawer closes, focus ends up on the outside `summary`, never on the trigger |
| A9 | Login screen renders without shell chrome | PASS - no sidebar, no topbar in the login stage |
| A10 | Login inputs have labels and `autocomplete` | PASS - username / current-password |
| A11 | Login error is announced | PASS - `role="alert"` |
| A12 | Money: currency named once per column, no per-cell symbol | PASS - `(IDR)` in headers, 0 cells containing "Rp" |
| A13 | Console clean while clicking every control | PASS - 0 errors, 0 unhandled rejections across theme, width and drawer controls |
| A14 | Three empty states (no-data / no-match / denied) are distinguishable | BLOCKED - mockup ships no empty state; that is T-292 |
| A15 | Terminology matches DOMAIN.md (Kas besar / Kasir) | **FAIL** - 4 "Teller" on screen, 0 "Kasir", 0 "Kas besar". Matches Rina's finding; goes to T-292 |

A7 and A8 are the same two failures Sari's `keyboard-flows --config keyboard-mockup` reports
(`drawer-focus-return`, `drawer-focus-trap`). Two independent methods, same result: this is a real
defect of the drawer spec, not a flake.

Measurement note: the mockup stage is scaled, so computed pixel widths inside it are not design
values (a 520px drawer measures 445). Judge width from the CSS, not the box.

## Part B - app pass (BLOCKED until a session + seed fixture exists)

Every item needs one of: a headless login fixture, or a dev env with ephemeral Postgres seeded
once. Without it `/app/*` redirects to `/login` and there is no screen to click.

| # | Check | Status |
|---|---|---|
| B1 | Skip link is the first Tab stop and jumps to `#main` | BLOCKED |
| B2 | Sidebar 240px: exactly one `aria-current="page"`, hover uses surface-2 only | BLOCKED |
| B3 | <1024: open/close by keyboard, Esc returns focus to the menu button, Tab does not leak behind | BLOCKED |
| B4 | Topbar 56px, breadcrumb matches the route | BLOCKED |
| B5 | `/login` and `/app/print/*` render without shell chrome (the easiest regression to miss) | BLOCKED |
| B6 | Console clean and zero failed requests on every route | BLOCKED |
| B7 | Empty / loading / error per screen, three empties phrased differently | BLOCKED |
| B8 | Money columns keep one symbol per column at every width | BLOCKED |

## Handoff note

The mockup lives in `.local/redesign/` and is gitignored. It is the only renderable artifact for
this design, so a fresh clone cannot repeat Part A. Tracked here are the checks and their results;
the artifact itself is still disk-only.
