## Test integrasi HTTP sesi kas teller (T-093) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi/izin (401/403), validasi 400, konflik 409 (`session_already_open`,
## `insufficient_vault`, `vault_not_configured`, `session_not_open`, `session_not_owned`),
## 404 (`current` tanpa sesi, `close` tak dikenal), 201/200 + bentuk kontrak, urutan
## expected/counted/variance, idempotensi (replay 200 + `Idempotent-Replayed`, isi beda 409), dan
## **dua penutupan bersamaan** (satu 200, satu 409, vault bertambah sekali).
##
## Test me-reset seluruh schema, menyiapkan seed pack `base` + pengguna dev, beberapa vault cabang,
## dan member izin teller (migrasi `platform/0024`/`0025`) lewat role `platform_admin`.
##
## **HUMAN-REVIEW-REQUIRED**: mutasi vault + variance kas (AGENTS.md §8).

import std/[algorithm, httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids, money, result]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  SessionsPath = "/api/v1/teller/sessions"
  CurrentPath = "/api/v1/teller/sessions/current"
  ClosePath = "/api/v1/teller/sessions/{sessionId}/close"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  OtherTellerUser = "dev.teller2"
  BranchMakerUser = "dev.branchmaker"
  DevPassword = "rahasia-panjang-123"
  BusinessDate = "2026-10-22"
  CookieName = "kran_session"
  BranchA = "11111111-1111-7111-8111-111111111111"
  BranchB = "22222222-2222-7222-8222-222222222222"
  BranchC = "33333333-3333-7333-8333-333333333333"
  BranchD = "44444444-4444-7444-8444-444444444444"
  OtherBranch = "99999999-9999-7999-8999-999999999999"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_teller_sessions: KRAN_DATABASE_URL kosong — dilewati"
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

  # `dev.maker` (aktor sukses) + `dev.teller2` (uji kepemilikan) memegang seluruh izin tanpa batas
  # cabang; `dev.branchmaker` hanya di `OtherBranch` → `authorizedAtBranch` harus menolak `BranchA`.
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.maker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                                   must_change_password)
    SELECT gen_random_uuid(), 'dev.teller2', 'Dev Teller 2', password_algo, password_hash, false
      FROM platform.app_user WHERE username = 'dev.maker'
  """)
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.teller2' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                                   must_change_password)
    SELECT gen_random_uuid(), 'dev.branchmaker', 'Dev Branch Maker', password_algo,
           password_hash, false
      FROM platform.app_user WHERE username = 'dev.maker'
  """)
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, '""" & OtherBranch & """'
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.branchmaker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

  # Buka/tutup sesi memposting jurnal GL, jadi tanggal bisnis jam palsu wajib punya periode OPEN
  # (trigger `ledger.assert_journal_period_open`).
  execScript(db, """
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    SELECT md5('itapi-teller-sessions|2026')::uuid, '2026-01-01'::date, '2026-12-31'::date, 'OPEN',
           md5('itapi-teller-sessions|fixture')::uuid,
           md5('itapi-teller-sessions|fixture')::uuid
    WHERE NOT EXISTS (
      SELECT 1 FROM ledger.period
       WHERE starts_on <= '2026-10-22'::date AND ends_on >= '2026-10-22'::date)
  """)

  # Vault: BranchA cukup, BranchB kecil (uji insufficient), BranchD untuk konkurensi; BranchC sengaja
  # tanpa baris (uji vault_not_configured).
  for (branch, balance) in [(BranchA, "1000.0000"), (BranchB, "50.0000"), (BranchD, "100.0000")]:
    execScript(db, "INSERT INTO teller.vault (branch_id, balance) VALUES ('" & branch & "', '" &
      balance & "')")
  dbPool.release(db)

var app = AppContext(version: "itapi-teller-sessions-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: fakeClock(dateTime(2026, mOct, 22, 9, 0, 0)),
                     readiness: databaseProbe())

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
    replayed: string

var idemCounter = 0

proc autoIdemKey(): string =
  inc idemCounter
  "it-session-" & $idemCounter

proc call(verb, path, payload, token: string, idempotencyKey = "",
    sendKey = true): Reply =
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
    if sendKey:
      client.headers["Idempotency-Key"] =
        if idempotencyKey.len > 0: idempotencyKey else: autoIdemKey()
    response = client.post(baseUrl & path, payload)
  result.code = response.code.int
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  result.replayed = response.headers.getOrDefault("Idempotent-Replayed")
  result.body = newJNull()
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

proc postJson(path: string, payload: JsonNode, token = "", key = "",
    sendKey = true): Reply =
  call("POST", path, $payload, token, key, sendKey)

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

