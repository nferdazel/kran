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

import lending/infrastructure/ppap_repo

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


# Periode GL untuk tanggal uji PPAP (suite sebelumnya tidak menjurnal).
execScript(db, """
  INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
  VALUES ('33333333-3333-4333-8333-333333333333', DATE '2026-01-01', DATE '2027-12-31', 'OPEN',
          '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1')
""")

proc ppapTask(): DayCloseTask =
  let reg = newRegistry()
  registerLendingTasks(reg, dbPool)
  for t in reg.all():
    if t.id == ppapTaskId:
      return t
  raise newException(ValueError, "task tidak terdaftar: " & ppapTaskId)

proc newPpapLoan(loanId: Id; outstanding: string) =
  db.exec(sql"""
    INSERT INTO lending.loan
      (loan_id, party_id, product_version_id, branch_id, principal, status, disbursed_on,
       applied_by, approved_by)
    VALUES (?, ?::uuid, ?::uuid, ?::uuid, 100000000.00, 'ACTIVE', DATE '2026-01-01', ?::uuid,
            ?::uuid)""", $loanId, PartyId, VersionId, BranchId, ActorId, ApproverId)
  db.exec(sql"""
    INSERT INTO lending.loan_balance (loan_id, principal_outstanding)
    VALUES (?, ?::numeric)""", $loanId, outstanding)

proc setOutstanding(loanId: Id; outstanding: string) =
  db.exec(sql"UPDATE lending.loan_balance SET principal_outstanding = ?::numeric WHERE loan_id = ?",
    outstanding, $loanId)

proc setGrade(loanId: Id; businessDate, grade: string) =
  db.exec(sql"""
    INSERT INTO lending.collectibility_snapshot (loan_id, business_date, dpd, grade)
    VALUES (?, ?::date, 0, ?)""", $loanId, businessDate, grade)

proc allowanceOn(loanId: Id; businessDate: string): string =
  let rows = db.getAllRows(sql"""
    SELECT allowance::numeric(24,2)::text FROM lending.ppap_snapshot
     WHERE loan_id = ? AND business_date = ?::date""", $loanId, businessDate)
  if rows.len == 0:
    return ""
  rows[0][0]

proc journalRows(businessDate, eventType: string): int =
  parseInt(db.getValue(sql"""
    SELECT count(*)::text FROM ledger.journal
     WHERE business_date = ?::date AND source_event = ?""", businessDate, eventType))

proc journalTotal(businessDate, eventType: string): string =
  db.getValue(sql"""
    SELECT coalesce(sum(l.debit), 0)::numeric(24,2)::text
      FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
     WHERE j.business_date = ?::date AND j.source_event = ?""", businessDate, eventType)

proc accountsOf(businessDate, eventType: string): string =
  ## `503:DEBIT,111:CREDIT` — arah akun adalah isi keputusan D-185, jadi diuji apa adanya.
  db.getValue(sql"""
    SELECT string_agg(gl_account || ':' || CASE WHEN debit > 0 THEN 'DEBIT' ELSE 'CREDIT' END,
                      ',' ORDER BY line_no)
      FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
     WHERE j.business_date = ?::date AND j.source_event = ?""", businessDate, eventType)

proc totalAllowance(businessDate: string): string =
  db.getValue(sql"""
    SELECT coalesce(sum(allowance), 0)::numeric(24,2)::text
      FROM lending.ppap_snapshot WHERE business_date = ?::date""", businessDate)

