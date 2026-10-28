## Test integrasi gate pra/pasca-tutup (T-136) — butuh `KRAN_DATABASE_URL`.
##
## Dua lapis yang dibuktikan:
##   1. **Lewat `ctl` yang sebenarnya**: gate gagal → run `BLOCKED`, tanggal tetap `CLOSING`,
##      `daycloser-status` menahan deploy, dan setelah keadaan diperbaiki (lewat cancel + run ulang,
##      jalur yang memang disediakan) run selesai dan tanggal maju.
##   2. **Langsung per gate**: setiap gate dijalankan terhadap data yang memang melanggar, supaya
##      kode temuan (`DAY-30x`) dan angkanya (metrics) tidak hanya diasumsikan.
##
## Suite ini me-reset seluruh schema (pola suite integrasi lain) dan menghapus
## `platform.business_date` di akhir supaya e2e/suite berikutnya mulai tanpa penutupan berjalan.

import std/[json, options, os, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/dayclose

import daycloser/domain/types
import platform/domain/[calendar, scope]
import platform/infrastructure/calendar_repo

import ../src/[daycloser_ctl, daycloser_gates]

const
  repoRoot = "."
  Monday = "2026-10-26"
  Tuesday = "2026-10-27"
  Wednesday = "2026-10-28"
  Thursday = "2026-10-29"
  BranchId = "b0000000-0000-4000-8000-0000000000a1"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser_gates: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))
execScript(db, readFile(repoRoot / "packs/base/seed/0001_dev_users.sql"))

# Prasyarat data: cabang, satu periode OPEN yang menutup seluruh tanggal uji (trigger
# `ledger.assert_journal_period_open` menolak jurnal tanpa periode), dan tanggal buku awal.
let actor = db.getValue(sql"SELECT user_id::text FROM platform.app_user LIMIT 1")
execScript(db, """
  INSERT INTO platform.branch (branch_id, code, name)
  VALUES ('""" & BranchId & """', '131', 'Cabang Gate')
  ON CONFLICT DO NOTHING
""")
execScript(db, """
  INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
  VALUES (md5('itdaycloser_gates|period')::uuid, DATE '2026-01-01', DATE '2026-12-31', 'OPEN',
          '""" & actor & """', '""" & actor & """')
  ON CONFLICT DO NOTHING
""")
execScript(db, """
  INSERT INTO platform.business_date (scope_type, scope_id, current_business_date, state, updated_by)
  VALUES ('INSTITUTION', NULL, DATE '""" & Monday & """', 'OPEN', '""" & actor & """')
""")

proc bd(): Option[BusinessDateRow] =
  businessDateOf(db, institutionScope())

proc runState(businessDate: string): string =
  db.getValue(sql"""
    SELECT state FROM daycloser.run
     -- Waktu mulai bisa sama persis (dua run dalam satu detik), jadi `run_id` (UUIDv7) yang
     -- memutuskan: test harus bertanya "run terakhir", bukan "baris mana yang terbaca lebih dulu".
     WHERE business_date = ?::date ORDER BY started_at DESC, run_id DESC LIMIT 1""",
    businessDate)

proc taskOf(businessDate, taskId: string): tuple[state, code, metrics: string] =
  let rows = db.getAllRows(sql"""
    SELECT t.state, coalesce(t.error->>'code', ''), coalesce(t.metrics::text, '')
      FROM daycloser.task t
      JOIN daycloser.run r USING (run_id)
     WHERE r.business_date = ?::date AND t.task_id = ?
     ORDER BY r.started_at DESC, r.run_id DESC LIMIT 1""", businessDate, taskId)
  if rows.len == 0:
    return ("", "", "")
  (rows[0][0], rows[0][1], rows[0][2])

proc ctxOn(businessDate: string): TaskContext =
  TaskContext(runId: "test", scopeType: "INSTITUTION", scopeId: "", businessDate: businessDate,
              levels: {clEOD}, mode: rmReal, chunkSize: 100)

