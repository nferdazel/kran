## Test integrasi task `deposit.interest_accrual` (T-138c) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan di sini tidak bisa dibuktikan unit test:
##   1. akrual menulis baris `deposit.interest_accrual` **dan** jurnal `InterestAccrued`
##      (D 501 / K 204) di transaksi yang sama;
##   2. catch-up: hari yang belum diakrualkan menyusul tanpa selisih pembulatan, karena yang
##      dibulatkan adalah kumulatif sejak `opened_on`, bukan bagian harian;
##   3. menjalankan tanggal yang sama dua kali tidak menambah baris/jurnal (idempoten);
##   4. basis & skala dibaca dari binding versi produk (ACT/360, rounding 1 desimal);
##   5. rekening `CLOSED` dan rekening yang dibuka setelah tanggal buku tidak diakrualkan;
##   6. konfigurasi produk yang hilang **menahan penutupan** (DAY-331) dan membatalkan seluruh
##      chunk — tidak ada akrual setengah jadi;
##   7. `countChunks`/paginasi chunk memecah rekening tanpa duplikat.
##
## **HUMAN-REVIEW-REQUIRED**: angka bunga di test ini adalah area kritis (AGENTS.md §8). Golden
## value dihitung dengan oracle independen (`decimal` Python, ROUND_HALF_EVEN), bukan dari
## implementasinya.
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain).

