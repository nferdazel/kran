## Test integrasi DB modul `teller` sesi kas (T-093) — butuh `KRAN_DATABASE_URL`.
##
## Membuktikan invarian yang dijaga DB/repo: buka menurunkan vault, satu sesi OPEN per (cabang,
## teller) dijaga partial unique index, vault tidak boleh negatif / tidak cukup, tutup menambah vault
## sebesar **counted** (bukan expected) dan mencatat variance, tutup ganda tidak menambah vault lagi,
## CHECK variance, dan `cash_movement` immutable. Dua penutupan bersamaan diserialisasi `FOR UPDATE`
## (satu berhasil, vault bertambah sekali).
##
## Migrasi dijalankan dari skema kosong → membuktikan `teller/0006` berada setelah `platform/0006`
## (FK `platform.app_user`) dan `deposit/0004` (FK `deposit.transaction`), dan `teller/0007` grant.
##
## Jalur HTTP (201/400/403/404/409/replay) ada di `apps/api/tests/itapi_teller_sessions.nim`.

import std/[atomics, json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, money, result]
import deposit/domain/account
import deposit/domain/transaction
import deposit/infrastructure/[account_repo, transaction_repo]
import ledger/domain/journal
import ledger/domain/period
import ledger/infrastructure/journal_repo
import ledger/infrastructure/ledger_repo
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo
import teller/domain/session
import teller/infrastructure/session_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itsession: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

const
  businessDate = "2026-10-15"
  branchA = "11111111-1111-7111-8111-111111111111"
  branchB = "22222222-2222-7222-8222-222222222222"
  branchC = "33333333-3333-7333-8333-333333333333"
  branchD = "44444444-4444-7444-8444-444444444444"
  branchE = "55555555-5555-7555-8555-555555555555"
  branchF = "66666666-6666-7666-8666-666666666666"
  tellerA = "a1111111-1111-7111-8111-111111111111"
  tellerB = "a2222222-2222-7222-8222-222222222222"

let
  testClock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")
  approver = Id("88888888-8888-7888-8888-888888888888")

# Jurnal fixture (untuk FK `cash_movement.transaction_id`) butuh periode OPEN pada tanggal bisnis.
discard insertPeriod(db,
  Period(periodId: newId(testClock), startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)

# FK `platform.app_user` butuh baris pengguna; cukup dua teller sintetis.
execScript(db, """
  INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                                 must_change_password)
  VALUES
    ('""" & tellerA & """', 'it.teller.a', 'Teller A (it)', 'x', 'x', false),
    ('""" & tellerB & """', 'it.teller.b', 'Teller B (it)', 'x', 'x', false)
""")

# Rekening + produk/party hanya untuk memenuhi FK `deposit.transaction` (movement menunjuknya).
let owner = newParty(newId(testClock), pkPerson, "Teller Test", Id(branchA), "{seq:6}{check}",
  nextCifSeq(db))
discard insertParty(db, owner, actor)
let prod = Product(productId: newId(testClock), code: "SAV-TEL", name: "Simpanan Tell",
  productType: ptSavings)
let ver = ProductVersion(versionId: newId(testClock), productId: prod.productId, versionNo: 1,
  effectiveFrom: "2020-01-01")
discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
  insertProduct(d, prod, actor)
  insertVersion(d, ver, actor)
  insertBinding(d, ver.versionId, ParamBinding(paramKey: "product.savings.min_balance",
    value: %"0.00"))
  1)
doAssert approveVersion(db, ver.versionId, approver), "versi produk uji gagal di-approve"
let testAccount = newAccount(newId(testClock), owner.partyId, prod.productId, ver.versionId, prod.code,
  Id(branchA), "001", "2026-10-01", nextAccountSeq(db))
discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
  insertAccount(d, testAccount, actor)
  1)

proc setVault(branch: Id, amount: Money) =
  db.exec(sql"""
    INSERT INTO teller.vault (branch_id, balance) VALUES (?, ?::numeric)
    ON CONFLICT (branch_id) DO UPDATE SET balance = EXCLUDED.balance, updated_at = now()""",
    $branch, amount.toDecimalString)

proc vaultOf(branch: Id): Money =
  vaultBalanceOf(db, branch).get()

