## Test integrasi HTTP endpoint **baca** day-close (T-139a) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan lewat jalur penuh: sesi & izin menyetir 401/403/404, `limit` divalidasi, status
## dan riwayat mengikuti kontrak, serta detail memuat task + chunk yang sama dengan baris DB.
##
## Seperti suite daycloser lain, test ini me-reset schema lalu menghapus `platform.business_date`
## di akhir supaya suite/e2e berikutnya mulai tanpa penutupan berjalan.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/clock
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import daycloser/domain/run
import daycloser/infrastructure/run_repo

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  StatusPath = "/api/v1/dayclose/status"
  RunsPath = "/api/v1/dayclose/runs"
  RunPath = "/api/v1/dayclose/runs/{runId}"
  LoginPath = "/api/v1/auth/login"
  AdminUser = "dev.maker"
  OtherUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  FixtureRunId = "11111111-1111-4111-8111-111111111111"
  UnknownRunId = "22222222-2222-4222-8222-222222222222"
  FixtureDate = "2026-10-28"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_dayclose: KRAN_DATABASE_URL kosong — dilewati"
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
  dbPool.release(db)

let db = dbPool.acquire()

type
  ServeArgs = object
    server: Server
    port: int

var
  apiServer: Server
  baseUrl: string
  serverThread: Thread[ServeArgs]

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

let app = AppContext(version: "itapi-dayclose-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: systemClock(), readiness: databaseProbe())
let port = freePort()
baseUrl = "http://127.0.0.1:" & $port
apiServer = newApiServer(app)
createThread(serverThread, serveInThread, ServeArgs(server: apiServer, port: port))

block:
  let deadline = epochTime() + 10.0
  var ready = false
  while not ready and epochTime() < deadline:
    try:
      let client = newHttpClient(timeout = 1000)
      try:
        ready = client.get(baseUrl & "/healthz").code.int == 200
      finally:
        client.close()
    except CatchableError:
      discard
    if not ready:
      sleep(50)
  doAssert ready, "server test tidak pernah siap"

type
  Reply = object
    code: int
    body: JsonNode
    setCookie: string

proc call(verb, path, token: string): Reply =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
  var response: Response
  if verb == "GET":
    response = client.get(baseUrl & path)
  else:
    response = client.post(baseUrl & path, "{}")
  result.code = response.code.int
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  result.body = newJNull()
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

proc getJson(path: string, token = ""): Reply =
  call("GET", path, token)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc login(username: string): Reply =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let response = client.post(baseUrl & LoginPath,
    $ %*{"username": username, "password": DevPassword})
  result.code = response.code.int
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  result.body = newJNull()
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

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

proc dbCount(query: SqlQuery, args: varargs[string, `$`]): int =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args).parseInt
  finally:
    dbPool.release(conn)

let admin = login(AdminUser)
doAssert admin.code == 200, "login dev.maker gagal — seed dev terpasang?"
let adminToken = tokenOf(admin)
let otherToken = tokenOf(login(OtherUser))

suite "day-close: sesi & izin":
  test "tanpa sesi → 401 di ketiga endpoint baca":
    check getJson(StatusPath).code == 401
    check getJson(RunsPath).code == 401
    check getJson(RunsPath & "/" & FixtureRunId).code == 401

  test "tanpa izin dayclose.run.read → 403 problem":
    let status = getJson(StatusPath, otherToken)
    check status.code == 403
    checkProblem(StatusPath, "GET", "403", status.body)

    let runs = getJson(RunsPath, otherToken)
    check runs.code == 403
    checkProblem(RunsPath, "GET", "403", runs.body)

    let detail = getJson(RunsPath & "/" & FixtureRunId, otherToken)
    check detail.code == 403
    checkProblem(RunPath, "GET", "403", detail.body)

  test "status tanpa baris business_date: bentuk kontrak, isi null":
    execScript(db, "DELETE FROM platform.business_date")
    let reply = getJson(StatusPath, adminToken)
    check reply.code == 200
    checkJson(StatusPath, "GET", "200", reply.body)
    check reply.body["businessDate"].kind == JNull
    check reply.body["activeRun"].kind == JNull
    check reply.body["latestRun"].kind == JNull

suite "day-close: riwayat kosong":
  test "limit divalidasi, batas atas jelas":
    for bad in ["0", "abc", "101", "-1"]:
      let reply = getJson(RunsPath & "?limit=" & bad, adminToken)
      check reply.code == 400
      checkProblem(RunsPath, "GET", "400", reply.body)

    let maxed = getJson(RunsPath & "?limit=100", adminToken)
    check maxed.code == 200
    checkJson(RunsPath, "GET", "200", maxed.body)
    check maxed.body["runs"].len == 0

  test "runId tidak ada / bukan uuid → 404":
    for id in [UnknownRunId, "bukan-uuid"]:
      let reply = getJson(RunsPath & "/" & id, adminToken)
      check reply.code == 404
      checkProblem(RunPath, "GET", "404", reply.body)

