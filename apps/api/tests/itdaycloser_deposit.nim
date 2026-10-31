## Test integrasi task day-close deposit (T-138c akrual, T-138d jatuh tempo/ARO) — butuh
## `KRAN_DATABASE_URL`.
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
##      chunk — tidak ada akrual setengah jadi (rollback diuji dengan urutan `account_id` yang
##      dipatok, karena id fixture bertimestamp sama);
##   7. `countChunks`/paginasi chunk memproses setiap rekening tepat sekali (dibaca dari metrics
##      task, bukan dari kueri offset yang dijalankan ulang).
##
## Jatuh tempo (`deposit.maturity_aro`): tiga instruksi ARO D-155, jurnal perpindahan, baris
## subledger per rekening dengan jurnal yang sama, penutupan `NONE`, tenor perpanjangan, idempotensi
## run ulang, paginasi saat populasi berubah, dan data rusak (ARO kosong/asing) yang menahan run.

##
## **HUMAN-REVIEW-REQUIRED**: angka bunga di test ini adalah area kritis (AGENTS.md §8). Golden
## value dihitung dengan oracle independen (`decimal` Python, ROUND_HALF_EVEN), bukan dari
## implementasinya.
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain).

import std/[json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[clock, dayclose, ids, money, result]

import daycloser/domain/[registry, types]

import deposit/domain/[account, transaction, transfer]
import deposit/infrastructure/[account_repo, maturity_repo, reconcile_repo, transaction_repo,
  transfer_repo]
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
# `platform.param_value.key` memakai FK ke `param_definition`: suite dormant menyemai ambangnya
# sendiri, jadi definisi parameter dasar harus ada lebih dulu.
execScript(db, readFile("packs/base/generated/param_definitions.sql"))

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

proc baseBindings(rate = "2.5"; basis = "ACT_365"; scale = "2"): seq[ParamBinding] =
  ## Atribut akrual minimal. Tanpa `rollover_tenor_days`: produk inilah yang dipakai test
  ## "binding tenor tidak ada" (DAY-354).
  @[ParamBinding(paramKey: "product.savings.min_balance", value: %"0.00"),
    ParamBinding(paramKey: "product.savings.interest_rate", value: %rate),
    ParamBinding(paramKey: "product.savings.day_count_basis", value: %basis),
    ParamBinding(paramKey: "product.savings.rounding_scale", value: %parseInt(scale))]

proc stdBindings(rate = "2.5"; basis = "ACT_365"; scale = "2"; tenor = 19):
    seq[ParamBinding] =
  ## Produk uji dengan tenor rollover (D-165). `tenor` sengaja parameter supaya ada test yang
  ## membuktikan nilainya benar-benar dibaca dari binding, bukan dari selisih tanggal. 19 hari
  ## membuat ekspektasi lama (20 Okt → 8 Nov) tetap sah.
  baseBindings(rate, basis, scale) & @[
    ParamBinding(paramKey: "product.savings.rollover_tenor_days", value: %tenor)]

proc timeDeposit(version: ProductVersion; productCode, openedOn, principal: string;
                 status = "ACTIVE"; maturityDate = ""; aro = ""; partyId = "";
                 fixedId = ""): Id =
  ## Rekening berjangka dengan saldo pokok. `newAccount` selalu melahirkan SAVINGS, jadi tipenya
  ## diubah sebelum disimpan (itulah yang dibaca task). `partyId` kosong = party baru (pola lama);
  ## diisi = rekening berbagi party dengan tabungan tujuan (T-138d).
  ##
  ## `fixedId` dipakai test yang butuh urutan `account_id` **deterministik**: `newId(fakeClock)`
  ## memberi timestamp UUIDv7 yang sama, jadi urutannya ditentukan bit acak dan test rollback bisa
  ## lolos tanpa membuktikan apa pun.
  var a = newAccount(
    (if fixedId.len == 0: newId(testClock) else: Id(fixedId)),
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

proc seedTransferActivity(version: ProductVersion; productCode: string;
                          sourceId, destinationId: Id; businessDate: string) =
  ## PB yang benar-benar tercatat (jurnal + baris `deposit.transfer`), dipakai membuktikan bahwa
  ## aktivitas dormant juga dibaca dari PB — bukan hanya dari `deposit.transaction` (D-157 butir 1).
  let value = moneyFromString("1000.00").value()
  discard dbPool.withTx(proc(d: DbConn): int =
    let journalId = postRuleJournalSync(d, testClock, "DepositTransferred", value, Id(BranchId),
      sourceId, businessDate, "test.transfer:" & $sourceId & ":" & businessDate, systemActor,
      %*{"product": productCode, "accountType": "SAVINGS"})
    insertTransfer(d, Transfer(transferId: newId(testClock), sourceAccountId: sourceId,
      destinationAccountId: destinationId, amount: value, businessDate: businessDate,
      narration: "PB uji aktivitas", journalId: journalId), systemActor)
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
  ## `runId` harus UUID sah: task meneruskannya ke `ledger.journal.daycloser_run_id` (D-158), jadi
  ## nilai seperti "test" membuat jurnal akrual gagal ditulis dan seluruh chunk kembali `DAY-337`.
  TaskContext(runId: "11111111-1111-4111-8111-111111111111", scopeType: "INSTITUTION", scopeId: "",
    businessDate: businessDate, levels: {clEOD}, mode: rmReal, chunkSize: chunkSize)

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

  test "rekening DORMANT tetap diakrualkan (D-154 butir 1, D-157)":
    # Dormant membatasi layanan, bukan perjanjian bunga: predikat akrual `status <> 'CLOSED'`.
    let accountId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      status = "DORMANT")

    check runAt(AccrualDate).isOk
    let row = accrualRow(accountId, AccrualDate)
    check row.amount == "19178.08"
    check row.journalId.len > 0

suite "akrual bunga: konfigurasi produk rusak":
  test "binding rate hilang = DAY-331 dan chunk dibatalkan utuh":
    let incomplete = newProductWith(@[
      ParamBinding(paramKey: "product.savings.min_balance", value: %"0.00")])
    # Id dipilih tetap supaya urutan `account_id` deterministik: rekening sehat **sebelum** dan
    # **sesudah** rekening rusak. Dengan `newId(fakeClock)` semua id bertimestamp sama, urutannya
    # ditentukan bit acak, dan rekening rusak bisa terurut paling awal — ketiga assertion di bawah
    # lalu lolos tanpa pernah membuktikan rollback.
    let healthyFirst = timeDeposit(std.version, std.product.code, OpenedOn, "1000000.00",
      fixedId = "f1000000-0000-7000-8000-0000000000a1")
    let brokenId = timeDeposit(incomplete.version, incomplete.product.code, OpenedOn,
      "10000000.00", fixedId = "f1000000-0000-7000-8000-0000000000a2")
    let healthyLast = timeDeposit(std.version, std.product.code, OpenedOn, "1000000.00",
      fixedId = "f1000000-0000-7000-8000-0000000000a3")
    # PostgreSQL membandingkan `uuid` per byte; teks kanonik adalah hex byte yang sama.
    check $healthyFirst < $brokenId
    check $brokenId < $healthyLast
    let uniqueDate = "2026-12-30"

    let res = runAt(uniqueDate)
    check not res.isOk
    check res.error.code == "DAY-331"
    # Satu chunk: rekening sehat pertama sudah ditulis sebelum rekening rusak gagal, jadi yang diuji
    # adalah rollback chunk yang sungguh berisi baris, bukan chunk kosong.
    for accountId in [healthyFirst, brokenId, healthyLast]:
      check accrualRow(accountId, uniqueDate).amount == ""
      check journalOf(accountId, uniqueDate).len == 0

    # Higiene test: keluarkan rekening rusak dari populasi akrual supaya test berikutnya tidak
    # blocked oleh konfigurasi yang memang sengaja salah.
    execScript(db, "UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = '" &
      $brokenId & "'")

suite "akrual bunga: pembagian chunk":
  test "countChunks dan paginasi memproses setiap rekening tepat sekali":
    let total = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.account
       WHERE account_type = 'TIME_DEPOSIT' AND status <> 'CLOSED'"""))
    check total > 2

    let t = task()
    let counted = t.countChunks(ctxOn(AccrualDate, chunkSize = 2), 2)
    check counted.isOk
    check counted.value() == (total + 1) div 2

    # Yang diperiksa adalah **apa yang diproses task** (`metrics.accounts` per chunk), bukan
    # kueri offset yang dijalankan ulang: kueri ulang akan selalu konsisten dengan dirinya sendiri
    # walau `runChunk` memakai offset yang salah. Jumlah total yang diproses harus sama dengan
    # populasi — offset salah membuat rekening terlewat (kurang) atau diproses dua kali (lebih).
    var processed = 0
    for i in 0 ..< counted.value():
      let res = runAt("2026-12-31", chunkNo = i, chunkSize = 2)
      # Rekening rusak sudah di-CLOSED; sisa populasi sehat.
      check res.isOk
      let accounts = res.value().metrics["accounts"].getInt()
      check accounts <= 2
      processed += accounts
    check processed == total

    # Bukti kedua dari sisi data: setiap rekening yang berhak diakrualkan pada tanggal itu punya
    # baris, dan tidak ada rekening di luar populasi yang mendapat baris.
    let withRow = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.interest_accrual ia
        JOIN deposit.account a ON a.account_id = ia.account_id
       WHERE ia.business_date = '2026-12-31'::date
         AND a.account_type = 'TIME_DEPOSIT' AND a.status <> 'CLOSED'"""))
    check withRow > 0
    check parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM deposit.interest_accrual ia
        JOIN deposit.account a ON a.account_id = ia.account_id
       WHERE ia.business_date = '2026-12-31'::date
         AND (a.account_type <> 'TIME_DEPOSIT' OR a.status = 'CLOSED')""")) == 0

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

# ---------------------------------------------------------------------------------------------
# Dormant (T-138e, D-152 butir 4 / D-157)
# ---------------------------------------------------------------------------------------------

const
  DormantRunDate = "2026-10-28"
  ## Harus sama dengan ambang default pack (`deposit.dormant.after_months`): cutoff = 2025-10-28.
  DormantMonths = 12

proc seedDormantMonths(months: int) =
  ## Nilai parameter institusi untuk suite ini. Ditulis langsung ke `platform.param_value` (pola
  ## `itapi_closeguard`), bukan lewat pack, supaya suite bisa menguji beberapa ambang.
  execScript(db, """
    INSERT INTO platform.param_value
      (param_value_id, key, scope_type, scope_id, value, effective_from, status, maker, checker,
       reason)
    VALUES (md5('deposit.dormant.after_months|test')::uuid, 'deposit.dormant.after_months',
            'GLOBAL', NULL, '""" & $months & """'::jsonb, DATE '1970-01-01', 'ACTIVE',
            '00000000-0000-4000-8000-0000000000c9', '00000000-0000-4000-8000-0000000000ca',
            'seed test dormant')
    ON CONFLICT (param_value_id) DO UPDATE SET value = EXCLUDED.value
  """)

proc dormantTask(): DayCloseTask =
  let reg = newRegistry()
  registerDepositTasks(reg, dbPool)
  taskOf(reg, dormantTaskId)

proc runDormantAt(businessDate: string; chunkNo = 0; chunkSize = 1000): TaskResult =
  dormantTask().run(ctxOn(businessDate, chunkSize), Chunk(chunkNo: chunkNo))

proc dormantPopulation(): int =
  parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM deposit.account
     WHERE status IN ('ACTIVE', 'DORMANT')"""))

