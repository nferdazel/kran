## Test integrasi DB modul `deposit` transaksi tunai (T-088b) — butuh `KRAN_DATABASE_URL`.
##
## Membuktikan invarian yang dijaga DB/repo: setor/tarik mengubah saldo, tarik melebihi saldo/minimum
## ditolak **tanpa** mengubah saldo/baris, dua tarikan bersamaan tidak menembus saldo (satu sukses
## satu ditolak), dan periode CLOSED membuat jurnal gagal sehingga **seluruh** transaksi (saldo +
## baris) di-rollback. Migrasi dijalankan dari skema kosong → membuktikan `deposit/0004` berada
## setelah `ledger/0003` (FK `ledger.journal`).

import std/[atomics, json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, money, result]
import deposit/domain/account
import deposit/domain/transaction
import deposit/infrastructure/[account_repo, transaction_repo]
import ledger/domain/[journal, period]
import ledger/infrastructure/[journal_repo, ledger_repo]
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "ittransaction: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

const
  branchIdRaw = "11111111-1111-7111-8111-111111111111"
  openedOn = "2026-10-01"
  businessDate = "2026-10-15"

let
  testClock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))
  branch = Id(branchIdRaw)
  actor = Id("77777777-7777-7777-8777-777777777777")
  approver = Id("88888888-8888-7888-8888-888888888888")
  periodId = newId(testClock)

discard insertPeriod(db,
  Period(periodId: periodId, startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)

proc fixture(): tuple[party: Party, product: Product, version: ProductVersion] =
  let p = newParty(newId(testClock), pkPerson, "Budi Santoso", branch, "{seq:6}{check}",
    nextCifSeq(db))
  discard insertParty(db, p, actor)
  let prod = Product(productId: newId(testClock), code: "SAV01", name: "Simpanan Sukarela",
    productType: ptSavings)
  let v = ProductVersion(versionId: newId(testClock), productId: prod.productId, versionNo: 1,
    effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prod, actor)
    insertVersion(d, v, actor)
    insertBinding(d, v.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"0.0000"))
    1)
  doAssert approveVersion(db, v.versionId, approver), "versi produk uji gagal di-approve"
  (p, prod, v)

let fx = fixture()

proc accountRow(): Account =
  newAccount(newId(testClock), fx.party.partyId, fx.product.productId, fx.version.versionId,
    fx.product.code, branch, openedOn, nextAccountSeq(db))

proc save(a: Account) =
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertAccount(d, a, actor)
    1)

proc balanceOfAccount(accountId: Id): Money =
  accountById(db, accountId).get().balance

proc saveJournal(amount: Money): Id =
  ## Jurnal setor (101/201) seimbang untuk memenuhi FK `deposit.transaction.journal_id`.
  let jid = newId(testClock)
  let j = Journal(journalId: jid, businessDate: businessDate, valueDate: businessDate,
    sourceEvent: "DepositPosted", sourceRef: newId(testClock),
    idempotencyKey: "ittx-" & $jid)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    discard insertJournal(d, j, actor)
    insertJournalLine(d, jid, JournalLine(lineNo: 1, glAccount: "101", branchId: branch,
      debit: amount, credit: zero()))
    insertJournalLine(d, jid, JournalLine(lineNo: 2, glAccount: "201", branchId: branch,
      debit: zero(), credit: amount))
    1)
  jid

proc txRow(accountId, journalId: Id, amount: Money, t: TransactionType): Transaction =
  Transaction(transactionId: newId(testClock), txType: t, accountId: accountId, amount: amount,
    businessDate: businessDate, narration: "uji", journalId: journalId)

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

