# T-241-login - Sign-in screen: design direction

Phase: P6 · Size: S · Risk: full (authz) · Status: APPROVED (direction accepted 2026-11-11; implementation not started)

Carved out of T-241 on 2026-11-11 by Raka: this file covers the sign-in screen only. The other
repair screens stay in T-241. No implementation starts until the direction below is approved.

Status is `APPROVED` as of 2026-11-11. The artifact this task owes is the direction, not a diff. The
implementation task opens only after approval, and it inherits the acceptance list at the bottom.

## Approval (2026-11-11, Raka)

Direction accepted as written, with these decisions:

- **OPEN-1 approved.** `login_error_unreachable` may be added to both catalogs for the
  dependency-down state. The 401, 403 and MFA copy stays exactly as it is; the new key only
  replaces `error_generic` on network and 5xx failures.
- **OPEN-2 approved.** `login-light.png` and `login-dark.png` may be regenerated inside the
  implementation task and no other snapshot. Evidence lists both PNGs, and I review the diff
  before the push.
- `login_intro` stays as it is. No copy churn beyond removing `login_subtitle` and the duplicated
  brand line.
- The shared `--public` row fix is in scope; `+error.svelte` gets one screenshot check.
- OPEN-3 stays open and out of scope.

Implementation is separate work, queued behind T-236. This is an auth surface, so it passes
Galih's checklist before it merges, and I own the push.

Queue value: `full (authz)` because this screen is the only surface where the 401 / 403 / MFA
timing contract (O-034, O-071) is observable by an unauthenticated person. The layout work must not
move that behaviour by one message; a clean-context reviewer confirms it. Raka may downgrade this to
`standard (general)` if he judges the diff too small to matter.

## Design read

Reading this as: an institutional sign-in for tellers and admins at a 1366x768 desk, in KRAN's
calm-work-tool visual language (DESIGN §1), dial ENERGY 1 / RHYTHM 1 / MOTION 1.

One image for the whole screen: **a door, not a page.** The operator sees the building's nameplate,
one open doorway with two fields in it, and nothing else asking for attention. Everything the screen
needs to say fits in three lines and one plane; the rest of the canvas stays empty because the work
behind it has not started yet.

## Why the current screen reads as leftover material

Open facts, read from source at `98e50ec` and `7f8a92a`:

1. `apps/web/src/routes/+layout.svelte:109-113` already renders the product name in the public
   header, `common_app_title` ("KRAN — Sistem Koperasi & Bank"), right above the page. The page then
   prints `common_brand_short` ("KRAN") again at `login/+page.svelte:144`. Two product names sit
   about 40 px apart.
