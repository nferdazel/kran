# KRAN capability ledger

Derived from the replanning audit (backend capability map and screen inventory) and re-checked
against the tree. The old product has 21 delivered,
4 partial, and 12 missing capabilities. The coop and pilot capabilities that P3-P7 will add are
listed as missing until their tasks land.

How to read a row:

- `delivered` means the named test fails if the capability breaks. The screen or endpoint column
  names the layer that the audit proved; it does not claim that every persona reaches that layer
  through the current web UI.
- `partial` means a real path exists but a material part is missing. The note names the limit.
- `missing` means no path exists. The note names the audit finding or the task that will create it.
- A row may cite an operation id instead of a screen when the capability is API-only today.

| ID | Capability (can the persona do this today?) | Persona | Screen or endpoint | Evidence | Status |
|---|---|---|---|---|---|
| C-01 | Sign in, keep a session, and change a password | Kasir, Admin | `/login`, `login`, `changePassword` | `apps/web/tests/e2e/flow.spec.ts`; `apps/api/tests/itapi_auth.nim` | delivered |
| C-02 | Hold a role and branch scope that the server enforces on every call | Admin | `authorize` on each route | `apps/api/tests/itapi_roles.nim`; `modules/platform/tests/itauth.nim` | delivered |
| C-03 | Submit and approve a parameter change as maker and checker | Manajer, Admin | `/app/params`, `submitParamChange`, `approveParamChange` | `modules/platform/tests/itparam.nim`; `apps/web/tests/e2e/flow.spec.ts` | delivered |
| C-04 | Read the audit trail for an actor, entity, or date | Admin, Manajer | `/app/audit`, `listAudit` | `apps/api/tests/itapi_auth.nim`; `modules/platform/tests/itplatform.nim` | delivered |
| C-05 | Check liveness and readiness of the service | Operator | `getHealth`, `getReadiness` | `apps/api/tests/itapi_ws.nim` | delivered |
| C-06 | Create, search, and read a party with a CIF | Admin | `searchParties`, `createParty`, `getParty` | `apps/api/tests/itapi_party.nim` | delivered |
| C-07 | Open a period, post a balanced journal, and reverse it with a reason | Admin | `/app/ledger/admin`, `listJournals`, `reverseJournal` | `apps/api/tests/itapi_journal.nim`; `modules/ledger/tests/itjournal.nim` | delivered |
| C-08 | Read a trial balance and period balances | Manajer, Pengurus | `/app/ledger`, `getTrialBalance`, `getLedgerBalances` | `apps/api/tests/itapi_ledger.nim`; `modules/ledger/tests/ittb.nim` | delivered |
| C-09 | Create and approve a savings product version | Admin, Manajer | `/app/products`, `createProductVersion`, `approveProductVersion` | `apps/api/tests/itapi_product.nim`; `modules/product/tests/itproduct.nim` | delivered |
| C-10 | Open, list, and read a savings account | Admin | `openDepositAccount`, `getDepositAccount`, `listDepositAccounts` | `apps/api/tests/itapi_deposit.nim`; `modules/deposit/tests/itaccount.nim` | delivered |
| C-11 | Post a cash deposit and a cash withdrawal | Kasir | `/app/teller`, `postCashTransaction` | `apps/web/tests/e2e/teller.spec.ts`; `apps/api/tests/itapi_teller.nim` | delivered |
| C-12 | Post a transfer between two accounts | Operator (API) | `postTransfer` | `apps/api/tests/itapi_teller.nim`; `modules/deposit/tests/ittransfer.nim` | delivered |
| C-13 | Open and close a cash session and approve a vault top-up | Kasir, Manajer | `/app/teller`, `/app/vault`, `openTellerSession`, `closeTellerSession`, `approveTellerVaultTopUp` | `apps/api/tests/itapi_teller_sessions.nim`; `apps/web/tests/e2e/vault.spec.ts` | delivered |
| C-14 | Submit, approve, and disburse a loan | Petugas pinjaman, Manajer | `/app/loans/[loanId]`, `submitLoan`, `approveLoan`, `disburseLoan` | `apps/api/tests/itapi_lending.nim` | delivered |
| C-15 | Record an instalment payment with component allocation | Kasir | `/app/loans/[loanId]?tab=pay`, `payLoan` | `apps/api/tests/itapi_lending.nim`; `apps/web/tests/e2e/lending-actions.spec.ts` | delivered |
| C-16 | Restructure, write off, and recover a loan | Manajer | `/app/loans/[loanId]`, `restructureLoan`, `writeOffLoan`, `recoverLoan` | `apps/api/tests/itapi_lending.nim`; `apps/web/tests/e2e/lending-actions.spec.ts` | delivered |
| C-17 | Read loan arrears, allowance, and GL reconciliation reports | Manajer | `loanArrearsReport`, `loanAllowanceReport`, `loanReconciliation` | `apps/api/tests/itapi_lending_reports.nim` | delivered |
| C-18 | Run EOD and resume or cancel a run | Manajer | `/app/close`, `startDayClose`, `resumeDayClose`, `cancelDayClose` | `apps/api/tests/itdaycloser_lifecycle.nim`; `apps/web/tests/e2e/dayclose.spec.ts` | delivered |
| C-19 | Close an accounting period through EOM | Manajer | `/app/close`, `closePeriod` | `apps/api/tests/itdaycloser_ledger.nim` | delivered |
| C-20 | Reprint a cash slip with its reference | Kasir | `/app/print/slip/[transactionId]`, `getCashTransactionSlip` | `apps/web/tests/e2e/print.spec.ts` | delivered |
| C-21 | Retry a money post without double posting | Kasir | `postCashTransaction` with `Idempotency-Key` | `apps/api/tests/itapi_idempotency.nim` | delivered |
| C-22 | Use a second factor at sign-in | Kasir, Admin | `/login`, `startMfaEnrolment`, `verifyMfaChallenge` | `apps/api/tests/itapi_mfa.nim`; limit: seeded off (R-19, R-29), no UI enrolment or recovery codes until T-246 | partial |
| C-23 | Record and inspect an identity document | Admin | `addIdentityDoc`, `getPartyKyc` | `apps/api/tests/itapi_kyc.nim`; limit: number and metadata only, no file or image storage (DEP-2), 501 without a KEK | partial |
| C-24 | Print a statement with a running balance | Kasir | `/app/print/statement/[accountId]`, `getAccountStatement` | `apps/web/tests/e2e/print.spec.ts`; `apps/api/tests/itapi_deposit.nim`; limit: no running balance, 500-row cap | partial |
| C-25 | Create and rename a branch without a shell | Admin | `/api/v1/branches`, `listBranches` | `apps/api/tests/itapi_users.nim`; limit: read-only API, writes use `ctl create-branch` | partial |
| C-26 | Open a time deposit and run its maturity and early-withdrawal rules | Admin | none | `missing: BE-EFF-04, account.nim:131; no create path` | missing |
| C-27 | Pay a return on savings | Anggota, Admin | none | `missing: BE-EFF-05; savings earns no interest; R-16 moves return to SHU` | missing |
| C-28 | Recognise loan interest over time | Manajer | none | `missing: BE-EFF-08; cash-basis on payment` | missing |
| C-29 | Assess a late penalty | Petugas pinjaman | none | `missing: BE-EFF-08; schedule always sets penalty due to zero` | missing |
| C-30 | Close the year | Manajer | `/app/close` | `missing: B8, calendar.nim:109; EOY is a label, not a task` | missing |
| C-31 | Register and track a member lifecycle | Admin | `/app/members` | `missing: B6; no coop module` | missing |
| C-32 | Generate and collect pokok and wajib obligations | Admin | `/app/savings/obligations` | `missing: B9; savings kind is a label only` | missing |
| C-33 | Calculate and distribute SHU | Manajer | `/app/reports/shu` | `missing: B8; no SHU code` | missing |
| C-34 | Produce the RAT report pack | Pengurus | `/app/reports` | `missing: B8, R-28; no report queries` | missing |
| C-35 | Produce balance sheet, income statement, and equity statement | Pengurus | `/app/reports` | `missing: C18; report.nim has trial balance and balances only` | missing |
| C-36 | Produce regulatory, tax, and APU-PPT reports | Manajer | none | `missing: BE-EFF-33; no route` | missing |
| C-37 | Notify an operator of an event | Admin | none | `missing: BE-EFF-34; no notifier` | missing |
| C-38 | Onboard a member with a number and KYC references | Admin | `/app/members/new` | `missing: T-204, T-205, T-206, T-245` | missing |
| C-39 | Exit a member and compute the refund | Manajer | `/app/members/[memberId]/exit` | `missing: T-205, T-245` | missing |
| C-40 | Generate the period obligation list idempotently | Admin | `/app/savings/obligations` | `missing: T-208` | missing |
| C-41 | Pay or waive an obligation and see arrears | Admin | `/app/savings/obligations` | `missing: T-214` | missing |
| C-42 | Offer pokok, wajib, and sukarela as product kinds with SHU return | Admin | `/app/products` | `missing: T-213` | missing |
| C-43 | Sign and compute the SHU basis per member | Manajer | `/app/reports/shu` | `missing: T-211, T-216` | missing |
| C-44 | Record the RAT decision before distribution | Manajer | `/app/reports/shu` | `missing: T-217` | missing |
| C-45 | Post the SHU distribution with a checker | Manajer | `/app/reports/shu` | `missing: T-218` | missing |
| C-46 | Create a user, reset a password, and enrol MFA without a shell | Admin | `/app/users` | `missing: T-246` | missing |
| C-47 | Page through every capped list with a total | all | list endpoints | `missing: T-220` | missing |
| C-48 | See a member register report | Pengurus | `/app/reports/member-register` | `missing: T-224` | missing |
| C-49 | See a SHU statement per member | Pengurus | `/app/reports/shu` | `missing: T-229` | missing |

## Counts

| Status | Old product | Coop and pilot | Total |
|---|---:|---:|---:|
| delivered | 21 | 0 | 21 |
| partial | 4 | 0 | 4 |
| missing | 12 | 12 | 24 |
