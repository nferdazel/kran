# KRAN - Information architecture & interaction flows (target state)

Status: Wave 3, 4 Nov 2026 · read-only on source · feeds `docs/` rebuild, not yet ratified.
Scope: structure, flows, screen states. Visual style stays D-160. Money, authz and posting rules are
invariants, not design choices.
Tags: `R-xx` owner ruling · `FE-EFF-xx` / `FE-LOGIC-xx` audit finding · `[DEP-n]` backend capability that
does not exist today (§3.8) · `NEEDS-COMPLIANCE-REVIEW` = unverified regulation, never asserted.

## 1. Design read

Back-office core-banking **workstation** for a 3-10 person Indonesian KSP: teller, loan officer,
manager, admin, and non-daily pengurus. Language: near-neutral ledger surface, hairline rules, one
plum accent, tabular money, one focus per screen. Dials **ENERGY 2 / RHYTHM 2 / MOTION 2** - unchanged
from D-160. Reason: the work is read-and-type under time pressure; extra energy raises the cost of a
misread number, and every dial increase would have to be paid back in scan time.

## 2. Personas

Roles are seats, not job titles; in a 3-person KSP seats overlap, so separation of duties is enforced
**per action** (R-17) and checked by the server, not by hiding a job title.

| Role | Daily work | Must never | Screen set | Permission shape |
|---|---|---|---|---|
| Kasir / teller | open cash, deposit, withdrawal, transfer, loan instalment, reprint, close cash | post without an open session; approve a vault top-up; see another branch's cash | K-01, K-06 (read), K-08, K-14 (pay), K-23, K-24 | `teller.session.open/close/read`, `teller.transaction.post`, `deposit.account.read`, `lending.loan.pay`, branch-scoped |
| Petugas pinjaman | survey, application, schedule preview, disbursement, collections | approve own application; disburse to cash; edit a posted payment | K-06, K-07, K-08, K-11-K-15, K-24 | `lending.loan.submit/read/disburse/pay`, `party.party.read/create`, `party.kyc.manage` |
| Manajer | approvals (loan, param, product, vault), arrears review, EOD/EOM/EOY, reports | approve own submission; close without counting cash; run EOY without a signed SHU basis | K-02, K-03, K-04, K-11, K-13, K-14, K-15, K-16, K-17, K-19, K-20 | checker grants (`*.approve`), `dayclose.run.manage`, read on ledger/report |
| Admin / operator (pembukuan) | member data, obligations, corrections, user admin, daily recap | delete a posting; create an operator without a role+branch; edit a closed period | K-04-K-10, K-17-K-21, K-23 | `coop.member.*` [DEP-1], `deposit.account.manage`, `ledger.*.manage`, `platform.user.manage`, `platform.audit.read` |
| Pengurus (read-only oversight) | read RAT pack, member register, close certificates, SHU | post, approve, or change any record | K-04, K-06, K-08, K-16 | read-only: `report.read`, `coop.member.read`, `ledger.journal.read`; audit only if explicitly granted |

Rule: a screen never becomes reachable because a role name matches; every entry carries the permission
code the server checks. Reason: role names drift, codes are tested.

## 3. Screen inventory (target)

24 target screens. The 15 existing ones: **5 repair · 9 rebuild · 1 merge (route deleted)**; plus **10 new**. One "screen" (K-16) is a report family
of eight documents; counted as one apparatus, not eight, because they share period/branch/print and
differ only in columns.
States column order: **E**mpty · **L**oading · error(**X**) · **P**artial · **S**tale · **R**ead-only/locked ·
**N**o-permission.