suite "deposit: mutasi saldo & baris transaksi":
  test "setor menambah saldo dan menulis baris transaksi":
    let a = accountRow()
    save(a)
    let jid = saveJournal(money(100_0000))
    let after = dbPool.withTx(proc(d: DbConn): Option[Money] {.closure.} =
      let bal = increaseBalance(d, a.accountId, money(100_0000))
      if bal.isSome:
        insertTransaction(d, txRow(a.accountId, jid, money(100_0000), ttCashDeposit), actor)
      bal)
    check after.isSome
    check after.get() == money(100_0000)
    check balanceOfAccount(a.accountId) == money(100_0000)

    let rows = transactionsByAccount(db, a.accountId)
    check rows.len == 1
    check rows[0].txType == ttCashDeposit
    check rows[0].amount == money(100_0000)
    check rows[0].journalId == jid
    check transactionById(db, rows[0].transactionId).isSome

  test "baris transaksi immutable: UPDATE/DELETE/TRUNCATE ditolak (review m7)":
    let a = accountRow()
    save(a)
    let jid = saveJournal(money(50_0000))
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      discard increaseBalance(d, a.accountId, money(50_0000))
      insertTransaction(d, txRow(a.accountId, jid, money(50_0000), ttCashDeposit), actor)
      1)
    let txId = $transactionsByAccount(db, a.accountId)[0].transactionId
    expectDbError(proc() = db.exec(
      sql"UPDATE deposit.transaction SET narration = 'ubah' WHERE transaction_id = ?", txId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM deposit.transaction WHERE transaction_id = ?", txId))
    expectDbError(proc() = db.exec(sql"TRUNCATE deposit.transaction"))

  test "tarik mengurangi saldo sampai tepat minimum":
    let a = accountRow()
    save(a)
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      discard increaseBalance(d, a.accountId, money(100_0000))
      1)
    let jid = saveJournal(money(70_0000))
    let after = dbPool.withTx(proc(d: DbConn): Option[Money] {.closure.} =
      let bal = decreaseBalance(d, a.accountId, money(70_0000), money(30_0000))
      if bal.isSome:
        insertTransaction(d, txRow(a.accountId, jid, money(70_0000), ttCashWithdrawal), actor)
      bal)
    check after.isSome
    check after.get() == money(30_0000)
    check balanceOfAccount(a.accountId) == money(30_0000)

  test "tarik melebihi saldo ditolak tanpa ubah saldo/baris":
    let a = accountRow()
    save(a)
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      discard increaseBalance(d, a.accountId, money(100_0000))
      1)
    let before = transactionsByAccount(db, a.accountId).len
    let after = dbPool.withTx(proc(d: DbConn): Option[Money] {.closure.} =
      decreaseBalance(d, a.accountId, money(100_0001), zero()))
    check after.isNone
    check balanceOfAccount(a.accountId) == money(100_0000)
    check transactionsByAccount(db, a.accountId).len == before

  test "saldo minimum dari pemanggil dihormati":
    let a = accountRow()
    save(a)
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      discard increaseBalance(d, a.accountId, money(100_0000))
      1)
    # Melewati minimum dengan 1 unit terkecil → ditolak.
    check dbPool.withTx(proc(d: DbConn): Option[Money] {.closure.} =
      decreaseBalance(d, a.accountId, money(70_0001), money(30_0000))).isNone
    check balanceOfAccount(a.accountId) == money(100_0000)
    # Tepat minimum → boleh.
    check dbPool.withTx(proc(d: DbConn): Option[Money] {.closure.} =
      decreaseBalance(d, a.accountId, money(70_0000), money(30_0000))).get() == money(30_0000)

  test "CHECK saldo >= 0 menolak UPDATE negatif (backstop DB)":
    let a = accountRow()
    save(a)
    expectDbError(proc() = db.exec(
      sql"UPDATE deposit.account_balance SET balance = -1 WHERE account_id = ?", $a.accountId))

var workerStarted: Atomic[bool]
var workerSucceeded: Atomic[bool]

type WithdrawArgs = object
  pool: DbPool
  accountId: string
  amount: string
  minBalance: string