proc seedTransaction(amount: Money): Id =
  ## Jurnal seimbang + baris transaksi tunai (FK `cash_movement.transaction_id`).
  let jid = newId(testClock)
  let txId = newId(testClock)
  let j = Journal(journalId: jid, businessDate: businessDate, valueDate: businessDate,
    sourceEvent: "ItSessionTest", sourceRef: txId, idempotencyKey: "its-" & $jid)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    discard insertJournal(d, j, actor)
    insertJournalLine(d, jid, JournalLine(lineNo: 1, glAccount: "101.2", branchId: Id(branchA),
      debit: amount, credit: zero()))
    insertJournalLine(d, jid, JournalLine(lineNo: 2, glAccount: "201", branchId: Id(branchA),
      debit: zero(), credit: amount))
    insertTransaction(d, Transaction(transactionId: txId, txType: ttCashDeposit,
      accountId: testAccount.accountId, amount: amount, businessDate: businessDate, narration: "",
      journalId: jid), actor)
    1)
  txId

proc openSession(branch, teller: Id, openingFloat: Money): Id =
  ## Buka sesi seperti composition root: debit vault, lalu sisipkan sesi OPEN.
  let s = newOpenSession(newId(testClock), branch, teller, businessDate, openingFloat, teller)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    doAssert debitVault(d, branch, openingFloat).isSome, "vault tidak cukup di fixture"
    doAssert insertOpenSession(d, s), "sesi OPEN gagal disisipkan di fixture"
    1)
  s.sessionId

proc addMovement(sessionId: Id, movementType: CashMovementType, amount: Money) =
  let txId = seedTransaction(amount)
  let m = newCashMovement(newId(testClock), sessionId, movementType, amount, txId, businessDate,
    $actor)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertMovement(d, m)
    1)

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

suite "teller: vault":
  test "debit vault bersyarat: saldo cukup berkurang, saldo kurang ditolak utuh":
    setVault(Id(branchA), money(100_0000))
    check vaultOf(Id(branchA)) == money(100_0000)
    check debitVault(db, Id(branchA), money(40_0000)) == some(money(60_0000))
    check vaultOf(Id(branchA)) == money(60_0000)
    # 60 < 1000 → tidak ada baris diubah.
    check debitVault(db, Id(branchA), money(1000_0000)).isNone
    check vaultOf(Id(branchA)) == money(60_0000)
    # Vault cabang tanpa baris: none (dibedakan pemanggil → vault_not_configured).
    check vaultBalanceOf(db, Id(branchC)).isNone
    check debitVault(db, Id(branchC), zero()).isNone

  test "vault tidak boleh negatif (CHECK DB)":
    setVault(Id(branchB), money(10_0000))
    expectDbError(proc() = db.exec(
      sql"UPDATE teller.vault SET balance = -1 WHERE branch_id = ?", branchB))

