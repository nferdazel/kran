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

import std/[json, os, sequtils, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[clock, dayclose, ids, money, result]

import daycloser/domain/[registry, types]

import deposit/domain/account
import deposit/infrastructure/account_repo
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

import ../src/daycloser_deposit

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
                 status = "ACTIVE"; maturityDate = ""): Id =
  ## Rekening berjangka dengan saldo pokok. `newAccount` selalu melahirkan SAVINGS, jadi tipenya
  ## diubah sebelum disimpan (itulah yang dibaca task).
  var a = newAccount(newId(testClock), newPartyRow(), version.productId, version.versionId,
    productCode, Id(BranchId), "142", openedOn, nextAccountSeq(db))
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
    1)
  a.accountId

proc taskOf(reg: Registry; id: TaskId): DayCloseTask =
  for t in reg.all():
    if t.id == id:
      return t
  raise newException(ValueError, "task tidak terdaftar: " & id)

proc task(): DayCloseTask =
  let reg = newRegistry()
  registerDepositTasks(reg, dbPool)
  taskOf(reg, interestAccrualTaskId)

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

proc journalOf(accountId: Id; businessDate: string): seq[tuple[gl, debit, credit: string]] =
  ## Baris jurnal untuk kunci idempotensi akrual rekening+taggal. Kosong = tidak ada jurnal.
  for row in db.getAllRows(sql"""
      SELECT l.gl_account, l.debit::text, l.credit::text
        FROM ledger.journal j
        JOIN ledger.journal_line l USING (journal_id)
       WHERE j.idempotency_key = ?
       ORDER BY l.line_no""", "interest.accrual:" & $accountId & ":" & businessDate):
    result.add (row[0], row[1], row[2])

proc runAt(businessDate: string; chunkNo = 0; chunkSize = 1000): TaskResult =
  task().run(ctxOn(businessDate, chunkSize), Chunk(chunkNo: chunkNo))

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
