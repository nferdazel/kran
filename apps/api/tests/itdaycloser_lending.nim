## Test integrasi task day-close `lending.dpd_regrade` (T-166) — butuh `KRAN_DATABASE_URL`.
##
## Yang hanya bisa dibuktikan di sini (bukan unit test):
##   1. DPD dihitung dari angsuran **belum lunas tertua** di DB, bukan dari tanggal cair;
##   2. idempotensi nyata: menjalankan tanggal buku yang sama dua kali tidak menambah snapshot,
##      tidak menerbitkan event kedua, dan melaporkan `skipped`;
##   3. golongan berubah pada tanggal berikutnya → snapshot baru + satu event `CollectibilityChanged`;
##   4. ambang benar-benar dibaca dari parameter: mengganti `lending.collectibility.dpd_bounds`
##      menggeser golongan tanpa mengubah kode;
##   5. parameter hilang/rusak **menggagalkan task** (`DAY-372`), bukan memakai ambang bawaan;
##   6. paginasi chunk (`countChunks` + `psByChunkCount`) memproses setiap pinjaman tepat sekali.
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain).

import std/[json, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[clock, dayclose, ids, result]

import daycloser/domain/[registry, types]

import ../src/daycloser_lending

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_lending: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, ".")
discard applyAllMigrations(db, ".")
execScript(db, readFile("packs/base/generated/param_definitions.sql"))
execScript(db, readFile("packs/base/generated/param_values.sql"))

const
  BranchId = "b0000000-0000-4000-8000-0000000000d1"
  ActorId = "00000000-0000-4000-8000-0000000000d9"
  ApproverId = "00000000-0000-4000-8000-0000000000da"
  ProductId = "00000000-0000-4000-8000-0000000000d2"
  VersionId = "00000000-0000-4000-8000-0000000000d3"
  PartyId = "00000000-0000-4000-8000-0000000000d4"
  RegradeDate = "2026-11-01"

let testClock = fakeClock(dateTime(2026, mNov, 1, 20, 0, 0))

block:
  db.exec(sql"""
    INSERT INTO party.party (party_id, cif, kind, display_name, status, branch_id,
                             created_by, updated_by)
    VALUES (?::uuid, 'DPD0001', 'PERSON', 'Anggota Uji DPD', 'ACTIVE', ?::uuid, ?::uuid, ?::uuid)""",
    PartyId, BranchId, ActorId, ActorId)
  db.exec(sql"""
    INSERT INTO lending.loan_product (product_id, code, name, created_by)
    VALUES (?::uuid, 'DPDTEST', 'Pinjaman Uji DPD', ?::uuid)""", ProductId, ActorId)
  db.exec(sql"""
    INSERT INTO lending.loan_product_version
      (version_id, product_id, version_no, status, schedule_method, tenor_months, annual_rate,
       allocation_order, created_by, approved_by)
    VALUES (?::uuid, ?::uuid, 1, 'ACTIVE', 'FLAT', 12, 120000, 'INTEREST,PRINCIPAL,PENALTY',
            ?::uuid, ?::uuid)""", VersionId, ProductId, ActorId, ApproverId)

proc newLoan(loanId: Id; status = "ACTIVE"; disbursed = true) =
  db.exec(sql"""
    INSERT INTO lending.loan
      (loan_id, party_id, product_version_id, branch_id, principal, status, disbursed_on,
       applied_by, approved_by)
    VALUES (?, ?::uuid, ?::uuid, ?::uuid, 1000000.00, ?, NULLIF(?, '')::date, ?::uuid, ?::uuid)""",
    $loanId, PartyId, VersionId, BranchId, status,
    (if disbursed: "2026-01-01" else: ""), ActorId, ApproverId)

proc newInstallment(loanId: Id; no: int; dueOn: string; paid = false) =
  db.exec(sql"""
    INSERT INTO lending.installment
      (loan_id, no, due_on, principal_due, interest_due, penalty_due,
       paid_principal, paid_interest, paid_penalty, paid_on)
    VALUES (?, ?, ?::date, 100000.00, 10000.00, 0,
            ?, ?, 0, NULLIF(?, '')::date)""",
    $loanId, no, dueOn,
    (if paid: "100000.00" else: "0.00"), (if paid: "10000.00" else: "0.00"),
    (if paid: dueOn else: ""))

proc task(): DayCloseTask =
  let reg = newRegistry()
  registerLendingTasks(reg, dbPool)
  for t in reg.all():
    if t.id == regradeTaskId:
      return t
  raise newException(ValueError, "task tidak terdaftar: " & regradeTaskId)

proc ctxOn(businessDate: string; chunkSize = 1000): TaskContext =
  TaskContext(runId: "22222222-2222-4222-8222-222222222222", scopeType: "INSTITUTION", scopeId: "",
    businessDate: businessDate, levels: {clEOD}, mode: rmReal, chunkSize: chunkSize)

proc runChunk(businessDate: string; chunkNo = 0; chunkSize = 1000): TaskOutcome =
  let outcome = task().run(ctxOn(businessDate, chunkSize), Chunk(chunkNo: chunkNo))
  doAssert outcome.isOk, "task gagal: " & outcome.error.message
  outcome.val

proc snapshotOf(loanId: Id): tuple[dpd, grade: string] =
  let rows = db.getAllRows(sql"""
    SELECT dpd::text, grade FROM lending.collectibility_snapshot
     WHERE loan_id = ? AND business_date = ?::date""", $loanId, RegradeDate)
  if rows.len == 0:
    return ("", "")
  (rows[0][0], rows[0][1])

