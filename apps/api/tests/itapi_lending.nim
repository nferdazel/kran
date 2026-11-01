## Test integrasi HTTP modul `lending` (T-163) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi/izin (401/403), pengajuan oleh maker (201, audit, `LoanSubmitted`),
## persetujuan diri sendiri (409 `self_approval`), persetujuan oleh checker (200, audit,
## `LoanApproved`), keputusan kedua (409 `not_applied`), plafon parameter (409 `limit_exceeded`),
## versi produk yang belum ACTIVE, dan anggota yang tidak aktif.
##
## Fixture dibuat lewat SQL langsung: yang diuji adalah handler beserta transaksinya, bukan jalur
## pembuatan anggota/produk (itu `itapi_party`/`itapi_product`).

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
  LoansPath = "/api/v1/lending/loans"
  ApprovePath = "/api/v1/lending/loans/{loanId}/approve"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  ApproverUser = "dev.approver"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  # Fixture tetap: satu cabang, satu anggota aktif, satu anggota suspended.
  BranchId = "11111111-1111-7111-8111-111111111111"
  PartyId = "22222222-2222-7222-8222-222222222222"
  PartySuspendedId = "33333333-3333-7333-8333-333333333333"
  ActorId = "77777777-7777-7777-8777-777777777777"
  MakerId = "88888888-8888-7888-8888-888888888888"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_lending: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

var versionActive = ""
var versionDraft = ""

block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))
  # `dev.approver` tidak ada di seed dev; dibuat dari hash pengguna seed lain supaya kata
  # sandinya sama. Hanya untuk DB uji.
  execScript(db, """
    INSERT INTO platform.app_user
      (user_id, username, full_name, password_algo, password_hash, must_change_password)
    SELECT md5('dev|dev.approver')::uuid, 'dev.approver', 'Uji Approver (dev)',
           password_algo, password_hash, false
      FROM platform.app_user WHERE username = 'dev.checker'
    ON CONFLICT (username) DO UPDATE SET must_change_password = false, status = 'ACTIVE'
  """)
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username IN ('dev.maker', 'dev.approver')
       AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO party.party (party_id, cif, kind, display_name, status, branch_id,
                             created_by, updated_by)
    VALUES
      ('""" & PartyId & """', 'LN000001', 'PERSON', 'Siti Aminah', 'ACTIVE',
       '""" & BranchId & """', '""" & ActorId & """', '""" & ActorId &
      """'),
      ('""" & PartySuspendedId &
      """', 'LN000002', 'PERSON', 'Budi Suspend', 'SUSPENDED',
       '""" & BranchId & """', '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO lending.loan_product (product_id, code, name, created_by)
    VALUES (md5('lending|product-active')::uuid, 'LNPILOT', 'Pinjaman Modal Kerja',
            '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO lending.loan_product_version
      (version_id, product_id, version_no, status, schedule_method, tenor_months, annual_rate,
       allocation_order, created_by, approved_by)
    VALUES
      (md5('lending|version-active')::uuid, md5('lending|product-active')::uuid, 1, 'ACTIVE',
       'ANNUITY', 12, 150000, 'INTEREST,PRINCIPAL,PENALTY', '""" & MakerId &
      """',
       '""" & ActorId & """'),
      (md5('lending|version-draft')::uuid, md5('lending|product-active')::uuid, 2, 'DRAFT',
       'FLAT', 6, 120000, 'PRINCIPAL,INTEREST,PENALTY', '""" & MakerId & """', NULL)
  """)
  versionActive = db.getValue(sql"SELECT md5('lending|version-active')::uuid::text")
  versionDraft = db.getValue(sql"SELECT md5('lending|version-draft')::uuid::text")
  dbPool.release(db)

