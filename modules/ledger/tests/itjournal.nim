## Test integrasi jurnal (T-073) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan di DB sungguhan: immutability (UPDATE/DELETE/TRUNCATE), keseimbangan deferred
## saat COMMIT, periode harus OPEN, akun harus postable & ACTIVE, idempotency unik, dan pembalik
## menukar sisi.

import std/[atomics, options, os, random, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, money]
import ledger/domain/[coa, journal, period]
import ledger/infrastructure/[journal_repo, ledger_repo]

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itjournal: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")

let
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")
  branch = Id("11111111-1111-7111-8111-111111111111")
  octId = newId(testClock)
  novId = newId(testClock)

discard insertPeriod(db,
  Period(periodId: octId, startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)
discard insertPeriod(db,
  Period(periodId: novId, startsOn: "2026-11-01", endsOn: "2026-11-30"), actor)
discard closePeriod(db, novId, actor)

var keyCounter = 0

proc nextKey(): string =
  keyCounter.inc
  "itjournal-" & $keyCounter

proc line(no: int, account: string, debit, credit: int64): JournalLine =
  JournalLine(lineNo: no, glAccount: account, branchId: branch,
    debit: money(debit), credit: money(credit))

proc newJournal(businessDate = "2026-10-15", lines: seq[JournalLine] = @[]): Journal =
  var ls = lines
  if ls.len == 0:
    ls = @[line(1, "101.2", 250_0000, 0), line(2, "201", 0, 250_0000)]
  Journal(journalId: newId(testClock), businessDate: businessDate, valueDate: businessDate,
    sourceEvent: "DepositPosted", sourceRef: newId(testClock),
    idempotencyKey: nextKey(), lines: ls)

proc save(j: Journal): string =
  ## Header + baris **wajib satu transaksi**: constraint trigger keseimbangan deferred, sehingga
  ## autocommit per pernyataan akan memeriksa jurnal yang baru punya 1 baris (dan menolaknya).
  result = dbPool.withTx(proc(d: DbConn): string {.closure.} =
    let recordedAt = insertJournal(d, j, actor)
    for l in j.lines:
      insertJournalLine(d, j.journalId, l)
    recordedAt)

proc expectDbError(body: proc()) =
  var raised = false
  try:
    body()
  except DbError:
    raised = true
  check raised

var periodClosed: Atomic[bool]

type CloseArgs = tuple[pool: DbPool, periodId: string, actorId: string]

proc closePeriodSlowly(args: CloseArgs) {.thread.} =
  ## Menutup periode dalam transaksi yang ditahan `800 ms` setelah UPDATE, supaya insert jurnal
  ## dari koneksi lain benar-benar menunggu lock lalu melihat versi CLOSED setelah COMMIT.
  {.cast(gcsafe).}:
    discard args.pool.withTx(proc(d: DbConn): int {.closure.} =
      exec(d,
        sql"UPDATE ledger.period SET status = 'CLOSED', closed_at = now(), closed_by = ? WHERE period_id = ?",
        args.actorId, args.periodId)
      periodClosed.store(true)
      sleep(800)
      1)

suite "journal: penyimpanan & immutability":
  test "jurnal seimbang tersimpan dan terbaca utuh":
    let j = newJournal()
    discard save(j)
    let stored = journalById(db, j.journalId)
    check stored.isSome
    check stored.get().businessDate == "2026-10-15"
    check stored.get().valueDate == "2026-10-15"
    check stored.get().sourceEvent == "DepositPosted"
    check stored.get().idempotencyKey == j.idempotencyKey
    check stored.get().reversalOf.len == 0
    check stored.get().recordedAt.len >= 20
    check stored.get().lines.len == 2
    check stored.get().lines.totalDebit == money(250_0000)
    check stored.get().lines.totalCredit == money(250_0000)

  test "idempotency key unik":
    let j = newJournal()
    discard save(j)
    var duplicate = newJournal()
    duplicate.idempotencyKey = j.idempotencyKey
    expectDbError(proc() = discard save(duplicate))
    check journalByIdempotencyKey(db, j.idempotencyKey).get().journalId == j.journalId

  test "UPDATE dan DELETE ditolak trigger":
    let j = newJournal()
    discard save(j)
    expectDbError(proc() = db.exec(
      sql"UPDATE ledger.journal SET source_event = 'X' WHERE journal_id = ?", $j.journalId))
    expectDbError(proc() = db.exec(
      sql"UPDATE ledger.journal_line SET debit = debit + 1 WHERE journal_id = ?", $j.journalId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM ledger.journal_line WHERE journal_id = ?", $j.journalId))
    expectDbError(proc() = db.exec(
      sql"DELETE FROM ledger.journal WHERE journal_id = ?", $j.journalId))
    check journalById(db, j.journalId).isSome

  test "TRUNCATE ditolak trigger":
    expectDbError(proc() = db.exec(sql"TRUNCATE ledger.journal_line, ledger.journal"))

suite "journal: aturan akuntansi di DB":
  test "jurnal tidak seimbang ditolak saat COMMIT":
    let j = newJournal(lines = @[line(1, "101.2", 100_0000, 0), line(2, "201", 0, 99_0000)])
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertJournal(d, j, actor)
        for l in j.lines:
          insertJournalLine(d, j.journalId, l)
        1)
    except DbError:
      raised = true
    check raised
    check journalById(db, j.journalId).isNone

  test "jurnal satu baris ditolak saat COMMIT":
    let j = newJournal(lines = @[line(1, "101.2", 100_0000, 0)])
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertJournal(d, j, actor)
        insertJournalLine(d, j.journalId, j.lines[0])
        1)
    except DbError:
      raised = true
    check raised

  test "akun header (postable=false) ditolak":
    expectDbError(proc() = discard save(
      newJournal(lines = @[line(1, "1", 100, 0), line(2, "201", 0, 100)])))
    # `101 KAS` kini induk non-postable (0033); posting langsung ke `101` juga ditolak.
    expectDbError(proc() = discard save(
      newJournal(lines = @[line(1, "101", 100, 0), line(2, "201", 0, 100)])))

  test "akun non-ACTIVE ditolak":
    let a = CoaAccount(accountId: newId(testClock), code: "1999", name: "AKUN NONAKTIF",
      accountType: atAsset, normalSide: nsDebit, postable: true, status: asActive)
    discard insertCoa(db, a, actor)
    db.exec(sql"UPDATE ledger.coa_account SET status = 'INACTIVE' WHERE code = '1999'")
    expectDbError(proc() = discard save(
      newJournal(lines = @[line(1, "1999", 100, 0), line(2, "201", 0, 100)])))

  test "periode CLOSED dan tanggal tanpa periode ditolak":
    expectDbError(proc() = discard save(newJournal(businessDate = "2026-11-15")))
    expectDbError(proc() = discard save(newJournal(businessDate = "2027-01-05")))

  test "tutup periode bersamaan tidak bisa ditembus jurnal (O-089)":
    ## Sesi A menutup Oktober tetapi belum COMMIT; sesi B memposting jurnal Oktober. Trigger
    ## harus MENUNGGU lock baris periode (FOR SHARE) sampai A selesai, bukan membaca versi lama
    ## OPEN. Tanpa perbaikan, insert B lolos dan `blocked` tetap false.
    let sesiA = dbPool.acquire()
    let sesiB = dbPool.acquire()
    let jid = newId(testClock)
    let idem = nextKey()
    try:
      exec(sesiA, sql"BEGIN")
      exec(sesiA,
        sql"UPDATE ledger.period SET status = 'CLOSED', closed_at = now(), closed_by = ? WHERE period_id = ?",
        $actor, $octId)
      exec(sesiB, sql"BEGIN")
      exec(sesiB, sql"SET LOCAL lock_timeout = '200ms'")
      var blocked = false
      try:
        exec(sesiB,
          sql"INSERT INTO ledger.journal (journal_id, business_date, value_date, source_event, source_ref, idempotency_key, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)",
          $jid, "2026-10-15", "2026-10-15", "DepositPosted", $jid, idem, $actor)
      except DbError as e:
        blocked = true
        # Mekanisme: menunggu lock baris periode, bukan galat lain (mis. tabel/kolom salah).
        check "lock timeout" in e.msg
      check blocked
      exec(sesiB, sql"ROLLBACK")
      exec(sesiA, sql"ROLLBACK")
    finally:
      # Aman walau transaksi sudah di-rollback (Postgres hanya memberi peringatan).
      exec(sesiA, sql"ROLLBACK")
      exec(sesiB, sql"ROLLBACK")
      dbPool.release(sesiA)
      dbPool.release(sesiB)

    # Setelah A rollback, periode OPEN lagi dan posting normal tetap berjalan.
    check periodById(db, octId).get().status == psOpen
    let j = newJournal()
    discard save(j)
    check journalById(db, j.journalId).isSome

  test "insert yang menunggu penutupan ditolak setelah close COMMIT (O-089)":
    ## Melengkapi test di atas: yang dibuktikan bukan hanya "menunggu", tetapi bahwa setelah
    ## penutupan COMMIT, insert dievaluasi ulang dan **ditolak** — jurnal tidak pernah masuk ke
    ## periode CLOSED. Thread menahan transaksi 800 ms; insert memakai `lock_timeout` 5 s supaya
    ## kegagalan yang diharapkan adalah pelanggaran periode, bukan timeout.
    periodClosed.store(false)
    var closer: Thread[CloseArgs]
    createThread(closer, closePeriodSlowly, (pool: dbPool, periodId: $octId, actorId: $actor))
    while not periodClosed.load():
      sleep(5)
    let sesiB = dbPool.acquire()
    let jid = newId(testClock)
    let idem = nextKey()
    var pesan = ""
    try:
      exec(sesiB, sql"BEGIN")
      exec(sesiB, sql"SET LOCAL lock_timeout = '5s'")
      try:
        exec(sesiB,
          sql"INSERT INTO ledger.journal (journal_id, business_date, value_date, source_event, source_ref, idempotency_key, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)",
          $jid, "2026-10-15", "2026-10-15", "DepositPosted", $jid, idem, $actor)
      except DbError as e:
        pesan = e.msg
      check pesan.len > 0
      check "periode OPEN" in pesan # bukan "lock timeout"
      exec(sesiB, sql"ROLLBACK")
    finally:
      exec(sesiB, sql"ROLLBACK")
      dbPool.release(sesiB)
    joinThread(closer)

    check journalById(db, jid).isNone
    # Kembalikan periode ke OPEN supaya suite berikutnya tetap bisa posting.
    db.exec(sql"UPDATE ledger.period SET status = 'OPEN', closed_at = NULL, closed_by = NULL WHERE period_id = ?", $octId)
    check periodById(db, octId).get().status == psOpen

suite "journal: pembalik & daftar":
  test "pembalik menukar sisi dan ditandai reversal_of":
    let original = newJournal()
    discard save(original)
    check not reversalExistsFor(db, original.journalId)
    let stored = journalById(db, original.journalId).get()
    let rev = Journal(journalId: newId(testClock), businessDate: stored.businessDate,
      valueDate: stored.valueDate, sourceEvent: "reversal", sourceRef: original.journalId,
      idempotencyKey: nextKey(), reversalOf: $original.journalId,
      lines: reversalLinesOf(stored.lines))
    discard save(rev)
    check reversalExistsFor(db, original.journalId)
    let storedRev = journalById(db, rev.journalId).get()
    check storedRev.reversalOf == $original.journalId
    check storedRev.lines[0].glAccount == "101.2"
    check storedRev.lines[0].credit == money(250_0000)
    check storedRev.lines[0].debit.isZero
    check storedRev.lines.totalDebit == storedRev.lines.totalCredit

  test "daftar menyaring tanggal & event di SQL":
    let j = newJournal(businessDate = "2026-10-16")
    discard save(j)
    let byDate = journals(db, "2026-10-16")
    check byDate.len == 1
    check byDate[0].journalId == j.journalId
    check byDate[0].lines.len == 0
    let byEvent = journals(db, "", "reversal")
    check byEvent.len >= 1
    for x in byEvent:
      check x.sourceEvent == "reversal"

  test "30 jurnal acak seimbang tersimpan dalam satu transaksi":
    var r = initRand(20261020)
    let before = journals(db, "2026-10-20").len
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      for _ in 0 ..< 30:
        let amount = r.rand(1 .. 9_000_000).int64
        var j = newJournal(businessDate = "2026-10-20")
        j.lines = @[line(1, "101.2", amount, 0), line(2, "201", 0, amount)]
        discard insertJournal(d, j, actor)
        for l in j.lines:
          insertJournalLine(d, j.journalId, l)
      1)
    check journals(db, "2026-10-20").len == before + 30

