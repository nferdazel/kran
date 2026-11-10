# App gate log - browser e2e (design system v2)

Owner: Sari (QA). One entry per `./task e2e` run, verbatim numbers. This is evidence, not a
verdict summary: a run that fails stays red here until a later entry shows it green.

Prerequisite: `./task devdb up` (tunnel to `kran_dev`). `./task e2e` builds the API binary,
resets the dev DB, runs expand + contract migrations, seeds, then runs Playwright with the
minimum-test guard (`KRAN_E2E_MIN_TESTS`, default 40).

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
