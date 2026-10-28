## Test integrasi task `ledger` day-close (T-137) — butuh `KRAN_DATABASE_URL`.
##
## Membuktikan empat hal yang tidak bisa dibuktikan unit test:
##   1. snapshot saldo benar-benar ditulis untuk tanggal buku dan isinya sama dengan jurnal;
##   2. penutupan periode GL bulanan memakai jalur yang sama dengan HTTP (status `CLOSED`,
##      audit, event `period.closed`), dengan `closed_by` NULL = pelaku sistem;
##   3. menjalankan task yang sama dua kali tidak mengubah hasil (idempoten per business date);
##   4. penutupan periode berjalan **setelah** snapshot dan gate pasca-tutup (urutan DAG), dan
##      hanya untuk periode yang jatuh tempo pada bulan itu.
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain) dan menghapus
## `platform.business_date` di akhir.

import std/[json, os, strutils, tables, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[dayclose, result]

import daycloser/domain/[registry, types]

import ../src/[daycloser_ctl, daycloser_ledger, daycloser_tasks]

const
  repoRoot = "."
  ## Jumat terakhir Oktober 2026: hari kerja terakhir bulan itu → level EOD + EOM.
  CloseDate = "2026-10-30"
  NextMonth = "2026-11-30"
  ## Tanggal uji yang **tidak** dipakai suite lain, supaya kasus "periode tidak ada" dan "periode
  ## masih OPEN di depan" tidak bergantung urutan test.
  NoPeriodDate = "2028-06-30"
  LongPeriodDate = "2029-07-30"
  BranchId = "b0000000-0000-4000-8000-0000000000b1"
  PeriodId = "d0000000-0000-4000-8000-0000000000a1"
  NextPeriodId = "d0000000-0000-4000-8000-0000000000a2"
  LongPeriodId = "d0000000-0000-4000-8000-0000000000a3"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_ledger: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyAllMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))
execScript(db, readFile(repoRoot / "packs/base/seed/0001_dev_users.sql"))

let actor = db.getValue(sql"SELECT user_id::text FROM platform.app_user LIMIT 1")
execScript(db, """
  INSERT INTO platform.branch (branch_id, code, name)
  VALUES ('""" & BranchId & """', '141', 'Cabang Ledger')
  ON CONFLICT DO NOTHING
""")
execScript(db, """
  INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
  VALUES ('""" & PeriodId & """', DATE '2026-10-01', DATE '""" & CloseDate &
    """', 'OPEN',
          '""" & actor & """', '""" & actor & """')
""")

proc postJournal(amount, debit, credit, businessDate: string) =
  let journalId = db.getValue(sql"SELECT gen_random_uuid()::text")
  discard dbPool.withTx(proc(d: DbConn): int =
    discard d.execAffectedRows(sql"""
      INSERT INTO ledger.journal
        (journal_id, business_date, value_date, source_event, source_ref, idempotency_key,
         created_by)
      VALUES (?::uuid, ?::date, ?::date, 'LedgerFixture', ?::uuid, ?, ?::uuid)""",
      journalId, businessDate, businessDate, journalId, "ledger-fixture-" & journalId, actor)
    discard d.execAffectedRows(sql"""
      INSERT INTO ledger.journal_line (journal_id, line_no, gl_account, branch_id, debit, credit)
      VALUES (?::uuid, 1, ?, ?::uuid, ?::numeric, 0),
             (?::uuid, 2, ?, ?::uuid, 0, ?::numeric)""",
      journalId, debit, BranchId, amount, journalId, credit, BranchId, amount)
    1)

proc ctxOn(businessDate: string): TaskContext =
  TaskContext(runId: "test", scopeType: "INSTITUTION", scopeId: "", businessDate: businessDate,
              levels: {clEOD, clEOM}, mode: rmReal, chunkSize: 100)

proc taskOf(reg: Registry; id: TaskId): DayCloseTask =
  for t in reg.all():
    if t.id == id:
      return t
  raise newException(ValueError, "task tidak terdaftar: " & id)

proc periodState(): tuple[status, closedBy, closedAt: string] =
  let rows = db.getAllRows(sql"""
    SELECT status, coalesce(closed_by::text, ''), coalesce(closed_at::text, '')
      FROM ledger.period WHERE period_id = ?::uuid""", PeriodId)
  if rows.len == 0:
    return ("", "", "")
  (rows[0][0], rows[0][1], rows[0][2])