import std/[json, options, os, sequtils, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[clock, dayclose, ids, money, result]

import daycloser/domain/[registry, types]

import deposit/domain/[account, transaction]
import deposit/infrastructure/[account_repo, reconcile_repo, transaction_repo]
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

import ../src/daycloser_deposit
import ../src/deposit_posting
import ../src/posting

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_deposit: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

const
  repoRoot = "."
  BranchId = "b0000000-0000-4000-8000-0000000000c1"
  PeriodId = "d0000000-0000-4000-8000-0000000000c1"
  OpenedOn = "2026-10-01"
  AccrualDate = "2026-10-28"

let
  ## Jam tetap: jurnal memakai `newId(clock)`/`newId` untuk idempotensi, bukan waktu nyata.
  testClock = fakeClock(dateTime(2026, mOct, 28, 20, 0, 0))
  actor = Id("00000000-0000-4000-8000-0000000000c9")
  maker = Id("00000000-0000-4000-8000-0000000000ca")

# Periode GL harus memuat tanggal buku; tanpa itu trigger `ledger` menolak jurnal.
execScript(db, """
  INSERT INTO platform.branch (branch_id, code, name)
  VALUES ('""" & BranchId & """', '142', 'Cabang Akrual')
  ON CONFLICT DO NOTHING
""")
execScript(db, """
  INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
  VALUES ('""" & PeriodId & """', DATE '2026-01-01', DATE '2026-12-31', 'OPEN',
          '""" & $actor & """', '""" & $actor & """')
""")

var productSeq = 0

proc newPartyRow(): Id =
  productSeq.inc
  let p = newParty(newId(testClock), pkPerson, "Anggota Akrual " & $productSeq,
    Id(BranchId), "{seq:6}{check}", nextCifSeq(db))
  discard insertParty(db, p, actor)
  p.partyId

proc newProductWith(bindings: seq[ParamBinding]): tuple[product: Product, version: ProductVersion] =
  ## Produk simpanan + versi ACTIVE lewat repo, supaya invarian versi produk terpenuhi.
  productSeq.inc
  let prod = Product(productId: newId(testClock), code: "TD" & align($productSeq, 3, '0'),
    name: "Deposito Uji " & $productSeq, productType: ptSavings)
  let v = ProductVersion(versionId: newId(testClock), productId: prod.productId, versionNo: 1,
    effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int =
    insertProduct(d, prod, actor)
    insertVersion(d, v, maker)
    for b in bindings:
      insertBinding(d, v.versionId, b)
    1)
  doAssert approveVersion(db, v.versionId, actor), "versi produk uji gagal di-approve"
  (prod, v)

proc stdBindings(rate = "2.5"; basis = "ACT_365"; scale = "2"): seq[ParamBinding] =
  @[ParamBinding(paramKey: "product.savings.min_balance", value: %"0.00"),
    ParamBinding(paramKey: "product.savings.interest_rate", value: %rate),
    ParamBinding(paramKey: "product.savings.day_count_basis", value: %basis),
    ParamBinding(paramKey: "product.savings.rounding_scale", value: %parseInt(scale))]

proc timeDeposit(version: ProductVersion; productCode, openedOn, principal: string;
                 status = "ACTIVE"; maturityDate = ""; aro = ""; partyId = ""): Id =
  ## Rekening berjangka dengan saldo pokok. `newAccount` selalu melahirkan SAVINGS, jadi tipenya
  ## diubah sebelum disimpan (itulah yang dibaca task). `partyId` kosong = party baru (pola lama);
  ## diisi = rekening berbagi party dengan tabungan tujuan (T-138d).
  var a = newAccount(newId(testClock),
    (if partyId.len == 0: newPartyRow() else: Id(partyId)),
    version.productId, version.versionId, productCode, Id(BranchId), "142", openedOn,
    nextAccountSeq(db))
  a.accountType = atTimeDeposit
  a.status = parseAccountStatus(status)
  discard dbPool.withTx(proc(d: DbConn): int =
    insertAccount(d, a, actor)
    d.exec(sql"""
      UPDATE deposit.account_balance SET balance = ?::numeric WHERE account_id = ?""",
      principal, $a.accountId)
    if maturityDate.len > 0:
      d.exec(sql"""UPDATE deposit.account SET maturity_date = ?::date WHERE account_id = ?""",
        maturityDate, $a.accountId)
    if aro.len > 0:
      d.exec(sql"""UPDATE deposit.account SET aro_instruction = ? WHERE account_id = ?""",
        aro, $a.accountId)
    1)
  a.accountId

proc savingsAccount(version: ProductVersion; productCode, partyId, openedOn: string;
                    balance = "0.00"): Id =
  ## Rekening tabungan anggota untuk menerima pembayaran jatuh tempo (T-138d).
  var a = newAccount(newId(testClock), Id(partyId), version.productId, version.versionId,
    productCode, Id(BranchId), "142", openedOn, nextAccountSeq(db))
  discard dbPool.withTx(proc(d: DbConn): int =
    insertAccount(d, a, actor)
    d.exec(sql"""
      UPDATE deposit.account_balance SET balance = ?::numeric WHERE account_id = ?""",
      balance, $a.accountId)
    1)
  a.accountId

proc seedPrincipalMovement(version: ProductVersion; productCode, accountId, amount,
                           businessDate: string) =
  ## Setoran pokok awal yang **benar-benar tercatat**: baris `deposit.transaction` + jurnal
  ## seimbang. Tanpa ini `reconcile-deposits` melihat saldo cache tanpa sumber dan test rekonsiliasi
  ## akan lulus/gagal karena artefak fixture, bukan karena alur jatuh tempo.
  let value = moneyFromString(amount).value()
  discard dbPool.withTx(proc(d: DbConn): int =
    let journalId = postRuleJournalSync(d, testClock, "DepositPosted", value, Id(BranchId),
      Id(accountId), businessDate, "test.deposit:" & accountId, systemActor,
      %*{"product": productCode, "accountType": "TIME_DEPOSIT"})
    insertTransaction(d, Transaction(transactionId: newId(testClock), txType: ttCashDeposit,
      accountId: Id(accountId), amount: value, businessDate: businessDate,
      narration: "setoran pokok", journalId: journalId), systemActor)
    1)

proc taskOf(reg: Registry; id: TaskId): DayCloseTask =
  for t in reg.all():
    if t.id == id:
      return t
  raise newException(ValueError, "task tidak terdaftar: " & id)

proc task(): DayCloseTask =
  let reg = newRegistry()
  registerDepositTasks(reg, dbPool)
  taskOf(reg, interestAccrualTaskId)

proc maturityTask(): DayCloseTask =
  let reg = newRegistry()
  registerDepositTasks(reg, dbPool)
  taskOf(reg, maturityAroTaskId)

proc ctxOn(businessDate: string; chunkSize = 1000): TaskContext =
  TaskContext(runId: "test", scopeType: "INSTITUTION", scopeId: "", businessDate: businessDate,
    levels: {clEOD}, mode: rmReal, chunkSize: chunkSize)

proc accrualRow(accountId: Id; businessDate: string):
    tuple[principal, days, rate, basis, amount, cumulative, journalId: string] =
  let rows = db.getAllRows(sql"""
    SELECT principal::text, days::text, rate_percent::text, basis_days::text, amount::text,
           cumulative::text, coalesce(journal_id::text, '')
      FROM deposit.interest_accrual
     WHERE account_id = ? AND business_date = ?::date""", $accountId, businessDate)
  if rows.len == 0:
    return ("", "", "", "", "", "", "")
  (rows[0][0], rows[0][1], rows[0][2], rows[0][3], rows[0][4], rows[0][5], rows[0][6])

proc journalLines(key: string): seq[tuple[gl, debit, credit: string]] =
  ## Baris jurnal untuk satu kunci idempotensi. Kosong = jurnal tidak pernah ditulis.
  for row in db.getAllRows(sql"""
      SELECT l.gl_account, l.debit::text, l.credit::text
        FROM ledger.journal j
        JOIN ledger.journal_line l USING (journal_id)
       WHERE j.idempotency_key = ?
       ORDER BY l.line_no""", key):
    result.add (row[0], row[1], row[2])

proc journalOf(accountId: Id; businessDate: string): seq[tuple[gl, debit, credit: string]] =
  ## Baris jurnal akrual rekening+tanggal.
  journalLines("interest.accrual:" & $accountId & ":" & businessDate)

proc maturityJournal(accountId: Id; businessDate: string):
    seq[tuple[gl, debit, credit: string]] =
  ## Jurnal pokok jatuh tempo (`DepositMatured`, ARO `NONE`).
  journalLines("maturity:" & $accountId & ":" & businessDate)

proc interestPostJournal(accountId: Id; businessDate: string):
    seq[tuple[gl, debit, credit: string]] =
  ## Jurnal bunga jatuh tempo (`InterestPosted` atau `InterestCapitalized`).
  journalLines("interest.post:" & $accountId & ":" & businessDate)

proc balanceOf(accountId: Id): string =
  db.getValue(sql"""
    SELECT coalesce(balance::text, '') FROM deposit.account_balance WHERE account_id = ?""",
    $accountId)

proc journalIdFor(key: string): string =
  db.getValue(sql"""
    SELECT coalesce(journal_id::text, '') FROM ledger.journal WHERE idempotency_key = ?""", key)


proc stateOf(accountId: Id): tuple[status, maturity: string] =
  let row = db.getAllRows(sql"""
    SELECT status, coalesce(to_char(maturity_date, 'YYYY-MM-DD'), '')
      FROM deposit.account WHERE account_id = ?""", $accountId)
  if row.len == 0:
    return ("", "")
  (row[0][0], row[0][1])

proc transactionsOf(accountId: Id; txType: TransactionType):
    seq[tuple[amount, businessDate, journalId, narration: string]] =
  for row in db.getAllRows(sql"""
      SELECT amount::text, to_char(business_date, 'YYYY-MM-DD'), coalesce(journal_id::text, ''),
             coalesce(narration, '')
        FROM deposit.transaction
       WHERE account_id = ? AND tx_type = ?
       ORDER BY created_at""", $accountId, $txType):
    result.add (row[0], row[1], row[2], row[3])

proc mismatchFor(accountNo: string): seq[BalanceMismatch] =
  ## Selisih rekonsiliasi untuk satu rekening. Fixture suite lain sengaja menyetel saldo langsung
  ## (tanpa baris subledger), jadi yang dibuktikan di sini adalah rekening yang benar-benar dialirkan
  ## lewat task, bukan "tidak ada selisih sama sekali di DB uji".
  for m in accountBalanceMismatches(db, ""):
    if m.accountNo == accountNo:
      result.add m

proc runAt(businessDate: string; chunkNo = 0; chunkSize = 1000): TaskResult =
  task().run(ctxOn(businessDate, chunkSize), Chunk(chunkNo: chunkNo))

proc runMaturityAt(businessDate: string; chunkNo = 0; chunkSize = 1000): TaskResult =
  maturityTask().run(ctxOn(businessDate, chunkSize), Chunk(chunkNo: chunkNo))

let std = newProductWith(stdBindings())

suite "akrual bunga: satu rentang":
  test "baris akrual + jurnal D 501 / K 204 untuk 28 hari":
    let accountId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00")

    let res = runAt(AccrualDate)
    check res.isOk

    let row = accrualRow(accountId, AccrualDate)
    # 10.000.000 × 2,5% × 28/365 = 19.178,08219… → 19.178,08 (oracle: decimal HALF_EVEN)
    check row.amount == "19178.08"
    check row.cumulative == "19178.08"
    check row.principal == "10000000.00"
    check row.days == "28"
    check row.rate == "2.5000"
    check row.basis == "365"
    check row.journalId.len > 0

    let lines = journalOf(accountId, AccrualDate)
    check lines.len == 2
    check lines[0].gl == "501"
    check lines[0].debit == "19178.08"
    check lines[0].credit == "0.00"
    check lines[1].gl == "204"
    check lines[1].credit == "19178.08"

    # Event non-akuntansi: jurnal sudah ditulis sinkron, jadi konsumen outbox tidak boleh
    # memposting jurnal kedua.
    check db.getValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'InterestAccrued' AND dedup_key = ?""",
      "interest.accrued:" & $accountId & ":" & AccrualDate) == "1"

suite "akrual bunga: catch-up":
  test "hari yang belum diakrualkan menyusul tanpa selisih pembulatan":
    let accountId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00")

    # 5 hari: 10.000.000 × 2,5% × 5/365 = 3.424,6575… → 3.424,66
    check runAt("2026-10-05").isOk
    check accrualRow(accountId, "2026-10-05").amount == "3424.66"

    # Sampai 28 hari kumulatif = 19.178,08; bagian hari ini = 19.178,08 − 3.424,66 = 15.753,42.
    check runAt(AccrualDate).isOk
    let second = accrualRow(accountId, AccrualDate)
    check second.amount == "15753.42"
    check second.cumulative == "19178.08"
    check second.days == "23"

    # Jumlah bagian = satu pembulatan rentang penuh (bukan 28 pembulatan harian).
    check db.getValue(sql"""
      SELECT sum(amount)::text FROM deposit.interest_accrual WHERE account_id = ?""",
      $accountId) == "19178.08"

  test "menjalankan tanggal yang sama lagi tidak menambah baris atau jurnal":
    let accountId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00")
    check runAt(AccrualDate).isOk
    let before = db.getValue(sql"""
      SELECT count(*)::text FROM deposit.interest_accrual WHERE account_id = ?""", $accountId)

    let again = runAt(AccrualDate)
    check again.isOk
    check again.value.metrics{"accrued"}.getInt == 0
    check db.getValue(sql"""
      SELECT count(*)::text FROM deposit.interest_accrual WHERE account_id = ?""", $accountId) ==
      before
    check journalOf(accountId, AccrualDate).len == 2

suite "akrual bunga: atribut produk":
  test "ACT/360 memakai pembagi 360":
    let act360 = newProductWith(stdBindings(basis = "ACT_360"))
    let accountId = timeDeposit(act360.version, act360.product.code, OpenedOn, "10000000.00")

    check runAt(AccrualDate).isOk
    let row = accrualRow(accountId, AccrualDate)
    # 10.000.000 × 2,5% × 28/360 = 19.444,4444… → 19.444,44
    check row.amount == "19444.44"
    check row.basis == "360"

  test "rounding_scale 1 membulatkan ke satu desimal":
    let coarse = newProductWith(stdBindings(scale = "1"))
    let accountId = timeDeposit(coarse.version, coarse.product.code, OpenedOn, "10000000.00")

    check runAt(AccrualDate).isOk
    let row = accrualRow(accountId, AccrualDate)
    # 19.178,0821… dibulatkan ke 0,1 → 19.178,1
    check row.amount == "19178.10"
    check row.cumulative == "19178.10"

  test "pokok nol: baris tercatat, jurnal tidak dibuat":
    let accountId = timeDeposit(std.version, std.product.code, OpenedOn, "0.00")

    check runAt(AccrualDate).isOk
    let row = accrualRow(accountId, AccrualDate)
    check row.amount == "0.00"
    check row.journalId == ""
    check journalOf(accountId, AccrualDate).len == 0

suite "akrual bunga: batas jatuh tempo (T-138d, D-155)":
  test "bunga berhenti sehari sebelum maturity_date":
    # Dibuka 1 Okt, jatuh tempo 20 Okt → hari terakhir berbunga 19 Okt (19 hari).
    let accountId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = "2026-10-20")

    check runAt(AccrualDate).isOk
    let row = accrualRow(accountId, AccrualDate)
    # 10.000.000 × 2,5% × 19/365 = 13.013,6986… → 13.013,70
    check row.amount == "13013.70"
    check row.days == "19"

    # Penutupan berikutnya tidak menambah bunga melewati perjanjian.
    check runAt("2026-10-29").isOk
    check accrualRow(accountId, "2026-10-29").amount == ""
    check db.getValue(sql"""
      SELECT count(*)::text FROM deposit.interest_accrual WHERE account_id = ?""",
      $accountId) == "1"

suite "akrual bunga: rekening yang tidak diakrualkan":
  test "rekening CLOSED tidak diakrualkan":
    let accountId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      status = "CLOSED")
    check runAt(AccrualDate).isOk
    check accrualRow(accountId, AccrualDate).amount == ""

  test "rekening yang dibuka setelah tanggal buku belum berbunga":
    let accountId = timeDeposit(std.version, std.product.code, "2026-11-02", "10000000.00")
    check runAt(AccrualDate).isOk
    check accrualRow(accountId, AccrualDate).amount == ""

suite "akrual bunga: konfigurasi produk rusak":
  test "binding rate hilang = DAY-331 dan chunk dibatalkan utuh":
    let incomplete = newProductWith(@[
      ParamBinding(paramKey: "product.savings.min_balance", value: %"0.00")])
    let brokenId = timeDeposit(incomplete.version, incomplete.product.code, OpenedOn,
      "10000000.00")
    # Rekening sehat di chunk yang sama: kalau akrualnya ikut ter-commit padahal chunk gagal,
    # penutupan berikutnya akan menganggap hari itu sudah selesai.
    let healthyId = timeDeposit(std.version, std.product.code, OpenedOn, "1000000.00")
    let uniqueDate = "2026-12-30"

    let res = runAt(uniqueDate)
    check not res.isOk
    check res.error.code == "DAY-331"
    check accrualRow(brokenId, uniqueDate).amount == ""
    check accrualRow(healthyId, uniqueDate).amount == ""
    check journalOf(healthyId, uniqueDate).len == 0

    # Higiene test: keluarkan rekening rusak dari populasi akrual supaya test berikutnya tidak
    # blocked oleh konfigurasi yang memang sengaja salah.
    execScript(db, "UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = '" &
      $brokenId & "'")

suite "akrual bunga: pembagian chunk":
  test "countChunks dan paginasi tidak menduplikasi rekening":
    let total = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.account
       WHERE account_type = 'TIME_DEPOSIT' AND status <> 'CLOSED'"""))
    check total > 2

    let t = task()
    let counted = t.countChunks(ctxOn(AccrualDate, chunkSize = 2), 2)
    check counted.isOk
    check counted.value() == (total + 1) div 2

    var seen: seq[string]
    for i in 0 ..< counted.value():
      let res = runAt("2026-12-31", chunkNo = i, chunkSize = 2)
      # Rekening rusak sudah di-CLOSED; sisa populasi sehat.
      check res.isOk
      let ids = db.getAllRows(sql"""
        SELECT a.account_id::text FROM deposit.account a
         WHERE a.account_type = 'TIME_DEPOSIT' AND a.status <> 'CLOSED'
         ORDER BY a.account_id LIMIT 2 OFFSET ?::int""", $(i * 2))
      for row in ids:
        seen.add row[0]
    check seen.len == total
    check deduplicate(seen).len == total