proc vaultOf(branch: string): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(sql"SELECT balance::text FROM teller.vault WHERE branch_id = ?", branch)
  finally:
    dbPool.release(conn)

proc openBody(branch, openingFloat: string, note = ""): JsonNode =
  result = %*{"branchId": branch, "openingFloat": openingFloat}
  if note.len > 0:
    result["note"] = %note

proc openSession(token, branch, openingFloat: string, key = ""): Reply =
  postJson(SessionsPath, openBody(branch, openingFloat), token, key)

proc closeSession(token, sessionId, countedCash: string, key = ""): Reply =
  postJson(SessionsPath & "/" & sessionId & "/close", %*{"countedCash": countedCash}, token, key)

proc dbCount(query: SqlQuery, args: varargs[string, `$`]): int =
  let conn = dbPool.acquire()
  try:
    parseInt(conn.getValue(query, args))
  finally:
    dbPool.release(conn)

proc auditCount(action: string): int =
  dbCount(sql"SELECT count(*)::text FROM platform.audit_log WHERE action = ?", action)

proc outboxCount(eventType: string): int =
  dbCount(sql"SELECT count(*)::text FROM platform.outbox WHERE event_type = ?", eventType)

proc reasonOf(reply: Reply): string =
  reply.body["params"]["reason"].getStr()

suite "sessions: autentikasi & izin":
  test "tanpa sesi → 401":
    let reply = openSession("", BranchA, "0.0000")
    check reply.code == 401
    checkProblem(SessionsPath, "POST", "401", reply.body)

  test "izin hanya di cabang lain → 403 branch_not_allowed":
    let token = tokenOf(login(BranchMakerUser))
    check token.len > 0
    let reply = openSession(token, BranchA, "0.0000", "sess-403-" & $epochTime())
    check reply.code == 403
    checkProblem(SessionsPath, "POST", "403", reply.body)
    check reasonOf(reply) == "branch_not_allowed"

    let current = call("GET", CurrentPath & "?branchId=" & BranchA, "", token)
    check current.code == 403
    checkProblem(CurrentPath, "GET", "403", current.body)

suite "sessions: validasi 400":
  test "branchId/openingFloat/note/kunci tidak sah → 400":
    let token = tokenOf(login(MakerUser))
    check token.len > 0

    let badBranch = openSession(token, "bukan-uuid", "0.0000")
    check badBranch.code == 400
    checkProblem(SessionsPath, "POST", "400", badBranch.body)

    for bad in ["-5.0000", "abc", "1.00001"]:
      let reply = openSession(token, BranchA, bad)
      check reply.code == 400
      checkProblem(SessionsPath, "POST", "400", reply.body)

    let longNote = postJson(SessionsPath, openBody(BranchA, "0.0000", repeat('n', 201)), token)
    check longNote.code == 400
    checkProblem(SessionsPath, "POST", "400", longNote.body)

    let tanpaKunci = postJson(SessionsPath, openBody(BranchA, "0.0000"), token, sendKey = false)
    check tanpaKunci.code == 400
    checkProblem(SessionsPath, "POST", "400", tanpaKunci.body)

  test "current tanpa/keliru branchId → 400":
    let token = tokenOf(login(MakerUser))
    let missing = call("GET", CurrentPath, "", token)
    check missing.code == 400
    checkProblem(CurrentPath, "GET", "400", missing.body)
    let bad = call("GET", CurrentPath & "?branchId=nope", "", token)
    check bad.code == 400

