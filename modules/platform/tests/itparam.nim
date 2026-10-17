## Test integrasi parameter framework (butuh `KRAN_DATABASE_URL`).
##
## Cakupan kriteria T-005: resolusi PRODUCT→BRANCH→INSTITUTION→SEGMENT→GLOBAL pada `as_of`;
## overlap ACTIVE ditolak EXCLUDE; `ParamNotFound` tanpa fallback; startup check gagal-cepat;
## maker-checker (+ 4-eyes, supersede, reject); audit + event `ParamChanged` di outbox;
## invalidasi cache lewat `LISTEN/NOTIFY`.
##
## Test ini **menghapus schema `platform`** di DB yang ditunjuk `KRAN_DATABASE_URL` (DB dev).

import std/[algorithm, atomics, unittest, os, json, options, strutils]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids, auditcontext, paramkey]
import platform/domain/[authz, event, param]
import platform/infrastructure/[audit_repo, outbox_repo, param_repo]

const
  repoRoot = "."
  sessionKey = "platform.security.session_idle_minutes"
  passwordKey = "platform.security.password_min_length"
  fiscalKey = "platform.calendar.fiscal_year_start_month"
  asOf = "2026-10-13"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itparam: KRAN_DATABASE_URL kosong — dilewati"
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

proc lookup(pairs: seq[(ParamScopeType, string)]): ScopeValueLookup =
  let captured = pairs
  result = proc(scopeType: ParamScopeType): Option[string] =
    for (t, id) in captured:
      if t == scopeType:
        return some(id)
    none(string)

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

suite "param: startup check = visibilitas resolusi (O-057)":
  test "nilai ber-id konkret tidak menyelamatkan pemanggil id kosong (bukan wildcard)":
    # Aturan lama memperlakukan `scopeId` kosong sebagai wildcard: kandidat `INSTITUTION:<id apa
    # pun>` dianggap memenuhi. Resolusi tidak begitu (`some("")` hanya cocok dengan `scope_id`
    # NULL), jadi key ini sebenarnya tidak terlihat oleh institusi akar.
    let key = fiscalKey
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    let pvId = $newId(sysClock)
    execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, scope_id," &
      " value, effective_from, status, maker, checker, reason) VALUES ('" & pvId & "', '" & key &
      "', 'INSTITUTION', 'inst-lain', '2'::jsonb, DATE '2026-01-01', 'ACTIVE', '" & $maker &
      "', '" & $checker & "', 'uji O-057')")
    # Resolusi untuk institusi akar (id kosong) tidak melihat nilai ber-id konkret…
    check resolveCandidate(candidatesOf(db, key, asOf),
      lookup(@[(pstInstitution, "")])).isNone
    # …jadi startup check harus setuju. Uji ini GAGAL pada aturan lama (dulu lolos).
    check missingActiveKeys(db, [key], pstInstitution, "", asOf) == @[key]
    # Pemanggil dengan id yang sama melihatnya: bedanya "id beda", bukan "tidak ada nilai".
    check missingActiveKeys(db, [key], pstInstitution, "inst-lain", asOf).len == 0

  test "nilai GLOBAL tetap memenuhi level mana pun (sama dengan resolusi)":
    let key = fiscalKey
    exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    let pvId = $newId(sysClock)
    execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, value," &
      " effective_from, status, maker, checker, reason) VALUES ('" & pvId & "', '" & key &
      "', 'GLOBAL', '1'::jsonb, DATE '2026-01-01', 'ACTIVE', '" & $maker & "', '" & $checker &
      "', 'uji GLOBAL')")
    # `resolveCandidate` selalu mencocokkan GLOBAL, apa pun scope pemanggil — startup check ikut.
    check missingActiveKeys(db, [key], pstInstitution, "inst-1", asOf).len == 0
    check missingActiveKeys(db, [key], pstBranch, "br-1", asOf).len == 0
    check missingActiveKeys(db, [key], pstInstitution, "", asOf).len == 0

