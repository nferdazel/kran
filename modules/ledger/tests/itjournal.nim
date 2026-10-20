## Test integrasi jurnal (T-073) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan di DB sungguhan: immutability (UPDATE/DELETE/TRUNCATE), keseimbangan deferred
## saat COMMIT, periode harus OPEN, akun harus postable & ACTIVE, idempotency unik, dan pembalik
## menukar sisi.

import std/[options, os, random, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, money]
import ledger/domain/[coa, journal, period]
import ledger/infrastructure/[journal_repo, ledger_repo]

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itjournal: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

discard applyMigrations(db, ".")
db.exec(sql"DROP SCHEMA IF EXISTS ledger CASCADE")
db.exec(sql"DELETE FROM platform.schema_migration WHERE migration_id LIKE 'ledger/%'")
discard applyMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")
  branch = Id("11111111-1111-7111-8111-111111111111")
  octId = newId(testClock)
  novId = newId(testClock)

discard insertPeriod(db,
  Period(periodId: octId, startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)
discard insertPeriod(db,
  Period(periodId: novId, startsOn: "2026-11-01", endsOn: "2026-11-30"), actor)
discard closePeriod(db, novId, actor)

var keyCounter = 0

proc nextKey(): string =
  keyCounter.inc
  "itjournal-" & $keyCounter

proc line(no: int, account: string, debit, credit: int64): JournalLine =
  JournalLine(lineNo: no, glAccount: account, branchId: branch,
    debit: money(debit), credit: money(credit))

proc newJournal(businessDate = "2026-10-15", lines: seq[JournalLine] = @[]): Journal =
  var ls = lines
  if ls.len == 0:
    ls = @[line(1, "101", 250_0000, 0), line(2, "201", 0, 250_0000)]
  Journal(journalId: newId(testClock), businessDate: businessDate, valueDate: businessDate,
    sourceEvent: "DepositPosted", sourceRef: newId(testClock),
    idempotencyKey: nextKey(), lines: ls)

proc save(j: Journal): string =
  ## Header + baris **wajib satu transaksi**: constraint trigger keseimbangan deferred, sehingga
  ## autocommit per pernyataan akan memeriksa jurnal yang baru punya 1 baris (dan menolaknya).
  result = dbPool.withTx(proc(d: DbConn): string {.closure.} =
    let recordedAt = insertJournal(d, j, actor)
    for l in j.lines:
      insertJournalLine(d, j.journalId, l)
    recordedAt)

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

suite "journal: penyimpanan & immutability":
  test "jurnal seimbang tersimpan dan terbaca utuh":
    let j = newJournal()
    discard save(j)
    let stored = journalById(db, j.journalId)
    check stored.isSome
    check stored.get().businessDate == "2026-10-15"
    check stored.get().valueDate == "2026-10-15"
    check stored.get().sourceEvent == "DepositPosted"
    check stored.get().idempotencyKey == j.idempotencyKey
    check stored.get().reversalOf.len == 0
    check stored.get().recordedAt.len >= 20
    check stored.get().lines.len == 2
    check stored.get().lines.totalDebit == money(250_0000)
    check stored.get().lines.totalCredit == money(250_0000)

  test "idempotency key unik":
    let j = newJournal()
    discard save(j)
    var duplicate = newJournal()
    duplicate.idempotencyKey = j.idempotencyKey
    expectDbError(proc() = discard save(duplicate))
    check journalByIdempotencyKey(db, j.idempotencyKey).get().journalId == j.journalId

  test "UPDATE dan DELETE ditolak trigger":
    let j = newJournal()
    discard save(j)
    expectDbError(proc() = db.exec(
      sql"UPDATE ledger.journal SET source_event = 'X' WHERE journal_id = ?", $j.journalId))
    expectDbError(proc() = db.exec(
      sql"UPDATE ledger.journal_line SET debit = debit + 1 WHERE journal_id = ?", $j.journalId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM ledger.journal_line WHERE journal_id = ?", $j.journalId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM ledger.journal WHERE journal_id = ?", $j.journalId))
    check journalById(db, j.journalId).isSome

  test "TRUNCATE ditolak trigger":
    expectDbError(proc() = db.exec(sql"TRUNCATE ledger.journal_line, ledger.journal"))

suite "journal: aturan akuntansi di DB":
  test "jurnal tidak seimbang ditolak saat COMMIT":
    let j = newJournal(lines = @[line(1, "101", 100_0000, 0), line(2, "201", 0, 99_0000)])
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertJournal(d, j, actor)
        for l in j.lines:
          insertJournalLine(d, j.journalId, l)
        1)
    except DbError:
      raised = true
    check raised
    check journalById(db, j.journalId).isNone

  test "jurnal satu baris ditolak saat COMMIT":
    let j = newJournal(lines = @[line(1, "101", 100_0000, 0)])
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertJournal(d, j, actor)
        insertJournalLine(d, j.journalId, j.lines[0])
        1)
    except DbError:
      raised = true
    check raised

  test "akun header (postable=false) ditolak":
    expectDbError(proc() = discard save(
      newJournal(lines = @[line(1, "1", 100, 0), line(2, "201", 0, 100)])))

  test "akun non-ACTIVE ditolak":
    let a = CoaAccount(accountId: newId(testClock), code: "1999", name: "AKUN NONAKTIF",
      accountType: atAsset, normalSide: nsDebit, postable: true, status: asActive)
    discard insertCoa(db, a, actor)
    db.exec(sql"UPDATE ledger.coa_account SET status = 'INACTIVE' WHERE code = '1999'")
    expectDbError(proc() = discard save(
      newJournal(lines = @[line(1, "1999", 100, 0), line(2, "201", 0, 100)])))

  test "periode CLOSED dan tanggal tanpa periode ditolak":
    expectDbError(proc() = discard save(newJournal(businessDate = "2026-11-15")))
    expectDbError(proc() = discard save(newJournal(businessDate = "2027-01-05")))

