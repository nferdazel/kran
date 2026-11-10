# App gate log - browser e2e (design system v2)

Owner: Sari (QA). One entry per `./task e2e` run, verbatim numbers. This is evidence, not a
verdict summary: a run that fails stays red here until a later entry shows it green.

Prerequisite: `./task devdb up` (tunnel to `kran_dev`). `./task e2e` builds the API binary,
resets the dev DB, runs expand + contract migrations, seeds, then runs Playwright with the
minimum-test guard (`KRAN_E2E_MIN_TESTS`, default 40).

Newest entry first.

---

## 2026-11-10 14:56-15:01 WIB - branch `feat/design-system-v2` @ `e93aa70`

Command: `./task devdb status` -> `./task build` -> `./task e2e` (foreground, run by Sari)
Result: **PASSED** (`ok: e2e green: 79 test`, exit 0, log `.build/e2e-gate-e93aa70.log`)

```
4 skipped
79 passed (4.7m)
```

0 failed, 0 did not run, 0 flaky. `devdb status` exit 0 (`kran_dev @ PostgreSQL 18.6`); the
tunnel was already up, no `devdb up` needed. `./task build` -> `ok: .build/bin/kran-api`. The
40-test minimum guard was satisfied. Skips are only `visual.spec.ts` (4, Linux-only baselines).

`e93aa70` adds one file on top of `7ef2c81`/`4db4090`: `apps/web/tests/e2e/shell-panel.spec.ts`,
the browser proof for T-285 acceptance item 2. 78 -> 79 passed is exactly that test.

### The new test

`apps/web/tests/e2e/shell-panel.spec.ts:86` - "panel off-canvas <1024px: trap Tab, Shift+Tab dan
Escape" - **PASS (980ms)**, inside `./task e2e` (not a side runner), viewport 390x844, real
logged-in session. Five assertions, all behaviour-bound:

1. load: `.shell__panel` hidden (visibility, so its links are not phantom tab stops),
   `[data-shell-menu-button]` visible with `aria-expanded="false"` and a non-empty accessible
   name, no scrim in DOM;
2. open: panel + scrim visible, `aria-expanded="true"`, `document.activeElement` is the panel's
   first focusable element;
3. Tab `N` times (N = panel focusable count): focus never leaves the panel on any step, and the
   last Tab wraps back to the first element;
4. Shift+Tab from the first element wraps to the last;
5. Escape: panel hidden, `aria-expanded="false"`, scrim gone, `document.activeElement` is
   exactly the menu button (`toBeFocused`).

Read line by line by Sari: no `skip`, no `.only`, no axe rule disabled, no threshold moved. If
the trap in `AppShell.svelte` is removed the spec goes red at step 3 (focus escapes the panel)
and step 5 (focus does not return to the button). Nadia reported a mutation check on her own
tree (handler removed -> 1 failed, then restored, `git diff packages/ui` empty); that check is
her evidence, not re-run by me here - this assignment forbids editing `packages/`/`apps/`.

### axe - 2 themes x 2 locales

29 axe-labelled tests, all PASS, **0 violations** - nothing to report as a K-ID. No `region`,
no `landmark-unique`, no other rule fired anywhere in the suite. Coverage held: `ledger`,
`dayclose`, `loans`, `lending-actions`, `teller`, `vault`, `screens`, `print`, `palette` loop
both themes x both locales; `password`, `/login` and `/app` cover both themes in one locale.

### Keyboard

In-suite: 14 keyboard tests PASS (`keyboard.spec.ts` x4, `dayclose` reload + history bounds,
`ledger` Tab in / arrows + Home/End / Tab out, `loans` list->detail->back, `lending-actions` pay
instalment, `palette` Ctrl+K open + Ctrl+K not stolen while typing, `screens` x4, `teller` open
session -> deposit -> close with zero difference), plus the new `shell-panel` trap test = 15.

Print: all three PASS - `print.spec.ts:202` slip, `:233` statement, `:264` print axe 2 themes x
2 locales.

### Keyboard runner (`keyboard-flows --config keyboard-app`) - still not a pass

```
gate-e93aa70: 5 flows -> 0 PASS, 0 FAIL, 5 BLOCKED
```

Unchanged and still proving nothing: every flow is BLOCKED on unwritten `TODO:` selectors
(`teller-deposit` K-01, `vault-approve` K-02, `close-cash` K-03, `drawer-open-close`,
`sidebar-offcanvas` - the last still lists `TODO:menu button in topbar (T-285)` even though the
in-suite Playwright spec above now covers that behaviour). It is a separate runner with its own
config, so this green run does not fill it in. Results: `.local/qa/results/gate-e93aa70.{json,md}`.

### `/app/*` render