# ---------------------------------------------------------------------------------------------
# Jatuh tempo / ARO (T-138d, D-155)
# ---------------------------------------------------------------------------------------------

# Higiene: suite akrual di atas membuat satu rekening berjangka dengan `maturity_date` 2026-10-20
# dan **tanpa** `aro_instruction` (kasus batas akrual). Rekening itu jatuh tempo pada setiap tanggal
# buku suite ini dan akan menghentikan task dengan DAY-341 — bukan perilaku yang diuji di sini.
# Ditutup, bukan diberi ARO: tanpa rekening simpanan tujuan ia tetap gagal (DAY-343).
execScript(db, """
  UPDATE deposit.account SET status = 'CLOSED', updated_by = '""" & $actor & """'
   WHERE account_type = 'TIME_DEPOSIT' AND maturity_date IS NOT NULL
     AND aro_instruction IS NULL
""")

const
  MaturityDate = "2026-10-20"
  MaturityRunDate = "2026-10-28"

suite "jatuh tempo ARO NONE (D-155 butir 2)":
  test "pokok + bunga pindah ke rekening simpanan, deposito ditutup":
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)

    # Bunga hari terakhir tenor (19 Okt) harus sudah tercatat sebelum dipindahkan.
    check runAt(MaturityRunDate).isOk
    check accrualRow(depositId, MaturityRunDate).amount == "13013.70"

    let res = runMaturityAt(MaturityRunDate)
    check res.isOk
    check res.value.metrics{"closed"}.getInt == 1
    check res.value.metrics{"principal"}.getStr == "10000000.00"
    check res.value.metrics{"interestPaid"}.getStr == "13013.70"

    check stateOf(depositId) == ("CLOSED", MaturityDate)
    check balanceOf(depositId) == "0.00"
    check balanceOf(savingsId) == "10013013.70"

    # DepositMatured D 202 / K 201 sebesar pokok.
    let principalLines = maturityJournal(depositId, MaturityRunDate)
    check principalLines.len == 2
    check principalLines[0].gl == "202"
    check principalLines[0].debit == "10000000.00"
    check principalLines[1].gl == "201"
    check principalLines[1].credit == "10000000.00"

    # InterestPosted D 204 / K 201 sebesar bunga akrual (19 hari).
    let interestLines = interestPostJournal(depositId, MaturityRunDate)
    check interestLines.len == 2
    check interestLines[0].gl == "204"
    check interestLines[0].debit == "13013.70"
    check interestLines[1].gl == "201"
    check interestLines[1].credit == "13013.70"

    # Subledger: pokok keluar dari deposito dan masuk ke tabungan dengan **jurnal yang sama**;
    # bunga masuk ke tabungan dengan jurnal bunga.
    let principalJournalId = journalIdFor("maturity:" & $depositId & ":" & MaturityRunDate)
    let interestJournalId = journalIdFor("interest.post:" & $depositId & ":" & MaturityRunDate)
    check principalJournalId.len > 0
    let outRows = transactionsOf(depositId, ttMaturityOut)
    check outRows.len == 1
    check outRows[0].amount == "10000000.00"
    check outRows[0].businessDate == MaturityRunDate
    check outRows[0].journalId == principalJournalId
    let inRows = transactionsOf(savingsId, ttMaturityIn)
    check inRows.len == 1
    check inRows[0].amount == "10000000.00"
    check inRows[0].journalId == principalJournalId
    let interestRows = transactionsOf(savingsId, ttInterestCredit)
    check interestRows.len == 1
    check interestRows[0].amount == "13013.70"
    check interestRows[0].journalId == interestJournalId

    # Rekonsiliasi merekonstruksi saldo dari baris subledger: tanpa baris MATURITY_* di kedua
    # rekening ini, keduanya akan dilaporkan selisih.
    let depositNo = accountById(db, depositId).get().accountNo
    let savingsNo = accountById(db, savingsId).get().accountNo
    check reconciledAccountCount(db, "") > 0
    check mismatchFor(depositNo).len == 0
    check mismatchFor(savingsNo).len == 0

  test "tanpa rekening simpanan tujuan = DAY-343, tidak ada yang berubah":
    let partyId = newPartyRow() # sengaja tanpa rekening tabungan
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)

    let res = runMaturityAt(MaturityRunDate)
    check not res.isOk
    check res.error.code == "DAY-343"
    check res.error.message.contains(accountById(db, depositId).get().accountNo)
    check stateOf(depositId) == ("ACTIVE", MaturityDate)
    check balanceOf(depositId) == "10000000.00"
    check maturityJournal(depositId, MaturityRunDate).len == 0
    check interestPostJournal(depositId, MaturityRunDate).len == 0
    check transactionsOf(depositId, ttMaturityOut).len == 0

    # Higiene: rekening tanpa tujuan tidak boleh menahan suite berikutnya.
    execScript(db, "UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = '" &
      $depositId & "'")