suite "journal: pembalik & daftar":
  test "pembalik menukar sisi dan ditandai reversal_of":
    let original = newJournal()
    discard save(original)
    check not reversalExistsFor(db, original.journalId)
    let stored = journalById(db, original.journalId).get()
    let rev = Journal(journalId: newId(testClock), businessDate: stored.businessDate,
      valueDate: stored.valueDate, sourceEvent: "reversal", sourceRef: original.journalId,
      idempotencyKey: nextKey(), reversalOf: $original.journalId,
      lines: reversalLinesOf(stored.lines))
    discard save(rev)
    check reversalExistsFor(db, original.journalId)
    let storedRev = journalById(db, rev.journalId).get()
    check storedRev.reversalOf == $original.journalId
    check storedRev.lines[0].glAccount == "101"
    check storedRev.lines[0].credit == money(250_0000)
    check storedRev.lines[0].debit.isZero
    check storedRev.lines.totalDebit == storedRev.lines.totalCredit

  test "daftar menyaring tanggal & event di SQL":
    let j = newJournal(businessDate = "2026-10-16")
    discard save(j)
    let byDate = journals(db, "2026-10-16")
    check byDate.len == 1
    check byDate[0].journalId == j.journalId
    check byDate[0].lines.len == 0
    let byEvent = journals(db, "", "reversal")
    check byEvent.len >= 1
    for x in byEvent:
      check x.sourceEvent == "reversal"

  test "30 jurnal acak seimbang tersimpan dalam satu transaksi":
    var r = initRand(20261020)
    let before = journals(db, "2026-10-20").len
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      for _ in 0 ..< 30:
        let amount = r.rand(1 .. 9_000_000).int64
        var j = newJournal(businessDate = "2026-10-20")
        j.lines = @[line(1, "101", amount, 0), line(2, "201", 0, amount)]
        discard insertJournal(d, j, actor)
        for l in j.lines:
          insertJournalLine(d, j.journalId, l)
      1)
    check journals(db, "2026-10-20").len == before + 30

suite "journal: guard tambahan (review T-073)":
  test "header tanpa baris ditolak saat COMMIT":
    let j = newJournal(businessDate = "2026-10-17")
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertJournal(d, j, actor)
        1)
    except DbError:
      raised = true
    check raised
    check journalById(db, j.journalId).isNone

  test "baris tidak bisa ditambahkan setelah periode ditutup":
    let decId = newId(testClock)
    discard insertPeriod(db,
      Period(periodId: decId, startsOn: "2026-12-01", endsOn: "2026-12-31"), actor)
    let j = newJournal(businessDate = "2026-12-15")
    discard save(j)
    discard closePeriod(db, decId, actor)
    expectDbError(proc() = insertJournalLine(db, j.journalId,
      line(3, "101", 1_0000, 0)))

  test "hanya satu pembalik per jurnal asal (indeks unik DB)":
    let original = newJournal(businessDate = "2026-10-18")
    discard save(original)
    let stored = journalById(db, original.journalId).get()
    let first = Journal(journalId: newId(testClock), businessDate: stored.businessDate,
      valueDate: stored.valueDate, sourceEvent: "reversal", sourceRef: original.journalId,
      idempotencyKey: nextKey(), reversalOf: $original.journalId,
      lines: reversalLinesOf(stored.lines))
    discard save(first)
    var second = first
    second.journalId = newId(testClock)
    second.idempotencyKey = nextKey()
    expectDbError(proc() = discard save(second))
    check journals(db, stored.businessDate, "reversal").len == 1