suite "teller: sesi kas":
  test "buka sesi menurunkan vault; expected = opening float saat kosong":
    setVault(Id(branchB), money(100_0000))
    let sid = openSession(Id(branchB), Id(tellerA), money(40_0000))
    check vaultOf(Id(branchB)) == money(60_0000)
    let found = openSessionFor(db, Id(branchB), Id(tellerA))
    check found.isSome
    check found.get().sessionId == sid
    check found.get().status == tssOpen
    check found.get().openingFloat == money(40_0000)
    check found.get().expectedCash.isNone
    let totals = movementTotalsOf(db, sid)
    check totals.cashIn == zero()
    check totals.cashOut == zero()
    check expectedCashOf(found.get().openingFloat, totals.cashIn, totals.cashOut) == money(40_0000)

  test "dua sesi OPEN (cabang, teller) ditolak partial unique; boleh setelah ditutup":
    setVault(Id(branchC), money(100_0000))
    let sid = openSession(Id(branchC), Id(tellerA), money(10_0000))
    # Jalan repo (ON CONFLICT) → false, bukan error DB.
    let dup = newOpenSession(newId(testClock), Id(branchC), Id(tellerA), businessDate,
      money(10_0000), Id(tellerA))
    check not insertOpenSession(db, dup)
    # Jalan SQL mentah → unique violation.
    expectDbError(proc() = db.exec(sql"""
      INSERT INTO teller.teller_session
        (session_id, branch_id, teller_user_id, business_date, status, opening_float, opened_by)
      VALUES (gen_random_uuid(), ?::uuid, ?::uuid, ?::date, 'OPEN', '1.00', ?::uuid)""",
      branchC, tellerA, tellerA))
    # Tutup → sesi baru untuk pasangan yang sama boleh.
    check closeSession(db, sid, money(10_0000), money(10_0000), zero(), "", Id(tellerA))
    check openSession(Id(branchC), Id(tellerA), money(5_0000)) != sid

  test "teller lain di cabang yang sama boleh punya sesi OPEN sendiri":
    setVault(Id(branchD), money(100_0000))
    let s1 = openSession(Id(branchD), Id(tellerA), money(10_0000))
    let s2 = openSession(Id(branchD), Id(tellerB), money(10_0000))
    check s1 != s2
    check openSessionFor(db, Id(branchD), Id(tellerA)).get().sessionId == s1
    check openSessionFor(db, Id(branchD), Id(tellerB)).get().sessionId == s2

  test "tutup menambah vault sebesar counted (bukan expected) + mencatat variance":
    setVault(Id(branchE), money(200_0000))
    let sid = openSession(Id(branchE), Id(tellerA), money(100_0000))
    check vaultOf(Id(branchE)) == money(100_0000)
    addMovement(sid, cmCashIn, money(30_0000))
    addMovement(sid, cmCashOut, money(10_0000))

    let totals = movementTotalsOf(db, sid)
    check totals.cashIn == money(30_0000)
    check totals.cashOut == money(10_0000)
    let expected = expectedCashOf(money(100_0000), totals.cashIn, totals.cashOut)
    check expected == money(120_0000)
    let counted = money(125_0000)
    let variance = varianceOf(counted, expected)
    check variance == money(5_0000)
    check closeSession(db, sid, expected, counted, variance, "kas lebih", Id(tellerA))
    check creditVault(db, Id(branchE), counted).isSome
    # Vault = 200 - 100 (buka) + 125 (counted fisik) = 225; kalau salah pakai expected jadi 220.
    check vaultOf(Id(branchE)) == money(225_0000)

    let closed = sessionById(db, sid).get()
    check closed.status == tssClosed
    check closed.openingFloat == money(100_0000)
    check closed.expectedCash == some(money(120_0000))
    check closed.countedCash == some(money(125_0000))
    check closed.variance == some(money(5_0000))
    check closed.note == "kas lebih"
    check closed.closedAt.len > 0
    # Paritas: net movement = Σ movement baris (formula domain sama dengan agregat SQL).
    check netMovementOf(movementsOf(db, sid)) == money(20_0000)
    check expected == money(100_0000) + netMovementOf(movementsOf(db, sid))

  test "tutup kedua tidak menambah vault lagi":
    let before = vaultOf(Id(branchE))
    # Sesi branchE sudah CLOSED oleh test sebelumnya: closeSession lagi → false, vault tetap.
    let closedSessionId = openSessionFor(db, Id(branchE), Id(tellerA))
    check closedSessionId.isNone
    let s = sessionById(db, Id("00000000-0000-7000-8000-000000000000"))
    check s.isNone
    check vaultOf(Id(branchE)) == before

    # Sesi baru untuk pasangan sama, lalu tutup dua kali.
    let sid = openSession(Id(branchE), Id(tellerA), zero())
    let counted = zero()
    check closeSession(db, sid, zero(), counted, zero(), "", Id(tellerA))
    let vaultAfterFirst = vaultOf(Id(branchE))
    check not closeSession(db, sid, zero(), zero(), zero(), "", Id(tellerA))
    check vaultOf(Id(branchE)) == vaultAfterFirst

  test "CHECK variance: baris CLOSED dengan variance menyimpang ditolak":
    expectDbError(proc() = db.exec(sql"""
      INSERT INTO teller.teller_session
        (session_id, branch_id, teller_user_id, business_date, status, opening_float, opened_by,
         expected_cash, counted_cash, variance, closed_at, closed_by)
      VALUES (gen_random_uuid(), ?::uuid, ?::uuid, ?::date, 'CLOSED', '0.00', ?::uuid,
              '10.00', '10.00', '1.00', now(), ?::uuid)""",
      branchC, tellerB, businessDate, tellerB, tellerB))
    # Baris CLOSED tanpa seluruh kolom penutup juga ditolak.
    expectDbError(proc() = db.exec(sql"""
      INSERT INTO teller.teller_session
        (session_id, branch_id, teller_user_id, business_date, status, opening_float, opened_by,
         counted_cash, variance, closed_at, closed_by)
      VALUES (gen_random_uuid(), ?::uuid, ?::uuid, ?::date, 'CLOSED', '0.00', ?::uuid,
              '10.00', '0.00', now(), ?::uuid)""",
      branchC, tellerB, businessDate, tellerB, tellerB))

  test "movement immutable: UPDATE/DELETE/TRUNCATE ditolak":
    setVault(Id(branchA), money(0))
    let sid = openSession(Id(branchA), Id(tellerB), zero())
    addMovement(sid, cmCashIn, money(7_0000))
    let movementId = $movementsOf(db, sid)[0].movementId
    expectDbError(proc() = db.exec(
      sql"UPDATE teller.cash_movement SET amount = 1 WHERE movement_id = ?", movementId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM teller.cash_movement WHERE movement_id = ?", movementId))
    expectDbError(proc() = db.exec(sql"TRUNCATE teller.cash_movement"))

var closeSuccess: Atomic[int]

type CloseArgs = object
  pool: DbPool
  sessionId: string
  counted: string
  actor: string

proc closeWorker(args: CloseArgs) {.thread.} =
  {.cast(gcsafe).}:
    let ok =
      try:
        args.pool.withTx(proc(d: DbConn): bool {.closure.} =
          exec(d, sql"SET LOCAL lock_timeout = '5000'")
          let sid = Id(args.sessionId)
          let sOpt = sessionByIdForUpdate(d, sid)
          if sOpt.isNone or sOpt.get().status != tssOpen:
            return false
          let s = sOpt.get()
          let totals = movementTotalsOf(d, s.sessionId)
          let expected = expectedCashOf(s.openingFloat, totals.cashIn, totals.cashOut)
          let counted = moneyFromString(args.counted).value()
          let variance = varianceOf(counted, expected)
          if not closeSession(d, sid, expected, counted, variance, "", Id(args.actor)):
            return false
          creditVault(d, s.branchId, counted).isSome)
      except DbError:
        false
    if ok:
      closeSuccess.atomicInc(1)

suite "teller: dua penutupan bersamaan":
  test "satu berhasil, satu ditolak, vault bertambah sekali":
    setVault(Id(branchA), money(200_0000))
    let sid = openSession(Id(branchA), Id(tellerA), money(50_0000))
    check vaultOf(Id(branchA)) == money(150_0000)

    closeSuccess.store(0)
    var w1, w2: Thread[CloseArgs]
    createThread(w1, closeWorker, CloseArgs(pool: dbPool, sessionId: $sid,
      counted: money(50_0000).toDecimalString, actor: tellerA))
    createThread(w2, closeWorker, CloseArgs(pool: dbPool, sessionId: $sid,
      counted: money(50_0000).toDecimalString, actor: tellerA))
    joinThread(w1)
    joinThread(w2)

    check closeSuccess.load() == 1
    check sessionById(db, sid).get().status == tssClosed
    # 150 + 50 (counted sekali) = 200; kalau dua kali jadi 250.
    check vaultOf(Id(branchA)) == money(200_0000)

var
  gateLocked: Atomic[bool]
  gateInserted: Atomic[bool]

type GateArgs = object
  pool: DbPool
  branch: string
  teller: string
  sessionId: string
  transactionId: string
  movementId: string
  amount: string

proc gateWorker(args: GateArgs) {.thread.} =
  ## Meniru transaksi tunai in-flight: kunci sesi (`FOR KEY SHARE` lewat `lockOpenSession`), lalu
  ## tulis movement **setelah jeda** supaya penutupan yang tidak menunggu lock pasti membacanya
  ## sebagai nol.
  {.cast(gcsafe).}:
    let ok =
      try:
        args.pool.withTx(proc(d: DbConn): bool {.closure.} =
          exec(d, sql"SET LOCAL lock_timeout = '5000'")
          let locked = lockOpenSession(d, Id(args.branch), Id(args.teller), businessDate)
          if locked.isNone:
            return false
          gateLocked.store(true)
          sleep(1500)
          insertMovement(d, newCashMovement(Id(args.movementId), Id(args.sessionId), cmCashIn,
            moneyFromString(args.amount).value(), Id(args.transactionId), businessDate, $actor))
          gateInserted.store(true)
          true)
      except DbError:
        false
    discard ok

suite "teller: transaksi tunai vs penutupan bersamaan":
  test "penutupan menunggu transaksi in-flight sehingga movement masuk expected_cash":
    setVault(Id(branchF), money(0))
    let sid = openSession(Id(branchF), Id(tellerB), zero())
    let txId = seedTransaction(money(25_0000))
    let movementId = newId(testClock)

    gateLocked.store(false)
    gateInserted.store(false)
    var w: Thread[GateArgs]
    createThread(w, gateWorker, GateArgs(pool: dbPool, branch: branchF, teller: tellerB,
      sessionId: $sid, transactionId: $txId, movementId: $movementId,
      amount: money(25_0000).toDecimalString))
    var waited = 0
    while not gateLocked.load() and waited < 2500:
      sleep(2)
      inc waited
    # Jangan menggantung bila worker gagal mengunci; gagal terlihat lebih baik daripada hang.
    check gateLocked.load()

    # Penutupan dari koneksi lain HARUS menunggu `FOR UPDATE` vs `FOR KEY SHARE`; setelah transaksi
    # commit, `expected_cash` sudah memuat movement itu (tanpa ini movement bisa hilang).
    var seenCashIn = zero()
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      exec(d, sql"SET LOCAL lock_timeout = '5000'")
      let s = sessionByIdForUpdate(d, sid)
      if s.isSome:
        seenCashIn = movementTotalsOf(d, sid).cashIn
      1)
    joinThread(w)

    check gateInserted.load()
    check seenCashIn == money(25_0000)