2. The page prints three nearly identical sentences in a row: `login_title` ("Masuk"),
   `login_intro` ("Gunakan akun kerja Anda..."), and `login_subtitle` ("Institutional operator
   session authentication"). The third is internal vocabulary on screen, which DESIGN §9 forbids
   ("istilah internal tidak tampil ke operator").
3. Nothing bounds the form. `.kran-page` is a 42 rem column with no surface, sitting directly under
   the header. The eye finds no doorway and no edge, so the form looks like an ordinary content
   page that happens to have a password field.
4. The public shell has a sizing bug that makes this worse. `.kran-shell` declares four rows
   (`components.css:43`, `grid-template-rows: auto auto 1fr auto`) but the public layout renders
   three children: header, `main`, footer. The `1fr` row therefore lands on the footer, so the
   footer stretches to fill the screen and `main` keeps only its content height. The form is glued
   under the header, and a tall surface-coloured block sits under it. This affects `/login` and
   `+error.svelte` alike.
5. The only coloured element on the screen today is a 40 px plum button at the end of two
   full-width fields, and it is not even full width, so the screen has no focal point.

None of this is a polish problem. Point 4 is a layout defect, points 1 and 2 are copy that
contradicts DESIGN §9, and point 3 is the missing composition.

## Composition

Three elements, one axis, one plane. Everything is left-aligned on a single vertical line; nothing
is centred inside the column.

```
1440 x 900 (public frame comes from +layout.svelte)

+------------------------------------------------------------------+
| [header 52px]  KRAN - Sistem Koperasi & Bank          (surface)   |
+------------------------------------------------------------------+
|                                                                  |
|                    +--- plane 400px ---+                         |
|                    |                   |                         |
|                    |  Masuk            |  h1 22px / 600          |
|                    |  Gunakan akun ... |  13px muted, max 2 baris |
|                    |                   |                         |
|                    |  Nama pengguna    |  label 14px / 500       |
|                    |  [_____________]  |  field 40px             |
|                    |                   |                         |
|                    |  Kata sandi       |                          |
|                    |  [_____________]  |                          |
|                    |  -----------------|--- hairline              |
|                    |  [   Masuk      ] |  primary 40px, full     |
|                    +-------------------+  width, plum            |
|                                                                  |
+------------------------------------------------------------------+
| [footer 44px]  tema / bahasa                            (surface) |
+------------------------------------------------------------------+
```

Wait: the h1 and the intro sit **on the canvas**, above the plane, not inside it. That is the one
composition decision worth arguing. If the title sits inside the plane, the screen becomes a card
with a heading, which is the generic sign-in of every SaaS product, and it also forces the error
alert and the MFA prompt to compete for the same box. With the title outside, the plane holds
exactly one thing: the thing the operator types into.

The plane itself:

```
.kran-signin__plane            <- proposed class name, see handoff
  background   var(--color-surface-raised)
  border       1px solid var(--color-hairline)
  border-radius var(--radius-md)      6px
  box-shadow   none                   DESIGN §5: flat cards, shadow is for overlays only
  padding      var(--space-5)        24px
```

Before / after shape:

```
BEFORE                                AFTER
brand (muted p)                       [canvas] h1 + one intro line
h1                                    [plane]  fields
intro (muted)                              hairline
subtitle (jargon)                          primary action
[field]
[field]
[primary 143px wide]
```

## Measurements

| Element | Value | Token / reason |
|---|---|---|
| Column width | 400 px, `inline-size: 100%` | two fields at 14 px never need more; wider makes the eye travel |
| Column position | horizontally centred, vertically centred in `main` while it fits | a door is centred in its wall; when it does not fit (short viewport, 200% zoom) top-align with 32 px |
| Gap title to plane | 24 px | `--space-5` |
| h1 | 22 px / 600 / line-height 1.2 | `--text-xl`, only page h1size in DESIGN §2 |
| Intro | 13 px muted, max 2 lines | `--text-sm`, `--color-text-muted` matches `kran-page-header__intro` |
| Label inside plane | 14 px / 500 | DESIGN §2: login uses 14 px |
| Field | 40 px high, radius 4, border 1 px `--color-border` | `--control-height-primary`, `--radius-sm` |
| Field gap | 16 px | `--space-4` |
| Divider above action | 1 px `--color-hairline`, 16 px above the button | echoes the same hairline that rules a ledger row |
| Primary button | 40 px high, full column width | single action, no ambiguity about where the form ends |
| Plane padding | 24 px, 16 px below 640 px | `--space-5` / `--space-4` |
| Screen inset (≤640) | 16 px each side | `--space-4`; plane drops its border and radius and sits flush on canvas |
| Footer | hugs its content, never stretches | see defect 4 |

## Typography and colour

One family (IBM Plex Sans, already loaded), no mono, no uppercase labels, no letter-spacing tricks.
The screen carries **one accent colour**: the plum primary button, which is the single focal point.
Everything else is `--color-text`, `--color-text-muted`, `--color-hairline`, `--color-border`. The
error alert is the only other colour and it is semantic (`--color-danger` + `--color-danger-tint`),
so it does not compete with the accent for "the important thing".

Both themes come from tokens with no local override. Dark mode is not a separate design.

## States

Every state below is part of the design, not an afterthought. Nothing here changes the auth logic;
it changes what the operator sees while that logic runs.

### 1. Empty (first visit)

Two empty fields, no alert, no hint text, button enabled. Labels are permanent (`<label for>`), never
placeholders. Autofocus on the username field only when the page is opened with no error and the
browser is idle: `autofocus` is acceptable here because the screen has exactly one job, and the skip
link still precedes it.

### 2. Filled, untouched

No validation on blur. A wrong password is not "this field is invalid"; the field-level error style
(`aria-invalid`) is reserved for an empty required field submitted with Enter.

### 3. Submitting (loading)

`submitting` is true for the duration of the request. Button: native `disabled`, plum replaced by
`--color-surface-disabled`, label swaps to `login_submitting` ("Memproses..."). Fields stay enabled
and focused, because disabling them would move focus and lose the caret. A second submit is already
guarded in the handler; the visual must agree with that guard, which it does.

No spinner. DESIGN §8: 150-200 ms transitions for non-number UI and nothing that shifts layout. A
label swap inside a fixed-width button is enough feedback for a request that usually returns in
under 300 ms.

### 4. Error: wrong credentials (401)

Plane gets an `Alert tone="negative"` as its first child, above the fields, **inside** the plane.
Copy is `login_error`: "Tidak dapat masuk dengan akun ini." It must not reveal whether the account
exists. Focus moves to the password field, the username is kept, the password is kept so a typo can
be corrected instead of retyped, and the button stays enabled.

Why inside the plane and not above the h1: DESIGN §7 wants the summary above the form, and the
plane **is** the form. An alert floating between the title and the plane reads as a page-level
notification, which is what a session-timeout message would be, not a login failure.

### 5. Error: account locked or inactive (403 after a correct password)

Same position, copy from `login_locked` or `login_inactive`. No focus move, because there is no
field to fix and stealing focus from the password field would hide the message behind the caret.
The button stays enabled: the lock expires. O-034 stays as it is: this message may only ever appear
after the password was verified.

### 6. MFA required (403 `mfa_required`)

The same plane, the same width, the same h1. The two fields are replaced in place by one field:

```
+--- plane 400px -----------------+
|  Masukkan kode dari aplikasi     |  login_mfa_prompt, 13px muted
|  autentikator untuk ...          |
|                                  |
|  Kode autentikasi                |
|  [__________________________]    |  40px, inputmode numeric,
|  --------------------------------|  autocomplete=one-time-code
|  [      Verifikasi kode       ]  |
+----------------------------------+
```

Focus moves to the code field on transition, so a keyboard-only operator is already where they need
to be. The screen does not navigate, because the half session is a cookie and a route change would
add nothing but a back button that cannot work. The username is not echoed back: the half session
already identifies the operator, and printing it invites shoulder-surfing in an open office.

Known dead end, written down rather than designed around: there is no "use another account" action,
so an operator who reached MFA cannot switch accounts without clearing cookies. Adding one means a
new i18n key and a decision about the half session cookie, so it is **out of scope** here and listed
as OPEN-3.

### 7. Error: wrong MFA code

`login_mfa_invalid` in the same alert position. Focus returns to the code field with the value
selected, so typing replaces it. Copy already names the cause (device clock) and the next action.

### 8. Dependency down (server unreachable, proxy dead, 5xx)

This is the state the screen never shows today: the catch block sets `error_generic` and nothing
else, so a dead server and a wrong password differ only by wording. What the operator sees:

- the same alert position, tone `negative`, form values intact
- one sentence that names the cause and the next step, in operator language, not "Something went
  wrong": `login_error_unreachable`, "Server KRAN tidak menjawab. Periksa jaringan kantor, lalu coba
  lagi." (new key, OPEN-1)
- button enabled, no auto-retry, no countdown, nothing that spins
- no toast: DESIGN §8 forbids an error that disappears on its own

When the request simply takes long (over 2 s, no failure yet), nothing else changes. There is no
skeleton, because there is no content to skeleton; a skeleton here would be a lie about data
arriving.

### 9. Success

Leaves the screen. `continueToApp` already routes by permission; the design adds nothing and shows
no "welcome" flash. A redirect that renders no intermediate frame is the correct transition.

### 10. Empty data

Not applicable, and worth stating: this screen has no collection, so there is no empty state and no
"no data" illustration. The honest empty state here is the empty form in state 1.

## Copy

Keep in the page: `login_title`, `login_intro`, `login_username_label`, `login_password_label`,
`login_submit`, `login_submitting`, `login_mfa_prompt`, `login_mfa_code_label`,
`login_mfa_submit`, `login_mfa_invalid`, `login_error`, `login_locked`, `login_inactive`.

Remove from the page:

- `common_brand_short` (line 144): the public header above already says the product name.
- `login_subtitle` (line 147): "Institutional operator session authentication" is internal
  vocabulary, and it is the third sentence saying the same thing.

`login_subtitle` then has no caller, and `tools/i18ncheck/lib.nim:264` fails on orphans ("key ...
tidak dipakai"), so the same commit must delete the key from `packages/i18n/messages/id.json` and
`en.json`. `common_brand_short` stays in the catalog: it is still used elsewhere.

Optional, needs Raka's call: shorten `login_intro` to one clause. Current Indonesian is "Gunakan
akun kerja Anda untuk mengakses back-office KRAN." Suggested: "Gunakan akun kerja Anda." The word
"back-office" is tolerated by DESIGN §9 (it is what the operator calls it) but the sentence is
longer than it needs to be for a screen that already says "Masuk" above it. Not required for the
layout to work.

## Accessibility contract

- One `h1` per page (`login_title`), `main#main` from the layout, skip link from the layout.
- DOM order equals visual order: title, intro, fields, action, then the layout footer with theme and
  language. The footer controls stay after the content, per DESIGN §10.
- Tab path: username, password, submit, then footer controls. Enter in either field submits. Esc
  does nothing on this screen (no dialog to close), and the design does not invent one.
- Visible focus: `:focus-visible` 2 px `--color-focus-ring` with 2 px offset, on every field and the
  button, in both themes. No `outline: none` anywhere.
- Alerts: `role="alert"` from the Alert component for `negative`, so a failed sign-in is announced
  once, without a live region of our own.
- Contrast: every pair is already in DESIGN §3. The one pair that needs re-checking is muted text on
  `--color-surface-raised` in dark mode (`#98A0A8` on `#212529`): measured once during
  implementation, not assumed.
- 200 % zoom: single column, no horizontal scroll, the plane drops its border below 640 px and the
  field labels wrap rather than clip.

## Anti-slop decisions and their reasons

| Decision | Reason (one line) |
|---|---|
| No card shadow, no gradient, no illustration | The screen is a door into a ledger tool; decoration would promise something the product does not do. |
| Title outside the plane | A heading inside a box makes it the generic SaaS sign-in and forces errors to fight the title for the same box. |
| One accent, only on the button | The button is the single decision on the screen; anywhere else the plum would stop meaning "act here". |
| No "lupa kata sandi" / "ingat saya" / SSO links | None of those features exist; a link with no destination is forbidden (R-26, R-24) and costs trust at the worst moment. |
| No drawn logo | DESIGN §13.14 and §1: the product name is set in type, not drawn. |
| No spinner, no pulse | MOTION 1, and DESIGN §8 forbids endless motion which eyeballs read as "still working" forever. |
| Left-aligned everything | Two labels of different lengths stay on one axis; centred type in a narrow column reads as a poster. |
| No dashed borders, no "no data" art | There is no data on this screen, so there is nothing to be empty. |
| Error inside the plane, below the title | DESIGN §7: the summary belongs above the form, and the plane is the form. |

## Scope

In scope for the implementation that follows approval:

- `apps/web/src/routes/login/+page.svelte`: composition, `<Input>`, `<Alert>` placement, focus
  policy, removal of the two copy lines.
- `packages/ui/src/components.css`: one new `.kran-signin` block for the column and plane, and the
  `--public` row fix so `main` takes the free space and the footer hugs its content.
- `packages/i18n/messages/{id,en}.json`: remove `login_subtitle`.
- Tests: `apps/web/tests/e2e/a11y.spec.ts` (explicit 1440 and 360 widths for the login axe run),
  `apps/web/tests/e2e/screens.spec.ts` or a new focused case for the error and MFA states, and the
  visual baseline for `/login`.

Explicitly out of scope:

- The auth flow itself: request shape, 401/403 timing, MFA cookie, redirect target. Untouched.
- MFA enrolment, password reset, SSO, remember-me, PIN login. No such feature exists; each needs its
  own task and its own copy.
- Every other public screen, except that the `--public` row fix is shared with `+error.svelte` and
  must be checked there in one screenshot.
- `visual.spec.ts` and its snapshots stay untouched until Raka approves the regeneration, because
  `login-light.png` and `login-dark.png` will legitimately change (OPEN-2).
- No API, no contract, no schema, no `apps/api`.

## Acceptance

Each item is written so it can fail on today's code. Implementation must prove each with a command
or a measured value, not a sentence.

1. **Frame.** At 1440x900 and 1366x768 the footer measures under 96 px and `main` fills the remaining
   height. Today the footer swallows the leftover space (`components.css:43` against three
   children). Fails today by measuring the footer box.
2. **Composition.** The plane is horizontally centred within 1 px at 1440, and the vertical gap
   above it equals the gap below plus or minus 8 px. Below 640 px the plane is flush (border 0,
   radius 0) with 16 px screen inset, and `document.scrollWidth === document.documentElement.clientWidth`
   at 360.
3. **One h1, no duplicated brand.** `h1` count is 1 on the page, `common_brand_short` and
   `login_subtitle` render nowhere on `/login`, and `./task check-fast` passes i18n with
   `login_subtitle` gone from both catalogs.
4. **Nothing local.** `grep -c "<style" apps/web/src/routes/login/+page.svelte` is 0; every rule used
   lives in `packages/ui`.
5. **Keyboard-only.** Tab from a fresh load reaches the username, the password, the button, in that
   order, with a visible ring on each; Enter submits from either field; the whole flow completes
   without a pointer.
6. **401.** With a wrong password, the alert is visible inside the plane, `document.activeElement`
   is the password input, the username is still there, and the copy is exactly `login_error`.
7. **403.** A locked account shows `login_locked` and the focus does not move. The message appears
   only after a correct password.
8. **MFA.** After a correct password on an MFA account, the plane shows one code field, the h1 is
   unchanged, focus is on the code field, and the column width changes by less than 4 px.
9. **MFA invalid.** A wrong code shows `login_mfa_invalid`, keeps the typed value selected, and
   leaves focus in the code field.
10. **Dependency down.** With the API blocked at the network level, the operator sees one alert with
    the unreachable copy, the button enabled and the typed values intact; no element animates.
11. **axe.** 0 blocking violations on `/login` at 1440x900 and 360x800, light and dark, `id` and
    `en`, with the widths set explicitly by `page.setViewportSize` (the lesson from T-291).
12. **Print and zoom.** Zoom 200 % keeps one column with no horizontal scroll; the screen is not a
    print surface, and printing it is not part of acceptance.

## Evidence

```
- Gate: design review only, no code (see Status).
- Gates to run at implementation: ./task check-fast; pnpm --filter @kran/ui test;
  svelte-check packages/ui; ./task e2e (axe on /login at 1440 and 360).
- Visual: login-light.png / login-dark.png must be regenerated with explicit approval (OPEN-2).
- Commit range: none yet.
- Capability row: none changes. Sign-in capability is already delivered.
- Human review: required at implementation (authz surface), Raka owns the direction approval.
```

## Handoff (for Nadia, after approval)

Files and rules, in the order I would build them:

1. `packages/ui/src/components.css`: add `.kran-shell--public { grid-template-rows: auto 1fr auto; }`
   next to the existing `.kran-shell` rule, with a comment saying the public layout renders three
   children. Then one `.kran-signin` block:

```
.kran-signin            column: inline-size 100%, max-inline-size 25rem, margin-inline auto,
                        display grid, gap var(--space-5)
.kran-signin__head      display grid, gap var(--space-1)   (h1 + intro, on canvas)
.kran-signin__plane     surface-raised, 1px hairline, radius-md, padding var(--space-5),
                        display grid, gap var(--space-4), font-size var(--text-md)
.kran-signin__actions   border-block-start 1px hairline, padding-block-start var(--space-4)
.kran-signin__actions .kran-button { inline-size: 100% }
@media (width <= 639.98px)  plane: border 0, radius 0, padding var(--space-4);
                            column: top-aligned with var(--space-6) instead of centred
```

2. `login/+page.svelte`: drop the brand paragraph and `login_subtitle`, wrap the content in
   `.kran-signin`, move the title and intro into `.kran-signin__head`, put the Alert as the plane's
   first child, use `<Input>` and `<Button variant="primary">` from `@kran/ui`. The page keeps zero
   local CSS.
3. Focus policy in the submit handlers: `#login-password` on 401, `#login-mfa-code` with
   `select()` on MFA entry and on an invalid code, no move on 403. Nothing else in the handlers
   changes.
4. i18n: delete `login_subtitle` from both catalogs; add `login_error_unreachable` if OPEN-1 is
   approved.
5. Tests and the visual baseline per the acceptance list.

Do not: restyle `Input`, `Button` or `Alert` themselves, change `.kran-page` (the error page still
uses it), or add a second accent colour.

## Delivery Gate (antislop, spec level)

This artifact is a direction, not a running screen, so R-35 (run and click every control) is owed by
the implementation and cannot be claimed here.

```
Block 1 Hard Gate      PASS  no fabricated data, no invented logo or testimonial, no dead control
                             designed in (no forgot-password link), no tag-key claims; contrast
                             pairs taken from DESIGN §3 with one pair flagged for re-measurement
Block 2 Purpose-Gate   PASS  every technique in the table carries a one-line reason; no technique
                             is used as a default (no shadow, no gradient, no glass, no glow)
Block 3 Liveliness     PASS  dials stated (1/1/1) and derived from DESIGN §1; one focal point;
                             one accent; the identity motif is the hairline plane on the canvas
Block 4 Craft & Locks  PASS  R-11 radius from the token set, R-20 identity argued from the product,
                             R-21 both themes by token, R-29 one accent, R-31 reasons tabled;
                             R-35 FAIL-UNTIL-BUILT, owed by the implementation task
```

## Notes

Assumptions I am making, each reversible by one word from Raka:

- Vertical centring (`main` takes the free space) is worth the shared `--public` change, because the
  error page has the same shape and the same flaw.
- The plane is flat with a hairline and no shadow: DESIGN §5 says shadow belongs to overlays, and
  this plane is not floating over anything.
- 400 px is the column width. 448 px would still look right; 400 px matches the form's needs and
  keeps 360 px comfortable.

Open items:

- **OPEN-1 (closed 2026-11-11).** `login_error_unreachable` for the dependency-down state is
  approved; the implementation adds it to both catalogs. Without it the screen would keep reusing
  `error_generic`, which does not tell the operator whether to retype their password or call the
  network desk.
- **OPEN-2 (closed 2026-11-11).** `apps/web/tests/e2e/visual.spec.ts` owns `login-light.png` and
  `login-dark.png`. This design changes them by definition. Regeneration is approved for those two
  files only, inside the implementation task, with both PNGs named in Evidence.
- **OPEN-3 (dead end after MFA).** No "use another account" action exists. An operator who lands on
  MFA cannot switch accounts without clearing cookies. Fixing it needs a new key and a decision about
  the half cookie. Not this task.
- **OPEN-4 (a11y coverage).** `apps/web/tests/e2e/a11y.spec.ts` reaches the public screens through
  `/`, not by naming `/login`, and sets no viewport. Item 11 fixes both; until it lands, the sign-in
  screen has axe coverage only at the desktop default.
