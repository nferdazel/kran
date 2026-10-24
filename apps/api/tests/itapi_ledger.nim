## Test integrasi HTTP `ledger` COA & periode (T-072) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan lewat jalur penuh: sesi & izin menyetir 401/403, kode COA divalidasi dari
## parameter (bukan konstanta), duplikat & tumpang tindih periode → 409, tutup periode menulis
## audit + event, dan konfigurasi pola yang rusak dijawab 500 (bukan 400).
##
## Test ini menghapus **semua schema modul** di DB dev (`resetTestSchemas`) lalu menyiapkan ulang
## migrasi,
## seed pack, seed pengguna dev, dan satu pemberian `platform_admin` untuk `dev.maker`.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, money, result]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  CoaPath = "/api/v1/ledger/coa"
  PeriodsPath = "/api/v1/ledger/periods"
  ClosePath = "/api/v1/ledger/periods/{periodId}/close"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_ledger: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.maker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

var app = AppContext(version: "itapi-ledger-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: systemClock(), readiness: databaseProbe())

type
  ServeArgs = object
    server: Server
    port: int

var
  serverThread: Thread[ServeArgs]
  baseUrl = ""

proc freePort(): int =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = int(socket.getLocalAddr()[1])
  socket.close()

proc serveInThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard # proses test berakhir dengan sendirinya (lihat O-025)

proc startServer(a: AppContext): string =
  let port = freePort()
  let server = newApiServer(a)
  createThread(serverThread, serveInThread, ServeArgs(server: server, port: port))
  result = "http://127.0.0.1:" & $port
  let deadline = epochTime() + 10.0
  var up = false
  while epochTime() < deadline and not up:
    try:
      let probe = newHttpClient(timeout = 1000)
      defer: probe.close()
      up = probe.get(result & "/healthz").code.int == 200
    except CatchableError:
      discard
    if not up:
      sleep(50)
  doAssert up, "server test tidak pernah siap"

block:
  baseUrl = startServer(app)

type
  CloseRaceArgs = object
    url: string
    path: string
    token: string

var
  closeRaceCode = 0
  closeRaceBody = ""

proc closeRaceWorker(args: CloseRaceArgs) {.thread.} =
  ## Menjalankan penutupan periode lewat HTTP dari thread lain supaya test bisa menahan lock baris
  ## di antara SELECT dan UPDATE handler (O-076).
  let client = newHttpClient(timeout = 20000)
  try:
    client.headers["Cookie"] = CookieName & "=" & args.token
    client.headers["Content-Type"] = "application/json"
    let response = client.post(args.url & args.path, $ %*{"reason": "balapan tutup"})
    {.cast(gcsafe).}:
      closeRaceCode = response.code.int
      closeRaceBody = response.body
  except CatchableError as e:
    {.cast(gcsafe).}:
      closeRaceCode = -1
      closeRaceBody = e.msg
  finally:
    client.close()

type
  Reply = object
    code: int
    raw: string
    body: JsonNode
    setCookie: string

proc call(verb, path, payload, token: string): Reply =
  let client = newHttpClient(timeout = 15000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
  var response: Response
  if verb == "GET":
    response = client.get(baseUrl & path)
  else:
    if payload.len > 0:
      client.headers["Content-Type"] = "application/json"
    response = client.post(baseUrl & path, payload)
  result.code = response.code.int
  result.raw = response.body
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  result.body = newJNull()
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

proc getJson(path: string, token = ""): Reply =
  call("GET", path, "", token)

proc postJson(path: string, payload: JsonNode, token = ""): Reply =
  call("POST", path, $payload, token)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc login(username: string, password = DevPassword): Reply =
  postJson(LoginPath, %*{"username": username, "password": password})

proc checkJson(path, verb, status: string, body: JsonNode) =
  let problems = contract.validateValue(contract.responseSchema(path, verb, status), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc checkProblem(path, verb, status: string, body: JsonNode) =
  let problems = contract.validateValue(
    contract.responseSchema(path, verb, status, "application/problem+json"), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc dbValue(query: SqlQuery, args: varargs[string, `$`]): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args)
  finally:
    dbPool.release(conn)

let maker = login(MakerUser)
doAssert maker.code == 200, "login dev.maker gagal — seed dev terpasang?"
let makerToken = tokenOf(maker)
let checkerToken = tokenOf(login(CheckerUser))

suite "ledger: autentikasi & izin":
  test "tanpa sesi → 401":
    check getJson(CoaPath).code == 401
    check getJson(PeriodsPath).code == 401
    check postJson(CoaPath, %*{"code": "9", "name": "Uji", "accountType": "ASSET"}).code == 401
    check postJson(PeriodsPath, %*{"startsOn": "2027-01-01", "endsOn": "2027-01-31"}).code == 401

  test "pemegang izin lain → 403":
    let create = postJson(CoaPath, %*{"code": "9001", "name": "Akun Uji",
      "accountType": "ASSET"}, checkerToken)
    check create.code == 403
    checkProblem(CoaPath, "POST", "403", create.body)
    check getJson(CoaPath, checkerToken).code == 403

suite "ledger: COA":
  test "daftar akun dari seed migrasi + filter":
    let all = getJson(CoaPath, makerToken)
    check all.code == 200
    checkJson(CoaPath, "GET", "200", all.body)
    check all.body["items"].len >= 15

    var hasKas = false
    var hasKasTeller = false
    for item in all.body["items"]:
      if item["code"].getStr() == "101":
        hasKas = true
        check item["name"].getStr() == "KAS"
        check item["accountType"].getStr() == "ASSET"
        check item["normalSide"].getStr() == "DEBIT"
        # `101 KAS` menjadi induk non-postable sejak migrasi 0033 (T-118).
        check not item["postable"].getBool()
      elif item["code"].getStr() == "101.2":
        hasKasTeller = true
        check item["name"].getStr() == "KAS DI TELLER"
        check item["postable"].getBool()
    check hasKas
    check hasKasTeller

    let assets = getJson(CoaPath & "?type=asset", makerToken)
    check assets.code == 200
    checkJson(CoaPath, "GET", "200", assets.body)
    for item in assets.body["items"]:
      check item["accountType"].getStr() == "ASSET"

    let headers = getJson(CoaPath & "?postable=false", makerToken)
    check headers.code == 200
    for item in headers.body["items"]:
      check not item["postable"].getBool()

    let badFilter = getJson(CoaPath & "?type=ASET", makerToken)
    check badFilter.code == 400
    checkProblem(CoaPath, "GET", "400", badFilter.body)

  test "buat akun: sisi normal diturunkan, kode duplikat 409":
    let created = postJson(CoaPath, %*{"code": "120", "name": "PIUTANG LAIN-LAIN",
      "accountType": "ASSET"}, makerToken)
    check created.code == 201
    checkJson(CoaPath, "POST", "201", created.body)
    check created.body["code"].getStr() == "120"
    check created.body["normalSide"].getStr() == "DEBIT"
    check created.body["status"].getStr() == "ACTIVE"

    let duplicate = postJson(CoaPath, %*{"code": "120", "name": "DUPLIKAT",
      "accountType": "ASSET"}, makerToken)
    check duplicate.code == 409
    checkProblem(CoaPath, "POST", "409", duplicate.body)

    let header = postJson(CoaPath, %*{"code": "6", "name": "PENDAPATAN LAIN",
      "accountType": "REVENUE", "postable": false}, makerToken)
    check header.code == 201
    check not header.body["postable"].getBool()
    check header.body["normalSide"].getStr() == "CREDIT"

    # Audit penulisan COA benar-benar tercatat (bukan hanya klaim di dokumen).
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.coa.create' AND resource_id = ?""",
      created.body["accountId"].getStr()) == "1"

  test "kode tidak cocok pola parameter → 400":
    let bad = postJson(CoaPath, %*{"code": "ABC-1", "name": "KODE SALAH",
      "accountType": "ASSET"}, makerToken)
    check bad.code == 400
    checkProblem(CoaPath, "POST", "400", bad.body)

    let badType = postJson(CoaPath, %*{"code": "130", "name": "TIPE SALAH",
      "accountType": "ASET"}, makerToken)
    check badType.code == 400
    checkProblem(CoaPath, "POST", "400", badType.body)

  test "pola parameter rusak → 500, bukan 400":
    # Nilai asli diambil dulu supaya pemulihan tidak bergantung pada penulisan ulang escape regex.
    let original = dbValue(sql"""
      SELECT value::text FROM platform.param_value WHERE key = 'ledger.coa.code_pattern'""")
    let conn = dbPool.acquire()
    try:
      conn.exec(sql"""
        UPDATE platform.param_value SET value = '"("'::jsonb
         WHERE key = 'ledger.coa.code_pattern'""")
      let reply = postJson(CoaPath, %*{"code": "140", "name": "AKUN POLA RUSAK",
        "accountType": "ASSET"}, makerToken)
      check reply.code == 500
      checkProblem(CoaPath, "POST", "500", reply.body)
      # Pesan menyebut parameter yang harus diperiksa, tanpa memuat nilainya.
      check reply.body["detail"].getStr().contains("ledger")
    finally:
      conn.exec(sql"""
        UPDATE platform.param_value SET value = ?::jsonb
         WHERE key = 'ledger.coa.code_pattern'""", original)
      dbPool.release(conn)

    # Pola pulih → jalur normal jalan lagi.
    let ok = postJson(CoaPath, %*{"code": "140", "name": "AKUN POLA PULIH",
      "accountType": "ASSET"}, makerToken)
    check ok.code == 201

suite "ledger: periode":
  test "buka periode: tersimpan, tumpang tindih 409, tanggal salah 400":
    let opened = postJson(PeriodsPath, %*{"startsOn": "2026-01-01", "endsOn": "2026-01-31"},
      makerToken)
    check opened.code == 201
    checkJson(PeriodsPath, "POST", "201", opened.body)
    check opened.body["status"].getStr() == "OPEN"
    check opened.body["closedAt"].kind == JNull
    check opened.body["closedBy"].kind == JNull

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.period.open' AND resource_id = ?""",
      opened.body["periodId"].getStr()) == "1"

    let overlap = postJson(PeriodsPath, %*{"startsOn": "2026-01-15", "endsOn": "2026-02-15"},
      makerToken)
    check overlap.code == 409
    checkProblem(PeriodsPath, "POST", "409", overlap.body)

    let reversed = postJson(PeriodsPath, %*{"startsOn": "2026-03-31", "endsOn": "2026-03-01"},
      makerToken)
    check reversed.code == 400
    checkProblem(PeriodsPath, "POST", "400", reversed.body)

    let badDate = postJson(PeriodsPath, %*{"startsOn": "2026-02-31", "endsOn": "2026-02-28"},
      makerToken)
    check badDate.code == 400
    checkProblem(PeriodsPath, "POST", "400", badDate.body)

    let list = getJson(PeriodsPath, makerToken)
    check list.code == 200
    checkJson(PeriodsPath, "GET", "200", list.body)
    check list.body["items"].len == 1

  test "tutup periode menulis audit + event, ulangan 409":
    let list = getJson(PeriodsPath, makerToken)
    let periodId = list.body["items"][0]["periodId"].getStr()
    let path = ClosePath.replace("{periodId}", periodId)

    let noReason = postJson(path, %*{"reason": "  "}, makerToken)
    check noReason.code == 400
    checkProblem(ClosePath, "POST", "400", noReason.body)

    let closed = postJson(path, %*{"reason": "tutup Januari 2026"}, makerToken)
    check closed.code == 200
    checkJson(ClosePath, "POST", "200", closed.body)
    check closed.body["status"].getStr() == "CLOSED"
    check closed.body["closedAt"].getStr().len >= 20
    check closed.body["closedBy"].getStr().len == 36

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.period.close' AND resource_id = ?""", periodId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.period.close' AND reason = ?""", "tutup Januari 2026") == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'period.closed' AND aggregate_id = ?""", periodId) == "1"

    let again = postJson(path, %*{"reason": "ulang"}, makerToken)
    check again.code == 409
    checkProblem(ClosePath, "POST", "409", again.body)
    # Percobaan yang kalah **tidak** boleh menambah audit/event kedua.
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.period.close' AND resource_id = ?""", periodId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'period.closed' AND aggregate_id = ?""", periodId) == "1"

  test "kalah balapan tutup periode → 409 dari guard UPDATE 0 baris, tanpa audit/event":
    let opened = postJson(PeriodsPath, %*{"startsOn": "2026-02-01", "endsOn": "2026-02-28"},
      makerToken)
    check opened.code == 201
    let periodId = opened.body["periodId"].getStr()
    let path = ClosePath.replace("{periodId}", periodId)

    # Kunci baris periode dari transaksi kedua. Handler boleh membaca OPEN (plain SELECT), tetapi
    # UPDATE `WHERE status = 'OPEN'` akan menunggu — persis jendela balapan yang dijaga guard.
    let side = dbPool.acquire()
    defer: dbPool.release(side)
    exec(side, sql"BEGIN")
    discard side.getValue(
      sql"SELECT 1 FROM ledger.period WHERE period_id = ?::uuid FOR UPDATE", periodId)
    let sidePid = side.getValue(sql"SELECT pg_backend_pid()")

    closeRaceCode = 0
    closeRaceBody = ""
    var worker: Thread[CloseRaceArgs]
    createThread(worker, closeRaceWorker, CloseRaceArgs(url: baseUrl, path: path,
        token: makerToken))

    var blocked = false
    let deadline = epochTime() + 10.0
    while epochTime() < deadline and not blocked:
      # Scope ke sesi ini: backend yang menunggu **diblokir oleh koneksi `side`**, bukan sesi lain.
      blocked = dbValue(sql"""
        SELECT count(*)::text FROM pg_stat_activity
         WHERE datname = current_database() AND pid <> pg_backend_pid()
           AND wait_event_type = 'Lock'
           AND ?::int = ANY(pg_blocking_pids(pid))""", sidePid) != "0"
      if not blocked:
        sleep(20)

    # Transaksi kedua menutup periode lebih dulu, lalu melepas kunci: UPDATE handler dievaluasi
    # ulang, melihat status CLOSED, mengenai 0 baris.
    exec(side, sql"""
      UPDATE ledger.period
         SET status = 'CLOSED', closed_at = now(),
             closed_by = (SELECT user_id FROM platform.app_user WHERE username = 'dev.maker'),
             updated_at = now(),
             updated_by = (SELECT user_id FROM platform.app_user WHERE username = 'dev.maker')
       WHERE period_id = ?::uuid""", periodId)
    exec(side, sql"COMMIT")
    joinThread(worker)

    check blocked
    check closeRaceCode == 409
    check parseJson(closeRaceBody)["title"].getStr().len > 0
    # Yang kalah tidak boleh menulis audit/event kedua untuk periode ini.
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.period.close' AND resource_id = ?""", periodId) == "0"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'period.closed' AND aggregate_id = ?""", periodId) == "0"

    # Bersihkan periode latihan: CLOSED tanpa `period.closed`/audit tidak mungkin di produksi dan
    # bisa mematahkan invarian yang ditambahkan nanti.
    let bersih = dbPool.acquire()
    try:
      exec(bersih, sql"DELETE FROM ledger.period WHERE period_id = ?::uuid", periodId)
    finally:
      dbPool.release(bersih)

    let missing = postJson(ClosePath.replace("{periodId}", "88888888-8888-7888-8888-888888888888"),
      %*{"reason": "tidak ada"}, makerToken)
    check missing.code == 404
    checkProblem(ClosePath, "POST", "404", missing.body)