suite "param: visibilitas daftar per scope (O-032, D-046 butir 6)":
  ## Aturan wewenangnya murni ada di `platform/domain/authz` (diuji di `tauthz`); yang dibuktikan di
  ## sini adalah terjemahannya ke SQL pada `paramValueRows`: baris di luar wewenang tidak muncul dan
  ## tidak memakan jatah `LIMIT`.
  const
    keyCabang = "platform.calendar.weekend_days"  # allowed_scopes: GLOBAL, BRANCH
    keyInstitusi = "platform.realtime.max_topics" # allowed_scopes: GLOBAL, INSTITUTION
    izin = "platform.param.read"
    cabangA = "uji-cabang-a"
    cabangB = "uji-cabang-b"

  proc baris(key, scope, scopeId, value: string) =
    let pvId = $newId(sysClock)
    let scopeIdCol = if scopeId.len == 0: "NULL" else: "'" & scopeId & "'"
    execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, scope_id," &
      " value, effective_from, status, maker, checker, reason) VALUES ('" & pvId & "', '" & key &
      "', '" & scope & "', " & scopeIdCol & ", '" & value & "'::jsonb, DATE '2026-01-01'," &
      " 'ACTIVE', '" & $maker & "', '" & $checker & "', 'uji visibilitas')")

  proc itemsFor(key: string, grants: seq[Grant]): seq[string] =
    ## Bentuk `scopeType:scopeId` yang terlihat pemegang `grants`, terurut supaya assertion-nya
    ## tidak bergantung urutan baris.
    for row in paramValueRows(db, "", 200, readableScopeFilter(grants, izin)):
      if row.key == key:
        result.add row.scopeType & ":" & row.scopeId
    result.sort()

  test "GLOBAL selalu ikut; INSTITUTION & BRANCH mengikuti grant pembaca":
    for key in [keyCabang, keyInstitusi]:
      exec(db, sql"DELETE FROM platform.param_value WHERE key = ?", key)
    baris(keyCabang, "GLOBAL", "", "[6, 7]")
    baris(keyInstitusi, "GLOBAL", "", "5")
    baris(keyCabang, "BRANCH", cabangA, "[5, 6]")
    baris(keyCabang, "BRANCH", cabangB, "[4, 5]")
    baris(keyInstitusi, "INSTITUTION", "uji-inst-1", "7")
    # Baris yang seharusnya tidak pernah lolos `allowed_scopes`: dibuktikan tetap gagal-tertutup,
    # supaya scope tanpa model keanggotaan (D-055) tidak bocor lewat jalur data.
    baris(keyCabang, "PRODUCT", "uji-produk-1", "[6, 0]")

    # Tanpa grant: hanya nilai GLOBAL.
    check itemsFor(keyCabang, @[]) == @["GLOBAL:"]
    check itemsFor(keyInstitusi, @[]) == @["GLOBAL:"]

    # Grant khusus cabang A: GLOBAL + cabang A. INSTITUTION butuh grant tanpa batas cabang,
    # dan PRODUCT tetap tidak terlihat siapa pun.
    let grantCabang = @[Grant(roleCode: "param_maker", branchId: cabangA, permission: izin)]
    check itemsFor(keyCabang, grantCabang) == @["BRANCH:" & cabangA, "GLOBAL:"]
    check itemsFor(keyInstitusi, grantCabang) == @["GLOBAL:"]

    # Grant tanpa batas cabang: semua scope yang punya model keanggotaan.
    let grantSemua = @[Grant(roleCode: "platform_admin", branchId: "", permission: izin)]
    check itemsFor(keyCabang, grantSemua) ==
      @["BRANCH:" & cabangA, "BRANCH:" & cabangB, "GLOBAL:"]
    check itemsFor(keyInstitusi, grantSemua) == @["GLOBAL:", "INSTITUTION:uji-inst-1"]

  test "baris di luar wewenang tidak memakan jatah LIMIT":
    # Baris terbaru di tabel adalah nilai PRODUCT di atas (tidak terlihat siapa pun). Kalau
    # penyaringan dilakukan setelah `LIMIT`, permintaan ber-limit 1 akan menerima halaman kosong.
    let grantCabang = @[Grant(roleCode: "param_maker", branchId: cabangA, permission: izin)]
    let terlihat = paramValueRows(db, "", 1, readableScopeFilter(grantCabang, izin))
    check terlihat.len == 1
    for row in terlihat:
      check row.scopeType != "PRODUCT"