suite "jatuh tempo ARO PRINCIPAL (D-155 butir 3)":
  test "pokok diperpanjang dengan tenor semula, bunga ke rekening simpanan":
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "PRINCIPAL", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)

    check runAt(MaturityRunDate).isOk
    let res = runMaturityAt(MaturityRunDate)
    check res.isOk
    check res.value.metrics{"rolledOver"}.getInt == 1

    # Tenor semula = 20 Okt − 1 Okt = 19 hari → jatuh tempo baru 8 Nov.
    check stateOf(depositId) == ("ACTIVE", "2026-11-08")
    check balanceOf(depositId) == "10000000.00"
    check balanceOf(savingsId) == "13013.70"

    # Pokok tidak berpindah: tidak ada jurnal DepositMatured dan tidak ada baris keluar.
    check maturityJournal(depositId, MaturityRunDate).len == 0
    check transactionsOf(depositId, ttMaturityOut).len == 0

    let interestLines = interestPostJournal(depositId, MaturityRunDate)
    check interestLines.len == 2
    check interestLines[0].gl == "204"
    check interestLines[0].debit == "13013.70"
    check interestLines[1].gl == "201"
    check interestLines[1].credit == "13013.70"

    let depositNo = accountById(db, depositId).get().accountNo
    let savingsNo = accountById(db, savingsId).get().accountNo
    check mismatchFor(depositNo).len == 0
    check mismatchFor(savingsNo).len == 0

