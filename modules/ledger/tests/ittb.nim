## Integrasi saldo turunan + trial balance (T-075).
##
## Rekonsiliasi: TB (dihitung dari jurnal) == agregasi SQL langsung, dan cache `balance_snapshot`
## hasil `rebuild_balance_snapshot` == angka TB. Tidak ada jalur tulis saldo selain jurnal.

import std/[options, random, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, money]
import ledger/domain/[journal, period, report]
import ledger/infrastructure/[journal_repo, ledger_repo, report_repo]

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "ittb: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")
  branch = Id("11111111-1111-7111-8111-111111111111")
  periodId = newId(testClock)

discard insertPeriod(db,
  Period(periodId: periodId, startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)

proc line(no: int, account: string, debit, credit: int64): JournalLine =
  JournalLine(lineNo: no, glAccount: account, branchId: branch,
    debit: money(debit), credit: money(credit))

# 40 jurnal acak seimbang dalam satu transaksi (uang bergerak antar akun nyata).
var r = initRand(20261020)
var expectedOct: int64 = 0
discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
  for i in 0 ..< 40:
    let amount = r.rand(1 .. 5_000_000).int64
    expectedOct += amount
    let j = Journal(journalId: newId(testClock), businessDate: "2026-10-15",
      valueDate: "2026-10-15", sourceEvent: "TbTest", sourceRef: newId(testClock),
      idempotencyKey: "ittb-" & $i,
      lines: @[line(1, "101.2", amount, 0), line(2, "201", 0, amount)])
    discard insertJournal(d, j, actor)
    for l in j.lines:
      insertJournalLine(d, j.journalId, l)
  1)

# Jurnal bulan sebelumnya: snapshot kumulatif, TB hanya periode berjalan.
const sepAmount = 100_0000'i64
block:
  let sepId = newId(testClock)
  discard insertPeriod(db,
    Period(periodId: sepId, startsOn: "2026-09-01", endsOn: "2026-09-30"), actor)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    let j = Journal(journalId: newId(testClock), businessDate: "2026-09-15",
      valueDate: "2026-09-15", sourceEvent: "TbTestPrior", sourceRef: newId(testClock),
      idempotencyKey: "ittb-prior",
      lines: @[line(1, "101.2", sepAmount, 0), line(2, "201", 0, sepAmount)])
    discard insertJournal(d, j, actor)
    for l in j.lines:
      insertJournalLine(d, j.journalId, l)
    1)

suite "trial balance: rekonsiliasi":
  test "TB seimbang, angkanya cocok dengan total yang dihitung test":
    let tb = trialBalance(db, periodId).get()
    check tb.lines.len == 2
    check tb.isBalanced
    check tb.totalDebit == money(expectedOct)
    check tb.totalCredit == money(expectedOct)
    for l in tb.lines:
      if l.accountCode == "101.2":
        check l.debit == money(expectedOct)
        check l.credit.isZero
      elif l.accountCode == "201":
        check l.credit == money(expectedOct)
        check l.debit.isZero
      else:
        check false

  test "angka TB sama dengan agregasi SQL langsung":
    let tb = trialBalance(db, periodId).get()
    for l in tb.lines:
      let direct = db.getRow(sql"""
        SELECT coalesce(sum(l.debit), 0)::text, coalesce(sum(l.credit), 0)::text
          FROM ledger.journal_line l JOIN ledger.journal j ON j.journal_id = l.journal_id
         WHERE l.gl_account = ? AND j.business_date BETWEEN ?::date AND ?::date""",
        l.accountCode, tb.startsOn, tb.endsOn)
      check moneyOf(direct[0]) == l.debit
      check moneyOf(direct[1]) == l.credit

  test "snapshot = kumulatif sampai tanggal; TB = pergerakan periode":
    let tb = trialBalance(db, periodId).get()
    rebuildSnapshot(db, tb.endsOn)
    let snap = snapshotTotals(db, tb.endsOn)
    check snap.len == tb.lines.len
    for (code, debit, credit) in snap:
      var found = false
      for l in tb.lines:
        if l.accountCode == code:
          found = true
          # Bulan sebelumnya ikut di snapshot (kumulatif), tidak ikut di TB periode Oktober.
          let priorDebit = if code == "101.2": sepAmount else: 0
          let priorCredit = if code == "201": sepAmount else: 0
          check debit == l.debit.minorUnits + priorDebit
          check credit == l.credit.minorUnits + priorCredit
      check found

  test "periode tidak ada = none (bukan angka kosong)":
    check trialBalance(db, Id("88888888-8888-7888-8888-888888888888")).isNone
