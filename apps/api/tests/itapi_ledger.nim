## Test integrasi HTTP `ledger` COA & periode (T-072) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan lewat jalur penuh: sesi & izin menyetir 401/403, kode COA divalidasi dari
## parameter (bukan konstanta), duplikat & tumpang tindih periode → 409, tutup periode menulis
## audit + event, dan konfigurasi pola yang rusak dijawab 500 (bukan 400).
##
## Test ini menghapus schema `platform` dan `ledger` di DB dev lalu menyiapkan ulang migrasi,
## seed pack, seed pengguna dev, dan satu pemberian `platform_admin` untuk `dev.maker`.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/clock
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
  discard applyMigrations(db, ".")
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
    for item in all.body["items"]:
      if item["code"].getStr() == "101":
        hasKas = true
        check item["name"].getStr() == "KAS"
        check item["accountType"].getStr() == "ASSET"
        check item["normalSide"].getStr() == "DEBIT"
        check item["postable"].getBool()
    check hasKas

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

    let missing = postJson(ClosePath.replace("{periodId}", "88888888-8888-7888-8888-888888888888"),
      %*{"reason": "tidak ada"}, makerToken)
    check missing.code == 404
    checkProblem(ClosePath, "POST", "404", missing.body)

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
    finally:
      conn.exec(sql"""
        UPDATE platform.user_role ur SET branch_id = NULL
          FROM platform.app_user u, platform.role r
         WHERE ur.user_id = u.user_id AND ur.role_id = r.role_id
           AND u.username = 'dev.maker' AND r.code = 'platform_admin'""")
      dbPool.release(conn)

    # Grant tanpa batas pulih → jalur normal jalan lagi.
    check getJson(CoaPath, makerToken).code == 200
