# KRAN - Compliance obligation map

This document maps what a KSP pilot must be able to demonstrate to an auditor, a regulator or
its own pengurus, to what the system records or emits today. It is **not legal advice**. It does
not replace a licensed Indonesian advisor signing the obligation map for a specific
institution, and it does not state that any obligation is met.

Compliance is claimed per institution and per deployment, never by the product globally. The
pilot shape assumed here is one KSP, one branch, fewer than 5,000 members and synthetic data.
Real member data changes the bar; items that become binding at that point are marked.

Sources:

- `compliance/register.yaml`, the machine-read requirement to control to test register, read by
  `./task traceability`.
- `compliance/register-validation.md`, the research log with sources and passages. Every legal
  basis below points there and carries `VERIFY`.
- The banking and cooperative compliance expert memo produced during the replan, whose gap ids
  (G-01 to G-15) and obligation ids (O1 to O8) are reused here.
- `SECURITY.md` for controls, `OPERATIONS.md` for procedures, `ACCEPTED-LIMITS.md` for accepted
  risks.

Status vocabulary:

| Status | Meaning |
|---|---|
| Implemented | A control exists in code with a test, and the evidence artefact can be produced on demand. |
| Partial | Some control exists; the missing part is named. |
| Absent | No control and no artefact. |
| Deferred | Researched and registered, with no consumer in code. It must not be described as met. |

`NEEDS-COMPLIANCE-REVIEW` marks a value, threshold, field set or period that is **not** verified.
It is not a formality: a value carrying it cannot be presented to an examiner as a legal
requirement, and it must not be removed without a signed ruling.

---

## 1. Obligation map

| # | Obligation area | What the system must record or emit | Evidence artefact | Current state |
|---|---|---|---|---|
| O1 | KYC and member identity | Party record, identity document type and number (encrypted), risk level, review due date, who verified and when, audit row per change | Member file: document sighted, verification date, verifier, risk rating, re-KYC history | **Partial**. Party and KYC profile exist, with encryption, masking and audited unmask. No onboarding screen, no document or image storage, no consent record. |
| O2 | Transaction recording and audit trail | Balanced journal per money movement; reversals instead of edits; attributable, tamper-evident state changes; actor, time, branch | Trial balance for any date; journal for any transaction; audit extract by actor and resource; chain verification output | **Strong core, weak access**. Ledger invariants and chain are tested. The audit viewer shows a short unfiltered list with raw actor ids; investigation needs SQL. |
| O3 | Periodic reporting to the pengurus and RAT | Server-computed statements for a closed period, printable, tied to the ledger: position, income, equity change, SHU, member register | Signed statement set compared with system output for the same period; each line reconciled to `journal_line` | **Absent**. No balance sheet, income statement or equity statement; no year-end close; no SHU; no member register. |
| O4 | Personal data protection | Consent record (notice version, time, channel, wording hash), retention per data class, subject export and erase path, access log for unmasked identity data, breach answerability | Consent evidence for sampled members; notice version and date; subject-request log; breach runbook with a drilled timeline | **Absent as product**. Field encryption, masking and audited unmask exist. Consent, export, erase and breach workflow do not. |
| O5 | APU-PPT / PMPJ | Daily cash aggregation per member, threshold from parameters (not code), flag and review workflow, report register with status and dates, supporting data | Report register; per-case file; evidence that aggregation matches `deposit.transaction` | **Absent**. No cumulative daily cash aggregation, no report register, no case file. |
| O6 | Document retention | Written schedule per record class, enforced by registered scheduled tasks; purge run log; archive or export path; proof that nothing inside its window was deleted | Retention policy document; purge task history; sample records older than N still present | **Undecided**. Audit, outbox and inbox have no retention. Only the idempotency sweep has a TTL. |
| O7 | Information security | Grant and revoke history, separation-of-duties conflicts, login and failure records, deploy and migration records, restore drill records, patched dependencies | Access matrix against actual accounts; grant/revoke audit; restore evidence; dependency scan output | **Partial**. Least-privilege roles and seeded conflict pairs exist; dependency scanning, privilege proof for append-only tables, and off-host encrypted backups do not. |
| O8 | Complaint and dispute handling | A case record (member, date, transaction reference, resolution, approver) linked to journal and slip; a printed slip the member can hold | Case file per complaint; the printed slip or statement | **Absent**. No complaint entity, and the member-facing artefact lacks institution header and member identity. |

