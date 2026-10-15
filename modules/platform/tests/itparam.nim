## Test integrasi parameter framework (butuh `CBS_DATABASE_URL`).
##
## Cakupan kriteria T-005: resolusi PRODUCT→BRANCH→INSTITUTION→SEGMENT→GLOBAL pada `as_of`;
## overlap ACTIVE ditolak EXCLUDE; `ParamNotFound` tanpa fallback; startup check gagal-cepat;
## maker-checker (+ 4-eyes, supersede, reject); audit + event `ParamChanged` di outbox;
## invalidasi cache lewat `LISTEN/NOTIFY`.
##
## Test ini **menghapus schema `platform`** di DB yang ditunjuk `CBS_DATABASE_URL` (DB dev).

import std/[atomics, unittest, os, json, options, strutils]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, auditcontext, paramkey]
import platform/domain/[event, param]
import platform/infrastructure/[audit_repo, outbox_repo, param_repo]

const
  repoRoot = "."
  sessionKey = "platform.security.session_idle_minutes"
  passwordKey = "platform.security.password_min_length"
  fiscalKey = "platform.calendar.fiscal_year_start_month"
  asOf = "2026-10-13"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itparam: CBS_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
let talker = dbPool.acquire() # koneksi kedua: untuk NOTIFY
let sysClock = systemClock()

execScript(db, "DROP SCHEMA IF EXISTS platform CASCADE")
discard applyMigrations(db, repoRoot)
# Ikut menguji artefak hasil paramgen: seed SQL harus benar-benar valid.
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

let maker = newId(sysClock)
let checker = newId(sysClock)
let ctxMaker = newAuditContext(maker, sysClock)
let ctxChecker = newAuditContext(checker, sysClock)

# Balapan dua koneksi (O-040): dua thread meng-approve `param_value_id` yang sama lewat koneksi
# berbeda, dimulai bersama-sama. Hasilnya harus **tepat satu pemenang** — bukan dua, dan bukan nol.
type
  RacerArgs = object
    pool: DbPool
    paramValueId: string

var
  raceGate: Atomic[bool]
  raceMenang: Atomic[int]
  raceKalah: Atomic[int]
  raceSelesai: Atomic[int]

proc racer(args: RacerArgs) {.thread.} =
  {.cast(gcsafe).}:
    while not raceGate.load():
      sleep(2)
    try:
      discard args.pool.withTx(proc(d: DbConn): ChangeOutcome {.closure.} =
        approveChange(d, ctxChecker, sysClock, args.paramValueId))
      discard raceMenang.fetchAdd(1)
    except DbError, ValueError:
      discard raceKalah.fetchAdd(1)
    discard raceSelesai.fetchAdd(1)

proc activeValues(key: string): seq[ParamCandidate] =
  candidatesOf(db, key, asOf)

proc lookup(pairs: seq[(ParamScopeType, string)]): ScopeLookup =
  let captured = pairs
  result = proc(scopeType: ParamScopeType): string =
    for (t, id) in captured:
      if t == scopeType:
        return id
    ""

suite "param: seed & definisi":
  test "definisi dari seed paramgen terpasang, nilai pack base ada":
    let def = definitionOf(db, sessionKey)
    check def.isSome
    check def.get().valueType == pvtInteger
    check def.get().allowedScopes == @[pstGlobal, pstInstitution]
    check def.get().schema["minimum"].getInt == 1
    let password = definitionOf(db, passwordKey)
    check password.get().sensitivity == psCritical
    # nilai ACTIVE dari pack base (scope INSTITUTION, scope_id NULL?) ada
    check candidatesOf(db, fiscalKey, asOf).len == 1
    check candidatesOf(db, fiscalKey, asOf)[0].value.getInt == 1

  test "key tak terdaftar ditolak (compile-time di kode, runtime di DB)":
    check definitionOf(db, "tidak.ada.key").isNone
    var raised = false
    try:
      discard submitValue(db, $newId(sysClock), "tidak.ada.key", "INSTITUTION", "", %*1,
        asOf, "", maker, "uji")
    except ValueError as e:
      raised = true
      check e.msg.contains("tidak dikenal")
    check raised

  test "scope di luar allowed_scopes ditolak":
    var raised = false
    try:
      discard submitValue(db, $newId(sysClock), sessionKey, "BRANCH", "br-1", %*30,
        asOf, "", maker, "uji")
    except ValueError as e:
      raised = true
      check e.msg.contains("tidak diizinkan")
    check raised

  test "nilai yang melanggar schema/bentuk tipe ditolak":
    for (value, diharapkan) in [(%*0, "schema"), (%*"30", "harus integer (angka JSON)")]:
      var raised = false
      try:
        discard submitValue(db, $newId(sysClock), sessionKey, "INSTITUTION", "inst-1",
          value, asOf, "", maker, "uji")
      except ValueError as e:
        raised = true
        check e.msg.contains(diharapkan)
      check raised