suite "dormant: penandaan status (T-138e)":

  test "tanpa aktivitas > ambang jadi DORMANT; yang beraktivitas tetap ACTIVE":
    seedDormantMonths(DormantMonths)
    let staleId = timeDeposit(std.version, std.product.code, "2024-01-01", "1000000.00")
    let recentId = timeDeposit(std.version, std.product.code, "2024-01-01", "1000000.00")
    seedPrincipalMovement(std.version, std.product.code, $recentId, "1000000.00", "2026-09-01")

    let res = runDormantAt(DormantRunDate)
    check res.isOk
    check stateOf(staleId).status == "DORMANT"
    check stateOf(recentId).status == "ACTIVE"
    # Tidak ada uang yang bergerak dan tidak ada jurnal: menandai dormant bukan peristiwa akuntansi.
    check balanceOf(staleId) == "1000000.00"
    check transactionsOf(staleId, ttCashDeposit).len == 0

  test "batas ambang: aktivitas tepat di cutoff belum dormant, sehari lebih lama sudah":
    # cutoff = 2026-10-28 − 12 bulan = 2025-10-28; yang diuji adalah `<`, bukan `<=`.
    let boundaryId = timeDeposit(std.version, std.product.code, "2025-10-28", "1000000.00")
    let olderId = timeDeposit(std.version, std.product.code, "2025-10-27", "1000000.00")

    check runDormantAt(DormantRunDate).isOk
    check stateOf(boundaryId).status == "ACTIVE"
    check stateOf(olderId).status == "DORMANT"

  test "DORMANT kembali ACTIVE setelah ada aktivitas":
    let accountId = timeDeposit(std.version, std.product.code, "2024-01-01", "1000000.00")
    check runDormantAt(DormantRunDate).isOk
    check stateOf(accountId).status == "DORMANT"

    seedPrincipalMovement(std.version, std.product.code, $accountId, "1000.00", "2026-10-20")
    execScript(db, """
      UPDATE deposit.account_balance SET balance = balance + 1000.00
       WHERE account_id = '""" & $accountId & """'""")
    check runDormantAt(DormantRunDate).isOk
    check stateOf(accountId).status == "ACTIVE"

  test "PB masuk dan keluar menghitung sebagai aktivitas (D-157 butir 1)":
    # Aktivitas dibaca dari `deposit.transaction` **dan** `deposit.transfer`; kalau lateral PB salah
    # kolom/arah, rekening yang baru saja menerima PB akan salah ditandai dormant.
    seedDormantMonths(DormantMonths)
    let sender = savingsAccount(std.version, std.product.code, $newPartyRow(), "2024-01-01")
    let receiver = savingsAccount(std.version, std.product.code, $newPartyRow(), "2024-01-01")
    seedTransferActivity(std.version, std.product.code, sender, receiver, "2026-09-01")

    check runDormantAt(DormantRunDate).isOk
    check stateOf(sender).status == "ACTIVE"
    check stateOf(receiver).status == "ACTIVE"

  test "rekening CLOSED tidak pernah disentuh":
    let closedId = timeDeposit(std.version, std.product.code, "2024-01-01", "0.00",
      status = "CLOSED")
    check runDormantAt(DormantRunDate).isOk
    check stateOf(closedId).status == "CLOSED"

  test "run ulang tidak menandai dua kali (idempoten)":
    let first = runDormantAt(DormantRunDate)
    check first.isOk
    let again = runDormantAt(DormantRunDate)
    check again.isOk
    check again.value().metrics["dormant"].getInt() == 0
    check again.value().metrics["reactivated"].getInt() == 0

  test "parameter ambang hilang = DAY-351 tanpa mengubah status":
    let accountId = timeDeposit(std.version, std.product.code, "2024-01-01", "1000000.00")
    execScript(db, """
      DELETE FROM platform.param_value
       WHERE param_value_id = md5('deposit.dormant.after_months|test')::uuid
    """)
    let res = runDormantAt(DormantRunDate)
    check not res.isOk
    check res.error.code == "DAY-351"
    check stateOf(accountId).status == "ACTIVE"
    seedDormantMonths(DormantMonths)

  test "paginasi chunk 2 memeriksa setiap rekening dalam populasi stabil":
    let total = dormantPopulation()
    check total > 2
    let t = dormantTask()
    let counted = t.countChunks(ctxOn(DormantRunDate, chunkSize = 2), 2)
    check counted.isOk
    check counted.value() == (total + 1) div 2

    # Status hanya berpindah ACTIVE <-> DORMANT, keduanya anggota populasi, jadi offset tidak
    # bergeser; yang dibuktikan: setiap halaman diproses dan jumlahnya menutup populasi.
    var processed = 0
    for i in 0 ..< counted.value():
      let res = runDormantAt(DormantRunDate, chunkNo = i, chunkSize = 2)
      check res.isOk
      let accounts = res.value().metrics["accounts"].getInt()
      check accounts <= 2
      processed += accounts
    check processed == total

