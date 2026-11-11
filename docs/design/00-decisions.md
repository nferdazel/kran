# Wave 3 - design decisions

Resolves the open questions raised by the IA, screen-spec and accessibility work. These are
**design decisions**, not owner rulings (`R-xx`). They can be overturned at the Wave 3 checkpoint
without redoing the documents, because each names the alternative it rejected.

Evidence base: `01-ia-flows.md`, `02-design-system.md`, `03-screen-specs-*.md`,
`04-a11y-and-copy.md`, `DESIGN.md` (D-160), and the Wave 1 audits.

| # | Decision | Reason | Rejected alternative |
|---|---|---|---|
| DD-01 | Keep the D-160 visual identity; redesign structure, flows and component coverage | Audit shows adoption failure, not direction failure (P-03) | New identity: high cost, no evidence the current one is wrong |
| DD-02 | Operator vocabulary is Indonesian: **Kasir**, **Kas besar**, **Tutup kas**, **Setor (masuk)**, **Tarik (keluar)**. Internal words (`teller`, `vault`, `uuid`, `run`, task codes, table names) never reach the UI | DESIGN §9; the current nav ships internal words, which the audits flagged | Keep `teller`/`vault`: they are implementation vocabulary, not operator language |
| DD-03 | `en` is a real operating mode, not a translation stub. `SHU` and `RAT` stay as acronyms in both locales, with a one-line gloss on first use per screen | R-09 keeps i18n id+en; translating SHU/RAT into "profit sharing"/"annual members meeting" loses legal meaning | Translate the acronyms: creates false equivalents |
| DD-04 | Session lock: **15 minutes idle**, warning at **14:00** with a 60-second countdown, one canonical sentence. Draft and idempotency key survive re-auth | R-21; the two design documents disagreed on warning timing (1 vs 2 minutes) | Two timers with different copy: produces contradictory warnings |
| DD-05 | One close console `/app/close` with level tabs **EOD / EOM / EOY**; EOY adds a prerequisites panel (SHU basis signed, parameter set) rather than a separate screen | One mental model for "closing"; EOY is a stricter level, not a different job | Separate `/app/eoy` route: splits one operation into two places to look |
| DD-06 | Account opening is merged into member detail (K-08). Account actions (block, close, dormant) live in the accounts section there | Every account belongs to a member; a standalone opening screen had no other purpose | Standalone `/app/accounts/open`: adds a route with one action |
| DD-07 | MVP assumes **members only** hold savings. Non-member savings are out of scope; recorded as an assumption, not a fact | KSP practice; keeps the member aggregate mandatory. `NEEDS-COMPLIANCE-REVIEW` on the bylaw detail | Support non-member savers: reopens the CIF-vs-member split the replan is closing |
| DD-08 | Reports: two routes, `/app/reports` (document checklist) and `/app/reports/[reportKey]` (document). **Ten** keys: BS, IS, equity, cash-flow statement with notes (R-44, `NEEDS-COMPLIANCE-REVIEW`), member register, savings arrears, loan exposure/arrears, cash recap, close certificate, SHU per member | Ten documents, one apparatus; savings arrears and loan arrears are different obligations, and R-44 adds the cash-flow statement | Eight keys (merging the two arrears): hides a distinct obligation |
| DD-09 | Transaction search stays, as a lightweight **Cari transaksi** panel reachable from the Kas header, not a new nav destination | Reprinting yesterday's slip is a real counter task; the IA doubted dropping it | Drop it: the doubt was justified, the task is real |
| DD-10 | Transfer is a **mode inside Kas**, not a nav item; it gains its own permission check when the endpoint does | Teller works from one station; a separate destination splits one session into two | Separate `/app/transfer` route: breaks the station model |
| DD-11 | Loan payment keeps a stable deep link `?tab=pay` | Teller shortcut and e2e need a stable target | No deep link: every shortcut depends on click order |
| DD-12 | Prototype data is **labelled synthetic**: a persistent "Prototipe, data sintetis" strip, placeholder tokens like `[NAMA ANGGOTA]`, and no realistic-looking personal names | Antislop AS-17/AS-23/AS-38: fabricated content that looks real is the strongest tell and misleads reviewers | Realistic fake names: reads as real customer data |

## Still open (needs owner or later evidence)

| # | Question | Why it cannot be decided here |
|---|---|---|
| O-1 | Does a pengurus need a separate read-only login, or is that a permission on a normal account? | Affects the role model and the audit trail, not just the UI |
| O-2 | Should the close certificate be printable on its own route (like slip/statement)? | Depends on whether the certificate is handed to anyone outside the cooperative |
| O-3 | Exact retention periods per record class (R-26 decides the mechanism, not the numbers) | `NEEDS-COMPLIANCE-REVIEW` |