proc withdrawWorker(args: WithdrawArgs) {.thread.} =
  {.cast(gcsafe).}:
    workerStarted.store(true)
    let res = args.pool.withTx(proc(d: DbConn): Option[Money] {.closure.} =
      decreaseBalance(d, Id(args.accountId), moneyFromString(args.amount).value(),
        moneyFromString(args.minBalance).value()))
    workerSucceeded.store(res.isSome)

suite "deposit: tarik bersamaan tidak menembus saldo":
  test "dua koneksi tarik dari saldo terbatas: satu sukses, satu ditolak":
    let a = accountRow()
    save(a)
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      discard increaseBalance(d, a.accountId, money(100_0000))
      1)

    let side = dbPool.acquire()
    defer: dbPool.release(side)
    exec(side, sql"BEGIN")
    discard side.getValue(
      sql"SELECT 1 FROM deposit.account_balance WHERE account_id = ? FOR UPDATE", $a.accountId)
    let sidePid = side.getValue(sql"SELECT pg_backend_pid()")

    workerStarted.store(false)
    workerSucceeded.store(false)
    var worker: Thread[WithdrawArgs]
    createThread(worker, withdrawWorker, WithdrawArgs(pool: dbPool, accountId: $a.accountId,
      amount: money(60_0000).toDecimalString, minBalance: zero().toDecimalString))
    while not workerStarted.load():
      sleep(2)

    # Koneksi lain benar-benar menunggu lock baris saldo yang dipegang `side`.
    var blocked = false
    let deadline = epochTime() + 10.0
    while epochTime() < deadline and not blocked:
      blocked = db.getValue(sql"""
        SELECT count(*)::text FROM pg_stat_activity
         WHERE datname = current_database() AND pid <> pg_backend_pid()
           AND wait_event_type = 'Lock'
           AND ?::int = ANY(pg_blocking_pids(pid))""", sidePid) != "0"
      if not blocked:
        sleep(20)
    check blocked

    # Sisi ini "menang": menarik 60 dari saldo 100 → 40, lalu lepas lock.
    check decreaseBalance(side, a.accountId, money(60_0000), zero()).isSome
    exec(side, sql"COMMIT")
    joinThread(worker)

    # Pekerja yang tertunda dievaluasi ulang terhadap saldo 40 → 40 - 60 < 0 → 0 baris.
    check not workerSucceeded.load()
    check balanceOfAccount(a.accountId) == money(40_0000)

suite "deposit: periode tertutup membatalkan seluruh transaksi":
  test "jurnal gagal pada periode CLOSED → saldo & baris tidak berubah":
    let a = accountRow()
    save(a)
    check closePeriod(db, periodId, actor).len > 0
    var failed = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        # Mutasi saldo lebih dulu, lalu jurnal (yang menolak karena periode tertutup).
        discard increaseBalance(d, a.accountId, money(100_0000))
        let jid = newId(testClock)
        let j = Journal(journalId: jid, businessDate: businessDate, valueDate: businessDate,
          sourceEvent: "DepositPosted", sourceRef: newId(testClock),
          idempotencyKey: "itclosed-" & $jid)
        discard insertJournal(d, j, actor)
        insertJournalLine(d, jid, JournalLine(lineNo: 1, glAccount: "101", branchId: branch,
          debit: money(100_0000), credit: zero()))
        insertJournalLine(d, jid, JournalLine(lineNo: 2, glAccount: "201", branchId: branch,
          debit: zero(), credit: money(100_0000)))
        insertTransaction(d, txRow(a.accountId, jid, money(100_0000), ttCashDeposit), actor)
        1)
    except DbError:
      failed = true
    check failed
    check balanceOfAccount(a.accountId) == zero()
    check transactionsByAccount(db, a.accountId).len == 0
    check not periodOpenFor(db, businessDate)
    # Kembalikan supaya suite lain tetap bisa menulis (dan bukti tidak bergantung urutan).
    db.exec(sql"""
      UPDATE ledger.period SET status = 'OPEN', closed_at = NULL, closed_by = NULL
       WHERE period_id = ?""", $periodId)
    check periodOpenFor(db, businessDate)
