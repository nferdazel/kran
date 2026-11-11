# KRAN design index

This file is the entry point to the design work. It points at the source documents; it does not
repeat their specifications.

## Chosen direction

D-160 (owner decision, 31 October 2026), reaffirmed by DD-01: keep the visual identity and
redesign structure, flows, and component coverage. The audit showed an adoption failure, not a
direction failure.

- Back-office core-banking workstation for a 3-10 person Indonesian KSP.
- IBM Plex Sans, cool neutral surfaces, one plum accent, tabular numerals, 1 px hairlines,
  elevation only for overlays.
- One work surface and one focus per screen. Tables and numbers lead. No dashboard cards, no
  decorative charts, no mascots, no emoji.
- Dials: **ENERGY 2 / RHYTHM 2 / MOTION 2**. Motion is limited to 150-200 ms for non-numeric
  transitions and 0 ms for numbers.

Sources: `DESIGN.md` (direction and token rules), `docs/design/00-decisions.md` (DD-01 to DD-12),
`docs/design/01-ia-flows.md` (personas, flows, screen inventory), `docs/design/02-design-system.md`
(tokens and components).

## Design decisions

| ID | Decision |
|---|---|
| DD-01 | Keep the D-160 identity; redesign structure, flows, and component coverage |
| DD-02 | Operator vocabulary is Indonesian; internal words never reach the UI |
| DD-03 | `en` is a real operating mode; SHU and RAT stay as acronyms with a one-line gloss |
| DD-04 | Session lock at 15 minutes idle, warning at 14:00 with a 60-second countdown; draft and idempotency key survive re-auth |
| DD-05 | One close console at `/app/close` with EOD, EOM, and EOY levels; EOY adds a prerequisites panel |
| DD-06 | Account opening is merged into member detail K-08; the standalone opening route is deleted |
| DD-07 | MVP assumes members only hold savings; non-member savings are out of scope and recorded as an assumption |
| DD-08 | Reports use two routes and one report family of eight documents: balance sheet, income statement, equity, member register, arrears, cash recap, close certificate, SHU per member |
| DD-09 | Transaction search stays as a lightweight Cari transaksi panel in the Kas header, not a nav destination |
| DD-10 | Transfer is a mode inside Kas, not a nav item, and gains its own permission when the endpoint does |
| DD-11 | Loan payment keeps the stable deep link `?tab=pay` |
| DD-12 | Prototype data is labelled synthetic; no realistic-looking personal names |

Rejected alternatives and reasons are in `docs/design/00-decisions.md`. Open design questions
O-1 to O-3 are there too. Rules prefixed `AS-xx` in `docs/design/` are design-wave rules, not
owner rulings; owner rulings use `R-xx` (R-41).

## The 24-screen map

The target has 24 screens in seven work groups. Depth limit is three: group, screen, record.
The full purpose, state matrix, permissions, and flows are in `docs/design/01-ia-flows.md`;
per-screen specs are in `docs/design/03-screen-specs-transactions.md` and
`docs/design/03-screen-specs-governance.md`.

| ID | Route | Group | Disposition |
|---|---|---|---|
| K-01 | `/app/teller` | Kas | rebuild |
| K-02 | `/app/vault` | Kas | repair |
| K-03 | `/app/close` | Buku besar | rebuild, replaces `/app/dayclose` |
| K-04 | `/app/ledger` | Buku besar | repair |
| K-05 | `/app/ledger/admin` | Buku besar | rebuild |
| K-06 | `/app/members` | Anggota | new |
| K-07 | `/app/members/new` | Anggota | new |
| K-08 | `/app/members/[memberId]` | Anggota | new |
| K-09 | `/app/members/[memberId]/exit` | Anggota | new |
| K-10 | `/app/savings/obligations` | Simpanan | new |
| K-11 | `/app/loans` | Pinjaman | rebuild |
| K-12 | `/app/loans/new` | Pinjaman | new |
| K-13 | `/app/loans/approvals` | Pinjaman | new |
| K-14 | `/app/loans/[loanId]` | Pinjaman | rebuild |
| K-15 | `/app/loans/arrears` | Pinjaman | new |
| K-16 | `/app/reports`, `/app/reports/[reportKey]` | Laporan | new, eight documents |
| K-17 | `/app/audit` | Pengaturan | new |
| K-18 | `/app/users` | Pengaturan | rebuild |
| K-19 | `/app/params` | Pengaturan | repair |
| K-20 | `/app/products` | Pengaturan | rebuild |
| K-21 | `/app/password` | Akun | repair |
| K-22 | `/login` | none | repair |
| K-23 | `/app/print/slip/[transactionId]` | print | rebuild |
| K-24 | `/app/print/statement/[accountId]` | print | rebuild |

`/app/accounts/open` is deleted as a destination; opening an account becomes a section of K-08
(DD-06). Ten screens are new. Five existing screens are repaired and nine are rebuilt; the
fifteenth existing route is the merged opening screen.

## Components

The target is 34 components in 8 categories, listed with variants, states, accessibility contract,
and props in `docs/design/02-design-system.md` section 5. Current implementations live in
`packages/ui/src/components/` and the shared stylesheet is `packages/ui/src/components.css`.
Three components survive unchanged, three change their API, and `Field` is retired into
`Input`, `Select`, and `MoneyInput`.

## Prototype and verification

- Prototype: `docs/design/prototype/` (12 pages, including `komponen.html`). The verification
  screenshots are kept with the local working archive.
- Verification report: `docs/design/05-verification.md` (axe, contrast, interaction and overflow
  results).
- Recorded result: 0 axe violations on 12 pages in light/id, dark/id, and dark/en; 227 enabled
  buttons clicked with 0 failures; 0 dead internal links; 0 px horizontal overflow at 1366 and
  480.

The prototype proves design behaviour only. It does not prove backend money, permissions, or
audit behaviour; those are proved by the tests named in `CAPABILITIES.md`.

## Design system v2 (in progress)

- Handoff: `docs/design/design-system-v2-handoff.md` — per-ticket scope, interaction rules from QA,
  terminology rulings, and the "Where things live" block.
- Copy audit behind the terminology rulings: `docs/design/design-system-v2-copy-audit.md`.
- Tickets: `docs/tasks/T-286.md` … `T-292.md` (T-284 tokens and T-285 shell are done). Implementation
  is on branch `feat/design-system-v2`; nothing here is on `main`.
- Gate scripts and exit criteria: `tools/qa/a11y/` (`a11y-matrix.mjs`, `keyboard-flows.mjs`,
  `EXIT-CRITERIA.md`, `MANUAL-CHECKLIST.md`). Run output stays in `.local/qa/results/` (gitignored).
  Browser-level gates are still open until a test session with seed fixtures exists.
