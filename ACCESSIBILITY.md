# Accessibility

KRAN targets **WCAG 2.2 level AA** in both themes (`light`, `dark`), both UI languages (`id`, `en`),
with the critical flows usable from the keyboard alone. This is a target with a tested gate, not a
certification.

The binding rules are `DESIGN.md` §10. What is enforced, where, and by which job is stated once, in
that section and in `.github/workflows/ci.yml`; accepted gaps live in `docs/ACCEPTED-LIMITS.md` and
are not repeated here. `./task e2e` refuses to run without `KRAN_DATABASE_URL` unless
`KRAN_ALLOW_NO_DB=1` is set, because a run that skips database-backed specs is not evidence.

## Gaps not yet filed in the register

These three are real and are tracked here only because `docs/ACCEPTED-LIMITS.md` does not carry a
row for them yet. Filing them properly is open work, not a decision to keep them.

- **The mobile gate covers one screen.** The 390 px viewport test runs only on `/app/vault`
  (`apps/web/tests/e2e/vault.spec.ts`). Teller, ledger, print and account-opening screens are not
  proven usable on a phone.
- **`/app/ledger` takes "today" from the browser**, not from the session's business date, so the
  period preselection can disagree with the business date shown in the shell on a device in another
  timezone.
- **Switching language remounts the page subtree** (`{#key locale}` in `apps/web/src/routes/+layout.svelte`).
  Text already typed into a form is lost when the language changes.

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
