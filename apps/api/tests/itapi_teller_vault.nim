## Test integrasi HTTP vault kas cabang (T-107) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi/izin (401/403 cabang), validasi 400 (amount ≤ 0, bukan desimal, `branchId`,
## kunci, note), 404 `vault_not_configured` (baca & top-up saat baris vault belum ada),
## 201 + bentuk kontrak, idempotensi (replay 200 + `Idempotent-Replayed`, isi beda 409), audit +
## event outbox, dan **dua top-up bersamaan** (increment atomik dijumlahkan, bukan saling menimpa).
##
## Test me-reset seluruh schema, menyiapkan seed pack `base` + pengguna dev, beberapa vault cabang,
## dan member izin `teller.vault.*` (migrasi `platform/0026`) lewat role `platform_admin`.
##
## **HUMAN-REVIEW-REQUIRED**: mutasi saldo vault kas (AGENTS.md §8).

import std/[algorithm, httpclient, json, net, os, strutils, times, unittest]

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
  VaultPath = "/api/v1/teller/vault"
  TopUpsPath = "/api/v1/teller/vault/topups"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  BranchMakerUser = "dev.branchmaker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchA = "11111111-1111-7111-8111-111111111111"
  BranchB = "22222222-2222-7222-8222-222222222222"
  BranchRace = "44444444-4444-7444-8444-444444444444"
  BranchNoVault = "33333333-3333-7333-8333-333333333333"
  OtherBranch = "99999999-9999-7999-8999-999999999999"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_teller_vault: KRAN_DATABASE_URL kosong — dilewati"
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

  # `dev.maker` (aktor sukses) memegang seluruh izin tanpa batas cabang; `dev.branchmaker` hanya di
  # `OtherBranch` → `authorizedAtBranch` harus menolak `BranchA`.
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

  # BranchA/BranchRace punya vault; BranchNoVault sengaja tanpa baris (uji 404 vault_not_configured).
  for (branch, balance) in [(BranchA, "1000.0000"), (BranchB, "100.0000"),
                            (BranchRace, "100.0000")]:
    execScript(db, "INSERT INTO teller.vault (branch_id, balance) VALUES ('" & branch & "', '" &
      balance & "')")
  dbPool.release(db)