proc ensurePeriod(startsOn, endsOn: string): string =
  ## Buka periode langsung di DB; yang diuji di suite ini laporan, bukan pembukaan periode.
  dbValue(sql"""
    INSERT INTO ledger.period
      (period_id, starts_on, ends_on, status, created_by, updated_by)
    VALUES
      (gen_random_uuid(), ?::date, ?::date, 'OPEN',
       '00000000-0000-0000-0000-0000000000a1',
       '00000000-0000-0000-0000-0000000000a1')
    RETURNING period_id::text""", startsOn, endsOn)

let
  mayPeriod = ensurePeriod("2026-05-01", "2026-05-31")
  julyPeriod = ensurePeriod("2026-07-01", "2026-07-31")

suite "ledger: grant bercabang tidak boleh aksi institusi":
  test "grant yang dibatasi cabang → 403; grant tanpa batas → 200":
    # D-062: aksi tingkat institusi (`targetBranch = ""`) hanya untuk grant tanpa batas cabang.
    # `requirePermission` sendiri tidak membedakan grant bercabang, jadi gerbang kedua
    # (`authorizedAtBranch`) yang harus menolak — inilah yang diuji di sini.
    let conn = dbPool.acquire()
    try:
      conn.exec(sql"""
        UPDATE platform.user_role ur SET branch_id = 'cabang-uji'
          FROM platform.app_user u, platform.role r
         WHERE ur.user_id = u.user_id AND ur.role_id = r.role_id
           AND u.username = 'dev.maker' AND r.code = 'platform_admin'""")

      let listCoa = getJson(CoaPath, makerToken)
      check listCoa.code == 403
      checkProblem(CoaPath, "GET", "403", listCoa.body)
      check listCoa.body["params"]["reason"].getStr() == "branch_not_allowed"

      let create = postJson(CoaPath, %*{"code": "150", "name": "AKUN CABANG",
        "accountType": "ASSET"}, makerToken)
      check create.code == 403
      checkProblem(CoaPath, "POST", "403", create.body)
      check dbValue(sql"""
        SELECT count(*)::text FROM platform.audit_log
         WHERE action = 'ledger.coa.create' AND after_value->>'code' = '150'""") == "0"

      let open = postJson(PeriodsPath, %*{"startsOn": "2027-01-01", "endsOn": "2027-01-31"},
        makerToken)
      check open.code == 403
      checkProblem(PeriodsPath, "POST", "403", open.body)
      check open.body["params"]["permission"].getStr() == "ledger.period.manage"

      let listPeriods = getJson(PeriodsPath, makerToken)
      check listPeriods.code == 403
      let balances = getJson("/api/v1/ledger/balances?periodId=" & mayPeriod, makerToken)
      check balances.code == 403
      checkProblem("/api/v1/ledger/balances", "GET", "403", balances.body)
      check balances.body["params"]["reason"].getStr() == "branch_not_allowed"
    finally:
      conn.exec(sql"""
        UPDATE platform.user_role ur SET branch_id = NULL
          FROM platform.app_user u, platform.role r
         WHERE ur.user_id = u.user_id AND ur.role_id = r.role_id
           AND u.username = 'dev.maker' AND r.code = 'platform_admin'""")
      dbPool.release(conn)

    # Grant tanpa batas pulih → jalur normal jalan lagi.
    check getJson(CoaPath, makerToken).code == 200

