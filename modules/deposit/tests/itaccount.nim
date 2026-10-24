## Integrasi DB modul `deposit` (T-088a) — butuh `KRAN_DATABASE_URL`.
##
## Membuktikan invarian yang dijaga database & repo: penyimpanan rekening + saldo awal 0, nomor
## rekening unik, FK party/produk/versi produk, dan CHECK saldo tidak negatif. Kesamaan cabang
## party↔rekening ditegakkan use case (lihat `itapi_deposit`), bukan DB.
##
## Test ini me-reset seluruh schema modul lewat `resetTestSchemas` (pola `itapi_*`) supaya migrasi
## dijalankan dari nol — termasuk membuktikan urutan `deposit/0003` berada setelah `product/0002`.

import std/[json, options, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, money]
import deposit/domain/account
import deposit/infrastructure/account_repo
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itaccount: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

const
  branchIdRaw = "11111111-1111-7111-8111-111111111111"
  openedOn = "2026-10-22"

let
  testClock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))
  branch = Id(branchIdRaw)
  actor = Id("77777777-7777-7777-8777-777777777777")
  maker = Id("88888888-8888-7888-8888-888888888888")

proc save(a: Account) =
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertAccount(d, a, actor)
    1)

proc fixture(): tuple[party: Party, product: Product, version: ProductVersion] =
  ## Party + produk SAVINGS dengan versi ACTIVE berlaku, dibuat lewat repo (bukan INSERT mentah)
  ## supaya invarian versi produk terpenuhi.
  let p = newParty(newId(testClock), pkPerson, "Budi Santoso", branch, "{seq:6}{check}",
    nextCifSeq(db))
  discard insertParty(db, p, actor)
  let prod = Product(productId: newId(testClock), code: "SAV01", name: "Simpanan Sukarela",
    productType: ptSavings)
  let v = ProductVersion(versionId: newId(testClock), productId: prod.productId, versionNo: 1,
    effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prod, actor)
    insertVersion(d, v, maker)
    insertBinding(d, v.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"0.00"))
    1)
  doAssert approveVersion(db, v.versionId, actor), "versi produk uji gagal di-approve"
  (p, prod, v)

let fx = fixture()

proc accountRow(seqNo: int64): Account =
  newAccount(newId(testClock), fx.party.partyId, fx.product.productId, fx.version.versionId,
    fx.product.code, branch, "001", openedOn, seqNo)

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

suite "deposit: repo rekening":
  test "penyimpanan rekening + saldo awal 0":
    let a = accountRow(nextAccountSeq(db))
    save(a)
    let stored = accountById(db, a.accountId)
    check stored.isSome
    check stored.get().accountNo == a.accountNo
    check stored.get().accountNo.len == accountNoWidth
    check stored.get().balance == zero()
    check stored.get().status == asActive
    check stored.get().accountType == atSavings
    check stored.get().partyId == fx.party.partyId
    check stored.get().productCode == "SAV01"
    check stored.get().branchId == branch
    check db.getValue(
      sql"SELECT balance::text FROM deposit.account_balance WHERE account_id = ?",
      $a.accountId) == "0.00"

  test "nomor rekening unik (duplikat ditolak DB)":
    let seqNo = nextAccountSeq(db)
    let first = accountRow(seqNo)
    save(first)
    let duplicate = accountRow(seqNo)
    expectDbError(proc() = save(duplicate))

  test "FK party/produk/versi produk salah ditolak DB":
    let bogusParty = newAccount(newId(testClock), Id("99999999-9999-7999-8999-999999999999"),
      fx.product.productId, fx.version.versionId, fx.product.code, branch, "001", openedOn,
      nextAccountSeq(db))
    expectDbError(proc() = save(bogusParty))

    let bogusVersion = newAccount(newId(testClock), fx.party.partyId, fx.product.productId,
      Id("aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"), fx.product.code, branch, "001", openedOn,
      nextAccountSeq(db))
    expectDbError(proc() = save(bogusVersion))

  test "CHECK saldo >= 0 menolak UPDATE negatif":
    let a = accountRow(nextAccountSeq(db))
    save(a)
    expectDbError(proc() = db.exec(
      sql"UPDATE deposit.account_balance SET balance = -1 WHERE account_id = ?", $a.accountId))
    check db.getValue(
      sql"SELECT balance::text FROM deposit.account_balance WHERE account_id = ?",
      $a.accountId) == "0.00"

  test "daftar rekening per party":
    let listed = accountsByParty(db, fx.party.partyId)
    check listed.len >= 3
    for a in listed:
      check a.partyId == fx.party.partyId
    check accountsByParty(db, Id("bbbbbbbb-bbbb-7bbb-8bbb-bbbbbbbbbbbb")).len == 0

suite "deposit: klasifikasi simpanan dari produk (T-111)":
  test "savingsKind rekening dari join produk; NULL = kosong":
    var prod = Product(productId: newId(testClock), code: "SAV-POKOK",
      name: "Simpanan Pokok", productType: ptSavings, savingsKind: some(skPokok))
    let v = ProductVersion(versionId: newId(testClock), productId: prod.productId,
      versionNo: 1, effectiveFrom: "2020-01-01")
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      insertProduct(d, prod, actor)
      insertVersion(d, v, maker)
      insertBinding(d, v.versionId, ParamBinding(paramKey: "product.savings.min_balance",
        value: %"0.00"))
      1)
    doAssert approveVersion(db, v.versionId, actor), "versi produk pokok gagal di-approve"

    let kinded = newAccount(newId(testClock), fx.party.partyId, prod.productId, v.versionId,
      prod.code, branch, "001", openedOn, nextAccountSeq(db))
    save(kinded)
    check accountById(db, kinded.accountId).get().savingsKind == "POKOK"

    # Rekening pada produk tanpa klasifikasi → kosong (bukan enum pertama).
    let plain = accountRow(nextAccountSeq(db))
    save(plain)
    check accountById(db, plain.accountId).get().savingsKind == ""
