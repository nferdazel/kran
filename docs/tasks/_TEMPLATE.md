# T-xxx - <title>

Phase: <P0-P8> · Size: <S/M/L> · Risk: <money|schema|authz|audit|general> · Status: READY

## Definition of Ready

- [ ] Phase exit criterion served: <criterion>
- [ ] Evidence anchor: <audit id, ruling, or design section>
- [ ] Files and modules to touch: <paths>
- [ ] Parameter keys: <new keys registered, or none>
- [ ] Migration shape: <none|expand|expand+contract, with contract entry if any>
- [ ] Tests: <existing tests that protect this>; <new test that proves it>
- [ ] UI obligations: <i18n id+en keys, a11y impact, states, or not applicable>
- [ ] Dependencies: <task ids, or none>
- [ ] Rollback: <how to undo>
- [ ] Size fits the 2-day cap: <yes, or split plan>
- [ ] Risk class assigned above

## Scope

<What changes, and what deliberately does not.>

## Acceptance

<The observable result. Name the test that fails on the parent commit and passes here.>

## Evidence

```
- Gate: <command>
- Output: <X passed, Y failed, key lines>
- Migration: <id / none>, applied to <db>, re-run safe: <yes/no>
- Manual check: <what was clicked or printed, if UI>
- Commit range: <sha..sha>
- Capability row: <id> -> <delivered|partial|missing>
- Human review: <required|not required>, by <role>, result
```

## Review

| Risk class | Requirement |
|---|---|
| `money` | Independent reviewer, maximum 2 rounds |
| `schema` | Independent reviewer, maximum 2 rounds |
| `authz` | Independent reviewer, maximum 2 rounds |
| `audit` | Independent reviewer, maximum 2 rounds |
| `general` | Self-review checklist plus gates |

A second review that still finds a BLOCKER returns the task to `READY` with a rewritten plan.
There is no third round. `HUMAN-REVIEW-REQUIRED` stays on money math, authorization, crypto, and
the audit chain.

## Rollback

<The revert or compensating action, and the data or migration step if one is needed.>

## Notes

<Assumptions, open items created, or links to a decision. No placeholders.>