| ID | Route | Group | Purpose (why it exists) | The one decision made there | Actor | States | Permissions | Status |
|---|---|---|---|---|---|---|---|---|
| K-01 | `/app/teller` | Kas | Cash station: session, setor, tarik, PB, angsuran, session ledger | Is this the right member and the right amount? | T | E L X P S R N | `teller.session.*`, `teller.transaction.post`, `deposit.account.read` | exists-rebuild |
| K-02 | `/app/vault` | Kas | Branch vault balance; top-up maker/checker | Approve this cash movement? | A,M | E L X S R N | `teller.vault.read/submit/approve` | exists-repair |
| K-03 | `/app/close` | Buku besar | One close console: EOD, EOM, EOY, certificate | Is this day/month/year closed, and may it be? | M | E L X P S R N | `dayclose.run.read/manage`, `ledger.period.manage` | exists-rebuild (was `/app/dayclose`) |
| K-04 | `/app/ledger` | Buku besar | Trial balance and balances per period | Does the trial balance balance? | A,M,P | E L X S R N | `ledger.journal.read`, `ledger.period.read` | exists-repair |
| K-05 | `/app/ledger/admin` | Buku besar | COA, journals, reversal; period close moved to K-03 | Reverse which entry, with what reason? | A | E L X S R N | `ledger.coa.manage`, `ledger.journal.reverse` | exists-rebuild |
| K-06 | `/app/members` | Anggota | Register: name, member no., KTP, phone, status | Which member is this? | A,L,T(read) | E L X S R N | `party.party.read`, `coop.member.read` [DEP-1] | new |
| K-07 | `/app/members/new` | Anggota | Onboarding: identity, KYC refs, consent, member no., pokok | Admit this person, or reject the duplicate? | A | E L X P R N | `party.party.create`, `party.kyc.manage`, `coop.member.create` [DEP-1,2] | new |
| K-08 | `/app/members/[memberId]` | Anggota | Member file: identity, status, accounts, obligations, loans, SHU | Is this member in good standing? | A,L,T | E L X P S R N | `party.party.read`, `deposit.account.read`, `lending.loan.read`, `coop.member.read` | new |
| K-09 | `/app/members/[memberId]/exit` | Anggota | Exit/refund computation, approval, statement | May this member leave, and what is refunded? | M,A | E L X P R N | `coop.member.manage` [DEP-1], `lending.loan.read` | new |
| K-10 | `/app/savings/obligations` | Simpanan | Pokok/wajib register per period: generate, pay, waive | Who still owes this period, and what do we do? | A | E L X S R N | `deposit.account.read`, `coop.obligation.*` [DEP-1] | new |
| K-11 | `/app/loans` | Pinjaman | Portfolio with paging, DPD, outstanding, holder | Which loan needs attention? | L,M | E L X S R N | `lending.loan.read` | exists-rebuild |
| K-12 | `/app/loans/new` | Pinjaman | Application: member, product, principal, tenor, schedule preview | Is this loan admissible? | L | E L X P R N | `lending.loan.submit`, `party.party.read` | new |
| K-13 | `/app/loans/approvals` | Pinjaman | Checker queue with approve/reject reason | Do I approve someone else's application? | M | E L X S R N | `lending.loan.approve` | new |
| K-14 | `/app/loans/[loanId]` | Pinjaman | Loan file: schedule, payments, disburse, restructure, write-off | Post this movement against this akad? | L,T,M | E L X P S R N | `lending.loan.read/disburse/pay/restructure/write_off/recovery` | exists-rebuild |
| K-15 | `/app/loans/arrears` | Pinjaman | Collections list by DPD/officer/product, printable | Who do we contact today? | L,M | E L X S R N | `lending.loan.read` | new |
| K-16 | `/app/reports/[reportKey]` | Laporan | Report family: BS, IS, equity, member register, arrears, cash recap, certificate, SHU | Is this period's pack complete and signed? | M,P,A | E L X P S R N | `report.*` [DEP-3] | new (8 documents) |
| K-17 | `/app/audit` | Pengaturan | Audit viewer: actor, action, entity, date, trace | Who did this, and when? | A,M,P | E L X S R N | `platform.audit.read` | new |
| K-18 | `/app/users` | Pengaturan | Create user, role+branch, reset, unlock, disable | Does this person get access, and to what? | A | E L X P R N | `platform.user.manage`, `platform.branch.read` [DEP-4] | exists-rebuild |
| K-19 | `/app/params` | Pengaturan | Typed parameter authoring, maker/checker | What value does the business run on? | M,A | E L X S R N | `platform.param.read/submit/approve` | exists-repair |
| K-20 | `/app/products` | Pengaturan | Savings/loan catalogue: create, version, approve | Which products may exist? | A,M | E L X S R N | `product.catalog.read/manage/approve` | exists-rebuild |
| K-21 | `/app/password` | account menu | Change own password | Did I type it correctly? | all | E L X N | self only | exists-repair |
| K-22 | `/login` | - | Sign in, optional TOTP | Is this me, on this terminal? | all | E L X N | none | exists-repair |
| K-23 | `/app/print/slip/[transactionId]` | print | Slip: identity, cashier, time, reprint marker | Is this the document I hand over? | T,A | L X R N | read of `teller.transaction.post` | exists-rebuild |
| K-24 | `/app/print/statement/[accountId]` | print | Statement/passbook with running balance | Send or print this statement? | T,A | L X P R N | `deposit.account.read` | exists-rebuild |