suite "param: effectiveTo tanpa penerus (O-043, D-046 butir 8)":
  ## Vonis `effectiveToGapProblem` atas keadaan DB. Yang paling penting di sini adalah kasus yang
  ## **akan** berubah saat persetujuan: nilai ACTIVE yang masih terbuka tidak menolong, sebab
  ## persetujuan kandidat justru memangkas nilai itu (`supersedePreviousValues`) dan meninggalkan
  ## tanggal setelah `effectiveTo` tanpa nilai. Kalau batas `effective_from >= kandidat` dilepas,
  ## test "nilai lama yang masih terbuka" di bawah ini gagal.
  const
    keyAkhir = "platform.calendar.weekend_days" # allowed_scopes: GLOBAL, BRANCH

  proc sisip(cabang, status, fromDate: string, toDate = ""): string =
    ## Baris langsung lewat SQL: yang diuji adalah vonis periode atas keadaan tertentu, bukan alur
    ## pengajuan (alur itu diuji lewat HTTP — `itapi_auth`).
    let pvId = $newId(sysClock)
    let toCol = if toDate.len == 0: "NULL" else: "DATE '" & toDate & "'"
    # Baris ACTIVE/SUPERSEDED wajib punya `checker` (4-eyes, `param_value_checker_chk`).
    let checkerCol = if status == "ACTIVE" or status == "SUPERSEDED": "'" & $checker & "'"
                     else: "NULL"
    execScript(db, "INSERT INTO platform.param_value (param_value_id, key, scope_type, scope_id," &
      " value, effective_from, effective_to, status, maker, checker, reason) VALUES ('" & pvId &
      "', '" & keyAkhir & "', 'BRANCH', '" & cabang & "', '[6, 7]'::jsonb, DATE '" & fromDate &
      "', " & toCol & ", '" & status & "', '" & $maker & "', " & checkerCol & ", 'uji periode')")
    pvId

  test "periode terbuka (tanpa effectiveTo) tidak pernah butuh penerus":
    check effectiveToGapProblem(db, keyAkhir, "BRANCH", "uji-akhir-terbuka", "2026-03-01",
      "").len == 0

  test "nilai lama yang masih terbuka bukan penerus — persetujuan justru memangkasnya":
    discard sisip("uji-akhir-pangkas", "ACTIVE", "2026-01-01")
    let problem = effectiveToGapProblem(db, keyAkhir, "BRANCH", "uji-akhir-pangkas", "2026-03-01",
      "2026-04-01")
    check problem.len > 0
    check "tidak punya penerus" in problem

  test "penerus PENDING yang mulai tepat di effectiveTo menutup periode":
    # Inilah urutan yang sah: penerus diajukan lebih dulu (ia belum bisa disetujui, sebab nilai
    # lama yang terbuka akan bersinggungan dengannya), lalu nilai terbatas, lalu keduanya.
    discard sisip("uji-akhir-penerus", "ACTIVE", "2026-01-01")
    discard sisip("uji-akhir-penerus", "PENDING", "2026-04-01")
    check effectiveToGapProblem(db, keyAkhir, "BRANCH", "uji-akhir-penerus", "2026-03-01",
      "2026-04-01").len == 0

  test "penerus yang mulai setelah effectiveTo tidak menutup periode":
    discard sisip("uji-akhir-celah", "ACTIVE", "2026-01-01")
    discard sisip("uji-akhir-celah", "PENDING", "2026-05-01")
    let problem = effectiveToGapProblem(db, keyAkhir, "BRANCH", "uji-akhir-celah", "2026-03-01",
      "2026-04-01")
    check problem.len > 0

  test "penerus harus di (key, scope) yang sama":
    discard sisip("uji-akhir-lain", "PENDING", "2026-04-01")
    let problem = effectiveToGapProblem(db, keyAkhir, "BRANCH", "uji-akhir-scope-lain",
      "2026-03-01",
      "2026-04-01")
    check problem.len > 0