suite "task ledger day-close":
  test "penutupan bulanan menulis snapshot, menutup periode, dan memakai jalur audit yang sama":
    postJournal("100.00", "101.2", "101.1", CloseDate)

    check runDayCloserCtl(dayCloserRunCmd, CloseDate, "", bootstrap = true) == 0

    # Snapshot: baris untuk tanggal buku, dan task menyimpan sidik jarinya sebagai bukti.
    let snapshotRows = db.getValue(sql"""
      SELECT count(*)::text FROM ledger.balance_snapshot WHERE as_of = ?::date""", CloseDate)
    check parseInt(snapshotRows) > 0

    let metrics = db.getValue(sql"""
      SELECT t.metrics::text FROM daycloser.task t JOIN daycloser.run r USING (run_id)
       WHERE r.business_date = ?::date AND t.task_id = ?
       ORDER BY r.started_at DESC LIMIT 1""", CloseDate, snapshotTaskId)
    let m = parseJson(metrics)
    check m{"accounts"}.getInt > 0
    check m{"totalDebit"}.getStr == m{"totalCredit"}.getStr
    check m{"snapshotHash"}.getStr.len == 64

    # Periode tertutup oleh proses sistem: tidak ada pelaku manusia yang dikarang.
    let p = periodState()
    check p.status == "CLOSED"
    check p.closedBy == ""
    check p.closedAt.len > 0

    check db.getValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.period.close'""") == "1"
    check db.getValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'period.closed'""") == "1"

  test "menjalankan task ulang tidak mengubah hasil (idempoten)":
    # Registry lengkap: `period_close` bergantung pada gate pasca-tutup, jadi registrasi parsial
    # ditolak (kontrak registry) — bukan hanya `resolve`.
    let reg = newRegistry()
    registerDayCloseTasks(reg, dbPool)
    let ctx = ctxOn(CloseDate)

    let snapMetrics = taskOf(reg, snapshotTaskId).run(ctx, Chunk(chunkNo: 0))
    check snapMetrics.isOk
    # Hash yang sama membuktikan snapshot dibangun ulang dari sumber yang sama, bukan ditambah.
    let first = db.getValue(sql"""
      SELECT count(*)::text FROM ledger.balance_snapshot WHERE as_of = ?::date""", CloseDate)
    let again = taskOf(reg, snapshotTaskId).run(ctx, Chunk(chunkNo: 0))
    check again.isOk
    check again.value.metrics{"snapshotHash"}.getStr ==
      snapMetrics.value.metrics{"snapshotHash"}.getStr
    check db.getValue(sql"""
      SELECT count(*)::text FROM ledger.balance_snapshot WHERE as_of = ?::date""", CloseDate) ==
      first

    # Periode yang sudah CLOSED dilaporkan, bukan digagalkan.
    let closed = taskOf(reg, periodCloseTaskId).run(ctx, Chunk(chunkNo: 0))
    check closed.isOk
    check closed.value.metrics{"alreadyClosed"}.getBool
    check db.getValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'period.closed'""") == "1"

  test "urutan DAG: penutupan periode setelah snapshot dan gate pasca-tutup":
    # Menutup periode tidak bisa dibatalkan, jadi ia harus berjalan paling akhir — bukan sekadar
    # didaftarkan terakhir (registry mengurutkan topologis dan memecah seri secara alfabetis).
    let reg = newRegistry()
    registerDayCloseTasks(reg, dbPool)
    var index: Table[string, int]
    let tasks = resolve(reg, {clEOD, clEOM})
    for i, t in tasks:
      index[t.id] = i
    check index.hasKey(periodCloseTaskId)
    for dep in ["ledger.daily_snapshot", "ledger.no_late_postings",
                "ledger.subledger_vs_gl", "ledger.trial_balance"]:
      check index.hasKey(dep)
      check index[dep] < index[periodCloseTaskId]
    for t in tasks:
      if t.id == periodCloseTaskId:
        check t.kind == tkPostCheck

  test "tidak ada periode yang memuat tanggal buku = DAY-324":
    # Registry lengkap: `period_close` bergantung pada gate pasca-tutup, jadi registrasi parsial
    # ditolak (kontrak registry) — bukan hanya `resolve`.
    let reg = newRegistry()
    registerDayCloseTasks(reg, dbPool)
    let result = taskOf(reg, periodCloseTaskId).run(ctxOn(NoPeriodDate), Chunk(chunkNo: 0))
    check not result.isOk
    check result.error.code == "DAY-324"
    check result.error.metrics{"businessDate"}.getStr == NoPeriodDate

  test "periode lebih panjang dari sebulan = tidak jatuh tempo (bukan kegagalan)":
    # Institusi memakai periode tahunan: penutupan bulanan tidak punya periode yang harus ditutup.
    # Menggagalkannya akan memblokir setiap akhir bulan tanpa jalan keluar (periode bulanan baru
    # akan bertabrakan dengan periode tahunan yang masih OPEN).
    execScript(db, """
      INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
      VALUES ('""" & LongPeriodId &
        """', DATE '2029-01-01', DATE '2029-12-31', 'OPEN',
              '""" & actor & """', '""" & actor & """')
    """)
    # Registry lengkap: `period_close` bergantung pada gate pasca-tutup, jadi registrasi parsial
    # ditolak (kontrak registry) — bukan hanya `resolve`.
    let reg = newRegistry()
    registerDayCloseTasks(reg, dbPool)
    let result = taskOf(reg, periodCloseTaskId).run(ctxOn(LongPeriodDate), Chunk(chunkNo: 0))
    check result.isOk
    check result.value.metrics{"status"}.getStr == "NOT_DUE"
    check db.getValue(sql"""
      SELECT status FROM ledger.period WHERE period_id = ?::uuid""", LongPeriodId) == "OPEN"

  test "periode sebelumnya masih OPEN = DAY-328 (tutup berurutan)":
    # Februari & Maret 2027 dua-duanya OPEN; menutup Maret lebih dulu membuat laporan Februari
    # tidak punya dasar (bulan sesudahnya sudah final, bulan itu belum).
    execScript(db, """
      INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
      VALUES (md5('itdaycloser_ledger|2027-02')::uuid, DATE '2027-02-01', DATE '2027-02-28',
              'OPEN', '""" & actor & """', '""" & actor &
        """'),
             (md5('itdaycloser_ledger|2027-03')::uuid, DATE '2027-03-01', DATE '2027-03-31',
              'OPEN', '""" & actor & """', '""" & actor & """')
    """)
    # Registry lengkap: `period_close` bergantung pada gate pasca-tutup, jadi registrasi parsial
    # ditolak (kontrak registry) — bukan hanya `resolve`.
    let reg = newRegistry()
    registerDayCloseTasks(reg, dbPool)
    let result = taskOf(reg, periodCloseTaskId).run(ctxOn("2027-03-31"), Chunk(chunkNo: 0))
    check not result.isOk
    check result.error.code == "DAY-328"
    check db.getValue(sql"""
      SELECT status FROM ledger.period
       WHERE period_id = md5('itdaycloser_ledger|2027-03')::uuid""") == "OPEN"

  test "sesi kas OPEN di rentang periode menahan penutupan periode = DAY-326":
    execScript(db, """
      INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
      VALUES ('""" & NextPeriodId & """', DATE '2026-11-01', DATE '""" & NextMonth &
        """', 'OPEN',
              '""" & actor & """', '""" & actor & """')
    """)
    execScript(db, """
      INSERT INTO teller.teller_session
        (session_id, branch_id, teller_user_id, business_date, status, opening_float, opened_by)
      VALUES ('c0000000-0000-4000-8000-0000000000c1', '""" & BranchId &
        """',
              '""" & actor & """', DATE '2026-11-13', 'OPEN', 0, '""" & actor & """')
    """)

    # Registry lengkap: `period_close` bergantung pada gate pasca-tutup, jadi registrasi parsial
    # ditolak (kontrak registry) — bukan hanya `resolve`.
    let reg = newRegistry()
    registerDayCloseTasks(reg, dbPool)
    let result = taskOf(reg, periodCloseTaskId).run(ctxOn(NextMonth), Chunk(chunkNo: 0))
    check not result.isOk
    check result.error.code == "DAY-326"
    check result.error.metrics{"openSessions"}.getInt == 1
    # Periode tetap OPEN: penolakan terjadi sebelum menutup, bukan sesudah.
    check db.getValue(sql"""
      SELECT status FROM ledger.period WHERE period_id = ?::uuid""", NextPeriodId) == "OPEN"

# Jangan tinggalkan tanggal buku `CLOSING` untuk suite/e2e berikutnya.
block:
  execScript(db, "DELETE FROM platform.business_date")