suite "day-close lending: penyisihan PPAP (T-167)":
  let
    d1 = "2026-11-10"
    d2 = "2026-11-11"
    d3 = "2026-11-12"
    loanA = newId(testClock)
    loanB = newId(testClock)

  # Suite sebelumnya meninggalkan pinjaman ACTIVE tanpa saldo/penilaian; menutupnya membuat populasi
  # `ACTIVE` di sini hanya pinjaman uji PPAP. Belum ada penyisihan, jadi tidak ada yang menggantung.
  db.exec(sql"UPDATE lending.loan SET status = 'CLOSED'")

  block:
    newPpapLoan(loanA, "12000000.00")
    newPpapLoan(loanB, "3000000.00")
    setGrade(loanA, d1, "SPECIAL_MENTION")
    setGrade(loanB, d1, "COLLECTIBLE")
    setGrade(loanA, d2, "LOSS")
    setGrade(loanB, d2, "COLLECTIBLE")
    setGrade(loanA, d3, "COLLECTIBLE")
    setGrade(loanB, d3, "COLLECTIBLE")

  test "menyisihkan menurut golongan dan menjurnal selisihnya (D 503 / K 111)":
    let outcome = ppapTask().run(ctxOn(d1), Chunk(chunkNo: 0))
    check outcome.isOk
    if not outcome.isOk:
      echo "PPAP-D1: ", outcome.error.code, " ", outcome.error.message
    check outcome.val.metrics["written"].getInt() == 2
    check outcome.val.metrics["journals"].getInt() == 1
    check allowanceOn(loanA, d1) == "360000.00" # 12.000.000 × 3% (dalam perhatian khusus)
    check allowanceOn(loanB, d1) == "15000.00" # 3.000.000 × 0,5% (PPKA umum, lancar)
    check journalTotal(d1, "PpapProvisioned") == "375000.00"
    check accountsOf(d1, "PpapProvisioned") == "503:DEBIT,111:CREDIT"
    check journalRows(d1, "PpapReleased") == 0
    check db.getValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'lending.ppap.provision'""") == "1"

  test "selisih dihitung terhadap tanggal buku sebelumnya, bukan angka mutlak":
    let outcome = ppapTask().run(ctxOn(d2), Chunk(chunkNo: 0))
    check outcome.isOk
    check allowanceOn(loanA, d2) == "12000000.00" # 100% setelah jadi LOSS
    # Σ baru 12.015.000 − Σ lama 375.000 = 11.640.000, itu yang dijurnal.
    check journalTotal(d2, "PpapProvisioned") == "11640000.00"

  test "golongan membaik → jurnal pembalik, bukan nominal negatif":
    setOutstanding(loanA, "5000000.00")
    let outcome = ppapTask().run(ctxOn(d3), Chunk(chunkNo: 0))
    check outcome.isOk
    check allowanceOn(loanA, d3) == "25000.00" # 5.000.000 × 0,5% (PPKA umum)
    check journalRows(d3, "PpapReleased") == 1
    # Σ baru 40.000 − Σ lama 12.015.000 = 11.975.000 yang dibalik.
    check journalTotal(d3, "PpapReleased") == "11975000.00"
    check accountsOf(d3, "PpapReleased") == "111:DEBIT,503:CREDIT"
    # Tidak ada sisi negatif: pembalik selalu nominal positif dengan arah berlawanan.
    check db.getValue(sql"""
      SELECT count(*)::text FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
       WHERE j.business_date = ?::date AND (l.debit < 0 OR l.credit < 0)""", d3) == "0"

  test "run ulang tanggal yang sama tidak menggandakan snapshot maupun jurnal":
    let snapshots = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM lending.ppap_snapshot WHERE business_date = ?::date""", d3))
    let journals = parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM ledger.journal WHERE business_date = ?::date""", d3))
    let outcome = ppapTask().run(ctxOn(d3), Chunk(chunkNo: 0))
    check outcome.isOk
    check outcome.val.metrics["written"].getInt() == 0
    check outcome.val.metrics["skipped"].getInt() == 2
    check parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM lending.ppap_snapshot WHERE business_date = ?::date""", d3)) ==
      snapshots
    check parseInt(db.getValue(sql"""
      SELECT count(*)::text FROM ledger.journal WHERE business_date = ?::date""", d3)) == journals

  test "Δ snapshot == Δ jurnal di seluruh rangkaian":
    check totalAllowance(d3) == "40000.00"
    check totalAllowance(d1) == "375000.00"
    check journalTotal(d2, "PpapProvisioned") == "11640000.00"
    check journalTotal(d3, "PpapReleased") == "11975000.00"
    # 11.640.000 − 11.975.000 + 375.000 = 40.000 = Σ allowance d3.
    check db.getValue(sql"""
      SELECT (
        (SELECT coalesce(sum(debit), 0) FROM ledger.journal_line l
           JOIN ledger.journal j USING (journal_id)
          WHERE j.source_event = 'PpapProvisioned')
        - (SELECT coalesce(sum(debit), 0) FROM ledger.journal_line l
             JOIN ledger.journal j USING (journal_id)
            WHERE j.source_event = 'PpapReleased')
      )::numeric(24,2)::text""") == totalAllowance(d3)

  test "parameter tarif rusak menggagalkan task, bukan menyisihkan nol":
    # Regrading tanggal itu lebih dulu: prasyarat golongan diperiksa **saat chunk berjalan**
    # (bukan saat perencanaan), jadi tanpa ini yang gagal adalah DAY-383, bukan pembacaan tarif.
    discard runChunk("2026-11-13")
    db.exec(sql"""
      UPDATE platform.param_value SET value = '["0","0.5","10","50"]'::jsonb
       WHERE key = 'lending.ppap.rates'""")
    let failed = ppapTask().run(ctxOn("2026-11-13"), Chunk(chunkNo: 0))
    check not failed.isOk
    check failed.error.code == "DAY-380"
    check db.getValue(sql"""
      SELECT count(*)::text FROM lending.ppap_snapshot WHERE business_date = '2026-11-13'""") == "0"
    db.exec(sql"""
      UPDATE platform.param_value SET value = '["0.5","3","10","50","100"]'::jsonb
       WHERE key = 'lending.ppap.rates'""")

  test "pinjaman ACTIVE belum dinilai kolektibilitasnya menahan penyisihan (DAY-383)":
    newPpapLoan(newId(testClock), "1000000.00")
    # Perencanaan chunk **tidak** boleh gagal hanya karena regrading hari itu belum berjalan:
    # perencanaan terjadi sebelum dependensi dieksekusi (bug yang ditemukan simulasi T-172).
    let chunks = ppapTask().countChunks(ctxOn("2026-11-14"), 100)
    check chunks.isOk
    # Prasyaratnya tetap fail-closed, tetapi pada saat chunk berjalan — ketika dependensi sudah
    # selesai dan pinjaman yang belum dinilai tidak bisa lagi dilewati diam-diam.
    let refused = ppapTask().run(ctxOn("2026-11-14"), Chunk(chunkNo: 0))
    check not refused.isOk
    check refused.error.code == "DAY-383"
    check db.getValue(sql"""
      SELECT count(*)::text FROM lending.ppap_snapshot WHERE business_date = '2026-11-14'""") == "0"