---

## 2. Obligation detail

### O1 KYC and member identity

**Obligation.** Identify the person before the first transaction, capture the document type and
number, assign a risk level, re-review on schedule, and escalate on suspicion. The legal basis
is researched in `compliance/register-validation.md` and remains `VERIFY`; whether each element
applies to a KSP pilot, and with what detail, is a question for the advisor.

**What must be recorded or emitted.** A party record; identity document type and number stored
as ciphertext; risk level and review date; the verifying user and timestamp; an audit row for
every change; a member number and membership status once the membership aggregate exists.

**Evidence artefact.** A member file that shows the document was sighted, by whom and when, the
risk rating, and the re-KYC history.

**Current gap.** The `party` module stores identity data with field encryption, masks it by
default, and audits unmasking with a reason. There is no onboarding screen: identity data can
only be entered through the API, so there is no product evidence of who verified what (blocker
B7, gap G-02). There is no document or image storage, and no consent record. Membership itself
is not a first-class aggregate: no member number, status, join or exit date (blocker B6, gap
G-01). Both are scheduled in the membership phase and the UI rebuild.

**Reference.** REG-004, REG-010, REG-001 (see section 3); audit G-01, G-02, B6, B7; roadmap P3
and P6.

### O2 Transaction recording and audit trail

**Obligation.** Every money movement posts a balanced journal; corrections are reversing
entries; every state change leaves an attributable, tamper-evident record. The accounting
standard and internal-control expectations are researched in
`compliance/register-validation.md` and remain `VERIFY`.

**What must be recorded or emitted.** Immutable `journal` and `journal_line`; immutability
triggers and deferred balance and two-line constraints; a hash-chained `platform.audit_log`
with actor, UTC time, business date and branch; a daily anchor line; journal ownership clear
enough that a subledger journal cannot be reversed through the generic endpoint.

**Evidence artefact.** Trial balance for any date; the journal for any transaction; an audit
extract for any actor or resource; `ctl verify-audit` output; the anchor file.

**Current gap.** The ledger core is the strongest part of the system: invariants are enforced by
the database and proven by integration tests. Three gaps matter for evidence:

1. Reversing a journal owned by lending, PPAP or accrual could succeed because ownership
   detection knows only a few tables (blocker B3). Scheduled in P1.
2. The audit viewer is a short unfiltered list with raw actor UUIDs, and `/audit` has no cursor,
   so a member's history cannot be produced from the product (gap G-05, `C18`). Investigation
   means SQL today.
3. The anchor stays on the host, and the chain is computed inside the database, so the
   guarantee is "no application path can alter history", not "no one can" (gap G-07). A written
   disclosure is required.

**Reference.** REG-011 and REG-101 (section 3); audit G-05, G-07, B3, B4; `SECURITY.md` section
6; `ACCEPTED-LIMITS.md`.

### O3 Reporting to the pengurus and RAT

**Obligation.** Produce, at least annually, the statements the pengurus signs and the RAT
ratifies: financial position, income, equity change, SHU, and the member register. Report
formats and the applicable standard are researched in `compliance/register-validation.md` and
remain `VERIFY`.

**What must be recorded or emitted.** Server-computed statements for a closed period, with
period and business date, printable, tied to closed periods and reconciling to `journal_line`.
A year-end close task, an SHU computation per member, and an archive of the RAT decision.

