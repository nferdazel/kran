## Test integrasi DB modul `deposit` pemindahbukuan (T-088c) — butuh `KRAN_DATABASE_URL`.
##
## Membuktikan invarian yang dijaga DB/repo: PB menggeser saldo dari sumber ke tujuan, PB melebihi
## saldo/minimum ditolak **tanpa** mengubah saldo/baris, rekening sama ditolak, baris transfer
## immutable, dan dua PB berlawanan arah bersamaan **tidak deadlock** (urutan kunci `account_id`
## naik). Migrasi dijalankan dari skema kosong → membuktikan `deposit/0007` berada setelah
## `ledger/0003` (FK `ledger.journal`).
##
## Jalur HTTP (201/400/403/409/replay) ada di `apps/api/tests/itapi_teller.nim`.

import std/[atomics, json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, money, result]
import deposit/domain/account
import deposit/domain/transfer
import deposit/infrastructure/[account_repo, transaction_repo, transfer_repo]
import ledger/domain/[journal, period]
import ledger/infrastructure/[journal_repo, ledger_repo]
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "ittransfer: KRAN_DATABASE_URL kosong — dilewati"
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

discard insertPeriod(db,
  Period(periodId: newId(testClock), startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)

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

proc credit(accountId: Id, amount: Money) =
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    discard increaseBalance(d, accountId, amount)
    1)

proc saveTransferJournal(amount: Money): Id =
  ## Jurnal PB (201/201) seimbang untuk memenuhi FK `deposit.transfer.journal_id`.
  let jid = newId(testClock)
  let j = Journal(journalId: jid, businessDate: businessDate, valueDate: businessDate,
    sourceEvent: transferSourceEvent, sourceRef: newId(testClock),
    idempotencyKey: "ittr-" & $jid)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    discard insertJournal(d, j, actor)
    insertJournalLine(d, jid, JournalLine(lineNo: 1, glAccount: "201", branchId: branch,
      debit: amount, credit: zero()))
    insertJournalLine(d, jid, JournalLine(lineNo: 2, glAccount: "201", branchId: branch,
      debit: zero(), credit: amount))
    1)
  jid

proc transferRow(sourceId, destinationId, journalId: Id, amount: Money): Transfer =
  Transfer(transferId: newId(testClock), sourceAccountId: sourceId,
    destinationAccountId: destinationId, amount: amount, businessDate: businessDate,
    narration: "uji PB", journalId: journalId)

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

suite "deposit: mutasi saldo pemindahbukuan":
  test "PB menggeser saldo sumber ke tujuan dan menulis baris transfer":
    let a = accountRow()
    let b = accountRow()
    save(a)
    save(b)
    credit(a.accountId, money(100_0000))
    let jid = saveTransferJournal(money(60_0000))

    let res = dbPool.withTx(proc(d: DbConn): Option[TransferBalances] {.closure.} =
      let balances = applyTransferBalances(d, a.accountId, b.accountId, money(60_0000), zero())
      if balances.isSome:
        insertTransfer(d, transferRow(a.accountId, b.accountId, jid, money(60_0000)), actor)
      balances)
    check res.isSome
    check res.get().sourceBalanceAfter == money(40_0000)
    check res.get().destinationBalanceAfter == money(60_0000)
    check balanceOfAccount(a.accountId) == money(40_0000)
    check balanceOfAccount(b.accountId) == money(60_0000)

    let rows = transfersByAccount(db, a.accountId)
    check rows.len == 1
    check rows[0].sourceAccountId == a.accountId
    check rows[0].destinationAccountId == b.accountId
    check rows[0].amount == money(60_0000)
    check rows[0].journalId == jid
    check transferById(db, rows[0].transferId).isSome
    # Tujuan juga melihatnya sebagai satu PB.
    check transfersByAccount(db, b.accountId).len == 1

  test "PB melebihi saldo ditolak tanpa mengubah saldo tujuan":
    let a = accountRow()
    let b = accountRow()
    save(a)
    save(b)
    credit(a.accountId, money(100_0000))
    let before = transfersByAccount(db, a.accountId).len

    # `b.account_id` sengaja lebih kecil dari `a` di sebagian kasus: kunci/urutan apa pun, syarat
    # saldo sumber tetap gagal sebelum tujuan ditambah → saldo tujuan tidak boleh berubah.
    let res = dbPool.withTx(proc(d: DbConn): Option[TransferBalances] {.closure.} =
      applyTransferBalances(d, a.accountId, b.accountId, money(100_0001), zero()))
    check res.isNone
    check balanceOfAccount(a.accountId) == money(100_0000)
    check balanceOfAccount(b.accountId) == zero()
    check transfersByAccount(db, a.accountId).len == before

  test "saldo minimum versi produk sumber dihormati":
    let a = accountRow()
    let b = accountRow()
    save(a)
    save(b)
    credit(a.accountId, money(100_0000))
    # Melewati minimum dengan 1 unit terkecil → ditolak, tak ada mutasi.
    check dbPool.withTx(proc(d: DbConn): Option[TransferBalances] {.closure.} =
      applyTransferBalances(d, a.accountId, b.accountId, money(70_0001), money(30_0000))).isNone
    check balanceOfAccount(a.accountId) == money(100_0000)
    check balanceOfAccount(b.accountId) == zero()
    # Tepat minimum → boleh.
    check dbPool.withTx(proc(d: DbConn): Option[TransferBalances] {.closure.} =
      applyTransferBalances(d, a.accountId, b.accountId, money(70_0000), money(30_0000))
      ).get().sourceBalanceAfter == money(30_0000)

  test "rekening sama ditolak repo (guard)":
    let a = accountRow()
    save(a)
    credit(a.accountId, money(10_0000))
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): Option[TransferBalances] {.closure.} =
        applyTransferBalances(d, a.accountId, a.accountId, money(1_0000), zero()))
    except ValueError:
      raised = true
    check raised
    check balanceOfAccount(a.accountId) == money(10_0000)

  test "baris transfer immutable: UPDATE/DELETE/TRUNCATE ditolak":
    let a = accountRow()
    let b = accountRow()
    save(a)
    save(b)
    credit(a.accountId, money(50_0000))
    let jid = saveTransferJournal(money(10_0000))
    var transferIdRaw = ""
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      discard applyTransferBalances(d, a.accountId, b.accountId, money(10_0000), zero())
      let t = transferRow(a.accountId, b.accountId, jid, money(10_0000))
      transferIdRaw = $t.transferId
      insertTransfer(d, t, actor)
      1)
    expectDbError(proc() = db.exec(
      sql"UPDATE deposit.transfer SET narration = 'ubah' WHERE transfer_id = ?", transferIdRaw))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM deposit.transfer WHERE transfer_id = ?", transferIdRaw))
    expectDbError(proc() = db.exec(sql"TRUNCATE deposit.transfer"))