Deleted as a destination: `/app/accounts/open` - opening an account is an action on a known member, not
a place you navigate to. It becomes a section of K-08. Reason: today it is the only "Anggota" entry and
it both promises membership the product lacks and hides the member it needs (FE-EFF-01, FE-EFF-16).

**3.8 Dependencies - screens that cannot ship before backend work**

| Tag | Missing capability | Blocks | Evidence |
|---|---|---|---|
| DEP-1 | `coop` module: member register, immutable number, status machine, obligation generation [R-15] | K-06-K-10, K-16 (member register, SHU), K-03 (EOY) | no module; `modules/` list |
| DEP-2 | KYC document **storage** - `identity-docs` stores encrypted number + metadata only; no file upload | K-07 photo/signature fields | OpenAPI `addIdentityDoc` (501 without KEK) |
| DEP-3 | Report queries. Only `trial-balance`, `balances`, `lending/reports/{arrears,allowance,reconciliation}` exist; BS/IS/equity/cash recap/certificate/SHU do not | K-16 documents appear one by one, never as fake numbers | OpenAPI path list |
| DEP-4 | User create/reset/MFA enrolment are `ctl` only; `/users` is GET-only | K-18 create/reset half | FE-EFF-06 |
| DEP-5 | Holder name on an account read model (`DepositAccount` exposes `partyId`, no name) | K-01 review, K-23, K-24, K-08 | FE-EFF-07 |
| DEP-6 | Realtime topics for maker/checker queues (only `param.changed` is scoped) | K-13, K-02, K-15 "stale" cells | FE-LOGIC-10 |
| DEP-7 | Client idle lock + draft store (none today; no backend change needed) | §4 lock, §6 rule 3 | R-21 |

Rule: a nav entry whose screen or permission is missing is **not rendered**; `resolve()` typing makes a
dead link a compile error (DESIGN §11; `nav.ts` types `href` as `ResolvedPathname`).

## 4. Navigation model

Seven groups by work, not by module. Depth limit **3**: group → screen → record. No fourth level, no
nested menus, one tab row inside a record. Reason: at 1366×768 a fourth level costs one extra
navigation step per transaction, which the teller pays 200 times a day.

```
Kas          Kas teller (K-01) T · Kas besar (K-02) A/M
Anggota      Daftar anggota (K-06) A/L/T · Anggota baru (K-07) A · [member] (K-08) A/L/T
Simpanan     Kewajiban pokok & wajib (K-10) A
Pinjaman     Pinjaman (K-11) L/M · Pengajuan (K-12) L · Persetujuan (K-13) M · Tunggakan (K-15) L/M
Buku besar   Neraca saldo (K-04) A/M/P · Jurnal & COA (K-05) A · Tutup buku (K-03) M
Laporan      Laporan (K-16: 8 dokumen) M/P/A
Pengaturan   Pengguna (K-18) A · Parameter (K-19) M/A · Produk (K-20) A/M · Audit (K-17) A/M/P
Akun         Ganti sandi (K-21) · Keluar            ← account menu, not a group
```

Boundaries and why:

| Group | Boundary reason |
|---|---|
| Kas | Cash is physical and counted; session, float and variance rules apply only here. |
| Anggota | Identity is the key every other screen searches by; membership is a lifecycle, not an account. |
| Simpanan | Pokok/wajib are period obligations shared across members, unlike one member's account. |
| Pinjaman | One file per akad; origination, approval and collection are three seats on one object. |
| Buku besar | Accounting read/admin, not operator work; only people who reconcile enter it. |
| Laporan | Read-only outputs; separating them stops "one screen per report" sprawl. |
| Pengaturan | Changes rules or access, not money; highest privilege, lowest frequency. |

Rules:
- Cash is the landing screen for a teller, not the ledger. Reason: DESIGN §11 makes the cash screen the
  station; the current `landingHref` prefers `/app/ledger` (nav.ts:197), which is a bookkeeper's home.