suite "jatuh tempo ARO PRINCIPAL_AND_INTEREST (D-155 butir 4)":
  test "bunga dikapitalisasi menjadi pokok, tanpa rekening simpanan":
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "PRINCIPAL_AND_INTEREST", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)

    check runAt(MaturityRunDate).isOk
    let res = runMaturityAt(MaturityRunDate)
    check res.isOk
    check res.value.metrics{"interestCapitalized"}.getStr == "13013.70"

    check stateOf(depositId) == ("ACTIVE", "2026-11-08")
    check balanceOf(depositId) == "10013013.70"

    # InterestCapitalized D 204 / K 202.
    let lines = interestPostJournal(depositId, MaturityRunDate)
    check lines.len == 2
    check lines[0].gl == "204"
    check lines[0].debit == "13013.70"
    check lines[1].gl == "202"
    check lines[1].credit == "13013.70"

    # Bunga masuk ke rekening deposito itu sendiri, supaya rekonsiliasi tetap cocok.
    let interestJournalId = journalIdFor("interest.post:" & $depositId & ":" & MaturityRunDate)
    let creditRows = transactionsOf(depositId, ttInterestCredit)
    check creditRows.len == 1
    check creditRows[0].amount == "13013.70"
    check creditRows[0].journalId == interestJournalId
    check db.getValue(sql"""
      SELECT count(*)::text FROM deposit.account
       WHERE party_id = ? AND account_type = 'SAVINGS'""", $partyId) == "0"

    let depositNo = accountById(db, depositId).get().accountNo
    check mismatchFor(depositNo).len == 0