Yes, without redirect. Logged-in sessions reached `/app`, `/app/dayclose`, `/app/ledger`,
`/app/loans`, `/app/users`, `/app/products`, `/app/ledger/admin`, `/app/accounts/open`,
`/app/password`, `/app/teller`, `/app/vault` and asserted page content there, not a login gate.
Also green: `zoom-125.spec.ts` x2 (1366x768 at 125% and 200%: no horizontal scroll, shell one
column, table still a table).

### Still not covered here - do not read this green as "everything passes"

1. axe at a real 360px viewport, and the `loading` / `empty` / `no-match` / `error` states -
   waits on T-292. Nothing above exercises them.
2. Drawer Escape focus-return and Tab trap (`drawer-focus-return`, `drawer-focus-trap`) - the
   app has no drawer yet (T-290). Still a hard requirement there.
3. axe with the off-canvas panel **open** - deliberately not added to keep runtime down, not
   weakened. The panel is a landmark and its content passed axe closed; the open state is not
   separately scanned.
4. 4 skipped visual regressions carry no signal on this OS.

---

## 2026-11-10 14:39-14:44 WIB - branch `feat/design-system-v2` @ `7ef2c81`

Command: `./task devdb status` -> `./task build` -> `./task e2e` (foreground, run by Sari)
Result: **PASSED** (`ok: e2e green: 78 test`, exit 0, log `.build/e2e-gate-7ef2c81.log`)

```
4 skipped
78 passed (5.0m)
```

0 failed, 0 did not run, 0 flaky. `devdb status` exit 0 (`kran_dev @ PostgreSQL 18.6`); tunnel
was already up, no `devdb up` needed. `./task build` -> `ok: .build/bin/kran-api`. The 40-test
minimum guard was satisfied. Skips are only `visual.spec.ts` (4) - Linux-only baselines, not a
pass.

`7ef2c81` is the fix unit for the three regressions recorded below (`329416f`): business date
back in `Topbar.svelte`, `.shell__panel` turned into `<aside aria-label>`, print stylesheet
hides the new chrome plus scoped print assertions.

### What the green run closes

| Red entry (`329416f`) | Now at `7ef2c81` |
|---|---|
| Business date indicator gone (4 failures) | `dayclose.spec.ts:83` axe id/light, id/dark, en/light, en/dark all PASS. The indicator is asserted, not just present: `.kran-business-date` visible, carries the locale label, and matches `/api/v1/dayclose/status` (real year, or "belum tersedia" when the API answers null) |
| Shell panel outside a landmark - axe `region` (16 failures) | 0 axe violations across the whole suite. `/app/ledger` 4 combos, `password` x2, `screens` x4, `teller`, `vault`, `loans`, `lending-actions`, `dayclose` x4, `/login` x2, `/app` after login x2 - all PASS |
| Print chrome not hidden (1 failure) | `print.spec.ts:202` slip PASS, `:233` statement PASS (this is one of the two that previously "did not run"), `:264` print axe 2 themes x 2 locales PASS |

### axe - 2 themes x 2 locales

29 axe-labelled tests, all PASS. Violation count 0, so there is no K-ID to report: no `region`,
no `landmark-unique`, and no other rule fired anywhere in the suite. Locale/theme coverage held:
where a spec loops both (ledger, dayclose, loans, lending, teller, vault, screens, print,
palette), both themes x both locales ran and passed; `password`, `/login` and `/app` cover both
themes in one locale.

### Keyboard (in-suite) - 14 tests, all PASS

`keyboard.spec.ts` x4 (skip link to #main, theme radio arrows, locale radio arrows, tab order
reaches every control in a logical order), `dayclose` reload + history bounds, `ledger` Tab in /
arrows + Home/End / Tab out, `loans` list->detail->back, `lending-actions` pay instalment,
`palette` Ctrl+K open + filter + Enter, `palette` Ctrl+K not stolen while typing in a field,
`screens` x4 (users role panel, products draft approval, ledger chart-of-accounts form, accounts
party picker), `teller` open session -> deposit -> close with zero difference.

### Keyboard runner (`keyboard-flows --config keyboard-app`) - still not a pass

```
keyboard-app: 5 flows -> 0 PASS, 0 FAIL, 5 BLOCKED
```

Every flow is BLOCKED on unwritten `TODO:` selectors, not skipped by choice:
`teller-deposit` (K-01), `vault-approve` (K-02), `close-cash` (K-03), `drawer-open-close`,
`sidebar-offcanvas` (`TODO:menu button in topbar (T-285)`, `TODO:sidebar nav (T-285)`).
This is the same 5-flow runner as before, and it still proves nothing.

### `/app/*` render

Yes, without redirect. Logged-in sessions reached `/app`, `/app/dayclose`, `/app/ledger`,
`/app/loans`, `/app/users`, `/app/products`, `/app/ledger/admin`, `/app/accounts/open`,
`/app/password`, `/app/teller` and `/app/vault` and asserted page content there, not a login
gate. Also green: `zoom-125.spec.ts` x2 (1366x768 at 125% and at 200%: no horizontal scroll,
shell one column, table still a table).