# ---------------------------------------------------------------------------------------------
# Jatuh tempo: guard dan rollback (review T-138d)
# ---------------------------------------------------------------------------------------------

proc closeAllTimeDeposits() =
  ## Higiene: hanya rekening yang dibuat test berikut yang boleh jatuh tempo pada tanggal uji.
  ## Tanpa ini rekening dari suite lain (yang sudah `CLOSED`/diperpanjang) bisa membuat chunk
  ## berhenti lebih dulu dengan kode lain, dan assertion jadi menebak urutan.
  execScript(db, """
    UPDATE deposit.account SET status = 'CLOSED'
     WHERE account_type = 'TIME_DEPOSIT' AND status <> 'CLOSED'""")

proc kindProduct(kind: SavingsKind): tuple[product: Product, version: ProductVersion] =
  ## Produk simpanan berklasifikasi (POKOK/WAJIB) untuk menguji pemilihan rekening tujuan.
  productSeq.inc
  let prod = Product(productId: newId(testClock), code: "TDK" & align($productSeq, 3, '0'),
    name: "Simpanan " & $kind, productType: ptSavings, savingsKind: some(kind))
  let v = ProductVersion(versionId: newId(testClock), productId: prod.productId, versionNo: 1,
    effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int =
    insertProduct(d, prod, actor)
    insertVersion(d, v, maker)
    insertBinding(d, v.versionId,
      ParamBinding(paramKey: "product.savings.min_balance", value: %"0.00"))
    1)
  doAssert approveVersion(db, v.versionId, actor), "versi produk POKOK gagal di-approve"
  (prod, v)