proc postJournal(amount: string; debit, credit: string; businessDate: string) =
  ## Jurnal seimbang minimum (dua baris). Header + baris satu transaksi: trigger header memeriksa
  ## saat COMMIT.
  let journalId = db.getValue(sql"SELECT gen_random_uuid()::text")
  discard dbPool.withTx(proc(d: DbConn): int =
    discard d.execAffectedRows(sql"""
      INSERT INTO ledger.journal
        (journal_id, business_date, value_date, source_event, source_ref, idempotency_key,
         created_by)
      VALUES (?::uuid, ?::date, ?::date, 'GateFixture', ?::uuid, ?, ?::uuid)""",
      journalId, businessDate, businessDate, journalId, "gate-fixture-" & journalId, actor)
    discard d.execAffectedRows(sql"""
      INSERT INTO ledger.journal_line (journal_id, line_no, gl_account, branch_id, debit, credit)
      VALUES (?::uuid, 1, ?, ?::uuid, ?::numeric, 0),
             (?::uuid, 2, ?, ?::uuid, 0, ?::numeric)""",
      journalId, debit, BranchId, amount, journalId, credit, BranchId, amount)
    1)

suite "gate day-close: lewat perintah ctl":
  test "sesi teller OPEN memblokir penutupan, lalu resume menyelesaikannya":
    execScript(db, """
      INSERT INTO teller.teller_session
        (session_id, branch_id, teller_user_id, business_date, status, opening_float, opened_by)
      VALUES ('c0000000-0000-4000-8000-0000000000a1', '""" & BranchId &
        """',
              '""" & actor & """', DATE '""" & Monday & """', 'OPEN', 0, '""" & actor & """')
    """)

    check runDayCloserCtl(dayCloserRunCmd, Monday, "") == 1
    check runState(Monday) == "BLOCKED"
    let gate = taskOf(Monday, "teller.sessions_closed")
    check gate.state == "FAILED"
    check gate.code == "DAY-301"
    check parseJson(gate.metrics){"openSessions"}.getInt == 1

    # Gate pra-tutup gagal **sebelum** freeze: tanggal buku sengaja tidak dibekukan, jadi
    # institusi masih bisa melayani transaksi. Yang menahan adalah run `BLOCKED` itu sendiri.
    check bd().get.currentDate == Monday
    check bd().get.state == bdsOpen
    check runDayCloserCtl(dayCloserRunCmd, Monday, "") == 3

    # Perbaiki keadaan: sesi ditutup seimbang.
    execScript(db, """
      UPDATE teller.teller_session
         SET status = 'CLOSED', expected_cash = 0, counted_cash = 0, variance = 0,
             closed_at = now(), closed_by = '""" & actor & """'
       WHERE session_id = 'c0000000-0000-4000-8000-0000000000a1'
    """)

    # Selama run BLOCKED, tanggal buku masih OPEN sehingga institusi boleh melayani. Jurnal baru
    # untuk tanggal itu berarti sertifikat gate pra-tutup yang lama sudah basi: resume **wajib**
    # memeriksa ulang gate yang dulu lulus, bukan melewatinya.
    postJournal("50.00", "101.9", "101.1", Monday)

    let runId = db.getValue(sql"""
      SELECT run_id::text FROM daycloser.run WHERE business_date = ?::date""", Monday)
    check runDayCloserCtl(dayCloserResumeCmd, "", runId) == 1
    check runState(Monday) == "BLOCKED"
    let staleGate = taskOf(Monday, "ledger.suspense_zero")
    check staleGate.state == "FAILED"
    check staleGate.code == "DAY-304"
    check bd().get.state == bdsOpen

    # Jalur pemulihan: batalkan, perbaiki buku, lalu tutup ulang tanggal yang sama.
    check runDayCloserCtl(dayCloserCancelCmd, "", runId) == 0
    postJournal("50.00", "101.1", "101.9", Monday)
    check runDayCloserCtl(dayCloserRunCmd, Monday, "") == 0
    check runState(Monday) == "COMPLETED"
    check bd().get.currentDate == Tuesday
    check bd().get.state == bdsOpen
    check taskOf(Monday, "teller.sessions_closed").state == "SUCCEEDED"

  test "pengajuan top-up menggantung memblokir penutupan":
    execScript(db, """
      INSERT INTO teller.vault_topup_request
        (request_id, branch_id, amount, source_account, note, requested_by)
      VALUES ('c0000000-0000-4000-8000-0000000000b1', '""" & BranchId &
        """', 100.00, '101.1',
              'pengajuan uji gate', '""" & actor & """')
    """)
    check runDayCloserCtl(dayCloserRunCmd, Tuesday, "") == 1
    check runState(Tuesday) == "BLOCKED"
    let gate = taskOf(Tuesday, "teller.pending_approvals")
    check gate.state == "FAILED"
    check gate.code == "DAY-303"
    check parseJson(gate.metrics){"pendingVaultTopUps"}.getInt == 1

    # Tanpa pengajuan, run yang sama dilanjutkan sampai selesai.
    execScript(db, """
      DELETE FROM teller.vault_topup_request
       WHERE request_id = 'c0000000-0000-4000-8000-0000000000b1'
    """)
    let runId = db.getValue(sql"""
      SELECT run_id::text FROM daycloser.run WHERE business_date = ?::date""", Tuesday)
    check runDayCloserCtl(dayCloserResumeCmd, "", runId) == 0
    check bd().get.currentDate == Wednesday

  test "akun selisih bersaldo memblokir; setelah dibatalkan & diperbaiki, tanggal ditutup":
    postJournal("100.00", "101.9", "101.1", Wednesday)

    check runDayCloserCtl(dayCloserRunCmd, Wednesday, "") == 1
    check runState(Wednesday) == "BLOCKED"
    let gate = taskOf(Wednesday, "ledger.suspense_zero")
    check gate.state == "FAILED"
    check gate.code == "DAY-304"

    # Run diblokir di PRECHECK, jadi tanggal belum dibekukan dan jurnal koreksi masih boleh
    # dibuat. Jalur yang tetap sah (dan mendokumentasikan pemulihan): batalkan run, perbaiki
    # buku, lalu tutup ulang.
    let runId = db.getValue(sql"""
      SELECT run_id::text FROM daycloser.run WHERE business_date = ?::date""", Wednesday)
    check runDayCloserCtl(dayCloserCancelCmd, "", runId) == 0
    check bd().get.state == bdsOpen

    postJournal("100.00", "101.1", "101.9", Wednesday)
    check runDayCloserCtl(dayCloserRunCmd, Wednesday, "") == 0
    check runState(Wednesday) == "COMPLETED"
    check bd().get.currentDate == Thursday

  test "gate pasca-tutup gagal: run BLOCKED, tanggal tetap CLOSING sampai dibatalkan":
    # GL 201 dikredit tanpa rekening simpanan: subledger 0.00 vs GL 100.00.
    postJournal("100.00", "101.1", "201", Thursday)
    check runDayCloserCtl(dayCloserRunCmd, Thursday, "") == 1
    check runState(Thursday) == "BLOCKED"
    let gate = taskOf(Thursday, "ledger.subledger_vs_gl")
    check gate.state == "FAILED"
    check gate.code == "DAY-308"
    check parseJson(gate.metrics){"subledger"}.getStr == "0.00"
    check parseJson(gate.metrics){"gl"}.getStr == "100.00"

    # Gate pasca-tutup berjalan setelah freeze: tanggal tetap terbekukan (semua tulisan ditahan
    # gerbang HTTP) sampai run diselesaikan.
    check bd().get.currentDate == Thursday
    check bd().get.state == bdsClosing
    check runDayCloserCtl(dayCloserStatusCmd, "", "") == 1
    check runDayCloserCtl(dayCloserRunCmd, Thursday, "") == 3

    let runId = db.getValue(sql"""
      SELECT run_id::text FROM daycloser.run WHERE business_date = ?::date""", Thursday)
    check runDayCloserCtl(dayCloserCancelCmd, "", runId) == 0
    check bd().get.state == bdsOpen
    postJournal("100.00", "201", "101.1", Thursday)

