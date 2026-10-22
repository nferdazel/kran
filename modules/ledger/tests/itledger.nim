## Test integrasi `ledger` COA & periode (T-072) — butuh `KRAN_DATABASE_URL`.
##
## Cakupan: seed COA dari migrasi (bukan kode), kode unik, CHECK sisi normal konsisten dengan tipe,
## filter daftar, periode tumpang tindih ditolak EXCLUDE, tutup periode mengisi kolom wajib, dan
## tidak ada jejak parsial saat transaksi dibatalkan.

import std/[options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import ledger/domain/[coa, period]
import ledger/infrastructure/ledger_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itledger: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

# Seluruh schema modul (termasuk `platform`) dibuat ulang dari nol supaya migrasi, seed, dan FK
# lintas modul konsisten; reset parsial pernah memutus FK modul lain (O-096).
resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 19, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")

proc newAccount(code, name: string, t: AccountType, postable = true): CoaAccount =
  CoaAccount(accountId: newId(testClock), code: code, name: name, accountType: t,
    normalSide: normalSideOf(t), postable: postable, status: asActive, createdAt: "")

suite "coa: seed & constraint":
  test "COA awal dari migrasi terpasang":
    let accounts = coaAccounts(db)
    check accounts.len >= 15
    let kas = coaByCode(db, "101")
    check kas.isSome
    check kas.get().name == "KAS"
    check kas.get().accountType == atAsset
    check kas.get().normalSide == nsDebit
    check kas.get().postable
    # Akun header tidak boleh dipakai posting.
    let header = coaByCode(db, "1")
    check header.isSome
    check not header.get().postable

  test "kode unik ditegakkan DB":
    let a = newAccount("9901", "AKUN UJI", atAsset)
    discard insertCoa(db, a, actor)
    let b = newAccount("9901", "AKUN UJI LAIN", atAsset)
    var raised = false
    try:
      discard insertCoa(db, b, actor)
    except DbError:
      raised = true
    check raised
    check coaByCode(db, "9901").get().name == "AKUN UJI"

  test "sisi normal yang tidak konsisten ditolak CHECK DB":
    # Invarian akuntansi: ASSET harus DEBIT. Jalur API menurunkannya, DB tetap menjaga.
    var raised = false
    try:
      db.exec(sql"""
        INSERT INTO ledger.coa_account
          (account_id, code, name, account_type, normal_side, postable, status, created_by, updated_by)
        VALUES (?, '9902', 'SALAH SISI', 'ASSET', 'CREDIT', true, 'ACTIVE', ?, ?)""",
        $newId(testClock), $actor, $actor)
    except DbError:
      raised = true
    check raised
    check coaByCode(db, "9902").isNone

  test "filter daftar menyaring di SQL":
    let assets = coaAccounts(db, "ASSET")
    check assets.len >= 2
    for a in assets:
      check a.accountType == atAsset
    let postableAssets = coaAccounts(db, "ASSET", "true")
    check postableAssets.len < assets.len
    for a in postableAssets:
      check a.postable
    let headers = coaAccounts(db, "", "false")
    check headers.len >= 4
    for a in headers:
      check not a.postable

suite "period: rentang & penutupan":
  test "periode tersimpan dan terbaca":
    let p = Period(periodId: newId(testClock), startsOn: "2026-01-01", endsOn: "2026-01-31",
      status: psOpen)
    discard insertPeriod(db, p, actor)
    let stored = periodById(db, p.periodId)
    check stored.isSome
    check stored.get().startsOn == "2026-01-01"
    check stored.get().endsOn == "2026-01-31"
    check stored.get().status == psOpen
    check stored.get().closedAt.len == 0
    check stored.get().closedBy.len == 0

  test "periode tumpang tindih ditolak EXCLUDE, yang bersambung diterima":
    let feb = Period(periodId: newId(testClock), startsOn: "2026-02-01", endsOn: "2026-02-28",
      status: psOpen)
    discard insertPeriod(db, feb, actor)

    var overlapRaised = false
    try:
      discard insertPeriod(db,
        Period(periodId: newId(testClock), startsOn: "2026-02-15", endsOn: "2026-03-15"),
        actor)
    except DbError:
      overlapRaised = true
    check overlapRaised

    # Rentang yang sama persis juga tumpang tindih.
    var duplicateRaised = false
    try:
      discard insertPeriod(db,
        Period(periodId: newId(testClock), startsOn: "2026-02-01", endsOn: "2026-02-28"),
        actor)
    except DbError:
      duplicateRaised = true
    check duplicateRaised

    # Satu hari di dalam periode yang ada tetap tumpang tindih (rentang inklusif).
    var singleDayRaised = false
    try:
      discard insertPeriod(db,
        Period(periodId: newId(testClock), startsOn: "2026-02-10", endsOn: "2026-02-10"),
        actor)
    except DbError:
      singleDayRaised = true
    check singleDayRaised

    # Bersambung tepat di hari berikutnya tidak tumpang tindih (rentang inklusif).
    let mar = Period(periodId: newId(testClock), startsOn: "2026-03-01", endsOn: "2026-03-31",
      status: psOpen)
    discard insertPeriod(db, mar, actor)
    check periodById(db, mar.periodId).isSome

  test "tutup periode mengisi closed_at/closed_by":
    let p = Period(periodId: newId(testClock), startsOn: "2026-04-01", endsOn: "2026-04-30",
      status: psOpen)
    discard insertPeriod(db, p, actor)
    let closedAt = closePeriod(db, p.periodId, actor)
    check closedAt.len >= 20
    let stored = periodById(db, p.periodId).get()
    check stored.status == psClosed
    check stored.closedAt == closedAt
    check stored.closedBy == $actor

    # Penutupan kedua (mis. balapan dua transaksi) = UPDATE 0 baris → hasil kosong, bukan
    # `closed_at` palsu. Handler menerjemahkannya jadi 409 tanpa audit/event kedua.
    check closePeriod(db, p.periodId, actor).len == 0
    check periodById(db, p.periodId).get().closedAt == closedAt

  test "rollback tidak meninggalkan akun":
    let a = newAccount("9903", "AKUN BATAL", atAsset)
    var failed = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertCoa(d, a, actor)
        raise newException(ValueError, "batal"))
    except ValueError:
      failed = true
    check failed
    check coaByCode(db, "9903").isNone