suite "day-close lending: restrukturisasi & hapus buku (T-168)":
  test "tunggakan jadwal lama yang diarsipkan tidak lagi dihitung sebagai DPD":
    let loanId = newId(testClock)
    newPpapLoan(loanId, "12000000.00")
    newInstallment(loanId, 1, "2026-06-01")
    # 1 Nov 2026: 153 hari menunggak → DOUBTFUL dengan ambang [90,120,180].
    discard runChunk("2026-11-01")
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-11-01'""", $loanId) == "DOUBTFUL"
    # Restrukturisasi: jadwal lama diarsipkan, jadwal baru jatuh tempo di masa depan.
    db.exec(sql"""
      UPDATE lending.installment SET superseded_on = '2026-11-15'
       WHERE loan_id = ? AND no = 1""", $loanId)
    newInstallment(loanId, 2, "2027-01-01")
    db.exec(sql"""
      UPDATE lending.installment SET schedule_version = 2
       WHERE loan_id = ? AND no = 2""", $loanId)
    discard runChunk("2026-12-01")
    check db.getValue(sql"""
      SELECT dpd::text FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-12-01'""", $loanId) == "0"
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-12-01'""", $loanId) == "COLLECTIBLE"

  test "restrukturisasi menahan golongan di kurang lancar walau DPD nol":
    let loanId = newId(testClock)
    newPpapLoan(loanId, "12000000.00")
    newInstallment(loanId, 1, "2026-06-01")
    # 1 Nov 2026: 153 hari menunggak → DOUBTFUL dengan ambang [90,120,180].
    discard runChunk("2026-11-01")
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-11-01'""", $loanId) == "DOUBTFUL"
    # Restrukturisasi seperti yang ditulis handler: jadwal lama diarsipkan, jadwal baru di masa
    # depan, dan pembanding "sebelum" dicatat (O-123, D-197).
    db.exec(sql"""
      UPDATE lending.installment SET superseded_on = '2026-11-15'
       WHERE loan_id = ? AND no = 1""", $loanId)
    newInstallment(loanId, 2, "2027-01-01")
    db.exec(sql"""
      UPDATE lending.installment SET schedule_version = 2
       WHERE loan_id = ? AND no = 2""", $loanId)
    db.exec(sql"""
      UPDATE lending.loan
         SET restructured_on = '2026-11-15', grade_before_restructure = 'DOUBTFUL',
             grade_cap = 'SUBSTANDARD'
       WHERE loan_id = ?""", $loanId)

    discard runChunk("2026-12-01")
    check db.getValue(sql"""
      SELECT dpd::text FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-12-01'""", $loanId) == "0"
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-12-01'""", $loanId) == "SUBSTANDARD"

  test "periode pembayaran bersih melepas batas golongan":
    let loanId = newId(testClock)
    newPpapLoan(loanId, "12000000.00")
    newInstallment(loanId, 1, "2026-06-01")
    discard runChunk("2026-11-01")
    db.exec(sql"""
      UPDATE lending.installment SET superseded_on = '2026-11-15'
       WHERE loan_id = ? AND no = 1""", $loanId)
    # Tiga angsuran baru, masing-masing dibayar tepat waktu (paid_on = due_on).
    newInstallment(loanId, 2, "2027-01-01", paid = true)
    newInstallment(loanId, 3, "2027-02-01", paid = true)
    newInstallment(loanId, 4, "2027-03-01", paid = true)
    db.exec(sql"UPDATE lending.installment SET schedule_version = 2 WHERE loan_id = ? AND no >= 2",
      $loanId)
    db.exec(sql"""
      UPDATE lending.loan
         SET restructured_on = '2026-11-15', grade_before_restructure = 'LOSS',
             grade_cap = 'SUBSTANDARD'
       WHERE loan_id = ?""", $loanId)

    # Dua periode bersih (Januari, Februari): batas masih berlaku.
    discard runChunk("2027-02-01")
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2027-02-01'""", $loanId) == "SUBSTANDARD"
    # Angsuran Maret jatuh tempo 1 Maret dan dibayar tepat waktu: tiga periode bersih, batas lepas.
    discard runChunk("2027-03-01")
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2027-03-01'""", $loanId) == "COLLECTIBLE"

  test "angsuran yang dibayar terlambat tidak dihitung sebagai periode bersih":
    let loanId = newId(testClock)
    newPpapLoan(loanId, "12000000.00")
    # Dibayar, tetapi lewat lima hari dari jatuh tempo: bukan periode bersih. Ditulis langsung
    # karena trigger `0089` menolak mengubah `paid_on` setelah baris dibayar (dan itu benar).
    for (no, due, paid) in [(1, "2027-01-01", "2027-01-06"),
        (2, "2027-02-01", "2027-02-06"), (3, "2027-03-01", "2027-03-06")]:
      db.exec(sql"""
        INSERT INTO lending.installment
          (loan_id, no, due_on, principal_due, interest_due, penalty_due,
           paid_principal, paid_interest, paid_penalty, paid_on)
        VALUES (?, ?, ?::date, 100000.00, 10000.00, 0, 100000.00, 10000.00, 0, ?::date)""",
        $loanId, no, due, paid)
    db.exec(sql"""
      UPDATE lending.loan
         SET restructured_on = '2026-11-15', grade_before_restructure = 'LOSS',
             grade_cap = 'SUBSTANDARD'
       WHERE loan_id = ?""", $loanId)
    discard runChunk("2027-04-01")
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2027-04-01'""", $loanId) == "SUBSTANDARD"

  test "sebelumnya kurang lancar tidak naik sebelum periode bersih cukup":
    let loanId = newId(testClock)
    newPpapLoan(loanId, "12000000.00")
    newInstallment(loanId, 1, "2027-01-01")
    db.exec(sql"""
      UPDATE lending.loan
         SET restructured_on = '2026-11-15', grade_before_restructure = 'SUBSTANDARD',
             grade_cap = 'SUBSTANDARD', collectibility = 'SUBSTANDARD'
       WHERE loan_id = ?""", $loanId)
    discard runChunk("2026-12-01")
    # DPD 0 (angsuran belum jatuh tempo) tetapi golongannya "tidak berubah": tetap kurang lancar.
    check db.getValue(sql"""
      SELECT grade FROM lending.collectibility_snapshot
       WHERE loan_id = ? AND business_date = '2026-12-01'""", $loanId) == "SUBSTANDARD"

  test "ambang periode bersih dibaca dari parameter, bukan angka di kode":
    let loanId = newId(testClock)
    newPpapLoan(loanId, "12000000.00")
    newInstallment(loanId, 1, "2027-01-01", paid = true)
    db.exec(sql"""
      UPDATE lending.loan
         SET restructured_on = '2026-11-15', grade_before_restructure = 'LOSS',
             grade_cap = 'SUBSTANDARD'
       WHERE loan_id = ?""", $loanId)
    db.exec(sql"""
      UPDATE platform.param_value SET value = '1'::jsonb
       WHERE key = 'lending.restructure.clean_periods'""")
    try:
      # Satu periode bersih sudah cukup bila parameter bernilai 1.
      discard runChunk("2027-02-01")
      check db.getValue(sql"""
        SELECT grade FROM lending.collectibility_snapshot
         WHERE loan_id = ? AND business_date = '2027-02-01'""", $loanId) == "COLLECTIBLE"
    finally:
      db.exec(sql"""
        UPDATE platform.param_value SET value = '3'::jsonb
         WHERE key = 'lending.restructure.clean_periods'""")

  test "parameter periode bersih hilang menggagalkan task, bukan memakai bawaan":
    db.exec(sql"""
      DELETE FROM platform.param_value WHERE key = 'lending.restructure.clean_periods'""")
    let failed = task().run(ctxOn("2027-05-01"), Chunk(chunkNo: 0))
    check not failed.isOk
    check failed.error.code == "DAY-372"
    db.exec(sql"""
      INSERT INTO platform.param_value
        (param_value_id, key, scope_type, scope_id, value, effective_from, status,
         maker, checker, reason)
      VALUES (md5('itdaycloser_lending|clean_periods')::uuid,
              'lending.restructure.clean_periods', 'GLOBAL', NULL, '3'::jsonb,
              DATE '1970-01-01', 'ACTIVE', '00000000-0000-4000-8000-0000000000a1',
              '00000000-0000-4000-8000-0000000000a2', 'uji: pulihkan parameter')""")

  test "penyisihan tidak dianggap menggantung setelah hapus buku":
    let loanId = newId(testClock)
    newPpapLoan(loanId, "1000000.00")
    setGrade(loanId, "2026-12-05", "LOSS")
    db.exec(sql"""
      INSERT INTO lending.ppap_snapshot
        (loan_id, business_date, grade, base_amount, rate_micro, allowance)
      VALUES (?, '2026-12-05', 'LOSS', 1000000.00, 1000000, 1000000.00)""", $loanId)
    # Pinjaman ACTIVE tidak pernah dihitung sebagai penyisihan menggantung.
    check strandedAllowances(db) == 0
    # Keluar dari ACTIVE tanpa hapus buku = CKPN yang tidak punya pemilik → task gagal terlihat.
    db.exec(sql"UPDATE lending.loan SET status = 'CLOSED' WHERE loan_id = ?", $loanId)
    check strandedAllowances(db) == 1
    # Setelah hapus buku, penyisihannya terpakai seluruhnya.
    db.exec(sql"""
      UPDATE lending.loan
         SET status = 'WRITTEN_OFF', written_off_on = '2026-12-06',
             written_off_by = ?::uuid, written_off_reason = 'uji hapus buku'
       WHERE loan_id = ?""", ActorId, $loanId)
    db.exec(sql"""
      INSERT INTO lending.writeoff
        (loan_id, business_date, principal_amount, interest_amount, penalty_amount,
         allowance_applied, expense_amount, created_by)
      VALUES (?, '2026-12-06', 1000000.00, 0, 0, 1000000.00, 0, ?::uuid)""", $loanId, ActorId)
    check strandedAllowances(db) == 0

dbPool.release(db)