suite "sessions: buka & vault":
  test "vault belum dikonfigurasi → 409 vault_not_configured":
    let token = tokenOf(login(MakerUser))
    let reply = openSession(token, BranchC, "0.0000", "sess-novault-" & $epochTime())
    check reply.code == 409
    checkProblem(SessionsPath, "POST", "409", reply.body)
    check reasonOf(reply) == "vault_not_configured"

  test "vault kurang → 409 insufficient_vault, vault utuh":
    let token = tokenOf(login(MakerUser))
    let before = vaultOf(BranchB)
    let reply = openSession(token, BranchB, "100.0000", "sess-insuf-" & $epochTime())
    check reply.code == 409
    check reply.body["params"]["reason"].getStr() == "insufficient_vault"
    check vaultOf(BranchB) == before

  test "opening float di atas plafon → 409 cash_limit_exceeded, vault utuh":
    let token = tokenOf(login(MakerUser))
    let before = vaultOf(BranchA)
    # Plafon `teller.cash.limit_opening_float` = 2.000.000; dicek lebih dulu daripada saldo vault,
    # sehingga alasan penolakan pasti plafon, bukan `insufficient_vault`.
    let reply = openSession(token, BranchA, "2000000.0001", "sess-limit-" & $epochTime())
    check reply.code == 409
    checkProblem(SessionsPath, "POST", "409", reply.body)
    check reasonOf(reply) == "cash_limit_exceeded"
    check vaultOf(BranchA) == before
    check dbCount(sql"""SELECT count(*)::text FROM teller.teller_session
                         WHERE branch_id = ? AND status = 'OPEN'""", BranchA) == 0

  test "buka 201 menurunkan vault; tutup 200 menambahnya sebesar counted":
    let token = tokenOf(login(MakerUser))
    let before = vaultOf(BranchB)

    let opensBefore = auditCount("teller.session.open")
    let openEventsBefore = outboxCount("TellerSessionOpened")
    let open = postJson(SessionsPath, openBody(BranchB, "40.0000", "shift pagi"), token,
      "sess-debit-" & $epochTime())
    check open.code == 201
    checkJson(SessionsPath, "POST", "201", open.body)
    check open.body["status"].getStr() == "OPEN"
    check open.body["branchId"].getStr() == BranchB
    check open.body["openingFloat"].getStr() == "40.0000"
    check open.body["openedAt"].getStr().len > 0
    check open.body["businessDate"].getStr() == BusinessDate
    check open.body["note"].getStr() == "shift pagi"
    check auditCount("teller.session.open") == opensBefore + 1
    check outboxCount("TellerSessionOpened") == openEventsBefore + 1
    check vaultOf(BranchB) == "10.0000"
    let sessionId = open.body["sessionId"].getStr()

    # expected = opening float (tanpa movement) = 40; counted 36 → variance -4 (kas kurang).
    let closesBefore = auditCount("teller.session.close")
    let closeEventsBefore = outboxCount("TellerSessionClosed")
    let close = postJson(SessionsPath & "/" & sessionId & "/close",
      %*{"countedCash": "36.0000", "note": "kurang 4"}, token,
      "sess-debit-close-" & $epochTime())
    check close.code == 200
    checkJson(ClosePath, "POST", "200", close.body)
    check close.body["status"].getStr() == "CLOSED"
    check close.body["openingFloat"].getStr() == "40.0000"
    check close.body["expectedCash"].getStr() == "40.0000"
    check close.body["countedCash"].getStr() == "36.0000"
    check close.body["variance"].getStr() == "-4.0000"
    check close.body["closedAt"].getStr().len > 0
    check close.body["businessDate"].getStr() == BusinessDate
    check close.body["note"].getStr() == "kurang 4"
    check auditCount("teller.session.close") == closesBefore + 1
    check outboxCount("TellerSessionClosed") == closeEventsBefore + 1
    # Vault = 50 - 40 (buka) + 36 (counted fisik) = 46.
    check vaultOf(BranchB) == "46.0000"

  test "note buka tidak hilang saat tutup tanpa note":
    let token = tokenOf(login(MakerUser))
    let open = postJson(SessionsPath, openBody(BranchB, "10.0000", "kas shift malam"), token,
      "sess-note-" & $epochTime())
    check open.code == 201
    check open.body["note"].getStr() == "kas shift malam"
    let sessionId = open.body["sessionId"].getStr()

    let close = postJson(SessionsPath & "/" & sessionId & "/close",
      %*{"countedCash": "10.0000"}, token, "sess-note-close-" & $epochTime())
    check close.code == 200
    check close.body["note"].getStr() == "kas shift malam"

  test "buka 201 → current 200; sesi kedua → 409; idempotensi & tutup":
    let token = tokenOf(login(MakerUser))
    let openKey = "sess-open-idem-" & $epochTime()
    let open = openSession(token, BranchA, "0.0000", openKey)
    check open.code == 201
    let sessionId = open.body["sessionId"].getStr()

    # Replay buka: 200 + header, sesi sama, vault tidak terdebit dua kali.
    let vaultBeforeReplay = vaultOf(BranchA)
    let replay = openSession(token, BranchA, "0.0000", openKey)
    check replay.code == 200
    check replay.replayed == "true"
    check replay.body["sessionId"].getStr() == sessionId
    check vaultOf(BranchA) == vaultBeforeReplay
    # Isi beda pada kunci yang sama → 409.
    let mismatch = openSession(token, BranchA, "1.0000", openKey)
    check mismatch.code == 409
    checkProblem(SessionsPath, "POST", "409", mismatch.body)

    # Sesi kedua untuk (teller, cabang) yang sama → 409.
    let dup = openSession(token, BranchA, "0.0000", "sess-dup-" & $epochTime())
    check dup.code == 409
    check dup.body["params"]["reason"].getStr() == "session_already_open"

    # current mengembalikan sesi itu.
    let current = call("GET", CurrentPath & "?branchId=" & BranchA, "", token)
    check current.code == 200
    checkJson(CurrentPath, "GET", "200", current.body)
    check current.body["sessionId"].getStr() == sessionId
    check current.body["tellerId"].getStr().len > 0

    # Tutup dengan counted = expected (0) → variance 0.
    let closeKey = "sess-close-idem-" & $epochTime()
    let close = closeSession(token, sessionId, "0.0000", closeKey)
    check close.code == 200
    check close.body["expectedCash"].getStr() == "0.0000"
    check close.body["variance"].getStr() == "0.0000"

    # Tutup kedua → 409 session_not_open (bukan 404).
    let closeAgain = closeSession(token, sessionId, "0.0000")
    check closeAgain.code == 409
    check closeAgain.body["params"]["reason"].getStr() == "session_not_open"

    # Replay tutup → 200 + header, tidak menambah vault lagi.
    let vaultAfterClose = vaultOf(BranchA)
    let closeReplay = closeSession(token, sessionId, "0.0000", closeKey)
    check closeReplay.code == 200
    check closeReplay.replayed == "true"
    check vaultOf(BranchA) == vaultAfterClose

    # Session baru bebas setelah ditutup; current lagi → 404 (sesi sebelumnya CLOSED).
    let currentAfter = call("GET", CurrentPath & "?branchId=" & BranchA, "", token)
    check currentAfter.code == 404
    check currentAfter.body["params"]["reason"].getStr() == "session_not_open"
    checkProblem(CurrentPath, "GET", "404", currentAfter.body)

  test "close sesi tak dikenal → 404":
    let token = tokenOf(login(MakerUser))
    let reply = closeSession(token, "00000000-0000-7000-8000-000000000000", "0.0000")
    check reply.code == 404
    checkProblem(ClosePath, "POST", "404", reply.body)