suite "param: resolusi nilai":
  test "PRODUCT → BRANCH → INSTITUTION → SEGMENT → GLOBAL (paling spesifik menang)":
    # Nilai disemai pada beberapa scope untuk satu key (allowed_scopes hanya ditegakkan app;
    # di sini nilai uji dibuat langsung agar urutan resolusi bisa diuji penuh).
    let key = fiscalKey
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    for (scope, id, value) in [("PRODUCT", "prod-1", "4"), ("BRANCH", "br-1", "3"),
                               ("INSTITUTION", "inst-1", "2"), ("SEGMENT", "koperasi", "5"),
                               ("GLOBAL", "", "1")]:
      let pvId = $newId(sysClock)
      let scopeIdCol = if id.len == 0: "NULL" else: "'" & id & "'"
      execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, scope_id," &
        " value, effective_from, status, maker, checker, reason) VALUES ('" & pvId & "', '" & key &
        "', '" & scope & "', " & scopeIdCol & ", '" & value & "'::jsonb, DATE '2026-01-01'," &
        " 'ACTIVE', '" & $maker & "', '" & $checker & "', 'uji resolusi')")

    let full = lookup(@[(pstProduct, "prod-1"), (pstBranch, "br-1"),
                        (pstInstitution, "inst-1"), (pstSegment, "koperasi")])
    let picked = resolveCandidate(activeValues(key), full)
    check picked.isSome
    check picked.get().scopeType == pstProduct
    check picked.get().value.getInt == 4

    let tanpaProduct = lookup(@[(pstBranch, "br-1"), (pstInstitution, "inst-1"),
                                (pstSegment, "koperasi")])
    check resolveCandidate(activeValues(key), tanpaProduct).get().value.getInt == 3

    let tanpaBranch = lookup(@[(pstInstitution, "inst-1"), (pstSegment, "koperasi")])
    check resolveCandidate(activeValues(key), tanpaBranch).get().value.getInt == 2

    let tanpaInstitution = lookup(@[(pstSegment, "koperasi")])
    check resolveCandidate(activeValues(key), tanpaInstitution).get().value.getInt == 5

    check resolveCandidate(activeValues(key), lookup(@[])).get().value.getInt == 1

  test "efektif-dated: nilai yang belum/sudah lewat tidak dipakai pada as_of":
    let key = fiscalKey
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    let lama = $newId(sysClock)
    let baru = $newId(sysClock)
    execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, value," &
      " effective_from, effective_to, status, maker, checker, reason) VALUES" &
      " ('" & lama & "', '" & key & "', 'GLOBAL', '7'::jsonb, DATE '2026-01-01'," &
      " DATE '2026-10-01', 'SUPERSEDED', '" & $maker & "', '" & $checker & "', 'lama')," &
      " ('" & baru & "', '" & key & "', 'GLOBAL', '9'::jsonb, DATE '2026-10-01', NULL," &
      " 'ACTIVE', '" & $maker & "', '" & $checker & "', 'baru')")
    check candidatesOf(db, key, "2026-09-30")[0].value.getInt == 7
    check candidatesOf(db, key, "2026-10-01")[0].value.getInt == 9
    check candidatesOf(db, key, "2026-10-13")[0].value.getInt == 9

  test "tanpa nilai aktif -> none (ParamNotFound, bukan fallback)":
    let key = passwordKey
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    check activeValues(key).len == 0
    check resolveCandidate(activeValues(key), lookup(@[])).isNone
    check missingActiveKeys(db, [key], pstInstitution, "", asOf) == @[key]