# ==== T-082: laporan saldo GL (opening/period/closing) ====

const BalancesPath = "/api/v1/ledger/balances"

proc asMoney(s: string): Money =
  let r = moneyFromString(s)
  doAssert r.isOk, "desimal tidak sah dari API: " & s
  r.value()

proc lineOf(body: JsonNode, code: string): JsonNode =
  for item in body["lines"]:
    if item["accountCode"].getStr() == code:
      return item
  newJNull()



proc postJournal(businessDate, debitAccount, creditAccount, amount: string) =
  ## Satu jurnal seimbang. Header + baris dalam **satu transaksi** (trigger keseimbangan
  ## deferred + penjaga `xmin` migrasi 0008).
  let conn = dbPool.acquire()
  try:
    exec(conn, sql"BEGIN")
    let jid = conn.getValue(sql"""
      INSERT INTO ledger.journal
        (journal_id, business_date, value_date, source_event, source_ref,
         idempotency_key, created_by)
      VALUES
        (gen_random_uuid(), ?::date, ?::date, 'BalancesTest', gen_random_uuid(),
         gen_random_uuid()::text, '00000000-0000-0000-0000-0000000000a1')
      RETURNING journal_id::text""", businessDate, businessDate)
    exec(conn, sql"""
      INSERT INTO ledger.journal_line
        (journal_id, line_no, gl_account, branch_id, debit, credit)
      VALUES
        (?::uuid, 1, ?, '11111111-1111-7111-8111-111111111111', ?::numeric, 0),
        (?::uuid, 2, ?, '11111111-1111-7111-8111-111111111111', 0, ?::numeric)""",
      jid, debitAccount, amount, jid, creditAccount, amount)
    exec(conn, sql"COMMIT")
  except DbError:
    exec(conn, sql"ROLLBACK")
    raise
  finally:
    dbPool.release(conn)