suite "jatuh tempo: idempoten":
  test "run ulang tanggal yang sama atau berikutnya tidak memproses dua kali":
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)

    check runAt(MaturityRunDate).isOk
    check runMaturityAt(MaturityRunDate).isOk
    let rowsBefore = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.transaction WHERE account_id = ? OR account_id = ?""",
      $depositId, $savingsId))
    let journalsBefore = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM ledger.journal
       WHERE idempotency_key IN (?, ?)""", "maturity:" & $depositId & ":" & MaturityRunDate,
      "interest.post:" & $depositId & ":" & MaturityRunDate))
    # 1 setoran pokok awal + 3 baris perpindahan (MATURITY_OUT, MATURITY_IN, INTEREST_CREDIT).
    check rowsBefore == 4
    check journalsBefore == 2

    let again = runMaturityAt(MaturityRunDate)
    check again.isOk
    check again.value.metrics{"accounts"}.getInt == 0
    check parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.transaction WHERE account_id = ? OR account_id = ?""",
      $depositId, $savingsId)) == rowsBefore
    check balanceOf(savingsId) == "10013013.70"

    check runMaturityAt("2026-10-29").isOk
    check parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.transaction WHERE account_id = ? OR account_id = ?""",
      $depositId, $savingsId)) == rowsBefore
    check balanceOf(savingsId) == "10013013.70"