suite "param: EXCLUDE tumpang tindih":
  test "dua ACTIVE dengan periode bertumpuk pada scope sama ditolak DB":
    let key = fiscalKey
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    let a = $newId(sysClock)
    let b = $newId(sysClock)
    execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, value," &
      " effective_from, effective_to, status, maker, checker, reason) VALUES" &
      " ('" & a & "', '" & key & "', 'GLOBAL', '1'::jsonb, DATE '2026-01-01', DATE '2026-12-31'," &
      " 'ACTIVE', '" & $maker & "', '" & $checker & "', 'satu')")
    var raised = false
    try:
      execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, value," &
        " effective_from, effective_to, status, maker, checker, reason) VALUES" &
        " ('" & b & "', '" & key & "', 'GLOBAL', '2'::jsonb, DATE '2026-06-01', NULL," &
        " 'ACTIVE', '" & $maker & "', '" & $checker & "', 'dua')")
    except DbError as e:
      raised = true
      check e.msg.contains("conflict") or e.msg.contains("exclusion")
    check raised

  test "periode bersambung tanpa tumpang tindih diterima":
    let key = fiscalKey
    let c = $newId(sysClock)
    execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, value," &
      " effective_from, effective_to, status, maker, checker, reason) VALUES" &
      " ('" & c & "', '" & key & "', 'GLOBAL', '3'::jsonb, DATE '2027-01-01', NULL," &
      " 'ACTIVE', '" & $maker & "', '" & $checker & "', 'sambung')")
    check candidatesOf(db, key, "2027-01-01")[0].value.getInt == 3

