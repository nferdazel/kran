# KRAN documentation map

This directory holds the living documents for KRAN. One page, one entry point, no status
table and no second inventory.

## Rule 1: current state versus history

- A living document describes the tree as it is today and is updated in the same commit as
  the behaviour it describes.
- History is frozen. `history/PHASES.md` records closed phases and is not rewritten when a
  later phase changes the product.
- Generated files (`PARAMETERS.md`, `SCHEMA.md`, `CAPABILITIES.md`) are read-only in review;
  they are regenerated from their source, never hand-edited.
- A statement without a code path, a test, or a decision id is a defect in the document, not
  a fact about the product.

## Rule 2: code and tests win over prose

For what the system **does**, the code and the tests are authoritative. For what the system
**should** do, `spec/kran-prd-techspec.md` and `DECISIONS.md` are authoritative. When prose
and behaviour disagree, record the difference, fix the document or the code in the same task,
and never quietly pick the convenient one.

## Rule 3: where to look

| Document | Use it for |
|---|---|
| `spec/kran-prd-techspec.md` | Product scope, domain model, invariants, security, UX, operations, compliance, references |
| `ROADMAP.md` | Phase order P0-P8, exit criteria, serial and parallel rules |
| `BACKLOG.md` | The task queue: id, phase, size, risk class, dependency, capability, status |
| `CAPABILITIES.md` | The capability ledger: can persona X do Y today, and which test proves it |
| `capabilities.yaml` | Machine-readable source for the ledger; same ids as the markdown table |
| `DOMAIN.md` | Glossary, aggregate ownership, Indonesian operator terms with English gloss |
| `DESIGN-INDEX.md` | Design direction, dials, the 12 design decisions, the 24-screen map, prototype pointers |
| `DECISIONS.md` | Owner rulings R-01 to R-30, active decisions in full, one-line archive index |
| `OPEN_ITEMS.md` | Items still open, plus closed ids that code or tests still cite |
| `ACCEPTED-LIMITS.md` | Risks the owner accepted, with a detection method and an owner per row |
| `ESCALATIONS.md` | Stop-and-ask log and the escalation template |
| `PARAMETERS.md` | Generated parameter catalogue; never a place for business values in code |
| `SCHEMA.md` | Generated schema inventory: tables, keys, FKs, invariant triggers, migration id |
| `OPERATIONS.md` | Deploy, migrations, backup and restore, day-close, ops CLI, break-glass, key rotation |
| `SECURITY.md` | Authentication, authorization, audit chain, retention, privacy controls |
| `COMPLIANCE.md` | Obligation map O1-O8, evidence per obligation, `NEEDS-COMPLIANCE-REVIEW` register |
| `RELEASE.md` | Version, tag, and deploy flow |
| `tasks/_TEMPLATE.md` | The task file to copy before starting work |
| `agent/REVIEWER.md` | The clean-context reviewer prompt for R-25 |
| `history/PHASES.md` | Condensed evidence for Fase 0-4 |
| `compliance/register.yaml` | Requirement to control to test traceability; read by the traceability gate |
| `compliance/register-validation.md` | Research log with sources for the compliance register |
| `adr/` | Architecture decision records, including `017-field-level-encryption.md` |

The API reference is the contract itself: `packages/contracts/openapi/kran-api.yaml`. There is
no prose API document that could drift from it.

## Starting a task

1. Take the top `READY` row from `BACKLOG.md`.
2. Copy `tasks/_TEMPLATE.md` to a new task file in `tasks/`.
3. Fill the Definition of Ready. If any item is false, the task goes back to the backlog, not
   into the code.
4. Implement test-first where the task touches money, a calculation, or a state machine.
5. Run the gate named in the task, then `./task check-fast` and `./task ci-fast` for backend or
   schema work.
6. Append the evidence block, update the capability row, and request review when the risk class
   requires it (`money`, `schema`, `authz`, `audit`).
7. Mark the task `DONE` only after the evidence exists. A partial result is a new task.

## Archive

The old corpus (229 files, including the 166 task files and the five milestone reports) is kept in a local
planning archive outside git (not in this repository). Historical `T-xxx` ids resolve
through `history/PHASES.md` and the old task files in git history; they are not paths in the
current tree.