suite "day-close: run tersimpan":
  test "status dan detail membaca baris run, task, chunk":
    execScript(db, "DELETE FROM platform.business_date")
    execScript(db, """
      INSERT INTO platform.business_date (scope_type, scope_id, current_business_date, state)
      VALUES ('INSTITUTION', NULL, DATE '""" & FixtureDate & """', 'OPEN')
    """)

    # Snapshot parameter harus konsisten dengan hash-nya: `snapshot()` menolak run yang snapshotnya
    # diubah di luar jalur aplikasi, jadi fixture memakai helper yang sama dengan produksi.
    let cfg = Config(chunkSize: 100, maxAttempts: 3, retryBackoffSeconds: 0)
    let snapshotJson = $cfg.configJson
    let snapshotHash = configHash(cfg)
    execScript(db, """
      INSERT INTO daycloser.run
        (run_id, scope_type, scope_id, business_date, levels, mode, state, control,
         param_snapshot, param_snapshot_hash, started_at)
      VALUES ('""" & FixtureRunId & """', 'INSTITUTION', NULL, DATE '""" & FixtureDate &
        """',
              '{EOD}', 'REAL', 'RUNNING', 'NONE',
              '""" & snapshotJson & """'::jsonb, '""" & snapshotHash & """', now())
    """)
    execScript(db, """
      INSERT INTO daycloser.task (run_id, task_id, kind, critical, state, attempt, error, reason)
      VALUES ('""" & FixtureRunId &
        """', 'ledger.suspense_zero', 'POSTCHECK', true, 'FAILED', 2,
              '{"code":"DAY-304","message":"saldo akun selisih tidak nol"}'::jsonb, NULL),
             ('""" & FixtureRunId &
        """', 'ledger.trial_balance', 'POSTCHECK', true, 'SUCCEEDED',
              1, NULL, NULL),
             ('""" & FixtureRunId & """', 'ledger.period_close', 'POSTCHECK', true, 'SKIPPED',
              1, NULL, 'bukan akhir bulan')
    """)
    execScript(db, """
      INSERT INTO daycloser.chunk (run_id, task_id, chunk_no, state, attempt, error)
      VALUES ('""" & FixtureRunId &
        """', 'ledger.suspense_zero', 0, 'FAILED', 2,
              '{"code":"DAY-304"}'::jsonb),
             ('""" & FixtureRunId &
        """', 'ledger.trial_balance', 0, 'SUCCEEDED', 1, NULL),
             ('""" & FixtureRunId & """', 'ledger.period_close', 0, 'SUCCEEDED', 1, NULL)
    """)

    let status = getJson(StatusPath, adminToken)
    check status.code == 200
    checkJson(StatusPath, "GET", "200", status.body)
    check status.body["businessDate"]["date"].getStr() == FixtureDate
    check status.body["businessDate"]["state"].getStr() == "OPEN"
    check status.body["businessDate"]["frozenAt"].kind == JNull
    check status.body["activeRun"]["runId"].getStr() == FixtureRunId
    check status.body["activeRun"]["state"].getStr() == "RUNNING"
    check status.body["activeRun"]["taskCounts"]["ok"].getInt() == 1
    check status.body["activeRun"]["taskCounts"]["failed"].getInt() == 1
    check status.body["activeRun"]["taskCounts"]["skipped"].getInt() == 1
    check status.body["activeRun"]["taskCounts"]["total"].getInt() == 3
    check status.body["latestRun"]["runId"].getStr() == FixtureRunId

    let runs = getJson(RunsPath, adminToken)
    check runs.code == 200
    checkJson(RunsPath, "GET", "200", runs.body)
    check runs.body["runs"].len == 1
    check runs.body["runs"][0]["runId"].getStr() == FixtureRunId
    check runs.body["runs"][0]["levels"][0].getStr() == "EOD"

    let detail = getJson(RunsPath & "/" & FixtureRunId, adminToken)
    check detail.code == 200
    checkJson(RunPath, "GET", "200", detail.body)
    let dbTasks = dbCount(sql"SELECT count(*)::text FROM daycloser.task WHERE run_id = ?::uuid",
      FixtureRunId)
    let dbChunks = dbCount(sql"SELECT count(*)::text FROM daycloser.chunk WHERE run_id = ?::uuid",
      FixtureRunId)
    check detail.body["tasks"].len == dbTasks
    var chunkTotal = 0
    for task in detail.body["tasks"]:
      chunkTotal += task["chunks"].len
      if task["taskId"].getStr() == "ledger.suspense_zero":
        check task["kind"].getStr() == "POSTCHECK"
        check task["critical"].getBool()
        check task["state"].getStr() == "FAILED"
        check task["attempt"].getInt() == 2
        check task["errorCode"].getStr() == "DAY-304"
        check task["reason"].kind == JNull
        check task["chunks"].len == 1
        check task["chunks"][0]["chunkNo"].getInt() == 0
        check task["chunks"][0]["state"].getStr() == "FAILED"
        check task["chunks"][0]["attempt"].getInt() == 2
        check task["chunks"][0]["errorCode"].getStr() == "DAY-304"
      if task["taskId"].getStr() == "ledger.period_close":
        check task["state"].getStr() == "SKIPPED"
        # Alasan skip disimpan (migrasi `0062`): monitor harus bisa menjelaskan kenapa dilewati.
        check task["reason"].getStr() == "bukan akhir bulan"
    check chunkTotal == dbChunks
    check detail.body["taskCounts"]["total"].getInt() == dbTasks

# Jangan tinggalkan tanggal buku `CLOSING` (atau run aktif) untuk suite/e2e berikutnya.
execScript(db, "DELETE FROM platform.business_date")