var app = AppContext(version: "itapi-teller-vault-0.0.0", role: "api", startedAt: epochTime(),
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
  "it-vault-" & $idemCounter

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

proc topUpBody(branch, amount: string, note = ""): JsonNode =
  result = %*{"branchId": branch, "amount": amount}
  if note.len > 0:
    result["note"] = %note

proc topUp(token, branch, amount: string, key = ""): Reply =
  postJson(TopUpsPath, topUpBody(branch, amount), token, key)

proc getVault(token, branch: string): Reply =
  call("GET", VaultPath & "?branchId=" & branch, "", token)

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

suite "vault: autentikasi & izin":
  test "tanpa sesi → 401":
    let reply = topUp("", BranchA, "10.0000")
    check reply.code == 401
    checkProblem(TopUpsPath, "POST", "401", reply.body)

  test "top-up izin hanya di cabang lain → 403 branch_not_allowed":
    let token = tokenOf(login(BranchMakerUser))
    check token.len > 0
    let reply = topUp(token, BranchA, "10.0000", "vault-403-" & $epochTime())
    check reply.code == 403
    checkProblem(TopUpsPath, "POST", "403", reply.body)
    check reasonOf(reply) == "branch_not_allowed"

  test "baca izin hanya di cabang lain → 403 branch_not_allowed":
    let token = tokenOf(login(BranchMakerUser))
    let reply = getVault(token, BranchA)
    check reply.code == 403
    checkProblem(VaultPath, "GET", "403", reply.body)
    check reasonOf(reply) == "branch_not_allowed"

suite "vault: validasi 400":
  test "amount ≤ 0 / bukan desimal / branchId salah / note panjang / tanpa kunci → 400":
    let token = tokenOf(login(MakerUser))
    check token.len > 0

    for bad in ["0.0000", "-5.0000", "abc", "1.00001", ""]:
      let reply = topUp(token, BranchA, bad)
      check reply.code == 400
      checkProblem(TopUpsPath, "POST", "400", reply.body)

    let badBranch = topUp(token, "bukan-uuid", "10.0000")
    check badBranch.code == 400
    checkProblem(TopUpsPath, "POST", "400", badBranch.body)

    let longNote = postJson(TopUpsPath, topUpBody(BranchA, "10.0000", repeat('n', 201)), token)
    check longNote.code == 400
    checkProblem(TopUpsPath, "POST", "400", longNote.body)

    let tanpaKunci = postJson(TopUpsPath, topUpBody(BranchA, "10.0000"), token, sendKey = false)
    check tanpaKunci.code == 400
    checkProblem(TopUpsPath, "POST", "400", tanpaKunci.body)

  test "baca tanpa/keliru branchId → 400":
    let token = tokenOf(login(MakerUser))
    let missing = call("GET", VaultPath, "", token)
    check missing.code == 400
    checkProblem(VaultPath, "GET", "400", missing.body)
    let bad = call("GET", VaultPath & "?branchId=nope", "", token)
    check bad.code == 400

suite "vault: baca & top-up":
  test "vault belum dikonfigurasi → 404 vault_not_configured (baca & top-up)":
    let token = tokenOf(login(MakerUser))

    let read = getVault(token, BranchNoVault)
    check read.code == 404
    checkProblem(VaultPath, "GET", "404", read.body)
    check reasonOf(read) == "vault_not_configured"

    let top = topUp(token, BranchNoVault, "10.0000", "vault-novault-" & $epochTime())
    check top.code == 404
    checkProblem(TopUpsPath, "POST", "404", top.body)
    check reasonOf(top) == "vault_not_configured"

  test "baca saldo 200 sesuai kontrak":
    let token = tokenOf(login(MakerUser))
    let reply = getVault(token, BranchB)
    check reply.code == 200
    checkJson(VaultPath, "GET", "200", reply.body)
    check reply.body["branchId"].getStr() == BranchB
    check reply.body["balance"].getStr() == "100.0000"

  test "top-up 201 menambah vault + audit + event":
    let token = tokenOf(login(MakerUser))
    let before = vaultOf(BranchA)
    let auditsBefore = auditCount("teller.vault.topup")
    let eventsBefore = outboxCount("TellerVaultTopedUp")

    let reply = topUp(token, BranchA, "250.0000", "vault-add-" & $epochTime())
    check reply.code == 201
    checkJson(TopUpsPath, "POST", "201", reply.body)
    check reply.body["branchId"].getStr() == BranchA
    check reply.body["balanceAfter"].getStr() == "1250.0000"
    check vaultOf(BranchA) == "1250.0000"
    check before == "1000.0000"
    check auditCount("teller.vault.topup") == auditsBefore + 1
    check outboxCount("TellerVaultTopedUp") == eventsBefore + 1

  test "replay kunci+isi sama → 200 tanpa menambah vault; isi beda → 409":
    let token = tokenOf(login(MakerUser))
    let key = "vault-idem-" & $epochTime()
    let first = topUp(token, BranchB, "25.0000", key)
    check first.code == 201
    let afterFirst = vaultOf(BranchB)

    let replay = topUp(token, BranchB, "25.0000", key)
    check replay.code == 200
    check replay.replayed == "true"
    check replay.body["balanceAfter"].getStr() == first.body["balanceAfter"].getStr()
    check vaultOf(BranchB) == afterFirst

    let mismatch = topUp(token, BranchB, "30.0000", key)
    check mismatch.code == 409
    checkProblem(TopUpsPath, "POST", "409", mismatch.body)

var topUpCodes: array[2, int]

type TopUpArgs = object
  token: string
  payload: string
  key: string
  slot: int

proc topUpWorker(args: TopUpArgs) {.thread.} =
  {.cast(gcsafe).}:
    let client = newHttpClient(timeout = 15000)
    client.headers["Cookie"] = CookieName & "=" & args.token
    client.headers["Content-Type"] = "application/json"
    client.headers["Idempotency-Key"] = args.key
    let response = client.post(baseUrl & TopUpsPath, args.payload)
    topUpCodes[args.slot] = response.code.int
    client.close()

suite "vault: dua top-up bersamaan":
  test "dua 201, vault bertambah jumlah keduanya (increment atomik)":
    let token = tokenOf(login(MakerUser))
    check vaultOf(BranchRace) == "100.0000"

    topUpCodes = [0, 0]
    var w1, w2: Thread[TopUpArgs]
    createThread(w1, topUpWorker, TopUpArgs(token: token,
      payload: $topUpBody(BranchRace, "30.0000"), key: "vault-race-1-" & $epochTime(), slot: 0))
    createThread(w2, topUpWorker, TopUpArgs(token: token,
      payload: $topUpBody(BranchRace, "20.0000"), key: "vault-race-2-" & $epochTime(), slot: 1))
    joinThread(w1)
    joinThread(w2)

    var codes = @[topUpCodes[0], topUpCodes[1]]
    codes.sort()
    check codes == @[201, 201]
    # 100 + 30 + 20 = 150; kalau ada lost update jadi 130 atau 120.
    check vaultOf(BranchRace) == "150.0000"
