# KRAN design index

This file is the entry point to the design work. It states the direction and points at the
documents that own the detail; it does not repeat their specifications.

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

Sources: `DESIGN.md` (binding direction and token rules), `docs/design/00-decisions.md` (DD-01 to
DD-12 with reason, rejected alternative, and the open questions O-1 to O-3), `docs/design/01-ia-flows.md`
(personas, flows, the 24-screen inventory with purpose, states and permissions).

## Design decisions

DD-01 to DD-12 live in `docs/design/00-decisions.md`. That file owns them; this index does not
restate the table. Rules prefixed `AS-xx` in `docs/design/` are design-wave rules, not owner
rulings; owner rulings use `R-xx` (R-41).

Where a DD and an owner decision disagree, the owner decision wins: DD-08 was written with eight
report keys and R-44 raised it to ten (`00-decisions.md` carries the corrected entry).

## The 24-screen map

The target has 24 screens in seven work groups; depth limit is three: group, screen, record. The
map itself is `docs/design/01-ia-flows.md` section 3: route, purpose, the one decision made on each
screen, actor, state matrix, and the permissions each screen gates. Per-screen specs are in
`docs/design/03-screen-specs-transactions.md` and `docs/design/03-screen-specs-governance.md`.

`/app/accounts/open` is deleted as a destination; opening an account becomes a section of K-08
(DD-06). Ten screens are new, five are repaired and nine rebuilt; K-16 is one report apparatus of
ten documents, not ten screens.

## Components

Components are specified in `docs/design/02-design-system.md` (token groups, states S1-S9, the
accessibility contract per component, and the adoption order). Implementations live in
`packages/ui/src/components/` and the shared stylesheet is `packages/ui/src/components.css`.
`DESIGN.md` §10 is the binding accessibility rule; `02-design-system.md` never overrides it.

## Prototype

`docs/design/prototype/` holds the 12-page prototype (including `komponen.html`) that proved the
layout and keyboard order before the rebuild. It proves design behaviour only: it does not prove
backend money, permissions or audit behaviour, which are proved by the tests named in
`CAPABILITIES.md`. The verification run of that prototype was a one-off on 5 November and its
screenshots are not in the tree; the durable accessibility evidence is `tools/qa/a11y/GATE-LOG.md`
and the `./task e2e` run it records.