var app = AppContext(version: "itapi-lending-0.0.0", role: "api", startedAt: epochTime(),
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

proc call(verb, path, payload, token: string): Reply =
  let client = newHttpClient(timeout = 60_000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
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

proc postJson(path: string, payload: JsonNode, token = ""): Reply =
  call("POST", path, $payload, token)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc fill(pathTemplate, loanId: string): string =
  pathTemplate.replace("{loanId}", loanId)

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
  for problem in problems:
    checkpoint problem

proc execDb(query: SqlQuery, args: varargs[string, `$`]) =
  let conn = dbPool.acquire()
  try:
    conn.exec(query, args)
  finally:
    dbPool.release(conn)

proc dbValue(query: SqlQuery, args: varargs[string, `$`]): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args)
  finally:
    dbPool.release(conn)

proc loanBody(partyId, versionId, principal: string): JsonNode =
  %*{"partyId": partyId, "productVersionId": versionId, "principal": principal}

let
  makerToken = tokenOf(postJson(LoginPath, %*{"username": MakerUser, "password": DevPassword}))
  approverToken = tokenOf(postJson(LoginPath, %*{"username": ApproverUser,
    "password": DevPassword}))
  checkerToken = tokenOf(postJson(LoginPath, %*{"username": CheckerUser,
    "password": DevPassword}))

doAssert makerToken.len > 0 and approverToken.len > 0 and checkerToken.len > 0,
  "login fixture gagal"

suite "lending: autentikasi & izin":
  test "tanpa sesi → 401":
    let r = postJson(LoansPath, loanBody(PartyId, versionActive, "5000000.00"))
    check r.code == 401

  test "pengguna tanpa izin lending → 403":
    # `dev.checker` memegang izin katalog produk, bukan pinjaman.
    let r = postJson(LoansPath, loanBody(PartyId, versionActive, "5000000.00"), checkerToken)
    check r.code == 403
    check r.body["params"]["permission"].getStr() == "lending.loan.submit"

suite "lending: pengajuan":
  test "pengajuan sah → 201 APPLIED + audit + LoanSubmitted":
    let r = postJson(LoansPath, loanBody(PartyId, versionActive, "5000000.00"), makerToken)
    check r.code == 201
    checkJson(LoansPath, "POST", "201", r.body)
    let loanId = r.body["loanId"].getStr()
    check r.body["status"].getStr() == "APPLIED"
    check r.body["branchId"].getStr() == BranchId
    check r.body["principal"].getStr() == "5000000.00"
    check r.body["disbursedOn"].kind == JNull
    check dbValue(sql"SELECT status FROM lending.loan WHERE loan_id = ?", loanId) == "APPLIED"
    check dbValue(sql"""SELECT approved_by::text FROM lending.loan WHERE loan_id = ?""",
      loanId).len == 0
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'lending.loan.submit' AND resource_id = ?""", loanId) == "1"
    check dbValue(sql"""SELECT count(*) FROM platform.outbox
                         WHERE event_type = 'LoanSubmitted' AND aggregate_id = ?""", loanId) == "1"

  test "plafon parameter: tepat di plafon diterima, di atasnya 409 limit_exceeded":
    let atLimit = postJson(LoansPath, loanBody(PartyId, versionActive, "100000000.00"), makerToken)
    check atLimit.code == 201
    let overLimit = postJson(LoansPath, loanBody(PartyId, versionActive, "100000000.01"),
      makerToken)
    check overLimit.code == 409
    check overLimit.body["params"]["reason"].getStr() == "limit_exceeded"
    checkProblem(LoansPath, "POST", "409", overLimit.body)

  test "versi produk DRAFT tidak boleh dipakai akad":
    let r = postJson(LoansPath, loanBody(PartyId, versionDraft, "5000000.00"), makerToken)
    check r.code == 409
    check r.body["params"]["reason"].getStr() == "product_version_not_active"

  test "anggota tidak aktif ditolak":
    let r = postJson(LoansPath, loanBody(PartySuspendedId, versionActive, "5000000.00"),
      makerToken)
    check r.code == 409
    check r.body["params"]["reason"].getStr() == "party_not_active"

  test "anggota/versi yang tidak ada → 404":
    let noParty = postJson(LoansPath,
      loanBody("44444444-4444-7444-8444-444444444444", versionActive, "5000000.00"), makerToken)
    check noParty.code == 404
    check noParty.body["params"]["reason"].getStr() == "party_not_found"
    let noVersion = postJson(LoansPath,
      loanBody(PartyId, "55555555-5555-7555-8555-555555555555", "5000000.00"), makerToken)
    check noVersion.code == 404
    check noVersion.body["params"]["reason"].getStr() == "product_version_not_found"

  test "pokok bukan nominal sah → 400":
    let r = postJson(LoansPath, loanBody(PartyId, versionActive, "0"), makerToken)
    check r.code == 400
    checkProblem(LoansPath, "POST", "400", r.body)

suite "lending: persetujuan":
  proc submitted(): string =
    let r = postJson(LoansPath, loanBody(PartyId, versionActive, "7500000.00"), makerToken)
    check r.code == 201
    r.body["loanId"].getStr()

  test "pengaju tidak boleh menyetujui pengajuannya sendiri":
    let loanId = submitted()
    let r = postJson(fill(ApprovePath, loanId), %*{}, makerToken)
    check r.code == 409
    check r.body["params"]["reason"].getStr() == "self_approval"
    checkProblem(ApprovePath, "POST", "409", r.body)
    check dbValue(sql"SELECT status FROM lending.loan WHERE loan_id = ?", loanId) == "APPLIED"

  test "checker lain menyetujui → 200 APPROVED + audit + LoanApproved":
    let loanId = submitted()
    let r = postJson(fill(ApprovePath, loanId), %*{}, approverToken)
    check r.code == 200
    checkJson(ApprovePath, "POST", "200", r.body)
    check r.body["status"].getStr() == "APPROVED"
    check dbValue(sql"""SELECT approved_by::text FROM lending.loan WHERE loan_id = ?""",
      loanId) ==
      dbValue(sql"SELECT md5('dev|dev.approver')::uuid::text")
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'lending.loan.approve' AND resource_id = ?""", loanId) == "1"
    check dbValue(sql"""SELECT count(*) FROM platform.outbox
                         WHERE event_type = 'LoanApproved' AND aggregate_id = ?""", loanId) == "1"

  test "persetujuan kedua → 409 not_applied":
    let loanId = submitted()
    check postJson(fill(ApprovePath, loanId), %*{}, approverToken).code == 200
    let again = postJson(fill(ApprovePath, loanId), %*{}, approverToken)
    check again.code == 409
    check again.body["params"]["reason"].getStr() == "not_applied"

  test "pinjaman tidak ada / loanId bukan uuid → 404":
    check postJson(fill(ApprovePath, "66666666-6666-7666-8666-666666666666"), %*{},
      approverToken).code == 404
    check postJson(fill(ApprovePath, "bukan-uuid"), %*{}, approverToken).code == 404