suite "jatuh tempo: proses terlambat (D-155 butir 6)":
  test "bunga tetap berhenti di maturity_date − 1, bukan tanggal proses":
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)

    # Penutupan tanggal jatuh tempo macet; proses baru berjalan 5 Nov.
    check runAt("2026-11-05").isOk
    check accrualRow(depositId, "2026-11-05").amount == "13013.70"

    let res = runMaturityAt("2026-11-05")
    check res.isOk
    check res.value.metrics{"interestPaid"}.getStr == "13013.70"
    check balanceOf(savingsId) == "10013013.70"
    let lines = interestPostJournal(depositId, "2026-11-05")
    check lines[0].debit == "13013.70"

suite "jatuh tempo: pembagian chunk":
  test "paginasi chunk memproses semua rekening walau populasi berubah":
    # Tiga rekening `NONE` dengan `chunkSize` 2. Paginasi `LIMIT/OFFSET` langsung pada himpunan
    # "jatuh tempo" akan melewati rekening: baris yang sudah diproses hilang dari halaman berikutnya
    # sehingga offset bergeser. Test ini gagal bila jendela halaman tidak stabil.
    var deposits: seq[Id]
    for _ in 0 ..< 3:
      let partyId = newPartyRow()
      let id = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
        maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
      seedPrincipalMovement(std.version, std.product.code, $id, "10000000.00", OpenedOn)
      discard savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
      deposits.add id

    check runAt("2026-10-30").isOk
    let total = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.account WHERE account_type = 'TIME_DEPOSIT'"""))
    let counted = maturityTask().countChunks(ctxOn("2026-10-30"), 2)
    check counted.isOk
    check counted.value() == (total + 1) div 2

    for i in 0 ..< counted.value():
      check runMaturityAt("2026-10-30", chunkNo = i, chunkSize = 2).isOk
    for id in deposits:
      check stateOf(id).status == "CLOSED"
      check balanceOf(id) == "0.00"

suite "jatuh tempo: data rusak":
  test "aro_instruction kosong = DAY-341, tidak ada rekening yang berubah":
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, partyId = $partyId)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)

    let res = runMaturityAt(MaturityRunDate)
    check not res.isOk
    check res.error.code == "DAY-341"
    check stateOf(depositId) == ("ACTIVE", MaturityDate)
    check balanceOf(depositId) == "10000000.00"
    check balanceOf(savingsId) == "0.00"
    check transactionsOf(savingsId, ttMaturityIn).len == 0

    execScript(db, "UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = '" &
      $depositId & "'")