suite "param: maker-checker":
  test "submit -> PENDING, belum terlihat aplikasi":
    let key = sessionKey
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    # nilai + audit + event dalam satu transaksi (dibungkus pool.withTx)
    let outcome = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      submitChange(d, ctxMaker, sysClock, key, "INSTITUTION", "inst-1", %*45, "2026-01-01", "",
        "penyesuaian kebijakan sesi"))
    check outcome.paramValueId.len > 0
    check outcome.auditHash.len == 64
    check rowStatus(db, outcome.paramValueId) == "PENDING"
    # belum ada nilai ACTIVE -> aplikasi akan menolak (ParamNotFound)
    check candidatesOf(db, key, asOf).len == 0
    # audit + event outbox ditulis di transaksi yang sama
    check countAudit(db) >= 1
    check countByStatus(db, Pending) >= 1

  test "checker menyetujui -> ACTIVE, nilai terlihat, event + NOTIFY terkirim":
    let pending = pendingValues(db)
    check pending.len >= 1
    var target = ""
    for (pvId, key) in pending:
      if key == sessionKey and target.len == 0:
        target = pvId
    check target.len > 0
    let outcome = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      approveChange(d, ctxChecker, sysClock, target))
    check outcome.paramValueId == target
    check rowStatus(db, target) == "ACTIVE"
    let aktif = candidatesOf(db, sessionKey, asOf)
    check aktif.len == 1
    check aktif[0].value.getInt == 45
    check aktif[0].scopeType == pstInstitution
    check countByStatus(db, Done) + countByStatus(db, InFlight) + countByStatus(db, Pending) >= 1

  test "maker tidak boleh menyetujui sendiri (checker = maker ditolak DB)":
    let key = sessionKey
    let submit = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      submitChange(d, ctxMaker, sysClock, key, "INSTITUTION", "inst-2", %*50, "2026-01-01", "",
        "usulan kedua"))
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): ChangeOutcome =
        approveChange(d, ctxMaker, sysClock, submit.paramValueId))
    except DbError as e:
      raised = true
      check e.msg.contains("self_approval") or e.msg.contains("check")
    check raised
    check rowStatus(db, submit.paramValueId) == "PENDING"

  test "balapan dua koneksi (double-approve): tepat satu pemenang (O-040)":
    let key = sessionKey
    let submit = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      submitChange(d, ctxMaker, sysClock, key, "INSTITUTION", "inst-race", %*75, "2026-09-01", "",
        "usulan balapan"))
    raceGate.store(false)
    raceMenang.store(0)
    raceKalah.store(0)
    raceSelesai.store(0)
    var a: Thread[RacerArgs]
    var b: Thread[RacerArgs]
    createThread(a, racer, RacerArgs(pool: dbPool, paramValueId: submit.paramValueId))
    createThread(b, racer, RacerArgs(pool: dbPool, paramValueId: submit.paramValueId))
    raceGate.store(true) # lepaskan keduanya
    joinThread(a)
    joinThread(b)

    check raceSelesai.load() == 2
    check raceMenang.load() == 1
    check raceKalah.load() == 1
    check rowStatus(db, submit.paramValueId) == "ACTIVE"
    # Efek samping hanya sekali: satu audit approve + satu event outbox untuk nilai itu.
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'param.approve' AND resource_id = ?""", submit.paramValueId) == "1"
    check db.getValue(sql"""
      SELECT count(*) FROM platform.outbox WHERE dedup_key = ?""",
      "param.change:" & submit.paramValueId & ":approved") == "1"

  test "approve nilai yang bukan PENDING -> ValueError":
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): ChangeOutcome =
        approveChange(d, ctxChecker, sysClock, $newId(sysClock)))
    except ValueError as e:
      raised = true
      check e.msg.contains("tidak ditemukan")
    check raised

  test "supersede: nilai baru mulai lebih akhir memangkas nilai ACTIVE sebelumnya":
    let key = sessionKey
    let submit = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      submitChange(d, ctxMaker, sysClock, key, "INSTITUTION", "inst-1", %*60, "2026-07-01", "",
        "ubah tengah tahun"))
    discard dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      approveChange(d, ctxChecker, sysClock, submit.paramValueId))

    let lama = candidatesOf(db, key, "2026-06-30")
    check lama.len == 1
    check lama[0].value.getInt == 45
    check lama[0].effectiveTo == "2026-07-01"
    let baru = candidatesOf(db, key, "2026-07-01")
    check baru.len == 1
    check baru[0].value.getInt == 60
    check db.getValue(sql"""
      SELECT count(*) FROM platform.param_value
       WHERE key = ? AND status = 'SUPERSEDED'""", key) == "1"

  test "reject menandai REJECTED dan tidak mengubah nilai aktif":
    let before = candidatesOf(db, sessionKey, asOf)
    let submit = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      submitChange(d, ctxMaker, sysClock, sessionKey, "INSTITUTION", "inst-1", %*70,
        "2026-08-01", "", "usulan ditolak"))
    check rejectValue(db, submit.paramValueId, checker, "tidak sesuai kebijakan")
    check rowStatus(db, submit.paramValueId) == "REJECTED"
    let after = candidatesOf(db, sessionKey, asOf)
    check after.len == before.len
    check after[0].value.getInt == before[0].value.getInt

  test "startup check gagal-cepat: key tanpa nilai aktif dilaporkan":
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", passwordKey)
    let missing = missingActiveKeys(db, [sessionKey, passwordKey, fiscalKey], pstInstitution,
      "inst-1", asOf)
    check missing == @[passwordKey]

  test "aktivasi hanya dari PENDING (penjaga anti double-approve)":
    # Dua checker yang menyetujui nilai yang sama hampir bersamaan: yang kalah tidak boleh
    # menulis ACTIVE kedua kalinya (audit + event ganda, `checker` tertimpa). Penjaganya ada di
    # langkah aktivasi, bukan di pemeriksaan status `approveValue` yang hanya melihat snapshot.
    # Scope baru supaya tidak menabrak EXCLUDE maupun hitungan kandidat test lain.
    let submit = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      submitChange(d, ctxMaker, sysClock, sessionKey, "INSTITUTION", "inst-penjaga", %*70,
        "2026-01-01", "", "uji penjaga aktivasi"))
    check rowStatus(db, submit.paramValueId) == "PENDING"
    check dbPool.withTx(proc(d: DbConn): bool =
      activatePending(d, submit.paramValueId, checker))
    check rowStatus(db, submit.paramValueId) == "ACTIVE"
    # Percobaan berikutnya (simulasi checker yang kalah balapan) tidak boleh mengaku berhasil.
    check not dbPool.withTx(proc(d: DbConn): bool =
      activatePending(d, submit.paramValueId, checker))

suite "param: cache & NOTIFY":
  test "NOTIFY terkirim saat approval, koneksi pendengar menerimanya":
    listenChanges(talker)
    let submit = dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      submitChange(d, ctxMaker, sysClock, passwordKey, "INSTITUTION", "inst-1", %*14,
        "2026-01-01", "", "naikkan panjang minimum"))
    discard dbPool.withTx(proc(d: DbConn): ChangeOutcome =
      approveChange(d, ctxChecker, sysClock, submit.paramValueId))
    let received = pollChanges(talker, timeoutMs = 2_000)
    check received.len >= 1
    check passwordKey in received
    # setelah invalidasi, pembacaan berikutnya melihat nilai baru (tidak ada cache basi di repo)
    let aktif = candidatesOf(db, passwordKey, asOf)
    check aktif.len == 1
    check aktif[0].value.getInt == 14