suite "jatuh tempo: baseline akrual & tenor per siklus (D-165)":
  test "siklus kedua hanya membayar bunga di atas baseline, tidak mengulang siklus pertama":
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "PRINCIPAL", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)

    # Siklus 1: seluruh akrual dibayar (baseline masih 0).
    check runAt(MaturityRunDate).isOk
    check runMaturityAt(MaturityRunDate).isOk
    let firstCumulative =
      moneyFromString(accrualRow(depositId, MaturityRunDate).cumulative).value()
    check moneyFromString(balanceOf(savingsId)).value() == firstCumulative
    check stateOf(depositId) == ("ACTIVE", "2026-11-08")

    # Siklus 2: akrual berjalan lagi sampai sehari sebelum jatuh tempo baru.
    check runAt("2026-11-08").isOk
    let secondCumulative =
      moneyFromString(accrualRow(depositId, "2026-11-08").cumulative).value()
    check secondCumulative > firstCumulative
    check runMaturityAt("2026-11-08").isOk

    # Yang dibayar = cumulative siklus 2, bukan jumlah kedua siklus. Tanpa baseline ini
    # `balanceOf` akan menjadi `firstCumulative + secondCumulative` (bug O-109).
    let paidTwoCycles = moneyFromString(balanceOf(savingsId)).value()
    check paidTwoCycles == secondCumulative
    check paidTwoCycles < firstCumulative + secondCumulative
    check db.getValue(sql"""
      SELECT interest_paid_cumulative::text FROM deposit.account WHERE account_id = ?""",
      $depositId) == secondCumulative.toDecimalString

  test "tenor perpanjangan dibaca dari binding produk, bukan selisih opened_on":
    let long = newProductWith(stdBindings(tenor = 45))
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(long.version, long.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "PRINCIPAL", partyId = $partyId)
    seedPrincipalMovement(long.version, long.product.code, $depositId, "10000000.00", OpenedOn)
    discard savingsAccount(long.version, long.product.code, $partyId, OpenedOn)

    check runAt(MaturityRunDate).isOk
    check runMaturityAt(MaturityRunDate).isOk
    # 20 Okt + 45 hari = 4 Des, bukan 8 Nov (selisih opened_on..maturity = 19 hari).
    check stateOf(depositId) == ("ACTIVE", "2026-12-04")

  test "binding tenor tidak ada = DAY-354, rekening tidak berubah":
    let bare = newProductWith(baseBindings())
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(bare.version, bare.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "PRINCIPAL", partyId = $partyId)
    seedPrincipalMovement(bare.version, bare.product.code, $depositId, "10000000.00", OpenedOn)
    let savingsId = savingsAccount(bare.version, bare.product.code, $partyId, OpenedOn)

    check runAt(MaturityRunDate).isOk
    let res = runMaturityAt(MaturityRunDate)
    check not res.isOk
    check res.error.code == "DAY-354"
    check stateOf(depositId) == ("ACTIVE", MaturityDate)
    check balanceOf(depositId) == "10000000.00"
    check balanceOf(savingsId) == "0.00"