- A group with zero permitted links is not rendered; no empty headers. Reason: an empty group advertises
  capability the operator does not have (fail-closed, nav.ts:157).
- Keyboard path: `Ctrl/Cmd+K` palette over the same leaves and permissions; `F2` member search, `F4`
  setor, `F5` tarik, `F9` PB inside K-01; `Ctrl+P` reprint last slip; `Enter` primary, `Esc` cancel.
  Reason: teller throughput; the function keys are a practice assumption from `SME-NOTES.md`, not a rule.
- 15-minute lock [R-21]: global idle timer; reset on key/pointer/route change; at 14 min a non-modal bar
  ("Sesi berakhir dalam 1 menit"); at 15 min a lock overlay with re-auth. Locked forms freeze but their
  draft and idempotency key survive in `sessionStorage` keyed by route + fingerprint; re-auth returns to
  the same screen and step. A POST in flight completes and its result is shown after unlock.
  `/app/print/*` never locks. Reason: a teller who walks away must not leave a posting screen live, and a
  counted entry lost at re-auth is the failure operators fear most.

## 5. Core flows

`T` = teller, `L` = loan officer, `M` = manager, `A` = admin. "Unknown" = the wording the operator sees
when the system cannot tell whether a write happened.

| # | Flow / entry | Steps | Decision points | Failure & recovery | Evidence | When unknown |
|---|---|---|---|---|---|---|
| F1 | Open cash - K-01, no session | branch → count denominations → total → review (branch, business date, teller, float) → Buka kas | branch (only if >1); float per denomination | 5xx/timeout: keep key, banner + "Cek status" (GET current) before retry; branch/date mismatch: blocked + exit | session record, audit row, printable opening float | gate blocks cash posting (fail-closed), PB still allowed, "Muat ulang status" |
| F2 | Deposit / withdrawal - K-01 `F4`/`F5`, or K-08 "Setor" | identify member → account list (kind, balance) → amount + narration (+ depositor name if ≠ holder) → review (name, member no., account no., kind, before, amount, after, cashier, time) → Simpan → ref, before→after, Cetak slip | which account; withdrawal minimum/limit | insufficient/min balance/closed period/no session: reason + fix; network: key kept, "Ulangi"; money already accepted: persistent half-failure block with ref + "Cek status" | cash transaction, journal, slip (R-22), audit | form disabled until status resolved; never "berhasil" |
| F3 | Transfer - K-01 `F9` (allowed without cash session) | source account → destination by **account number or member no.** → resolve → review both sides (name, member no., account no., branch, status, amount) → Simpan → slip | destination correctness; same-account and kind checks | not found: field error + "cari berdasarkan nama"; inactive/closed: reason; 5xx: key kept + status check | transfer record, two-sided posting, slip | submit disabled while resolving ("Mencari rekening…"); a raw UUID is never an input |
| F4 | Onboarding + KYC - K-06 "Anggota baru", or "tidak ditemukan → daftarkan" | identity (name, KTP, birth, address, phone) → duplicate check → KYC refs + consent → membership (branch, joined_on, proposed number, pokok) → review → Simpan → optional "Bayar pokok" → receipt + member card | duplicate: use existing or proceed with reason; backdated join needs reason; pokok now vs obligation | 409 duplicate: link to existing member, not a bare conflict; KYC storage 501: block with "Penyimpanan dokumen belum aktif"; member created but pokok failed: partial banner + "Bayar pokok" | member + party + KYC audit rows, receipt, member no. | number service down: "Nomor anggota diberikan saat simpan", never a fabricated number |
| F5 | Wajib payment + arrears - K-10, K-08 tab, or K-01 setoran line "Wajib" | pick period → generate obligations (if not yet) → list by status → select member → pay → review → post → receipt; waive with reason + approver | waive; part-pay; prepay | already paid: row state, no double post; generation twice: idempotent per period; timeout: status check | obligation status change, deposit posting, receipt | "Periode mungkin sudah dibuat" + reload; never re-generate blind |
| F6 | Loan application → approval → disbursement → instalment - K-12 / K-13 / K-14 / K-01 | member → product+version → principal, tenor, method → schedule preview → purpose/collateral → eligibility → submit → queue → checker reviews member file, exposure, schedule, note → approve/reject → disburse to member account → payment with allocation preview (penalty → interest → principal) → receipt with split | approve/reject; disburse destination; partial payment; restructure | self-approval: button disabled with reason (not a 409 after click); eligibility: specific reason + link to arrears; disburse timeout: status check, second disburse refused; payment: form cleared after success | application, two-actor approval trail, disbursement journal, receipt | loan banner "Status pencairan belum diketahui", repeat action blocked |
| F7 | Arrears follow-up - K-15, default DPD desc | filters (DPD bucket, officer, product) → row (member, member no., phone, due date, DPD, outstanding, last payment) → open K-14 → take payment or propose restructure → print list with total row | contact vs restructure vs write-off (approval) | no arrears vs filtered-empty: different copy; stale after payment: timestamp + reload | printed snapshot (business date, total), payment receipt | header always shows the business date DPD is computed against |
| F8 | EOD close - K-03 | pre-checks (open sessions, unposted, TB zero, pending approvals) → Run → task/chunk progress → result → certificate → print | run/resume/pause/cancel; clear blockers | blocker list with links; task error: code + hint + resume; timeout: "status tidak diketahui, jangan ulangi" + reload | run record, task states, certificate (period, totals, actor, time) | explicit banner; Run disabled until state is read |
| F9 | Month-end report pack - K-16 "Bulanan" | period + branch → document checklist → open each → verify control lines (TB zero, subledger = GL) → print → EOM close in K-03 | which documents; accrual vs cash basis (printed on IS) | missing query: document listed "Belum tersedia", never a number; period open: "Belum ditutup" watermark; no export: print only | printed pack with generated-at, period, actor; EOM record | each document shows "Dihitung <time>" - stale figures visible, not silent |
| F10 | Year-end SHU + RAT - K-03 EOY → K-16 "SHU" | EOY close → proposal (parameters, no defaults) → per-member basis (pokok/wajib/sukarela, loan service, active days) → print → record RAT decision (number, date, quorum, signatories, split) → distribution journal (maker) → checker approve → post → member statement | approve split; rounding account | unseeded parameters: blocked, "Parameter SHU belum ditetapkan"; EOY twice: no-op; no RAT record: distribution blocked; unbalanced journal: blocked | RAT record, frozen proposal, journal, member statements | screen names the missing input ("Saldo wajib per 31 Des belum tersedia") |
| F11 | Create user / reset password - K-18 | create (name, username, role, branch) → temp password shown once → force change → audit; reset → confirm → temp password once + sessions revoked; unlock/disable | role + branch scope; disable, never delete | 409 username: inline; timeout: reload list before retry; lost temp password: reset again | audit rows, revocation | no email claim; the password is handed over in person |