proc eventCount(loanId: Id): int =
  parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM platform.outbox
     WHERE event_type = 'CollectibilityChanged' AND aggregate_id = ?""", $loanId))

proc setBounds(raw: string) =
  ## Mengganti nilai parameter aktif (`GLOBAL`, berlaku sejak 1970) — bukan menambah baris baru,
  ## supaya test membuktikan pembacaan parameter, bukan urutan effective-dated.
  db.exec(sql"""
    UPDATE platform.param_value SET value = ?::jsonb
     WHERE key = 'lending.collectibility.dpd_bounds'""", raw)

suite "day-close lending: penilaian kolektibilitas (T-166)":
  let
    onTime = newId(testClock)     # angsuran belum jatuh tempo
    overdue95 = newId(testClock)  # 95 hari
    overdue200 = newId(testClock) # 200 hari
    settled = newId(testClock)    # semua angsuran sudah lunas

  block:
    newLoan(onTime)
    newInstallment(onTime, 1, "2026-12-01")
    newLoan(overdue95)
    newInstallment(overdue95, 1, "2026-07-29") # 95 hari sebelum 1 Nov 2026
    newInstallment(overdue95, 2, "2026-12-01")
    newLoan(overdue200)
    newInstallment(overdue200, 1, "2026-04-15") # 200 hari
    newLoan(settled)
    newInstallment(settled, 1, "2026-03-01", paid = true)

  test "DPD dihitung dari angsuran belum lunas tertua, bukan dari tanggal cair":
    discard runChunk(RegradeDate)
    check snapshotOf(onTime) == ("0", "COLLECTIBLE")
    check snapshotOf(overdue95) == ("95", "SUBSTANDARD")
    check snapshotOf(overdue200) == ("200", "LOSS")
    # Angsuran lunas tidak menunggak, meski tanggal jatuh temponya jauh di masa lalu.
    check snapshotOf(settled) == ("0", "COLLECTIBLE")
    check db.getValue(sql"SELECT collectibility FROM lending.loan WHERE loan_id = ?",
      $overdue95) == "SUBSTANDARD"
    check db.getValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'lending.collectibility.regrade'""") == "1"

  test "menjalankan tanggal yang sama dua kali tidak menambah snapshot atau event":
    let before = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM lending.collectibility_snapshot"""))
    let eventsBefore = eventCount(overdue95)
    let outcome = runChunk(RegradeDate)
    check parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM lending.collectibility_snapshot""")) == before
    check eventCount(overdue95) == eventsBefore
    # Semua baris tanggal itu sudah ada → dilaporkan `skipped`, bukan `graded`.
    check outcome.metrics["skipped"].getInt() == 4
    check outcome.metrics["graded"].getInt() == 0

  test "ambang dari parameter: kebijakan lebih ketat menggeser golongan":
    setBounds("[30, 60, 90]")
    discard runChunk("2026-11-02")
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-11-02'""", $overdue95) == "LOSS"
    # Pinjaman yang tadinya lancar tetap lancar: yang berubah hanya yang melewati ambang baru.
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-11-02'""", $onTime) == "COLLECTIBLE"
    setBounds("[90, 120, 180]")

  test "perubahan golongan menerbitkan satu event, bukan satu per run":
    # Tanggal baru dengan DPD lebih besar: 95 → COLLECTIBLE? tidak; gunakan pinjaman `onTime`
    # yang kini melewati jatuh tempo 1 Des 2026 pada tanggal buku 2027-01-05 (35 hari).
    # Hitungan dibandingkan relatif: penilaian pertama (dari `NULL`) juga menerbitkan event, dan
    # yang diuji di sini adalah "satu per perubahan", bukan "satu seumur pinjaman".
    let before = eventCount(onTime)
    discard runChunk("2027-01-05")
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2027-01-05'""", $onTime) == "SPECIAL_MENTION"
    check eventCount(onTime) == before + 1
    discard runChunk("2027-01-05")
    check eventCount(onTime) == before + 1

  test "parameter hilang membuat task gagal, bukan memakai ambang bawaan":
    db.exec(sql"""
      DELETE FROM platform.param_value WHERE key = 'lending.collectibility.dpd_bounds'""")
    let failed = task().run(ctxOn("2027-02-01"), Chunk(chunkNo: 0))
    check not failed.isOk
    check failed.error.code == "DAY-372"
    # Tidak ada snapshot yang ditulis untuk tanggal itu.
    check db.getValue(sql"""
      SELECT count(*)::text FROM lending.collectibility_snapshot
       WHERE business_date = '2027-02-01'""") == "0"

  test "paginasi chunk memproses setiap pinjaman tepat sekali":
    # Ambang dikembalikan supaya task bisa jalan; ukuran chunk 2 memaksa dua halaman.
    db.exec(sql"""
      INSERT INTO platform.param_value
        (param_value_id, key, scope_type, scope_id, value, effective_from, status,
         maker, checker, reason)
      VALUES (md5('itdaycloser_lending|bounds')::uuid, 'lending.collectibility.dpd_bounds',
              'GLOBAL', NULL, '[90, 120, 180]'::jsonb, DATE '1970-01-01', 'ACTIVE',
              '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2',
              'test')
      ON CONFLICT DO NOTHING""")
    let chunks = parseInt(db.getValue(sql"SELECT count(*)::text FROM lending.loan WHERE status = 'ACTIVE'"))
    let pages = task().countChunks(ctxOn("2027-03-01", chunkSize = 2), 2)
    check pages.isOk
    check pages.val == (chunks + 1) div 2
    var graded = 0
    for page in 0 ..< pages.val:
      let outcome = runChunk("2027-03-01", chunkNo = page, chunkSize = 2)
      graded += outcome.metrics["graded"].getInt()
    check graded == chunks

dbPool.release(db)
