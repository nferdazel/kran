## Posting jurnal **sinkron** untuk transaksi tunai `deposit` (T-088b, spec §9.3).
##
## Berbeda dari konsumen outbox (`posting.nim`), jurnal di sini ditulis di **transaksi DB yang sama**
## dengan mutasi saldo — bukan lewat worker. Alasannya: transaksi teller tidak boleh "saldo berubah
## tanpa jurnal" atau sebaliknya; satu `withDbTx` membuat keduanya atomik.
##
## Rule tetap dari data (`ledger.posting_rule`), bukan literal di kode (spec §10.5): `selectRule` +
## `buildLines` (domain ledger) dipakai ulang, sama seperti `handleReverseJournal`.
##
## **Penjaga penting**: event outbox yang diterbitkan handler transaksi **tidak boleh** ber-header
## `"accounting": true`, kalau tidak `posting.nim:isAccounting` akan memposting jurnal kedua. Posting
## di sini bukan event, jadi tidak ada header yang perlu diset.

import std/json

import db_connector/db_postgres

import kernel/[clock, ids, money]
import ledger/domain/[journal, posting]
import ledger/infrastructure/[journal_repo, posting_repo]

proc postJournalSync*(db: DbConn, clock: Clock, eventType: string, amount: Money,
    branchId: Id, sourceRef: Id, businessDate, idempotencyKey: string,
    actor: Id, productCode, accountType, savingsKind: string): Id =
  ## Menulis satu jurnal double-entry dari posting rule `eventType` di transaksi pemanggil dan
  ## mengembalikan `journal_id`. Tidak ada rule/ambigu → `ValueError`; periode tertutup/tidak ada →
  ## `DbError` dari trigger `ledger` (pemanggil memetakannya ke 409 `period_closed`).
  ## `idempotencyKey` unik per transaksi (lapis kedua anti-jurnal-ganda pada replay).
  ##
  ## Payload pemilihan rule **wajib** memuat konteks produk & rekening: `ruleMatches` mencocokkan
  ## `product_code` rule dengan `payload.product`, dan rule berkondisi (mis. `savingsKind` POKOK/WAJIB
  ## dari T-111) mencocokkan `conditions` sebagai subset payload. Nilai kosong sengaja **tidak**
  ## ditulis, supaya rule berkondisi tidak salah cocok pada rekening tanpa klasifikasi.
  var payload = %*{"product": productCode}
  if accountType.len > 0:
    payload["accountType"] = %accountType
  if savingsKind.len > 0:
    payload["savingsKind"] = %savingsKind
  let rule = selectRule(activeRules(db, eventType, businessDate), eventType, payload)
  let lines = buildLines(rule, amount, branchId)
  let journal = Journal(
    journalId: newId(clock),
    businessDate: businessDate,
    valueDate: businessDate,
    sourceEvent: eventType,
    sourceRef: sourceRef,
    idempotencyKey: idempotencyKey,
    reversalOf: "")
  discard insertJournal(db, journal, actor)
  for line in lines:
    insertJournalLine(db, journal.journalId, line)
  journal.journalId
