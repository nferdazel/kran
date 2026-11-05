# Wave 3 - prototype verification

Date: 5 Nov 2026 · Scope: `docs/design/prototype/` (12 pages) · Mode: antislop **during**

Two independent scripts, both re-runnable:

```
The two check scripts are kept with the local working archive. The recorded results are below;
re-running them is a one-minute task when the archive is present.
```

Both serve the prototype over a local HTTP server (127.0.0.1, ephemeral port). Serving matters:
`file://` blocks axe from reading stylesheets, which silently disables the colour-contrast rule.

---

## 1. Result

| Check | Method | Result |
|---|---|---|
| axe WCAG 2.2 A/AA | `@axe-core/playwright` 4.13, tags `wcag2a, wcag2aa, wcag21a, wcag21aa, wcag22aa` | **0 violations** on 12 pages × light/id, dark/id, dark/en |
| Console / page errors | `page.on("console"|"pageerror")` | **0** |
| Dead internal links | every `href="*.html"` resolved on disk | **0** |
| Untranslated i18n keys | text nodes matching `a.b.c` after switching to `en` | **0** |
| Horizontal overflow | 1366×900 and 480×900 | **0 px** on both |
| Theme toggle | `data-theme` after click | applied on every page |
| Interactive controls | **227** enabled buttons clicked, one reload per click, dialogs dismissed | **0 failures** |
| External requests | grep for `http(s)://` in html/js/css | **0** |
| Em dash in UI copy | grep for `-` | **0** |
| Emoji in UI | grep | **0** |
| `outline: none` | grep | **0** |
| Raw hex in page CSS | `screens-tx.css`, `screens-gov.css` | **0** (tokens only) |
| Fabricated personal data | grep for common fake names | **0** |

## 2. Token contrast (measured, not estimated)

26 foreground/background pairs across both themes. Text pairs use the 4.5:1 threshold; borders
use the 3:1 non-text threshold. Lowest text ratio: **4.98** (disabled text on disabled surface,
light). Lowest status-on-tint: **5.27** (warning, light). Lowest border: **3.53** (light) /
**4.19** (dark), both above 3:1.

| Theme | Pair | Ratio |
|---|---|---|
| light | text / canvas | 16.78 |
| light | muted / surface | 6.66 |
| light | muted / canvas | 6.21 |
| light | disabled / disabled surface | 4.98 |
| light | on-primary / primary | 10.84 |
| light | primary / surface | 10.84 |
| light | success / success tint | 6.62 |
| light | danger / danger tint | 6.31 |
| light | warning / warning tint | 5.27 |
| light | info / info tint | 6.85 |
| light | border / canvas (non-text) | 3.53 |
| light | focus ring / surface | 10.84 |
| dark | text / surface | 14.56 |
| dark | muted / surface | 6.77 |
| dark | muted / canvas | 7.35 |
| dark | disabled / disabled surface | 5.27 |
| dark | on-primary / primary | 8.87 |
| dark | primary / surface | 8.17 |
| dark | success / success tint | 6.64 |
| dark | danger / danger tint | 6.29 |
| dark | warning / warning tint | 7.02 |
| dark | info / info tint | 7.26 |
| dark | border / canvas (non-text) | 4.19 |
| dark | focus ring / surface | 8.17 |

Screenshots were captured during verification and kept with the local working archive, not in git.

## 3. Delivery Gate (antislop, 4 blocks)

| Block | Item | Status | Evidence |
|---|---|---|---|
| Hard Gate | R-02 no em dash | PASS | grep: 0 |
| Hard Gate | R-03 mobile reflow | PASS | 0 px overflow at 480 on 12 pages |
| Hard Gate | R-17 numbers have a source | PASS | all figures are labelled synthetic placeholders |
| Hard Gate | R-18 no testimonials | PASS | none exist |
| Hard Gate | R-23 assets | PASS | text mark, no drawn logo, no avatars |
| Hard Gate | R-24 navigation | PASS | 11 links, 0 dead |
| Hard Gate | R-25 contrast | PASS | §2, all text pairs ≥ 4.5 |
| Hard Gate | R-26 interactive elements work | PASS | 227 buttons clicked, 0 failures |
| Hard Gate | R-27 states | PASS | empty/loading/error/partial/locked/denied present per page |
| Hard Gate | R-28 FAQ | n/a | product UI has no FAQ |
| Hard Gate | R-32 keyboard | PASS | skip link, semantic order, Escape closes dialogs, focus restored |
| Hard Gate | R-33 no patch scripts | PASS | hand-written CSS/JS only |
| Hard Gate | R-34 both themes work | PASS | axe 0 in both themes, all pages |
| Hard Gate | R-35 verify before delivery | PASS | this document, two scripts |
| Hard Gate | R-36 no fabricated claims | PASS | no security/compliance claim in the UI |
| Hard Gate | R-37 direction | PASS | D-160, dial declared, P-03 recorded |
| Hard Gate | R-38 real content or labelled placeholder | PASS | synthetic strip + `[PLACEHOLDER]` tokens |
| Purpose-Gate | every technique has a written reason | PASS | `00-decisions.md`, `02-design-system.md` §1-8 |
| Liveliness | dials declared and held | PASS | ENERGY 2 / RHYTHM 2 / MOTION 2; motion limited to 150-200 ms non-numeric, 0 ms for numbers |
| Craftsmanship | C-1 intentionality | PASS | each screen states the one decision it supports |
| Craftsmanship | C-2 completeness | PASS | no dead controls (227 clicked) |
| Craftsmanship | C-3 content-driven | PASS | no dashboard cards, no KPI strip, report stays a document |
| Craftsmanship | C-4 resilience | PASS | 7 states per screen; both themes; both locales; 480-1366 |
| Craftsmanship | C-5 evidence over claims | PASS | no claim without a source; prototype limited to design |

## 4. What this verification does NOT prove

- **No backend behaviour.** The prototype is static; money, permissions and audit are exercised by
  the real app, not by these pages.
- **No screen-reader pass.** axe is a static rule engine; VoiceOver/NVDA behaviour is unverified.
- **Print was not physically printed.** Print stylesheets exist and hide chrome; pagination on real
  paper is unverified.
- **No performance measurement.** No bundle, no LCP, no query counts. Those belong to the
  implementation phase and its gates.
- **Focus visibility is asserted by CSS, not by pixel inspection** beyond the axe contrast rules.

These limits are stated because a prototype that claims more than it verified is the exact failure
mode the audits found in the old docs.