suite "jatuh tempo: guard (review T-138d)":

  test "rekening sehat sebelum rekening rusak ikut dibatalkan (DAY-341)":
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    # Id tetap: urutan `account_id` deterministik, rekening sehat benar-benar diproses lebih dulu.
    let healthyId = timeDeposit(std.version, std.product.code, OpenedOn, "5000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId,
      fixedId = "f2000000-0000-7000-8000-0000000000a1")
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    let brokenId = timeDeposit(std.version, std.product.code, OpenedOn, "1000000.00",
      maturityDate = MaturityDate, partyId = $partyId,
      fixedId = "f2000000-0000-7000-8000-0000000000a2")
    check $healthyId < $brokenId

    let res = runMaturityAt(MaturityRunDate)
    check not res.isOk
    check res.error.code == "DAY-341"
    # Rekening sehat sudah menulis jurnal + baris subledger sebelum chunk gagal: semuanya dibatalkan.
    check stateOf(healthyId) == ("ACTIVE", MaturityDate)
    check balanceOf(healthyId) == "5000000.00"
    check transactionsOf(healthyId, ttMaturityOut).len == 0
    check transactionsOf(savingsId, ttMaturityIn).len == 0
    check balanceOf(savingsId) == "0.00"
    check maturityJournal(healthyId, MaturityRunDate).len == 0
    check interestPostJournal(healthyId, MaturityRunDate).len == 0

  test "rekening POKOK bukan tujuan pembayaran: dipakai tabungan biasa (DAY-343 bila tidak ada)":
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let pokok = kindProduct(skPokok)
    # Rekening POKOK dibuat **lebih dulu** → `account_no` terkecil, jadi target default bila
    # penyaring `savings_kind` hilang.
    let pokokId = savingsAccount(pokok.version, pokok.product.code, $partyId, OpenedOn)
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    # Bunga tenor penuh (19 hari) harus sudah tercatat sebelum perpindahan diuji.
    check runAt(MaturityRunDate).isOk

    # Tanpa tabungan biasa, tidak ada target yang sah: POKOK tidak boleh dipakai.
    let noTarget = runMaturityAt(MaturityRunDate)
    check not noTarget.isOk
    check noTarget.error.code == "DAY-343"

    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    check runMaturityAt(MaturityRunDate).isOk
    check balanceOf(savingsId) == "10013013.70"
    check balanceOf(pokokId) == "0.00"
    check stateOf(depositId).status == "CLOSED"

  test "tabungan tujuan DORMANT tetap dipakai (bukan DAY-343) dan direaktivasi":
    closeAllTimeDeposits()
    seedDormantMonths(DormantMonths)
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    # Tabungan anggota lama tidak dipakai → DORMANT sebelum deposito jatuh tempo. Kredit jatuh tempo
    # adalah aktivitas, jadi rekening ini tetap target yang sah (D-157 butir 3).
    execScript(db, "UPDATE deposit.account SET status = 'DORMANT' WHERE account_id = '" &
      $savingsId & "'")
    check runAt(MaturityRunDate).isOk

    check runMaturityAt(MaturityRunDate).isOk
    check balanceOf(savingsId) == "10013013.70"
    check stateOf(depositId).status == "CLOSED"

    # Task dormant pada penutupan yang sama mengembalikannya ACTIVE.
    check runDormantAt(DormantRunDate).isOk
    check stateOf(savingsId).status == "ACTIVE"

  test "baris saldo hilang = DAY-348, deposito tidak ditutup":
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    discard savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    execScript(db, "DELETE FROM deposit.account_balance WHERE account_id = '" &
      $depositId & "'")

    let res = runMaturityAt(MaturityRunDate)
    check not res.isOk
    check res.error.code == "DAY-348"
    check stateOf(depositId).status == "ACTIVE"
    check transactionsOf(depositId, ttMaturityOut).len == 0

  test "jatuh tempo baru sudah lewat (terlambat > satu tenor) = DAY-349":
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "PRINCIPAL", partyId = $partyId)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    # Bunga tenor penuh diakrualkan lebih dulu supaya guard benar-benar diuji: tanpa ini
    # `interest.post:` kosong bukan karena guard, melainkan karena bunganya memang nol.
    check runAt(MaturityRunDate).isOk
    # Baris akrual bertanggal **tanggal buku**, bukan hari terakhir bunga.
    check accrualRow(depositId, MaturityRunDate).cumulative != ""

    # Tenor 19 hari: jatuh tempo 2026-10-20 → perpanjangan 2026-11-08, yang juga sudah lewat pada
    # 2026-12-01. Melanjutkan berarti membayar bunga siklus yang sama dua kali (O-109).
    let res = runMaturityAt("2026-12-01")
    check not res.isOk
    check res.error.code == "DAY-349"
    check stateOf(depositId) == ("ACTIVE", MaturityDate)
    check balanceOf(depositId) == "10000000.00"
    check balanceOf(savingsId) == "0.00"
    check interestPostJournal(depositId, "2026-12-01").len == 0
    check transactionsOf(savingsId, ttInterestCredit).len == 0

