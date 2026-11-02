## What changed

<!-- The change in a few sentences. List the modules and files that carry it. -->

## Why

<!-- The problem, the spec section, and the task id (docs/tasks/T-xxx.md) if there is one. -->

## How verified

<!-- Exact commands and their result. "Tests pass" is not evidence (AGENTS §5). Paste the exit
     status or the CI run link. If a gate was skipped, say which and why. -->

```
$ ./task ci
```

## Checklist

- [ ] `./task ci` is green on this branch and the result is shown above. For a docs-only PR, say
      that CI does not run for `**.md`/`docs/**` instead of claiming a green gate.
- [ ] Tests cover the change. A bug fix has a test that fails when the fix is reverted.
- [ ] `./task archcheck` passes; no new cross-module call outside `api.nim`/events.
- [ ] No business values in code. New parameters are registered with `tools/paramgen`, with
      migration and seed; `./task paramgen --check` and `lint-nomagic` pass.
- [ ] Money and rates use `Money`/`Rate`. No float for money, rate, or quantity.
- [ ] Use cases are atomic, events go through the outbox, and financial operations are idempotent.
- [ ] The OpenAPI contract is updated; `./task openapi` and the contract test pass.
- [ ] New UI text exists in both `id` and `en`; `./task check` i18n passes.
- [ ] UI changes pass axe in two themes × two locales and are usable keyboard-only
      (`./task e2e`).
- [ ] Migrations are expand-only. Destructive changes are a separate contract migration.
- [ ] New or changed operations have the right permission and audit event; sensitive data is
      masked or encrypted.
- [ ] `MODULE.md` and the affected docs are updated. Regulatory requirements carry `@REG-xxx`;
      unverified values stay tagged `NEEDS-COMPLIANCE-REVIEW`.
- [ ] No secrets and no real personal data. Test data is synthetic.
- [ ] An independent reviewer has approved this diff (clean context, not the author's reasoning).

## Review note

<!-- Critical areas — interest, accrual, PPAP, tax, reconciliation, encryption/key management,
     authorization, audit hash chain — must be marked HUMAN-REVIEW-REQUIRED (AGENTS §8).
     State the reviewer and the review round, or what is still open. -->

Merging to `main` deploys production; only the maintainer merges. Do not push to `main`.