suite "sessions: kepemilikan":
  test "sesi milik teller lain → 409 session_not_owned":
    let maker = tokenOf(login(MakerUser))
    let other = tokenOf(login(OtherTellerUser))
    let open = openSession(maker, BranchA, "0.0000", "sess-own-" & $epochTime())
    check open.code == 201
    let sessionId = open.body["sessionId"].getStr()

    let deny = closeSession(other, sessionId, "0.0000")
    check deny.code == 409
    checkProblem(ClosePath, "POST", "409", deny.body)
    check deny.body["params"]["reason"].getStr() == "session_not_owned"

    # Pemiliknya tetap bisa menutup (bukti 409 tadi bukan karena sesi rusak).
    let mine = closeSession(maker, sessionId, "0.0000")
    check mine.code == 200

var closeCodes: array[2, int]

type CloseArgs = object
  token: string
  path: string
  payload: string
  key: string
  slot: int

proc closeWorker(args: CloseArgs) {.thread.} =
  {.cast(gcsafe).}:
    let client = newHttpClient(timeout = 15000)
    client.headers["Cookie"] = CookieName & "=" & args.token
    client.headers["Content-Type"] = "application/json"
    client.headers["Idempotency-Key"] = args.key
    let response = client.post(baseUrl & args.path, args.payload)
    closeCodes[args.slot] = response.code.int
    client.close()

suite "sessions: dua penutupan bersamaan":
  test "satu 200, satu 409, vault bertambah sekali":
    let token = tokenOf(login(MakerUser))
    let open = openSession(token, BranchD, "0.0000")
    check open.code == 201
    let sessionId = open.body["sessionId"].getStr()
    check vaultOf(BranchD) == "100.0000"

    closeCodes = [0, 0]
    let path = SessionsPath & "/" & sessionId & "/close"
    let payload = $ %*{"countedCash": "30.0000"}
    var w1, w2: Thread[CloseArgs]
    createThread(w1, closeWorker, CloseArgs(token: token, path: path, payload: payload,
      key: "sess-race-1-" & $epochTime(), slot: 0))
    createThread(w2, closeWorker, CloseArgs(token: token, path: path, payload: payload,
      key: "sess-race-2-" & $epochTime(), slot: 1))
    joinThread(w1)
    joinThread(w2)

    var codes = @[closeCodes[0], closeCodes[1]]
    codes.sort()
    check codes == @[200, 409]
    # 100 + 30 (counted sekali) = 130; kalau dua kali jadi 160.
    check vaultOf(BranchD) == "130.0000"