**Evidence artefact.** The signed statement set compared with system output for the same
period, line by line.

**Current gap.** Reports are absent, not merely incomplete: no balance sheet, income statement
or equity statement (gap G-03, `C18`); no year-end close and no SHU (blocker B8, gap G-04);
no member register at all (blocker B6). The MVP report pack is the RAT set (R-28): balance
sheet, income statement, equity statement, member register, pokok/wajib arrears, loan exposure
and arrears, cash recap, close certificate, SHU per member, and a filtered audit viewer. Health
ratios, DPK and branch profit and loss are deferred with tags and must not be promised.

**Reference.** REG-011, REG-101, REG-103, REG-104, REG-205, REG-207 (section 3); audit G-01,
G-03, G-04; roadmap P4 and P5.

### O4 Personal data protection

**Obligation.** Record a lawful basis; give notice; state retention; answer subject requests;
detect and notify a breach. The research file records the statutory framework and the
notification window; both remain `VERIFY`, and the exact notice content is an advisor question,
not an engineering one.

**What must be recorded or emitted.** Consent rows (member, notice version, timestamp, channel,
wording hash); the notice version shown; retention per data class; an export and erase path; an
access log of who viewed unmasked identity data; a breach workflow that can answer "which
records, which members, since when" within hours.

**Evidence artefact.** Consent evidence for sampled members; notice version and date; a
subject-request log; a breach runbook with a drilled timeline.

**Current gap.** The product has encryption, masking and audited unmask, and logs without PII.
It has no consent record, no export or erase path, and no breach workflow (gap G-08). A
cooperative cannot simply delete financial history on request, because accounting and AML
retention point the other way; the resolution is a signed policy plus an "erasable /
non-erasable" classification, which does not exist. Organisational duties (notice text, DPO
contact, notification decision, DPIA) are outside the product and cannot be discharged by a
feature.

**Reference.** REG-002 (deferred, section 3); audit G-08, `BE-ISO-15`; `NEEDS-COMPLIANCE-REVIEW`.

### O5 APU-PPT / PMPJ

**Obligation.** Aggregate cash per member per business day, flag threshold and suspicion, keep
a register of reports filed, and retain supporting data. Applicability to a KSP and the
reporting mechanics are researched in `compliance/register-validation.md` and remain `VERIFY`.

**What must be recorded or emitted.** Daily cash aggregation per member; a threshold held in
parameters, not code; a flag and review workflow; a report register with status and dates; an
export that reconciles to `deposit.transaction`.

**Evidence artefact.** The report register, a per-case file, and evidence that aggregation
matches the transaction table.

**Current gap.** None of it exists: no aggregation, no register, no case file (gap G-09). Any
threshold quoted in the research file is research, not a settled rule, and must not be seeded
as a business value without the advisor's sign-off. When implemented, the threshold belongs in
the parameter catalogue and carries `NEEDS-COMPLIANCE-REVIEW` until signed.

**Reference.** REG-003 (deferred), REG-004 (risk monitoring) (section 3); audit G-09.

### O6 Document retention

**Obligation.** A written schedule per record class, enforced by scheduled tasks; a purge run
log; an archive or export path; proof that nothing inside its window was deleted. The statutory
periods per class are **not** settled in the repo.

**What must be recorded or emitted.** A retention parameter per class; a purge task registered
through `daycloser`, idempotent, with a run record; an archive or export path for records that
leave the hot database.

**Evidence artefact.** The retention policy document, the purge task history, and a sample
showing that records older than the stated period are still present.

**Current gap.** Retention is undecided for `platform.audit_log`, `platform.outbox` and
`platform.inbox`; no purge job exists (gap G-06, `BE-ISO-12`). The only retention that exists is
the idempotency TTL (24 hours default, hard cap 30 days). The expert memo proposes periods per
class, including a long period for postings and audit; those are **proposals**, not law, and
none is signed. The owner must decide the number per class, who may authorise an early purge,
whether archived audit segments stay queryable, and whether the institution's own AD/ART
imposes a longer period.