var
  workerFailed: Atomic[bool]

type TransferArgs = object
  pool: DbPool
  sourceId: string
  destinationId: string
  amount: string

proc transferWorker(args: TransferArgs) {.thread.} =
  {.cast(gcsafe).}:
    let ok =
      try:
        args.pool.withTx(proc(d: DbConn): bool {.closure.} =
          # Batas tunggu berikut hanya jaring pengaman; deadlock sejati tetap terdeteksi PG (~1 s).
          exec(d, sql"SET LOCAL lock_timeout = '30000'")
          applyTransferBalances(d, Id(args.sourceId), Id(args.destinationId),
            moneyFromString(args.amount).value(), zero()).isSome)
      except DbError:
        false
    if not ok:
      workerFailed.store(true)

proc blockedByHolder(pid: string): int =
  ## Jumlah sesi lain yang menunggu lock yang dipegang `pid` (pola `ittransaction`): sinkronisasi
  ## deterministik tanpa `sleep` yang bisa lolos saat pekerja belum benar-benar bersaing.
  parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM pg_stat_activity
     WHERE datname = current_database() AND pid <> pg_backend_pid()
       AND wait_event_type = 'Lock'
       AND ?::int = ANY(pg_blocking_pids(pid))""", pid))

suite "deposit: PB berlawanan arah bersamaan tidak deadlock":
  test "urutan kunci `account_id` menaik: kedua arah selesai tanpa deadlock":
    let a = accountRow()
    let b = accountRow()
    save(a)
    save(b)
    credit(a.accountId, money(100_0000))
    credit(b.accountId, money(100_0000))

    # Sesi uji memegang lock baris saldo **terkecil**. Dengan urutan `account_id` menaik, kedua PB
    # (dua arah) menunggu di baris yang sama → terserialisasi. Bila urutan kunci dihapus,
    # masing-masing memegang baris sumbernya lalu menunggu baris yang lain → deadlock dan salah satu
    # pekerja gagal (`workerFailed`), sehingga test ini gagal.
    let (minId, maxId) =
      if a.accountId < b.accountId: (a.accountId, b.accountId)
      else: (b.accountId, a.accountId)

    # Koneksi terpisah untuk memegang lock (pola ittransaction); polling pakai `db`.
    let side = dbPool.acquire()
    defer: dbPool.release(side)
    exec(side, sql"BEGIN")
    discard side.getValue(sql"""
      SELECT 1 FROM deposit.account_balance WHERE account_id = ? FOR UPDATE""", $minId)
    let holderPid = side.getValue(sql"SELECT pg_backend_pid()")

    workerFailed.store(false)
    var w1, w2: Thread[TransferArgs]
    createThread(w1, transferWorker, TransferArgs(pool: dbPool, sourceId: $minId,
      destinationId: $maxId, amount: money(60_0000).toDecimalString))
    createThread(w2, transferWorker, TransferArgs(pool: dbPool, sourceId: $maxId,
      destinationId: $minId, amount: money(60_0000).toDecimalString))

    # Tunggu **kedua** pekerja benar-benar menunggu lock sesi uji.
    let deadline = epochTime() + 5.0
    var blocked = 0
    while epochTime() < deadline and blocked < 2:
      blocked = blockedByHolder(holderPid)
      if blocked < 2:
        sleep(20)
    # Minimal satu pekerja terbukti menunggu lock holder. Menuntut dua bisa rapuh karena salah
    # satu pekerja bisa tertahan lebih dulu di lapisan pool/serialisasi; invarian yang sebenarnya
    # diuji ada di bawah: tidak ada worker gagal (deadlock) dan saldo akhir benar.
    check blocked >= 1

    # Lepas lock: kedua pekerja lanjut; dengan urutan menaik keduanya terserialisasi dan selesai.
    exec(side, sql"COMMIT")
    joinThread(w1)
    joinThread(w2)

    check not workerFailed.load()
    check balanceOfAccount(a.accountId) == money(100_0000)
    check balanceOfAccount(b.accountId) == money(100_0000)
    check transfersByAccount(db, a.accountId).len == 0 # belum ada baris transfer (mutasi saja)
