## End-to-end Fase 1 (T-077): party → product → posting rule → jurnal → trial balance.
##
## Satu alur sintetis lewat HTTP + konsumen outbox nyata, membuktikan batas antarmodul bekerja
## bersama: CIF dari parameter, produk parametrik, event akuntansi diposting menjadi jurnal
## seimbang, TB cocok, dan pembalik menetralkan angkanya.

import std/[httpclient, json, net, options, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids, money]
import ledger/domain/period
import ledger/infrastructure/[journal_repo, ledger_repo]
import openapi/lib
import party/domain/cif
import platform/domain/event
import platform/infrastructure/outbox_repo
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[context, posting, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  PartyPath = "/api/v1/parties"
  ProductsPath = "/api/v1/products"
  ProductsDetailPath = "/api/v1/products/{code}"
  TrialBalancePath = "/api/v1/ledger/trial-balance"
  JournalsPath = "/api/v1/ledger/journals"
  JournalDetailPath = "/api/v1/ledger/journals/{journalId}"
  ReversalPath = "/api/v1/ledger/journals/{journalId}/reversal"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "11111111-1111-7111-8111-111111111111"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_fase1: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

var
  testClock = fakeClock(dateTime(2026, mOct, 20, 9, 0, 0))
  actor = Id("77777777-7777-7777-8777-777777777777")
  periodId = newId(testClock)

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
  discard insertPeriod(db,
    Period(periodId: periodId, startsOn: "2026-10-01", endsOn: "2026-10-31"), actor)
  dbPool.release(db)

var app = AppContext(version: "itapi-fase1-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: testClock, readiness: databaseProbe())

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
    discard

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
    client.headers["Content-Type"] = "application/json"
    response = client.post(baseUrl & path, payload)
  result.code = response.code.int
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  result.body = newJNull()
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

proc getJson(path: string, token = ""): Reply = call("GET", path, "", token)
proc postJson(path: string, payload: JsonNode, token = "", key = ""): Reply =
  call("POST", path, $payload, token, key)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc checkJson(path, verb, status: string, body: JsonNode) =
  let problems = contract.validateValue(contract.responseSchema(path, verb, status,
    "application/json"), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc checkProblem(path, verb, status: string, body: JsonNode) =
  let problems = contract.validateValue(contract.responseSchema(path, verb, status,
    "application/problem+json"), body, "$")
  check problems.len == 0

proc withDbValue(query: SqlQuery, args: varargs[string, `$`]): string =
  let db = dbPool.acquire()
  try:
    db.getValue(query, args)
  finally:
    dbPool.release(db)

proc withDb(body: proc(db: DbConn)) =
  let db = dbPool.acquire()
  try:
    body(db)
  finally:
    dbPool.release(db)

# ---- alur -----------------------------------------------------------------------------------

var
  partyToken = ""
  partyId = ""
  productId = ""
  productCode = "SAV01"
  journalId = ""
  accountingEventId: Id
  amount = 250_000_0000'i64

suite "Fase 1 end-to-end":
  test "login maker":
    let login = postJson(LoginPath, %*{"username": MakerUser, "password": DevPassword})
    check login.code == 200
    partyToken = tokenOf(login)
    check partyToken.len > 0

  test "party: CIF dibentuk dari parameter":
    require partyToken.len > 0
    let created = postJson(PartyPath,
      %*{"kind": "PERSON", "displayName": "Siti Aminah", "branchId": BranchId}, partyToken)
    check created.code == 201
    checkJson(PartyPath, "POST", "201", created.body)
    partyId = created.body["partyId"].getStr()
    let cif = created.body["cif"].getStr()
    # Bandingkan dengan pola parameter + nomor urut DB, bukan sekadar panjangnya: handler yang
    # meng-hardcode 7 digit akan gagal di sini.
    let pattern = withDbValue(sql"""SELECT value #>> '{}' FROM platform.param_value
      WHERE key = 'party.cif.format' AND status = 'ACTIVE' AND scope_type = 'GLOBAL'
      ORDER BY effective_from DESC LIMIT 1""")
    let seq = parseBiggestInt(withDbValue(sql"SELECT last_value::text FROM party.cif_seq"))
    check cif == formatCif(pattern, seq)

  test "product: katalog parametrik + versi 1":
    require partyToken.len > 0
    let created = postJson(ProductsPath, %*{
      "code": productCode, "name": "Simpanan Sukarela", "productType": "SAVINGS",
      "effectiveFrom": "2026-10-01",
      "bindings": {"product.savings.min_balance": "10000.0000",
                   "product.savings.admin_fee": "2500.0000"}}, partyToken)
    check created.code == 201
    checkJson(ProductsPath, "POST", "201", created.body)
    check created.body["versions"].len == 1
    productId = created.body["productId"].getStr()
    let detail = getJson(ProductsDetailPath.replace("{code}", productCode), partyToken)
    check detail.code == 200

  test "event akuntansi diposting menjadi jurnal seimbang":
    require partyToken.len > 0
    accountingEventId = newId(testClock)
    withDb(proc(db: DbConn) =
      let ev = newOutboxEvent(accountingEventId, "DepositPosted", "deposit",
        "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa",
        "fase1:" & $accountingEventId,
        %*{"amount": "250000.0000", "branchId": BranchId, "businessDate": "2026-10-15",
           "product": productCode},
        headers = %*{"accounting": true})
      check appendEvent(db, ev))
    # Batch juga mengklaim event non-akuntansi (party.onboarded, ProductPublished) yang sudah
    # menunggu; yang dikunci adalah hasilnya: tepat satu jurnal dari event ini.
    discard processBatch(app, "fase1-worker", 10, 3, 0)

    withDb(proc(db: DbConn) =
      check db.getValue(sql"""
        SELECT status FROM platform.outbox WHERE outbox_id = ?""",
        $accountingEventId) == "DONE"
      check db.getValue(sql"SELECT count(*)::text FROM ledger.journal") == "1")

    let list = getJson(JournalsPath & "?businessDate=2026-10-15", partyToken)
    check list.code == 200
    checkJson(JournalsPath, "GET", "200", list.body)
    check list.body["items"].len == 1
    journalId = list.body["items"][0]["journalId"].getStr()

    let detail = getJson(JournalDetailPath.replace("{journalId}", journalId), partyToken)
    check detail.code == 200
    checkJson(JournalDetailPath, "GET", "200", detail.body)
    check detail.body["lines"].len == 2
    check detail.body["sourceEvent"].getStr() == "DepositPosted"
    check detail.body["sourceRef"].getStr() == "aaaaaaaa-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    check moneyOf(detail.body["totalDebit"].getStr()) == money(amount)
    check detail.body["totalDebit"].getStr() == detail.body["totalCredit"].getStr()

  test "trial balance cocok dan seimbang":
    require partyToken.len > 0
    let tb = getJson(TrialBalancePath & "?periodId=" & $periodId, partyToken)
    check tb.code == 200
    checkJson(TrialBalancePath, "GET", "200", tb.body)
    check moneyOf(tb.body["totalDebit"].getStr()) == money(amount)
    check tb.body["totalDebit"].getStr() == tb.body["totalCredit"].getStr()
    var kasDebit, simpananCredit: int64
    for line in tb.body["lines"]:
      if line["accountCode"].getStr() == "101":
        kasDebit = moneyOf(line["debit"].getStr()).minorUnits
      elif line["accountCode"].getStr() == "201":
        simpananCredit = moneyOf(line["credit"].getStr()).minorUnits
    check kasDebit == amount
    check simpananCredit == amount

  test "event turunan terbit: ProductPublished & journal.posted":
    withDb(proc(db: DbConn) =
      check db.getValue(sql"""
        SELECT count(*)::text FROM platform.outbox
         WHERE event_type = 'ProductPublished' AND aggregate_id = ?""", productId) == "1"
      check db.getValue(sql"""
        SELECT count(*)::text FROM platform.outbox
         WHERE event_type = 'journal.posted' AND aggregate_id = ?""", journalId) == "1")

  test "pembalik menetralkan TB dan tidak mengubah jurnal asal":
    require partyToken.len > 0
    require journalId.len > 0
    let before = getJson(JournalDetailPath.replace("{journalId}", journalId), partyToken)
    let beforeDebit = before.body["totalDebit"].getStr()
    let beforeCredit = before.body["totalCredit"].getStr()
    let reversal = postJson(ReversalPath.replace("{journalId}", journalId),
      %*{"reason": "uji end-to-end Fase 1"}, partyToken,
      "fase1-reversal:" & journalId)
    check reversal.code == 201
    checkJson(ReversalPath, "POST", "201", reversal.body)
    check reversal.body["reversalOf"].getStr() == journalId

    let original = getJson(JournalDetailPath.replace("{journalId}", journalId), partyToken)
    check original.body["lines"].len == 2
    check original.body["totalDebit"].getStr() == beforeDebit
    check original.body["totalCredit"].getStr() == beforeCredit

    let tb = getJson(TrialBalancePath & "?periodId=" & $periodId, partyToken)
    check tb.code == 200
    # Pembalik menambah satu jurnal lagi: total pergerakan berlipat dua, tetapi saldo per akun
    # kembali nol (debit dan kredit akun yang sama sama besar).
    check moneyOf(tb.body["totalDebit"].getStr()) == money(amount * 2)
    check tb.body["totalDebit"].getStr() == tb.body["totalCredit"].getStr()
    for line in tb.body["lines"]:
      if line["accountCode"].getStr() in ["101", "201"]:
        check moneyOf(line["debit"].getStr()).minorUnits == amount
        check moneyOf(line["credit"].getStr()).minorUnits == amount
    withDb(proc(db: DbConn) =
      check db.getValue(sql"""
        SELECT count(*)::text FROM ledger.journal""") == "2")