**Reference.** R-26; audit G-06, `BE-ISO-12`, `C09`; tasks T-248 and T-249. The machine
register has no retention requirement row yet, so no REG id is cited here; adding one is a
register change, not a documentation change.

### O7 Information security

**Obligation.** Least privilege, unique accounts, approval of privileged changes, backup and
restore proof, incident response, patched dependencies. Which control framework applies to a
KSP is `VERIFY`; a BPR-specific rule must not be claimed for this institution type.

**What must be recorded or emitted.** User and role grant history; separation-of-duties
conflicts; login and failure records; deploy and migration records; restore drill records;
dependency scan output.

**Evidence artefact.** The access matrix compared with actual accounts; grant and revoke audit;
restore evidence; dependency scan output.

**Current gap.** Roles are least-privilege and conflict pairs are seeded, but: dependency
scanning does not exist; proof that the runtime role cannot update append-only tables is a
manual step, not a CI assertion; revoke and disable are not bounded by the actor's grants; and
backups are unencrypted on the same host with no point-in-time recovery (gaps G-10, G-11,
G-13). MFA is optional by ruling, so the compensating controls must be operated and the
limitation disclosed. These are engineering controls, described in `SECURITY.md`, not
compliance claims.

**Reference.** REG-205 and REG-009 (scope and exclusions, section 3); audit G-10, G-11, G-13,
`BE-ISO-10`, `BE-ISO-13`.

### O8 Complaint and dispute handling

**Obligation.** A member can contest a posting; the cooperative can reconstruct it and show the
outcome. Whether a formal complaint register is required for a KSP, or is only good practice
under AD/ART and consumer protection, is `VERIFY`.

**What must be recorded or emitted.** A complaint case (member, date, transaction reference,
resolution, approver), linked to the journal and the slip; a printed slip or statement that
carries institution header, member identity, cashier, timestamp and timezone.

**Evidence artefact.** A case file per complaint, and the printed slip the member holds.

**Current gap.** No complaint entity exists (gap G-12). The slip is browser print only, with no
institution header, no member identity and no print audit; the exact field set is
`NEEDS-COMPLIANCE-REVIEW` (R-22). A member cannot currently be given a paper that names them,
which also weakens O2 and O3 evidence in a dispute.

**Reference.** R-22; audit G-12, `C14`; `ACCEPTED-LIMITS.md`.

---

## 3. Register index

Every requirement id below exists in `compliance/register.yaml`. Ids are reproduced exactly;
titles are the recorded titles, with `VERIFY` applying to every legal citation in them. The
register is a link checker, not a compliance claim: `./task traceability` proves that an
`active` row has a control and a matching test name, not that the value or article is correct.

### 3.1 Active requirements

| ID | Recorded title | Controls | Evidence in code |
|---|---|---|---|
| REG-204 | Asset quality and PPAP/CKPN: collectibility from DPD bands, allowance per grade. The cited regulation is `VERIFY`. | `lending.collectibility.dpd_bounds`, `lending.ppap.rates`, `lending.restructure.clean_periods`; module `lending` | `modules/lending/tests/tppap.nim`; `apps/api/tests/itdaycloser_lending.nim` |
| REG-004 | APU-PPT: member risk monitoring (risk level, re-KYC schedule); full CDD/EDD does not exist. `VERIFY`. | `party.kyc.risk_levels`, `party.kyc.default_risk_level`, `party.kyc.review_months`; module `party` | `apps/api/tests/itapi_kyc.nim` |
| REG-010 | Member identity: document types and lengths; no Dukcapil adapter. `VERIFY`. | `party.identity.doc_types`, `party.identity.doc_lengths`; module `party` | `apps/api/tests/itapi_kyc.nim` |
| REG-011 | Accounting standard: COA code pattern and posting rules; savings pokok/wajib in equity. `VERIFY`. | `ledger.coa.code_pattern`; module `ledger` | `apps/api/tests/itapi_ledger.nim`; `apps/api/tests/itapi_teller.nim` |
| REG-101 | Cooperative law: savings pokok/wajib treated as equity. `VERIFY`. | Modules `ledger`, `deposit`, `teller` (no parameter) | `apps/api/tests/itapi_teller.nim` |