suite "gate day-close: dijalankan langsung":
  test "trial balance seimbang melaporkan angka yang sama":
    let r = trialBalanceCheck(dbPool, ctxOn(Thursday))
    check r.ok
    check r.metrics{"totalDebit"}.getStr == r.metrics{"totalCredit"}.getStr
    check r.metrics{"difference"}.getStr == "0.00"

  test "subledger tanpa rekening tetapi GL bersaldo = DAY-308":
    # GL 201 dikredit tanpa rekening simpanan: subledger 0.00 vs GL 100.00.
    postJournal("100.00", "101.1", "201", Thursday)
    let r = subledgerCheck(dbPool, ctxOn(Thursday))
    check not r.ok
    check r.code == "DAY-308"
    check r.metrics{"subledger"}.getStr == "0.00"
    check r.metrics{"gl"}.getStr == "100.00"
    # Kembalikan supaya gate lain tidak mewarisi selisih ini.
    postJournal("100.00", "201", "101.1", Thursday)
    check subledgerCheck(dbPool, ctxOn(Thursday)).ok

  test "jurnal yang direkam setelah tanggal dibekukan = DAY-310":
    # Bekukan **sekarang**: jurnal yang sudah ada direkam sebelum titik ini, jadi bukan terlambat.
    execScript(db, """
      UPDATE platform.business_date
         SET state = 'CLOSING', updated_at = now()
       WHERE scope_type = 'INSTITUTION'
    """)
    let before = latePostingsCheck(dbPool, ctxOn(Thursday))
    check before.ok

    postJournal("10.00", "101.1", "101.9", Thursday)
    let after = latePostingsCheck(dbPool, ctxOn(Thursday))
    check not after.ok
    check after.code == "DAY-310"
    check after.metrics{"latePostings"}.getInt >= 1

    execScript(db, """
      UPDATE platform.business_date SET state = 'OPEN' WHERE scope_type = 'INSTITUTION'
    """)
    postJournal("10.00", "101.9", "101.1", Thursday)

  test "gate lulus menyimpan bukti walau tidak ada temuan":
    let sessions = tellerSessionsCheck(dbPool, ctxOn(Thursday))
    check sessions.ok
    check sessions.metrics{"openSessions"}.getInt == 0
    let pending = pendingApprovalsCheck(dbPool, ctxOn(Thursday))
    check pending.ok
    check pending.metrics{"pendingVaultTopUps"}.getInt == 0

  test "sesi ditutup dengan kas tidak seimbang = DAY-302":
    execScript(db, """
      UPDATE teller.teller_session
         SET expected_cash = 0, counted_cash = 10, variance = 10
       WHERE session_id = 'c0000000-0000-4000-8000-0000000000a1'
    """)
    let r = tellerSessionsCheck(dbPool, ctxOn(Thursday))
    check not r.ok
    check r.code == "DAY-302"
    check r.metrics{"unbalancedSessions"}.getInt == 1
    execScript(db, """
      UPDATE teller.teller_session
         SET expected_cash = 0, counted_cash = 0, variance = 0
       WHERE session_id = 'c0000000-0000-4000-8000-0000000000a1'
    """)

  test "akun parameter yang tidak dikenal mematikan gate tanpa galat = DAY-311":
    execScript(db, """
      UPDATE platform.param_value SET value = '["101.99"]'::jsonb
       WHERE param_value_id = md5('daycloser.precheck.suspense_accounts|base')::uuid
    """)
    let r = suspenseCheck(dbPool, ctxOn(Thursday))
    check not r.ok
    check r.code == "DAY-311"
    check r.metrics{"unknownAccounts"}[0].getStr == "101.99"
    execScript(db, """
      UPDATE platform.param_value SET value = '["101.9"]'::jsonb
       WHERE param_value_id = md5('daycloser.precheck.suspense_accounts|base')::uuid
    """)

  test "daftar akun kosong = DAY-312 (parameter tidak boleh mematikan gate)":
    execScript(db, """
      UPDATE platform.param_value SET value = '[]'::jsonb
       WHERE param_value_id = md5('daycloser.postcheck.subledger_gl_accounts|base')::uuid
    """)
    let r = subledgerCheck(dbPool, ctxOn(Thursday))
    check not r.ok
    check r.code == "DAY-312"
    execScript(db, """
      UPDATE platform.param_value SET value = '["201", "202"]'::jsonb
       WHERE param_value_id = md5('daycloser.postcheck.subledger_gl_accounts|base')::uuid
    """)

  test "pasca-tutup saat tanggal tidak CLOSING = DAY-309":
    execScript(db, """
      UPDATE platform.business_date SET state = 'OPEN' WHERE scope_type = 'INSTITUTION'
    """)
    let r = latePostingsCheck(dbPool, ctxOn(Thursday))
    check not r.ok
    check r.code == "DAY-309"

# Jangan tinggalkan tanggal buku `CLOSING` untuk suite/e2e berikutnya.
block:
  execScript(db, "DELETE FROM platform.business_date")