# ---------------------------------------------------------------------------------------------
# O-112: kunci baris `deposit.account` (jalur teller <-> task jatuh tempo)
# ---------------------------------------------------------------------------------------------
#
# Invarian yang dibuktikan: rekening tidak pernah berakhir `CLOSED` **bersaldo**, dan perpindahan
# jatuh tempo memakai saldo **sesudah** kunci didapat — bukan saldo basi dari halaman kandidat yang
# dibaca di luar transaksi chunk.
#
# Dua koneksi nyata (bukan simulasi urutan): satu koneksi memegang baris rekening `FOR UPDATE`,
# pekerja lain menjalankan task di thread sendiri. Sinkronisasinya `pg_blocking_pids` — bukan
# `sleep` sebagai penentu — jadi hasilnya tidak bergantung timing mesin.

type
  LockArgs = object
    accountId: Id
    businessDate: string

var
  ## Hasil pekerja thread: 0 = belum jalan, 1 = sukses / kunci didapat, -1 = task gagal.
  settleResult = 0
  lockResult = 0

proc settleWorker(businessDate: string) {.thread.} =
  ## Menjalankan task jatuh tempo pada koneksi pool sendiri, bukan `db` milik test: transaksi chunk
  ## harus benar-benar berjalan di koneksi lain saat test memegang kuncinya.
  {.cast(gcsafe).}:
    settleResult = (if runMaturityAt(businessDate).isOk: 1 else: -1)