proc rebuildSnapshotAt(asOf: string) =
  let conn = dbPool.acquire()
  try:
    discard conn.getValue(sql"SELECT ledger.rebuild_balance_snapshot(?::date)", asOf)
  finally:
    dbPool.release(conn)

block:
  # April: saldo awal periode Mei (periode lain, tetap OPEN).
  discard ensurePeriod("2026-04-01", "2026-04-30")
  postJournal("2026-04-10", "101.2", "201", "1000.00")
  postJournal("2026-04-20", "102", "201", "200.00")
  # Mei: mutasi di hari pertama & terakhir periode (batas inklusif).
  postJournal("2026-05-01", "101.2", "201", "100.00")
  postJournal("2026-05-31", "101.2", "201", "50.00")
  # Juni: di luar periode Mei → tidak boleh masuk closing Mei.
  discard ensurePeriod("2026-06-01", "2026-06-30")
  postJournal("2026-06-01", "101.2", "201", "9999.00")
  # Juli: untuk jalur snapshot saat periode CLOSED.
  postJournal("2026-07-05", "101.2", "201", "300.00")

suite "ledger: laporan saldo GL (T-082)":
  test "tanpa sesi → 401, tanpa izin → 403, periodId bentuk salah → 400":
    check getJson(BalancesPath & "?periodId=" & mayPeriod).code == 401

    let forbidden = getJson(BalancesPath & "?periodId=" & mayPeriod, checkerToken)
    check forbidden.code == 403
    checkProblem(BalancesPath, "GET", "403", forbidden.body)

    let bad = getJson(BalancesPath & "?periodId=bukan-uuid", makerToken)
    check bad.code == 400
    checkProblem(BalancesPath, "GET", "400", bad.body)

  test "periode tidak ada → 404 problem":
    let missing = getJson(BalancesPath &
      "?periodId=88888888-8888-7888-8888-888888888888", makerToken)
    check missing.code == 404
    checkProblem(BalancesPath, "GET", "404", missing.body)

  test "batas inklusif + akun tanpa mutasi ber-saldo-awal + akun kosong absen":
    let reply = getJson(BalancesPath & "?periodId=" & mayPeriod, makerToken)
    check reply.code == 200
    checkJson(BalancesPath, "GET", "200", reply.body)
    check reply.body["periodId"].getStr() == mayPeriod
    check reply.body["startsOn"].getStr() == "2026-05-01"
    check reply.body["endsOn"].getStr() == "2026-05-31"
    check reply.body["source"].getStr() == "ledger"
    check reply.body["computedAt"].getStr().endsWith("Z")
    check reply.body["computedAt"].getStr().len >= 20

    # 01/05 + 31/05 keduanya ikut (inklusif); 01/06 tidak.
    let kas = lineOf(reply.body, "101.2")
    check kas.kind == JObject
    check kas["openingDebit"].getStr() == "1000.00"
    check kas["openingCredit"].getStr() == "0.00"
    check kas["periodDebit"].getStr() == "150.00"
    check kas["periodCredit"].getStr() == "0.00"
    check kas["closingDebit"].getStr() == "1150.00"
    check kas["closingCredit"].getStr() == "0.00"

    # 201 hanya bergerak di sisi kredit.
    let simpanan = lineOf(reply.body, "201")
    check simpanan.kind == JObject
    check simpanan["openingCredit"].getStr() == "1200.00"
    check simpanan["periodCredit"].getStr() == "150.00"
    check simpanan["closingCredit"].getStr() == "1350.00"

    # 102 tidak bergerak di Mei tetapi saldo awalnya ≠ 0 → wajib tampil.
    let bank = lineOf(reply.body, "102")
    check bank.kind == JObject
    check bank["openingDebit"].getStr() == "200.00"
    check bank["periodDebit"].getStr() == "0.00"
    check bank["closingDebit"].getStr() == "200.00"

    # Akun yang tidak pernah dipakai tidak tampil.
    check lineOf(reply.body, "501").kind == JNull

  test "total opening + mutasi = closing (per akun dan menyeluruh)":
    let reply = getJson(BalancesPath & "?periodId=" & mayPeriod, makerToken)
    check reply.code == 200
    var sumOpenD, sumOpenC, sumPeriodD, sumPeriodC, sumCloseD, sumCloseC: Money
    for l in reply.body["lines"]:
      let openD = asMoney(l["openingDebit"].getStr())
      let openC = asMoney(l["openingCredit"].getStr())
      let periodD = asMoney(l["periodDebit"].getStr())
      let periodC = asMoney(l["periodCredit"].getStr())
      let closeD = asMoney(l["closingDebit"].getStr())
      let closeC = asMoney(l["closingCredit"].getStr())
      check closeD == openD + periodD
      check closeC == openC + periodC
      sumOpenD = sumOpenD + openD
      sumOpenC = sumOpenC + openC
      sumPeriodD = sumPeriodD + periodD
      sumPeriodC = sumPeriodC + periodC
      sumCloseD = sumCloseD + closeD
      sumCloseC = sumCloseC + closeC
    check sumOpenD == sumOpenC # neraca saldo awal seimbang
    check sumPeriodD == sumPeriodC
    check sumCloseD == sumCloseC
    check sumCloseD == sumOpenD + sumPeriodD
    # Mutasi periode laporan = mutasi trial balance periode yang sama.
    let tb = getJson("/api/v1/ledger/trial-balance?periodId=" & mayPeriod, makerToken)
    check tb.code == 200
    check asMoney(tb.body["totalDebit"].getStr()) == sumPeriodD

  test "periode CLOSED memakai snapshot; periode OPEN mengabaikannya":
    # Snapshot dibangun saat periode masih OPEN → tetap dihitung dari jurnal (`source=ledger`).
    rebuildSnapshotAt("2026-07-31")
    let openReply = getJson(BalancesPath & "?periodId=" & julyPeriod, makerToken)
    check openReply.code == 200
    check openReply.body["source"].getStr() == "ledger"

    # Tutup periode lalu baca lagi: snapshot terekonsiliasi → `source=snapshot`.
    let closed = postJson(ClosePath.replace("{periodId}", julyPeriod),
      %*{"reason": "tutup Juli 2026 (test saldo)"}, makerToken)
    check closed.code == 200
    check closed.body["status"].getStr() == "CLOSED"

    let closedReply = getJson(BalancesPath & "?periodId=" & julyPeriod, makerToken)
    check closedReply.code == 200
    checkJson(BalancesPath, "GET", "200", closedReply.body)
    check closedReply.body["source"].getStr() == "snapshot"
    check closedReply.body["computedAt"].getStr().endsWith("Z")
    # Angka tetap benar: 101.2 kumulatif s.d. 31 Juli = 1000 + 150 + 9999 + 300.
    let kas = lineOf(closedReply.body, "101.2")
    check kas.kind == JObject
    check kas["closingDebit"].getStr() == "11449.00"
    check asMoney(kas["closingDebit"].getStr()) ==
      asMoney(kas["openingDebit"].getStr()) + asMoney(kas["periodDebit"].getStr())

  test "snapshot basi ditolak: jurnal backdated setelah CLOSED → source=ledger":
    # Prasyarat: test sebelumnya menutup Juli dan cache 31 Juli cocok dengan jurnal.
    # Jurnal ke April (periode OPEN) mengubah saldo awal Juli, jadi cache tidak lagi sah.
    postJournal("2026-04-15", "101.2", "201", "77.00")

    let reply = getJson(BalancesPath & "?periodId=" & julyPeriod, makerToken)
    check reply.code == 200
    check reply.body["source"].getStr() == "ledger" # bukan `snapshot` yang sudah basi
    let kas = lineOf(reply.body, "101.2")
    check kas.kind == JObject
    # 11449 + 77: angka tetap dari jurnal, bukan dari cache lama.
    check kas["closingDebit"].getStr() == "11526.00"
