## Test integrasi modul `party` (T-070) — butuh `KRAN_DATABASE_URL`.
##
## Cakupan: CIF dari sequence, insert/baca, CIF unik, audit + outbox satu transaksi, dan
## rollback yang tidak meninggalkan party/audit/outbox.
##
## Test ini hanya menghapus schema `party` (bukan `platform`) supaya data dev lain tidak ikut
## hilang; ledger migrasi modul `party` dihapus agar migrasinya dijalankan ulang.

import std/[json, options, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[auditcontext, clock, ids]
import platform/domain/[audit, event]
import platform/infrastructure/[audit_repo, outbox_repo]
import party/domain/party
import party/infrastructure/party_repo

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itparty: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 19, 9, 0, 0))
  branch = Id("11111111-1111-7111-8111-111111111111")
  actor = Id("22222222-2222-7222-8222-222222222222")

suite "party: repo & CIF":
  test "sequence naik dan party tersimpan":
    let first = nextCifSeq(db)
    let second = nextCifSeq(db)
    check second == first + 1

    let p = newParty(newId(testClock), pkPerson, "Budi Santoso", branch, "{seq:6}{check}", first)
    let createdAt = insertParty(db, p, actor)
    check createdAt.len >= 20
    check p.cif.len == 7

    let row = partyById(db, p.partyId)
    check row.isSome
    check row.get().cif == p.cif
    check row.get().displayName == "Budi Santoso"
    check row.get().kind == pkPerson
    check row.get().status == psActive
    check row.get().branchId == branch

  test "CIF duplikat ditolak DB":
    let seq = nextCifSeq(db)
    let a = newParty(newId(testClock), pkOrg, "Koperasi A", branch, "{seq:6}{check}", seq)
    let b = newParty(newId(testClock), pkOrg, "Koperasi B", branch, "{seq:6}{check}", seq)
    discard insertParty(db, a, actor)
    var raised = false
    try:
      discard insertParty(db, b, actor)
    except DbError:
      raised = true
    check raised

suite "party: audit + outbox":
  test "party, audit, dan event lahir dalam satu transaksi":
    let p = newParty(newId(testClock), pkPerson, "Siti Aminah", branch, "{seq:8}{check}",
      nextCifSeq(db))
    let ctx = newAuditContext(actor, branchIds = @[branch], reason = "buat party",
      correlationId = "itparty-1", startedAt = testClock.now())

    let hash = dbPool.withTx(proc(d: DbConn): string {.closure.} =
      discard insertParty(d, p, actor)
      result = appendAudit(d, newAuditEntry(ctx, "party.create", "party", $p.partyId,
        testClock, businessDate = "2026-10-19", after = %*{"cif": p.cif}))
      discard appendEvent(d, newOutboxEvent(newId(testClock), "party.onboarded", "party",
        $p.partyId, "party.onboarded:" & $p.partyId, %*{"partyId": $p.partyId, "cif": p.cif})))

    check hash.len == 64
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'party.create' AND resource_id = ?""", $p.partyId) == "1"
    check db.getValue(sql"""
      SELECT payload->>'cif' FROM platform.outbox
       WHERE event_type = 'party.onboarded' AND aggregate_id = ?""", $p.partyId) == p.cif

  test "rollback transaksi tidak meninggalkan jejak":
    let p = newParty(newId(testClock), pkOrg, "Koperasi Batal", branch, "{seq:6}{check}",
      nextCifSeq(db))
    let ctx = newAuditContext(actor, branchIds = @[branch], startedAt = testClock.now())

    var failed = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertParty(d, p, actor)
        discard appendAudit(d, newAuditEntry(ctx, "party.create", "party", $p.partyId,
          testClock))
        raise newException(ValueError, "batal"))
    except ValueError:
      failed = true
    check failed

    check partyById(db, p.partyId).isNone
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log WHERE resource_id = ?""", $p.partyId) == "0"