### 3.2 Deferred requirements

Deferred means researched and registered with no consumer in code. Do not describe any of these
as implemented, and do not cite the recorded title as a settled legal requirement.

| ID | Recorded title | Why deferred / scope note |
|---|---|---|
| REG-001 | P2SK umbrella supervision; the KSP transition to OJK is not relevant to code yet. `VERIFY`. | No code consumer. |
| REG-002 | Personal data protection: consent, subject rights, retention, breach notification; not built. `VERIFY`. | O4; `NEEDS-COMPLIANCE-REVIEW`. |
| REG-003 | AML: LTKT/LTKM reporting; transaction monitoring not built. `VERIFY`. | O5; `NEEDS-COMPLIANCE-REVIEW`. |
| REG-008 | Final income tax on member savings interest; no tax module. `VERIFY`. | Out of MVP scope because savings return is SHU-based (R-16), not because it is met. Revisit if interest returns. |
| REG-009 | Deposit insurance: a KSP is not an LPS participant; rate and flag exist only for a BPR pack. `VERIFY`. | The product must never display a guarantee claim. |
| REG-103 | Cooperative business licence, BMPP ratios, own capital; enforcement absent. `VERIFY`. | Deferred with the health-ratio set (R-28). |
| REG-104 | Cooperative health assessment reports; not built. `VERIFY`. | Deferred; only relevant if the institution actually files. |
| REG-205 | BPR IT governance rule; pack BPR, later phase. `VERIFY`. | Must **not** be claimed for a KSP. |
| REG-207 | BPR reporting and credit information system; pack BPR, later phase. `VERIFY`. | Must **not** be claimed for a KSP. |

No requirement id above has been renamed, merged or renumbered. If a future register change
adds or retires an id, the change belongs in the register and its review log, not in this
document.

---

## 4. Research and verification status

- The only verification source in the repository is `compliance/register-validation.md`. It
  records sources, URLs and passages, and it marks open questions. Reading it is a starting
  point, not a sign-off.
- The specification carries `V?` and `V!` markers on uncertain regulatory statements. Those
  markers are not proof, and this document does not resolve them.
- Values that depend on an unverified basis are tagged `NEEDS-COMPLIANCE-REVIEW` in seeds,
  parameters and code. That tag is the guard against presenting a guess as a rule.
- This document deliberately does not restate article numbers, monetary thresholds or
  notification deadlines. Where a number matters, cite the research file and the signed
  advisor note; do not copy a number from a planning memo into code or a report.
- The register covers only the rows already traced to code. Other researched rows stay in the
  research log and the specification and are not counted as covered.

---

## 5. Evidence and audit readiness

An examiner asks for artefacts, not plans. "Produced" means it exists, can be reproduced on
demand, and cannot be edited by the person being audited.

| Artefact | Produced today | What is missing |
|---|---|---|
| Trial balance and journal for any date | Yes | No statement layer above it |
| Proof of ledger immutability | Yes, by triggers and integration tests | Proof that the runtime role lacks update and delete is a manual step, not a CI assertion |
| Audit chain verification | Yes, plus a daily anchor timer | The anchor stays on the host; the chain is computed in the database |
| Audit investigation by member or actor | No | The viewer is a short unfiltered list; no cursor; raw actor ids |
| Approval records | Partial: vault top-up, product versions, parameter changes | No single approvals view; lending and journal-correction pairs are not ratified |
| Member records | No | No membership aggregate |
| KYC file | Partial | No document artefact, no onboarding screen |
| Cash counts | Yes: sessions, expected cash, variance, journals | Variance explanation is not an evidenced artefact |
| Backup restoration proof | One drill, 21 Oct 2026 | Dumps are unencrypted, same host, no point-in-time recovery |
| Deploy and change record | Yes: release record, deploy log, CI gate | The build is not bit-reproducible (no Nim lockfile) |
| Access review evidence | Partial | Revoke and disable are not privilege-bounded |
| Printed slip or statement | Browser print only | No institution header, member identity, print audit or archive |