## 6. Cross-screen interaction rules

| Rule | Behaviour | Reason |
|---|---|---|
| Idempotency key | One `lib/app/idempotency.ts`; key per content fingerprint; kept on network/5xx/unknown; dropped on 2xx and business 4xx | Four divergent copies today already produced a 409 dead end (FE-PRAC-03) |
| Review before post | Inline review region on the same screen, not a modal, showing identity + amount + before/after; only irreversible actions (close, exit, write-off) use one dialog | One modal layer maximum (DESIGN §7); routine confirmations are pure friction |
| Session lock | As §4; never locks mid-POST; prints exempt; lock screen shows role, branch, time, not balances | Balances on a lock screen leak to whoever walks past |
| Stale & realtime | Every read stamps "dimuat <time>"; every mutation re-reads the mutated entity; realtime only where a second person decides; a denied topic surfaces as a warning | Silent staleness is worse than a visible timestamp (FE-LOGIC-09, FE-PRAC-10) |
| Error contract | Field: inline + `aria-describedby` + focus. Form: summary + transaction ref. System: banner + ref + retry. Unknown `reason` falls back to the envelope, never invented copy | Operators act on the message, so the message must be actionable (charter §4) |
| Permission denied | Nav hidden; direct URL renders an in-place "Tidak berizin" panel with the permission needed and a way back; a 403 on action refreshes the session | Redirect loops and silent empty screens are indistinguishable from bugs |
| Three empties | "Belum ada data" (next action named), "Tidak ada hasil untuk filter ini" (active filters + clear), "Tidak berizin" (role + way out) | A filtered-empty state that says "no data" is a false statement about the cooperative |
| No delete | Corrections are reversing entries with a reason; exit is a state, not a deletion | Ledger is immutable (charter §4.1) |

