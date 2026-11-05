# KRAN domain glossary and aggregate ownership

One word per thing. The Indonesian term is what an operator sees in the UI, on a slip, or on a
statement; the English gloss is for code, tests, and this document. Internal words stay internal.

Ownership rule: one module owns each aggregate and is the only writer of its tables. Other
modules talk to it through `api.nim` and events. The schema inventory is in `SCHEMA.md`; this
document names the invariant, not the DDL.

## Aggregates

| Aggregate | Owning module | Operator term | Invariant protected |
|---|---|---|---|
| Member | `coop` (target module, absent today) | Anggota (member), Nomor anggota (member number) | A member has one immutable number and a status lifecycle (candidate, active, exited). A member is never deleted; exit is a state with a reason and a date. Savings and loan obligations are derived from postings, never from a second balance table or a second ledger. |
| Party | `party` | Pihak (party); for a member the UI shows Anggota | A party has a unique CIF per the configured format and a normalized display name. Identity documents are stored as ciphertext plus a blind index; the module never touches cryptography. KYC risk history is append-only. A party is identity, not membership and not an account. |
| Account and deposit | `deposit` | Rekening simpanan (savings account), Setor (masuk) (deposit in), Tarik (keluar) (withdrawal out), Pemindahbukuan (PB) (internal transfer) | Balance never goes below zero at the database, and the write path rejects it first. Transaction and transfer rows are immutable; a correction is a reversing journal plus a new row. The ledger journal is the source of truth; the account balance is a cache. Money is exact decimal, never float. |
| Product | `product` | Produk (product), Versi produk (product version) | A product version is effective-dated. ACTIVE versions never overlap. Maker and checker are different people. An ACTIVE version is immutable; a business attribute change creates a new version. Bindings may only name registered parameters with the `product.` prefix. |
| Ledger and journal | `ledger` | Buku besar (ledger), Jurnal (journal), Neraca saldo (trial balance), Periode (period), Tutup buku (close books) | A journal balances at COMMIT, has at least two lines, and is immutable. One reversal per source journal. A period closes in one direction only; a closed period rejects postings. Account normal side follows account type. |
| Loan | `lending` | Pinjaman (loan), Akad (loan agreement), Angsuran (instalment), Tunggakan (arrears), Kolektibilitas (collectibility), Penyisihan (allowance), Hapus buku (write-off) | The schedule is stored per row, not regenerated after disbursement. Maker and checker differ above APPLIED. Allocation order comes from the pinned product version. A write-off is a ledger event with a reason, never a delete. Allowance and collectibility follow the business date. |
| Teller session | `teller` | Kasir (cashier), Kas besar (branch vault), Tutup kas (close cash) | One OPEN session per branch and cashier. Expected cash equals opening float plus cash in minus cash out. The vault balance never goes negative; a top-up is a maker-checker request, not a direct edit. A cash transaction has exactly one cash movement row. |
| Day-close | `daycloser` | Tutup buku harian, bulanan, tahunan (daily, monthly, annual close) | One active run per scope and business date, held by a unique index and an advisory lock. The state machine is explicit and resumable; a succeeded chunk is not rerun. Parameters are frozen per run. The business date moves with the run, and modules never create their own batch or cron. |
| Parameters | `platform` | Parameter (parameter), Nilai berlaku (effective value) | Every business number is a typed, effective-dated parameter. A change is a maker-checker request with a reason. A missing active value is an error, not a default in code. Scope resolution is PRODUCT, BRANCH, INSTITUTION, SEGMENT, GLOBAL, most specific first. |
| Audit | `platform` | Jejak audit (audit trail) | Audit rows are append-only and hash-chained; actor, action, entity, time, and reason are recorded. Retention is defined per record class. The chain head is copied off the host manually each day; automated off-host anchoring is an accepted limit. |

## Words that must not reach the operator

`DESIGN.md` section 9 and `docs/design/04-a11y-and-copy.md` section 5 set the rule: one word per
thing, and implementation vocabulary never appears in the UI or on paper.

| Internal word | Why it is banned | What the operator sees instead |
|---|---|---|
| `uuid`, `partyId`, `accountId` | An internal identifier is not an identity and cannot be checked at the counter | Nomor anggota (member number), Nomor rekening (account number), or Rujukan (reference) |
| `run` | The operator starts and follows a close, not an engine job | Proses (process), or Tutup buku harian, bulanan, tahunan |
| `vault` | The English implementation word hides a physical cash position | Kas besar (branch vault) |
| `party` | A member is a person, not a database row | Anggota (member); Pihak (party) only for a non-member counterparty |
| `CIF` | The CIF is an internal party key, not the membership identity | Nomor anggota for a member; the party name for a non-member |
| Table names such as `deposit.transaction`, `platform.audit_log` | A table is not a business object | Rekening (account), Transaksi (transaction), Jejak audit (audit trail), Jurnal (journal) |
| `teller` in Indonesian copy | The person is a cashier; the English word is a code identifier | Kasir (cashier) |
| `batch`, `dayclose`, `EOD`, `EOM`, `EOY` | Four internal names for one close model | Tutup buku harian, Tutup buku bulanan, Tutup buku tahunan |
| `finalisasi sesi`, `end session`, `logout` for a cash close | Closing cash is a counted physical act, not a session logout | Tutup kas (close cash) |
| `ID rekening`, `masukkan ID rekening` | The operator knows account numbers, not UUIDs | Nomor rekening (account number) |
| `trace ID`, `request ID` | The operator quotes one support number | Rujukan (reference) |

## Related vocabulary

| Concept | Indonesian UI | English UI | Note |
|---|---|---|---|
| Principal savings | Simpanan pokok | Principal savings | Paid once at joining, not withdrawable |
| Mandatory savings | Simpanan wajib | Mandatory savings | Per-period obligation, per member |
| Voluntary savings | Simpanan sukarela | Voluntary savings | Withdrawable balance |
| Surplus | SHU (Sisa Hasil Usaha) | SHU (surplus) | Expand once per document in each locale; never translate the acronym away |
| Annual members meeting | RAT (Rapat Anggota Tahunan) | RAT (annual members meeting) | Expand once per document in each locale |
| Board | Pengurus | Board | Governance role; read and approve, not data entry |
| Supervisory board | Pengawas | Supervisory board | Oversight, read-only |