suite "journal: guard tambahan (review T-073)":
  test "header tanpa baris ditolak saat COMMIT":
    let j = newJournal(businessDate = "2026-10-17")
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard insertJournal(d, j, actor)
        1)
    except DbError:
      raised = true
    check raised
    check journalById(db, j.journalId).isNone

  test "baris setelah header COMMIT ditolak, termasuk pasangan seimbang":
    # Dua baris berpasangan lolos pemeriksaan keseimbangan, jadi guard yang menolaknya harus
    # "transaksi sama dengan header" — bukan keseimbangan.
    let j = newJournal(businessDate = "2026-10-19")
    discard save(j)
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        insertJournalLine(d, j.journalId, line(3, "101.2", 1_0000, 0))
        insertJournalLine(d, j.journalId, line(4, "201", 0, 1_0000))
        1)
    except DbError:
      raised = true
    check raised
    check journalById(db, j.journalId).get().lines.len == 2

  test "periode tertutup juga menolak baris (defense-in-depth)":
    let decId = newId(testClock)
    discard insertPeriod(db,
      Period(periodId: decId, startsOn: "2026-12-01", endsOn: "2026-12-31"), actor)
    let j = newJournal(businessDate = "2026-12-15")
    discard save(j)
    discard closePeriod(db, decId, actor)
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        insertJournalLine(d, j.journalId, line(3, "101.2", 1_0000, 0))
        insertJournalLine(d, j.journalId, line(4, "201", 0, 1_0000))
        1)
    except DbError:
      raised = true
    check raised

  test "hanya satu pembalik per jurnal asal (indeks unik DB)":
    let original = newJournal(businessDate = "2026-10-18")
    discard save(original)
    let stored = journalById(db, original.journalId).get()
    let first = Journal(journalId: newId(testClock), businessDate: stored.businessDate,
      valueDate: stored.valueDate, sourceEvent: "reversal", sourceRef: original.journalId,
      idempotencyKey: nextKey(), reversalOf: $original.journalId,
      lines: reversalLinesOf(stored.lines))
    discard save(first)
    var second = first
    second.journalId = newId(testClock)
    second.idempotencyKey = nextKey()
    expectDbError(proc() = discard save(second))
    check journals(db, stored.businessDate, "reversal").len == 1