## 7. State matrix

`E` empty · `L` loading · `X` error · `P` partial (one panel failed) · `S` stale · `R` read-only/locked ·
`N` no-permission. `-` = the state cannot occur on a form-only screen; the adjacent states carry its failures.

| Screen | E | L | X | P | S | R | N |
|---|---|---|---|---|---|---|---|
| K-01 teller | "Kas belum dibuka" + Buka | session skeleton, numbers blank | banner + ref + retry | account loaded, session failed | stamp + reload | closed session → read-only strip | panel, no redirect |
| K-02 vault | "Belum ada pengajuan" | balance skeleton | banner + retry | balance ok, list failed | stamp + reload | checker view without grant | panel |
| K-03 close | no run today + Run | pre-check list loads | blocker list as error | checks ok, history failed | run state unknown banner | closed day → read-only | panel |
| K-04 ledger | no period selected | table skeleton, no totals | banner + retry | totals ok, lines failed | period stamp | closed period, no edit | panel |
| K-05 ledger admin | "Belum ada jurnal" | section skeletons | section-level error | one section failed | journal list stamp | closed period blocks reversal | section-hidden by grant |
| K-06 members | "Belum ada anggota" + Anggota baru | list skeleton | banner + retry | count ok, rows failed | stamp + reload | exited member marked | panel |
| K-07 onboarding | blank form, no sample data | save disabled | field + summary + ref | member ok, pokok failed | duplicate-check stale | step 2 locked until 1 valid | panel |
| K-08 member | new member, no accounts | identity skeleton | banner + retry | identity ok, loans failed | stamp per tab | exited → read-only | panel |
| K-09 exit | not eligible, reason shown | computation skeleton | banner + ref | refund ok, loans failed | computation stamp | approved → locked | panel |
| K-10 obligations | "Belum dibuat" + Buat | table skeleton | banner + retry | totals ok, rows failed | period stamp | waived rows locked | panel |
| K-11 loans | no loans + Ajukan | table skeleton | banner + retry | total ok, rows failed | stamp + reload | closed loan marked | panel |
| K-12 application | blank, no prefills | preview computing | field + summary + ref | schedule ok, eligibility failed | eligibility stamp | submitted → read-only | panel |
| K-13 approvals | "Tidak ada yang menunggu" | queue skeleton | banner + retry | row detail failed | stamp + reload | own submission → approve disabled + reason | panel |
| K-14 loan | new loan, no schedule | facts skeleton | banner + retry | facts ok, schedule failed | stamp per panel | written off → read-only | panel |
| K-15 arrears | "Tidak ada tunggakan" | table skeleton | banner + retry | total ok, rows failed | stamp + reload | - (read-only screen) | panel |
| K-16 reports | pick a document | report computing | document error + ref | header ok, table failed | "Dihitung <time>" | closed period, no regenerate | document hidden by grant |
| K-17 audit | no events for filter | table skeleton | banner + retry | count ok, rows failed | stamp + reload | - | panel |
| K-18 users | no users | list skeleton | banner + retry | list ok, roles failed | stamp + reload | self-row actions limited | panel |
| K-19 params | no active value + Ajukan | table skeleton | banner + retry | keys ok, audit failed | stamp + reload | pending value → locked | panel |
| K-20 products | no product + Buat | list skeleton | banner + retry | list ok, versions failed | stamp + reload | approved version locked | panel |
| K-21 password | - (form only) | submit disabled | field + summary | - | - | - | panel |
| K-22 login | - | submit disabled | form error, focus | - | - | - | n/a |
| K-23 slip | not found (ref shown) | document skeleton | error + retry | - | reprint stamp | immutable | panel |
| K-24 statement | no movement in range | document skeleton | error + retry | rows ok, totals failed | "Dihitung <time>" | closed range marked | panel |

## 8. Responsive and print targets

