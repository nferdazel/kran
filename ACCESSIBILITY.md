# Accessibility

KRAN is back-office software used by cooperative and bank staff for long shifts of data entry. The
target is **WCAG 2.2 level AA**, in both themes (`light` and `dark`), in both UI languages
(`id` and `en`), with the critical flows usable from the keyboard alone.

This is a target with a tested gate, not a certification. We do not claim full WCAG 2.2 AA
conformance for every screen; the enforced checks and the known gaps are listed below.

## What is enforced

| Concern | Where it is checked | What it proves |
|---|---|---|
| Colour contrast | `./task e2e` → vitest in [`packages/ui`](packages/ui) | the semantic token pairs from [`DESIGN.md`](DESIGN.md) §3 meet their thresholds in light and dark |
| Component semantics | `./task e2e` → `svelte-check --fail-on-warnings` | Svelte `a11y_*` diagnostics are errors, not warnings (D-053) |
| Automated rules | `./task e2e` → Playwright + axe | no axe violation of `moderate`, `serious`, or `critical` impact on covered routes, for 2 themes × 2 locales (D-166) |
| Keyboard | `./task e2e` → Playwright | skip link, tab order, theme/language controls after content, login, maker-checker parameter flow, vault submit/approve, admin screens, and the day-close monitor work without a mouse |
| Layout and zoom | `./task e2e` → Playwright | no horizontal page scroll at 125% zoom; the ledger keeps a labelled scroll region with a sticky code column; `/app/vault` works at 390 px |
| Text and translation | `./task check` → [`tools/i18ncheck`](tools/i18ncheck) | every message key exists in both `id` and `en` with consistent placeholders, and obvious hardcoded strings in components are rejected |
| Continuous integration | `.github/workflows/ci.yml`, job `web-e2e` | the gates above run with a real Postgres, so specs that need data do not silently skip (D-179) |

`./task e2e` refuses to run without `KRAN_DATABASE_URL` unless you explicitly set
`KRAN_ALLOW_NO_DB=1`; a run that skips database-backed specs is not evidence. The binding UI rules
are in [`DESIGN.md`](DESIGN.md) §10: visible focus with at least
3:1 contrast, DOM order equal to visual order, one `h1` per page, no `tabindex > 0`, no
`outline: none`, and no colour-only status.

## Known limits

These are real and recorded in [`docs/ACCEPTED-LIMITS.md`](docs/ACCEPTED-LIMITS.md); they are not
covered by a passing gate:

- **The mobile gate covers one screen.** The 390 px viewport test runs only on `/app/vault`.
  Teller, ledger, print, and account-opening screens have not been proven usable on a phone; they
  are reviewed manually (LED-7).
- **`/app/ledger` takes "today" from the browser**, not from the session's business date. On a
  device whose timezone differs from the branch's business date, the period preselection can be
  wrong even though the shell shows the correct business date (UI-7).
- **Switching language remounts the page subtree** (`{#key locale}`). Text in a form that is being
  filled in is lost when the language is changed (UI-8).
- **axe only covers routes that have a Playwright spec.** A screen without a spec has no automated
  accessibility evidence, even if it uses the same shared components.
- **`minor`-impact axe violations do not block** (D-166). They are reviewed case by case rather
  than silently ignored.
- **The visual direction v2 is being migrated screen by screen** (`DESIGN.md` §12). A screen still
  on v1 tokens is a known transition; the accessibility gate applies to it regardless. New
  deviations are review failures.
- **Printing uses the browser** (`@media print` + `window.print`), not a server-side PDF. Layout
  varies by browser and printer, and browser headers/footers cannot be suppressed with CSS
  (ACCEPTED-LIMITS §4b).

## Reporting a barrier

Accessibility barriers are bugs. Open an issue with the
[bug report form](https://github.com/nferdazel/kran/issues/new?template=bug_report.yml) and put
`[a11y]` at the start of the title. Include:

- the route or screen, and the action that hits the barrier;
- theme (`light`/`dark`), language (`id`/`en`), browser, and assistive technology if used;
- what happens, and what should happen instead;
- whether the affected flow is blocked entirely or only made harder.

If the problem is also a security issue (for example, data is exposed to the wrong user), follow
[`SECURITY.md`](SECURITY.md) instead of opening a public issue.