proc lockWorker(args: LockArgs) {.thread.} =
  {.cast(gcsafe).}:
    lockResult = dbPool.withConn(proc(d: DbConn): int =
      (if lockMaturityAccount(d, args.accountId, args.businessDate).isSome: 1 else: 0))

proc blockedByHolder(pid: string): int =
  ## Jumlah sesi yang menunggu lock `pid`, transitif (pola `itapi_teller_vault`): `pg_blocking_pids`
  ## hanya memberi penghalang langsung, padahal penunggu kedua bisa mengantre di belakang yang
  ## pertama. Ini yang membuat "pekerja benar-benar menunggu" deterministik.
  let conn = dbPool.acquire()
  try:
    parseInt(conn.getValue(sql"""
      WITH RECURSIVE blocked(pid) AS (
        SELECT a.pid FROM pg_stat_activity a
         WHERE a.datname = current_database() AND a.pid <> pg_backend_pid()
           AND ?::int = ANY(pg_blocking_pids(a.pid))
        UNION
        SELECT a.pid FROM pg_stat_activity a
          JOIN blocked b ON b.pid = ANY(pg_blocking_pids(a.pid))
      )
      SELECT count(*)::text FROM blocked""", pid))
  finally:
    dbPool.release(conn)

proc waitBlockedOn(pid: string): int =
  ## Tunggu sampai setidaknya satu sesi menunggu lock `pid` (batas 5 s = jaring aman supaya test
  ## tidak menggantung; jalannya test tidak bergantung pada angka ini).
  let deadline = epochTime() + 5.0
  result = 0
  while epochTime() < deadline and result == 0:
    result = blockedByHolder(pid)
    if result == 0:
      sleep(5)