The pilot readiness gate (T-253) and the audit evidence pack (T-257) collect these artefacts
with checksums and dates. A readiness checklist signed without the artefacts is not evidence.

---

## 6. Retention position

R-26 requires retention to be defined per record class, with a manual daily head-hash copy and a
written disclosure, and defers automated off-host anchoring. No period is settled by this
document.

| Class | Where it lives | Current retention | State |
|---|---|---|---|
| Financial postings | `ledger`, module subledgers | Permanent in practice; no purge path | Immutable by trigger; retention period still to be signed |
| Audit log and anchor lines | `platform.audit_log`, host anchor file | No purge; grows without bound | Period to be signed (T-248); head hash copied manually (T-249) |
| KYC and identity data | `party` | No purge; encrypted and masked | Period tied to membership life plus a signed tail; `NEEDS-COMPLIANCE-REVIEW` |
| Teller sessions and cash | `teller` | No purge | Cash-control evidence; period to be signed |
| Sessions and login events | `platform.session` | Session purge exists | Audit rows follow the audit class |
| Outbox and inbox | `platform.outbox`, `platform.inbox` | No purge | Delivery evidence, not legal evidence |
| Idempotency responses | `platform.idempotency_key` | 24 hours default, 30 days hard cap | May contain member data; do not raise the cap |
| Backups | Host filesystem | Daily 7, weekly 28, monthly 84, plus pre-deploy | Unencrypted, same host; off-host copy is not implemented |
| Printed slips and statements | Paper only | Not stored server-side | Policy decision: the member's copy is the only original |

Any number in this table that becomes a policy must be recorded in `DECISIONS.md`, applied
through parameters, and enforced by a registered `daycloser` task. A retention statement
without a purge task and a run log is not evidence.

---

## 7. What must not be claimed

- **Do not claim "compliant with" any law, regulation or standard.** The product is not
  certified, and no advisor has signed the obligation map for a specific institution.
- **Do not claim mandatory MFA.** MFA is optional (R-19, R-29). A stolen password yields a full
  session for an account without an enrolled factor. Say that in writing to the pengurus.
- **Do not claim deposit insurance.** A KSP is not an LPS participant; no screen or report may
  imply a guarantee.
- **Do not claim automated off-host audit anchoring.** The daily head-hash copy is manual and
  the disclosure is written.
- **Do not present a researched threshold or article as settled.** If it is tagged
  `NEEDS-COMPLIANCE-REVIEW` or `VERIFY`, it is not a requirement until signed.
- **Do not present the RAT report pack as delivered** before the annual close and SHU exist.

---

## 8. What requires a human signature

These cannot be verified from the repository:

1. The obligation map in this document, signed by a licensed advisor for the pilot institution.
2. Retention periods per record class, checked against the institution's AD/ART.
3. Written disclosure to the pengurus of: optional MFA, the host-local audit anchor, and
   unencrypted same-host backups.
4. A named-account matrix and a break-glass procedure actually in place in production.
5. A decision on whether the cooperative is a PMPJ subject and, if so, who files reports and
   how.
6. Consent and notice text, the complaint procedure, and who answers data-subject requests.
7. The SHU basis and the RAT decision record format.

Until those signatures exist, the correct statement is: the system has controls for parts of
O1, O2, O3 and O7, and the remaining obligations are open. That is the statement this document
supports.