### Still not covered here - do not read this green as "everything passes"

1. axe at a real 360px viewport, and the `loading` / `empty` / `no-match` / `error` states -
   waits on T-292. Nothing above exercises them.
2. Drawer Escape focus-return and Tab trap (`drawer-focus-return`, `drawer-focus-trap`) - the
   app has no drawer yet (T-290). Still a hard requirement there.
3. Off-canvas sidebar trap/Escape/focus-return below 1024px - `AppShell.svelte` implements it
   (Escape, focus wrap, focus back to the menu button) but no test at any level covers it, and
   `packages/ui/tests/shell.test.ts` has no such case despite T-285's DoR listing one. T-285's
   acceptance item 2 therefore stays unproven.
4. 4 skipped visual regressions carry no signal on this OS.

---

## 2026-11-10 - branch `feat/design-system-v2` @ `329416f`

Command: `./task devdb status` -> `./task e2e`
Result: **FAILED** (`!! FAILED: e2e failed`, log `.build/e2e.log`)

```
21 failed
4 skipped
2 did not run
55 passed (4.7m)
```

`devdb status` exit 0 (`kran_dev @ PostgreSQL 18.6`). The 40-test minimum guard was satisfied
(55 passed) - the run is red because of the failures, not because specs silently skipped.

This is the first run in which the app shell actually rendered in a browser (`/app/*` behind a
real session + seeded dev DB). Skips are only `visual.spec.ts` (baseline is Linux-only).

### Root cause 1 - business date indicator gone from `/app/*` (4 failures)

`axe: /app/dayclose id/light, id/dark, en/light, en/dark` all stop at
`dayclose.spec.ts:93`:

```
Locator: locator('.kran-business-date')
Expected: visible
Error: element(s) not found
```

`main`'s root layout rendered the indicator from `page.data.businessDate` (spec section 14.3).
The new `/app` shell (`AppShell` + `Topbar`) receives no business-date value at all and
`packages/ui/src/components/Topbar.svelte` has no `.kran-business-date` node, so every `/app`
screen lost the indicator. Product regression, not test fragility.

### Root cause 2 - shell panel content outside any landmark (16 failures)

`region` (moderate, blocking per D-166/T-149): "Some page content is not contained by
landmarks". Nodes, identical on every failing screen:

- `.sidebar__brand` (title + subtitle)
- `.sidebar-user` ("Masuk sebagai ...")
- `a[href$="/app/password"]` (Ganti kata sandi)

They are siblings of `<nav class="sidebar__nav">` inside `<div class="shell__panel">`, which is
plain `<div>` and therefore not a landmark. On `main` the brand sat inside `<nav class="kran-nav">`.

Failing specs (16): `flow` x2, `ledger` x4, `lending-actions` x1, `loans` x1, `password` x2,
`screens` x4 (`/app/users`, `/app/products`, `/app/ledger/admin`, `/app/accounts/open`),
`teller` x1, `vault` x1.

### Root cause 3 - print chrome not hidden by the print stylesheet (1 failure)

`print.spec.ts:202` "slip: dokumen tampil, Cetak dipanggil, nav/toolbar hilang saat print":

```
Error: strict mode violation: locator('nav') resolved to 2 elements
  1) <nav aria-label="Navigasi utama" class="sidebar__nav">
  2) <nav aria-label="Jejak navigasi" class="topbar__crumbs">
```

Two things are wrong here, and only the first is cosmetic to the test:

1. The assertion is unscoped: it assumed one `<nav>`. It now matches the sidebar nav and the
   breadcrumb nav.
2. `packages/ui/src/components.css` `@media print` still hides only the old class names
   (`.kran-nav`, `.kran-header`, `.kran-toolbar`, `.kran-skip-link`). The new shell uses
   `.shell`, `.shell__panel`, `.topbar`, `.sidebar__nav`, so the sidebar and topbar would print
   even after the locator is scoped. The acceptance ("nav/toolbar hilang saat print") is
   genuinely broken.

### Not reproduced - the two mockup keyboard failures

The mockup baseline (`EXIT-CRITERIA.md` section 4) has 2 FAILs: Escape does not return focus to
the drawer trigger, and Tab leaves the panel despite `aria-modal="true"`. They do **not**
reproduce in the app, because there is no drawer in the app yet (T-290). Everything else in the
app keyboard suite passed: `keyboard.spec.ts` x4 (skip link, theme radio, locale radio, tab
order), plus the keyboard-only flows for ledger, loans detail, lending actions, teller and the
four screen flows.

### Status

Gate app stays **RED**. T-285 (shell) is not done: three acceptance items are now provably
failing in a real browser, so evidence for it must carry this list instead of "lulus".