suite "kunci baris rekening (O-112)":
  test "penutupan menunggu kunci dan memindahkan saldo sesudah kunci":
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    check runAt(MaturityRunDate).isOk

    # Koneksi penahan memegang baris rekening — posisi transaksi teller yang sedang berjalan.
    let side = dbPool.acquire()
    defer: dbPool.release(side)
    exec(side, sql"BEGIN")
    lockAccountForUpdate(side, depositId)
    let holderPid = side.getValue(sql"SELECT pg_backend_pid()")

    settleResult = 0
    var worker: Thread[string]
    createThread(worker, settleWorker, MaturityRunDate)
    let blocked = waitBlockedOn(holderPid)

    # Setoran tunai yang sudah lolos cek status: saldo naik **sebelum** kunci dilepas. Halaman
    # kandidat sudah dibaca pekerja, jadi saldo ini hanya terlihat bila kunci + baca ulang bekerja.
    exec(side, sql"""
      UPDATE deposit.account_balance SET balance = balance + 500000.00
       WHERE account_id = ?""", $depositId)
    exec(side, sql"COMMIT")
    joinThread(worker)

    check blocked >= 1
    check settleResult == 1
    check stateOf(depositId) == ("CLOSED", MaturityDate)
    # Invarian: `CLOSED` tidak pernah bersaldo, dan pokok yang dipindahkan = saldo sesudah kunci
    # (10.500.000), bukan 10.000.000 dari halaman kandidat. Tanpa kunci, `adjustBalance` menyisakan
    # 500.000 → `DAY-345`, chunk dibatalkan, rekening tetap `ACTIVE`.
    check balanceOf(depositId) == "0.00"
    check balanceOf(savingsId) == "10513013.70"
    let lines = maturityJournal(depositId, MaturityRunDate)
    check lines.len == 2
    check lines[0].debit == "10500000.00"
    check lines[1].credit == "10500000.00"

  test "kunci jalur teller adalah baris yang sama dengan jalur jatuh tempo":
    # Membuktikan mutual exclusion tanpa harness HTTP: kunci yang diambil jalur setoran tunai
    # (`lockAccountForUpdate`) menahan pembacaan terkunci jalur jatuh tempo pada baris yang sama.
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)

    let side = dbPool.acquire()
    defer: dbPool.release(side)
    exec(side, sql"BEGIN")
    lockAccountForUpdate(side, depositId)
    let holderPid = side.getValue(sql"SELECT pg_backend_pid()")

    lockResult = 0
    var worker: Thread[LockArgs]
    createThread(worker, lockWorker, LockArgs(accountId: depositId,
      businessDate: MaturityRunDate))
    let blocked = waitBlockedOn(holderPid)
    exec(side, sql"COMMIT")
    joinThread(worker)

    check blocked >= 1
    check lockResult == 1
    # Tidak ada uang yang berpindah: yang diuji hanya serialisasi.
    check stateOf(depositId) == ("ACTIVE", MaturityDate)
    check balanceOf(depositId) == "10000000.00"
    check balanceOf(savingsId) == "0.00"

  test "rekening yang berubah sebelum chunk berjalan dilewati, kolom dibaca ulang":
    closeAllTimeDeposits()
    let partyId = newPartyRow()
    let depositId = timeDeposit(std.version, std.product.code, OpenedOn, "10000000.00",
      maturityDate = MaturityDate, aro = "NONE", partyId = $partyId)
    let savingsId = savingsAccount(std.version, std.product.code, $partyId, OpenedOn)
    seedPrincipalMovement(std.version, std.product.code, $depositId, "10000000.00", OpenedOn)
    check runAt(MaturityRunDate).isOk

    # Kandidat masih berhak saat halaman dibaca.
    let before = lockMaturityAccount(db, depositId, MaturityRunDate)
    check before.isSome
    check before.get().account.balance == moneyFromString("10000000.00").value()
    check before.get().accruedInterest == moneyFromString("13013.70").value()
    check before.get().hasBalance

    # Proses lain menutup rekening sebelum chunk berjalan: bukan lagi pekerjaan task ini.
    execScript(db, "UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = '" &
      $depositId & "'")
    check lockMaturityAccount(db, depositId, MaturityRunDate).isNone

    # Jatuh tempo yang sudah dimajukan (perpanjangan oleh proses lain) juga bukan pekerjaan tanggal
    # buku ini.
    execScript(db, """
      UPDATE deposit.account SET status = 'ACTIVE', maturity_date = DATE '2027-01-01'
       WHERE account_id = '""" & $depositId & """'""")
    check lockMaturityAccount(db, depositId, MaturityRunDate).isNone

    # Kolom keputusan (saldo) dibaca **sesudah** kunci: perubahan yang commit sebelum kunci didapat
    # ikut terbaca, bukan nilai dari halaman kandidat.
    execScript(db, """
      UPDATE deposit.account SET maturity_date = DATE '""" & MaturityDate &
        """'
       WHERE account_id = '""" & $depositId & """'""")
    execScript(db, """
      UPDATE deposit.account_balance SET balance = balance + 200000.00
       WHERE account_id = '""" & $depositId & """'""")
    let after = lockMaturityAccount(db, depositId, MaturityRunDate)
    check after.isSome
    check after.get().account.balance == moneyFromString("10200000.00").value()

    check runMaturityAt(MaturityRunDate).isOk
    check stateOf(depositId) == ("CLOSED", MaturityDate)
    check balanceOf(depositId) == "0.00"
    check balanceOf(savingsId) == "10213013.70"
