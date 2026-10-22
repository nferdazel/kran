## Test integrasi HTTP jurnal (T-073) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi & izin (401/403), daftar/detail sesuai kontrak, pembalik idempoten
## (201 lalu 200 dengan kunci sama), konflik kunci/jurnal sudah dibalik → 409, audit + event
## `journal.posted`, dan grant bercabang → 403.

import std/[httpclient, json, net, options, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids, money]
import ledger/domain/[journal, period]
import ledger/infrastructure/[journal_repo, ledger_repo]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  JournalsPath = "/api/v1/ledger/journals"
  DetailPath = "/api/v1/ledger/journals/{journalId}"
  ReversalPath = "/api/v1/ledger/journals/{journalId}/reversal"
  TrialBalancePath = "/api/v1/ledger/trial-balance"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "11111111-1111-7111-8111-111111111111"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_journal: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

let
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")

var mainPeriodId: Id

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
  mainPeriodId = newId(testClock)
  discard insertPeriod(db,
    Period(periodId: mainPeriodId, startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)

var app = AppContext(version: "itapi-journal-0.0.0", role: "api", startedAt: epochTime(),
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
  ReversalRaceArgs = object
    url: string
    path: string
    token: string
    key: string

var
  reversalRaceCode = 0
  reversalRaceBody = ""

proc reversalRaceWorker(args: ReversalRaceArgs) {.thread.} =
  ## Menjalankan pembalik lewat HTTP dari thread lain supaya test bisa menahan entri indeks unik
  ## `journal_idempotency_uq` di transaksi kedua (O-078).
  let client = newHttpClient(timeout = 30_000)
  try:
    client.headers["Cookie"] = CookieName & "=" & args.token
    client.headers["Content-Type"] = "application/json"
    client.headers["Idempotency-Key"] = args.key
    let response = client.post(args.url & args.path, $ %*{"reason": "balapan kunci"})
    {.cast(gcsafe).}:
      reversalRaceCode = response.code.int
      reversalRaceBody = response.body
  except CatchableError as e:
    {.cast(gcsafe).}:
      reversalRaceCode = -1
      reversalRaceBody = e.msg
  finally:
    client.close()

type
  Reply = object
    code: int
    raw: string
    body: JsonNode
    setCookie: string

proc call(verb, path, payload, token: string, idempotencyKey = ""): Reply =
  let client = newHttpClient(timeout = 60_000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
  if idempotencyKey.len > 0:
    client.headers["Idempotency-Key"] = idempotencyKey
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

proc postJson(path: string, payload: JsonNode, token = "", idempotencyKey = ""): Reply =
  call("POST", path, $payload, token, idempotencyKey)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc login(username: string, password = DevPassword): Reply =
  postJson(LoginPath, %*{"username": username, "password": password})

proc checkJson(path, verb, status: string, body: JsonNode, contentType = "application/json") =
  let problems = contract.validateValue(contract.responseSchema(path, verb, status, contentType),
    body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc checkProblem(path, verb, status: string, body: JsonNode) =
  checkJson(path, verb, status, body, "application/problem+json")

proc dbValue(query: SqlQuery, args: varargs[string, `$`]): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args)
  finally:
    dbPool.release(conn)

var keySeq = 0

proc nextKey(): string =
  keySeq.inc
  "itapi-journal-" & $keySeq

proc line(no: int, account: string, debit, credit: int64): JournalLine =
  JournalLine(lineNo: no, glAccount: account, branchId: Id(BranchId),
    debit: money(debit), credit: money(credit))

proc seedJournal(businessDate = "2026-10-15", amount: int64 = 250_0000): Id =
  ## Jurnal dibuat langsung lewat repo (HTTP sengaja tidak punya endpoint buat jurnal).
  let j = Journal(journalId: newId(testClock), businessDate: businessDate,
    valueDate: businessDate, sourceEvent: "DepositPosted", sourceRef: newId(testClock),
    idempotencyKey: nextKey(),
    lines: @[line(1, "101", amount, 0), line(2, "201", 0, amount)])
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    discard insertJournal(d, j, actor)
    for l in j.lines:
      insertJournalLine(d, j.journalId, l)
    1)
  j.journalId

proc raceReversal(sourceId: Id; winner: Journal; loserToken, loserKey: string):
    tuple[blocked: bool, code: int, body: string] =
  ## Menahan entri unik dari jurnal "pemenang" yang belum COMMIT, menjalankan pembalik lewat HTTP di
  ## thread lain, menunggu backend benar-benar diblokir koneksi ini, lalu melepas lock. Cabang catch
  ## yang dieksekusi ditentukan oleh konflik yang dibuat `winner` (lihat tiga test di suite pembalik).
  let path = ReversalPath.replace("{journalId}", $sourceId)
  let side = dbPool.acquire()
  try:
    exec(side, sql"BEGIN")
    discard insertJournal(side, winner, actor)
    for l in winner.lines:
      insertJournalLine(side, winner.journalId, l)
    let sidePid = side.getValue(sql"SELECT pg_backend_pid()")
    reversalRaceCode = 0
    reversalRaceBody = ""
    var worker: Thread[ReversalRaceArgs]
    createThread(worker, reversalRaceWorker,
      ReversalRaceArgs(url: baseUrl, path: path, token: loserToken, key: loserKey))

    var blocked = false
    let deadline = epochTime() + 10.0
    while epochTime() < deadline and not blocked:
      blocked = dbValue(sql"""
        SELECT count(*)::text FROM pg_stat_activity
         WHERE datname = current_database() AND pid <> pg_backend_pid()
           AND wait_event_type = 'Lock'
           AND ?::int = ANY(pg_blocking_pids(pid))""", sidePid) != "0"
      if not blocked:
        sleep(20)

    exec(side, sql"COMMIT")
    joinThread(worker)
    (blocked, reversalRaceCode, reversalRaceBody)
  finally:
    dbPool.release(side)

let maker = login(MakerUser)
doAssert maker.code == 200, "login dev.maker gagal — seed dev terpasang?"
let makerToken = tokenOf(maker)
let checkerToken = tokenOf(login(CheckerUser))

suite "journal: autentikasi & izin":
  test "tanpa sesi → 401":
    check getJson(JournalsPath).code == 401
    check getJson(DetailPath.replace("{journalId}",
      "88888888-8888-7888-8888-888888888888")).code == 401
    check postJson(ReversalPath.replace("{journalId}",
      "88888888-8888-7888-8888-888888888888"), %*{"reason": "uji"}, "",
      "k").code == 401

  test "pemegang izin lain → 403":
    let reply = getJson(JournalsPath, checkerToken)
    check reply.code == 403
    checkProblem(JournalsPath, "GET", "403", reply.body)

suite "journal: baca":
  test "daftar & detail sesuai kontrak":
    let id = seedJournal()
    let list = getJson(JournalsPath, makerToken)
    check list.code == 200
    checkJson(JournalsPath, "GET", "200", list.body)
    var found = false
    for item in list.body["items"]:
      if item["journalId"].getStr() == $id:
        found = true
        check item["reversalOf"].kind == JNull
        check not item.hasKey("lines")
    check found

    let detail = getJson(DetailPath.replace("{journalId}", $id), makerToken)
    check detail.code == 200
    checkJson(DetailPath, "GET", "200", detail.body)
    check detail.body["journalId"].getStr() == $id
    check detail.body["lines"].len == 2
    check detail.body["totalDebit"].getStr() == "250.0000"
    check detail.body["totalCredit"].getStr() == "250.0000"
    check detail.body["lines"][0]["glAccount"].getStr() == "101"

    let byDate = getJson(JournalsPath & "?businessDate=2026-10-15", makerToken)
    check byDate.code == 200
    check byDate.body["items"].len >= 1

    let badDate = getJson(JournalsPath & "?businessDate=2026-02-31", makerToken)
    check badDate.code == 400
    checkProblem(JournalsPath, "GET", "400", badDate.body)

  test "jurnal tidak ditemukan → 404":
    let reply = getJson(DetailPath.replace("{journalId}",
      "88888888-8888-7888-8888-888888888888"), makerToken)
    check reply.code == 404
    checkProblem(DetailPath, "GET", "404", reply.body)

suite "journal: pembalik":
  test "tanpa Idempotency-Key → 400":
    let id = seedJournal()
    let reply = postJson(ReversalPath.replace("{journalId}", $id), %*{"reason": "salah"},
      makerToken)
    check reply.code == 400
    checkProblem(ReversalPath, "POST", "400", reply.body)

  test "pembalik dibuat, idempoten, dan menulis audit + event":
    let id = seedJournal(amount = 175_0000)
    let path = ReversalPath.replace("{journalId}", $id)
    let key = nextKey()
    let created = postJson(path, %*{"reason": "koreksi posting"}, makerToken, key)
    check created.code == 201
    checkJson(ReversalPath, "POST", "201", created.body)
    check created.body["reversalOf"].getStr() == $id
    check created.body["sourceEvent"].getStr() == "reversal"
    check created.body["lines"][0]["credit"].getStr() == "175.0000"
    check created.body["lines"][0]["debit"].getStr() == "0.0000"
    check created.body["lines"][1]["debit"].getStr() == "175.0000"
    let reversalId = created.body["journalId"].getStr()

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'ledger.journal.reverse' AND resource_id = ?""", reversalId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'journal.posted' AND aggregate_id = ?""", reversalId) == "1"

    # Permintaan ulang dengan kunci sama → 200 dan jurnal yang sama (bukan jurnal kedua).
    let replay = postJson(path, %*{"reason": "koreksi posting"}, makerToken, key)
    check replay.code == 200
    checkJson(ReversalPath, "POST", "200", replay.body)
    check replay.body["journalId"].getStr() == reversalId

    # Kunci sama untuk jurnal asal lain → 409.
    let other = seedJournal()
    let conflict = postJson(ReversalPath.replace("{journalId}", $other),
      %*{"reason": "lain"}, makerToken, key)
    check conflict.code == 409
    checkProblem(ReversalPath, "POST", "409", conflict.body)

    # Jurnal yang sudah dibalik tidak bisa dibalik dua kali.
    let twice = postJson(path, %*{"reason": "lagi"}, makerToken, nextKey())
    check twice.code == 409
    checkProblem(ReversalPath, "POST", "409", twice.body)
    # Jurnal pembalik tidak bisa dibalik lagi.
    let chain = postJson(ReversalPath.replace("{journalId}", reversalId),
      %*{"reason": "balik pembalik"}, makerToken, nextKey())
    check chain.code == 409
    checkProblem(ReversalPath, "POST", "409", chain.body)

  test "balapan kunci sama + pembalik: yang kalah membaca ulang → 200 (O-078)":
    let id = seedJournal(amount = 150_0000)
    let key = nextKey()
    let original = dbPool.withConn(proc(d: DbConn): Journal = journalById(d, id).get())
    let winner = Journal(
      journalId: newId(testClock),
      businessDate: original.businessDate,
      valueDate: original.valueDate,
      sourceEvent: "reversal",
      sourceRef: id,
      idempotencyKey: key,
      reversalOf: $id,
      lines: reversalLinesOf(original.lines))

    let r = raceReversal(id, winner, makerToken, key)
    check r.blocked
    check r.code == 200
    if r.code == 200:
      let body = parseJson(r.body)
      check body["journalId"].getStr() == $winner.journalId
      check body["reversalOf"].getStr() == $id
      checkJson(ReversalPath, "POST", "200", body)
    check dbValue(sql"""
      SELECT count(*)::text FROM ledger.journal WHERE reversal_of = ?::uuid""", $id) == "1"

  test "balapan kunci sama + jurnal lain: 409 dari cabang idempotensi (O-078)":
    # `winner` bukan pembalik untuk asal ini dan memakai kunci yang sama → hanya
    # `journal_idempotency_uq` yang berkonflik. Catch harus menjawab 409, bukan 200.
    let id = seedJournal()
    let key = nextKey()
    let winner = Journal(
      journalId: newId(testClock),
      businessDate: "2026-10-15",
      valueDate: "2026-10-15",
      sourceEvent: "DepositPosted",
      sourceRef: newId(testClock),
      idempotencyKey: key,
      lines: @[line(1, "101", 100_0000, 0), line(2, "201", 0, 100_0000)])

    let r = raceReversal(id, winner, makerToken, key)
    check r.blocked
    check r.code == 409
    if r.code == 409:
      checkProblem(ReversalPath, "POST", "409", parseJson(r.body))
    check dbValue(sql"""
      SELECT count(*)::text FROM ledger.journal WHERE reversal_of = ?::uuid""", $id) == "0"

  test "balapan kunci beda + pembalik: 409 dari cabang indeks pembalik (O-078)":
    # `winner` pembalik untuk asal yang sama tetapi memakai kunci **berbeda** → hanya
    # `journal_reversal_uq` yang berkonflik. Catch harus menjawab 409, bukan 200 dengan jurnal asing.
    let id = seedJournal()
    let winnerKey = nextKey()
    let original = dbPool.withConn(proc(d: DbConn): Journal = journalById(d, id).get())
    let winner = Journal(
      journalId: newId(testClock),
      businessDate: original.businessDate,
      valueDate: original.valueDate,
      sourceEvent: "reversal",
      sourceRef: id,
      idempotencyKey: winnerKey,
      reversalOf: $id,
      lines: reversalLinesOf(original.lines))

    let r = raceReversal(id, winner, makerToken, nextKey())
    check r.blocked
    check r.code == 409
    if r.code == 409:
      checkProblem(ReversalPath, "POST", "409", parseJson(r.body))
    check dbValue(sql"""
      SELECT count(*)::text FROM ledger.journal WHERE reversal_of = ?::uuid""", $id) == "1"

  test "jurnal asal tidak ada → 404":
    let reply = postJson(ReversalPath.replace("{journalId}",
      "88888888-8888-7888-8888-888888888888"), %*{"reason": "tidak ada"},
      makerToken, nextKey())
    check reply.code == 404
    checkProblem(ReversalPath, "POST", "404", reply.body)

suite "journal: grant bercabang":
  test "grant dibatasi cabang → 403 pada baca & pembalik":
    let id = seedJournal()
    let conn = dbPool.acquire()
    try:
      conn.exec(sql"""
        UPDATE platform.user_role ur SET branch_id = 'cabang-uji'
          FROM platform.app_user u, platform.role r
         WHERE ur.user_id = u.user_id AND ur.role_id = r.role_id
           AND u.username = 'dev.maker' AND r.code = 'platform_admin'""")
      let list = getJson(JournalsPath, makerToken)
      check list.code == 403
      check list.body["params"]["reason"].getStr() == "branch_not_allowed"
      let reverse = postJson(ReversalPath.replace("{journalId}", $id),
        %*{"reason": "cabang"}, makerToken, nextKey())
      check reverse.code == 403
      checkProblem(ReversalPath, "POST", "403", reverse.body)
      let tb = getJson(TrialBalancePath & "?periodId=" & $mainPeriodId, makerToken)
      check tb.code == 403
      check tb.body["params"]["reason"].getStr() == "branch_not_allowed"
    finally:
      conn.exec(sql"""
        UPDATE platform.user_role ur SET branch_id = NULL
          FROM platform.app_user u, platform.role r
         WHERE ur.user_id = u.user_id AND ur.role_id = r.role_id
           AND u.username = 'dev.maker' AND r.code = 'platform_admin'""")
      dbPool.release(conn)
    check getJson(JournalsPath, makerToken).code == 200

suite "trial balance":
  test "TB sesuai kontrak dan seimbang":
    discard seedJournal(amount = 320_0000)
    let reply = getJson(TrialBalancePath & "?periodId=" & $mainPeriodId, makerToken)
    check reply.code == 200
    checkJson(TrialBalancePath, "GET", "200", reply.body)
    check reply.body["periodId"].getStr() == $mainPeriodId
    check reply.body["startsOn"].getStr() == "2026-10-01"
    check reply.body["endsOn"].getStr() == "2026-10-31"
    check reply.body["totalDebit"].getStr() == reply.body["totalCredit"].getStr()
    check reply.body["lines"].len >= 2

  test "periodId tidak sah → 400, periode tidak ada → 404":
    let bad = getJson(TrialBalancePath & "?periodId=bukan-uuid", makerToken)
    check bad.code == 400
    checkProblem(TrialBalancePath, "GET", "400", bad.body)
    let missing = getJson(TrialBalancePath, makerToken)
    check missing.code == 400
    let unknown = getJson(TrialBalancePath &
      "?periodId=88888888-8888-7888-8888-888888888888", makerToken)
    check unknown.code == 404
    checkProblem(TrialBalancePath, "GET", "404", unknown.body)

  test "pemegang izin lain → 403":
    let reply = getJson(TrialBalancePath & "?periodId=" & $mainPeriodId, checkerToken)
    check reply.code == 403
    checkProblem(TrialBalancePath, "GET", "403", reply.body)

  test "batas periode inklusif: tanggal pertama & terakhir ikut, luar tidak bisa dibuat":
    let before = moneyOf(getJson(TrialBalancePath & "?periodId=" & $mainPeriodId,
      makerToken).body["totalDebit"].getStr())
    discard seedJournal(businessDate = "2026-10-01", amount = 11_0000)
    discard seedJournal(businessDate = "2026-10-31", amount = 13_0000)
    let after = moneyOf(getJson(TrialBalancePath & "?periodId=" & $mainPeriodId,
      makerToken).body["totalDebit"].getStr())
    check after == before + money(24_0000)