| Context | Layout | Constraint |
|---|---|---|
| 1366×768 @100-125% (primary) | table + right action panel (360 px); toolbar ≤48 px; header 34 px | One screenful must hold the form, its review and the last result |
| 1100-1280 | panel drops below the table | Never a modal for a routine action (DESIGN §4) |
| 768-1024 (manager tablet) | single column; approvals and reports first-class | Tables keep horizontal scroll in a labelled region |
| ≤768 / zoom 200% | shell single column, stacked sections | Ledger, arrears, schedule and report tables are **never** card-ified; first and amount columns sticky |

Print:

| Document | Page | Must carry | Never |
|---|---|---|---|
| Slip (K-23) | 80 mm thermal, A5 fallback `NEEDS-COMPLIANCE-REVIEW` | member name + no., account no., amount, cashier, ref, timestamp + zone, COPY marker on reprint [R-22] | a reprint indistinguishable from the original |
| Statement (K-24) | A4 | running balance, period, generated-at, page x/y | totals that look like a GL reconciliation |
| Close certificate (K-03) | A4 | business date, totals, variance, actor, signature block | a certificate printed while the period is open |
| Report pack (K-16) | A4 portrait | repeated `thead`, control lines, period, "Belum ditutup" watermark when open | orphaned total rows |

## 9. What changes vs today

| Current screen | Verdict | Reason / finding |
|---|---|---|
| `/app/teller` | rebuild | PB unusable, no holder identity, blind close, stale balance after post (FE-EFF-03/07/08, FE-LOGIC-01/09/14) |
| `/app/vault` | repair | Branch race and stale filter rows; self-approval button (FE-LOGIC-07/08/17/19) |
| `/app/dayclose` → `/app/close` | rebuild | EOD only; EOM lives in ledger admin, EOY absent; two mental models (FE-EFF manager #5-6) |
| `/app/ledger` | repair | Filtered totals report a false imbalance; failures render empty; UTC default period (FE-LOGIC-02/03/11) |
| `/app/ledger/admin` | rebuild | Period close moves to K-03; journal search needs date/source filters (FE-EFF-18) |
| `/app/accounts/open` | merge → K-08 | Account opening without a member screen; no list, no holder name (FE-EFF-01/15/16) |
| `/app/loans` | rebuild | Limit 50, no DPD/outstanding, filter by UUID (FE-EFF-05, FE-LOGIC-04) |
| `/app/loans/[loanId]` | rebuild | No submit/approve; disburse unusable for `lending_maker`; duplicate payment after success (FE-EFF-02/04, FE-LOGIC-05/06) |
| `/app/params` | repair | Only keys with an active value; free-text numeric coercion; untyped (FE-EFF-13, FE-LOGIC-12) |
| `/app/products` | rebuild | Cannot create; offers TIME_DEPOSIT that nothing consumes (FE-EFF-12, R-16) |
| `/app/users` | rebuild | Cannot create/reset; branch typed as UUID (FE-EFF-06/14) |
| `/app/password` | repair | No confirmation field; typo locks the operator out (FE-LOGIC-21) |
| `/app/print/slip` | rebuild | No member, cashier, reprint marker (FE-EFF-19, R-22) |
| `/app/print/statement` | rebuild | No running balance, 500-row cap, no identity (FE-EFF-19) |
| `/login` | repair | `novalidate` with `required`; empty submit only fails server-side (FE-PRAC-22) |

New: member register, onboarding, member file, exit, obligations, origination, approval queue, arrears,
report family, audit viewer. Reason for each is the FE-EFF gap that has no screen at all - not a wish
list: membership, origination, approvals, arrears and reports are named BLOCKER/MAJOR in the audit.

## 10. Non-goals (MVP)

- Mobile app, offline mode, field-collection app. Reason: the pilot works from one branch on desktop.
- Time deposits and their catalogue entries (R-16); remove, do not hide.
- BPR/BPRS/syariah products, multi-koperasi, iuran anggota.
- Health ratios, DPK, branch P&L, cash-flow reports (R-28: deferred with tags).
- Promise-to-pay/contact log and dunning engine. Reason: beyond R-10 MVP; arrears is a list plus payment.
- Mandatory MFA (R-19/R-29); optional and throttled only.
- Automated off-host audit anchor (R-26); manual daily head-hash copy.
- Branch creation in the UI: no create endpoint exists (`listBranches` is read-only); stays a documented
  `ctl` runbook. Reason: a screen that cannot complete its task is worse than a named limit.
- File upload/scan of KYC documents; the product records references and consent only [DEP-2].
