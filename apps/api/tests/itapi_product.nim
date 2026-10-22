## Test integrasi HTTP modul `product` (T-076 + T-086 maker-checker) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi/izin (401/403), submit produk/versi sebagai DRAFT, approve oleh operator lain
## (men-seal, menutup versi ACTIVE sebelumnya, menerbitkan `ProductPublished`), reject berbahasa,
## katalog hanya memuat versi ACTIVE, validasi binding, duplikat → 409, grant bercabang → 403.

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
  ProductsPath = "/api/v1/products"
  DetailPath = "/api/v1/products/{code}"
  VersionsPath = "/api/v1/products/{code}/versions"
  ApprovePath = "/api/v1/products/{code}/versions/{versionId}/approve"
  RejectPath = "/api/v1/products/{code}/versions/{versionId}/reject"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  ApproverUser = "dev.approver"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_product: KRAN_DATABASE_URL kosong — dilewati"
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
  # Approver baru: pengaju dan pemutus harus orang berbeda (D-099), sedangkan `dev.maker` dan
  # `dev.checker` di seed tidak cukup (checker tidak memegang izin produk). Password disalin dari
  # seed supaya kredensialnya sama; penambahan ini hanya di DB uji.
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
     WHERE u.username IN ('dev.maker', 'dev.approver') AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)
  dbPool.release(db)

var app = AppContext(version: "itapi-product-0.0.0", role: "api", startedAt: epochTime(),
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

proc getJson(path: string, token = ""): Reply = call("GET", path, "", token)
proc postJson(path: string, payload: JsonNode, token = ""): Reply = call("POST", path, $payload, token)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc fill(pathTemplate, code, versionId: string): string =
  ## Isi placeholder path; kontrak divalidasi dengan template aslinya, bukan hasil isian.
  pathTemplate.replace("{code}", code).replace("{versionId}", versionId)

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

proc productBody(code, name: string, ptype = "SAVINGS", fromIso = "2026-10-01",
                 bindings: JsonNode = nil): JsonNode =
  let b = if bindings.isNil:
    %*{"product.savings.min_balance": "0.0000",
       "product.savings.admin_fee": "5000.0000"}
  else:
    bindings
  %*{"code": code, "name": name, "productType": ptype, "effectiveFrom": fromIso,
     "bindings": b}

proc versionOf(body: JsonNode, versionNo: int): JsonNode =
  for v in body["versions"]:
    if v["versionNo"].getInt() == versionNo:
      return v
  newJNull()

let makerToken = tokenOf(postJson(LoginPath,
  %*{"username": MakerUser, "password": DevPassword}))
let approverToken = tokenOf(postJson(LoginPath,
  %*{"username": ApproverUser, "password": DevPassword}))
let checkerToken = tokenOf(postJson(LoginPath,
  %*{"username": CheckerUser, "password": DevPassword}))

var
  productId = ""
  v1 = ""
  v2 = ""

suite "product: autentikasi & izin":
  test "tanpa sesi → 401":
    check getJson(ProductsPath).code == 401
    check postJson(ProductsPath, productBody("SAV01", "Simpanan")).code == 401

  test "pemegang izin lain → 403":
    let reply = getJson(ProductsPath, checkerToken)
    check reply.code == 403
    checkProblem(ProductsPath, "GET", "403", reply.body)

  test "checker tanpa izin approve → 403":
    # `dev.checker` (param_checker) tidak punya `product.catalog.approve`.
    let reply = postJson(fill(ApprovePath, "TIDAKADA", "00000000-0000-0000-0000-000000000000"),
      newJObject(), checkerToken)
    check reply.code == 403

suite "product: maker-checker":
  test "submit → DRAFT, tanpa event; draft tidak bocor ke katalog":
    let reply = postJson(ProductsPath, productBody("SAV01", "Simpanan Sukarela"), makerToken)
    check reply.code == 201
    checkJson(ProductsPath, "POST", "201", reply.body)
    check reply.body["code"].getStr() == "SAV01"
    productId = reply.body["productId"].getStr()
    let draft = versionOf(reply.body, 1)
    check draft["status"].getStr() == "DRAFT"
    check draft["effectiveTo"].kind == JNull
    check draft["approvedAt"].kind == JNull
    check draft["rejectReason"].kind == JNull
    check draft["bindings"].len == 2
    v1 = draft["versionId"].getStr()

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'product.draft' AND resource_id = ?""", productId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'ProductPublished' AND aggregate_id = ?""", productId) == "0"

    let list = getJson(ProductsPath & "?asOf=2026-10-15", makerToken)
    check list.code == 200
    checkJson(ProductsPath, "GET", "200", list.body)
    for item in list.body["items"]:
      if item["code"].getStr() == "SAV01":
        check item["currentVersion"].kind == JNull

  test "maker meng-approve dirinya → 409 self_approval":
    let path = fill(ApprovePath, "SAV01", v1)
    let reply = postJson(path, newJObject(), makerToken)
    check reply.code == 409
    checkProblem(ApprovePath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "self_approval"

  test "checker approve → ACTIVE + audit + ProductPublished":
    let path = fill(ApprovePath, "SAV01", v1)
    let reply = postJson(path, newJObject(), approverToken)
    check reply.code == 200
    checkJson(ApprovePath, "POST", "200", reply.body)
    let active = versionOf(reply.body, 1)
    check active["status"].getStr() == "ACTIVE"
    check active["approvedAt"].kind == JString
    check active["rejectReason"].kind == JNull

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'product.approve' AND resource_id = ?""", productId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'ProductPublished' AND aggregate_id = ?""", productId) == "1"
    check dbValue(sql"""
      SELECT status FROM product.product_version WHERE version_id = ?""", v1) == "ACTIVE"

    let list = getJson(ProductsPath & "?asOf=2026-10-15", makerToken)
    for item in list.body["items"]:
      if item["code"].getStr() == "SAV01":
        check item["currentVersion"]["versionNo"].getInt() == 1

  test "approve kedua → 409 not_draft":
    let path = fill(ApprovePath, "SAV01", v1)
    let reply = postJson(path, newJObject(), approverToken)
    check reply.code == 409
    check reply.body["params"]["reason"].getStr() == "not_draft"

  test "reject tanpa reason → 400; dengan reason → REJECTED tanpa event":
    let created = postJson(ProductsPath, productBody("SAV02", "Simpanan Dua"), makerToken)
    check created.code == 201
    let pid = created.body["productId"].getStr()
    let vid = versionOf(created.body, 1)["versionId"].getStr()

    let noReason = postJson(fill(RejectPath, "SAV02", vid), newJObject(), approverToken)
    check noReason.code == 400
    checkProblem(RejectPath, "POST", "400", noReason.body)

    let rejected = postJson(fill(RejectPath, "SAV02", vid), %*{"reason": "atribut salah"},
      approverToken)
    check rejected.code == 200
    checkJson(RejectPath, "POST", "200", rejected.body)
    let rv = versionOf(rejected.body, 1)
    check rv["status"].getStr() == "REJECTED"
    check rv["rejectReason"].getStr() == "atribut salah"
    check rv["approvedAt"].kind == JNull

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'ProductPublished' AND aggregate_id = ?""", pid) == "0"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'product.reject' AND resource_id = ?""", pid) == "1"

    # Draft yang ditolak tidak muncul di katalog.
    let list = getJson(ProductsPath & "?asOf=2026-10-15", makerToken)
    for item in list.body["items"]:
      if item["code"].getStr() == "SAV02":
        check item["currentVersion"].kind == JNull

  test "versi baru tetap DRAFT: tidak menutup versi ACTIVE berjalan":
    let reply = postJson(VersionsPath.replace("{code}", "SAV01"),
      %*{"effectiveFrom": "2026-11-01",
         "bindings": {"product.savings.min_balance": "10000.0000"}}, makerToken)
    check reply.code == 201
    checkJson(VersionsPath, "POST", "201", reply.body)
    check versionOf(reply.body, 1)["effectiveTo"].kind == JNull
    check versionOf(reply.body, 2)["status"].getStr() == "DRAFT"
    v2 = versionOf(reply.body, 2)["versionId"].getStr()

  test "approve versi baru menutup versi ACTIVE lama (inklusif)":
    let approval = postJson(fill(ApprovePath, "SAV01", v2), newJObject(), approverToken)
    check approval.code == 200
    checkJson(ApprovePath, "POST", "200", approval.body)
    check versionOf(approval.body, 1)["effectiveTo"].getStr() == "2026-10-31"
    check versionOf(approval.body, 2)["status"].getStr() == "ACTIVE"

    let october = getJson(ProductsPath & "?asOf=2026-10-31", makerToken)
    for item in october.body["items"]:
      if item["code"].getStr() == "SAV01":
        check item["currentVersion"]["versionNo"].getInt() == 1
    let november = getJson(ProductsPath & "?asOf=2026-11-01", makerToken)
    for item in november.body["items"]:
      if item["code"].getStr() == "SAV01":
        check item["currentVersion"]["versionNo"].getInt() == 2

suite "product: validasi & konflik":
  test "binding ke parameter tak terdaftar → 400":
    let reply = postJson(ProductsPath, productBody("SAV03", "Simpanan Tiga",
      bindings = %*{"product.tidak_ada": "1"}), makerToken)
    check reply.code == 400
    checkProblem(ProductsPath, "POST", "400", reply.body)

  test "tanpa binding / tipe salah / tanggal salah → 400":
    let empty = postJson(ProductsPath, productBody("SAV04", "Kosong", bindings = %*{}),
      makerToken)
    check empty.code == 400
    let badType = postJson(ProductsPath, productBody("SAV05", "Tipe", ptype = "DEPOSITO"),
      makerToken)
    check badType.code == 400
    let badDate = postJson(ProductsPath, productBody("SAV06", "Tanggal",
      fromIso = "2026-02-31"), makerToken)
    check badDate.code == 400

  test "versi mulai besok (H+1) sah sebagai draft, bukan 500":
    let created = postJson(ProductsPath, productBody("SAV-H1", "Versi Harian",
      fromIso = "2026-10-01"), makerToken)
    check created.code == 201
    let next = postJson(VersionsPath.replace("{code}", "SAV-H1"),
      %*{"effectiveFrom": "2026-10-02",
         "bindings": {"product.savings.min_balance": "0.0000"}}, makerToken)
    check next.code == 201
    check versionOf(next.body, 1)["effectiveTo"].kind == JNull
    check versionOf(next.body, 2)["status"].getStr() == "DRAFT"

  test "nilai di luar batas/overflow → 400, bukan 500":
    let overflow = postJson(ProductsPath, productBody("SAV07", "Besar",
      bindings = %*{"product.savings.min_balance": "922337203685478.0000"}), makerToken)
    check overflow.code == 400
    checkProblem(ProductsPath, "POST", "400", overflow.body)
    let negative = postJson(ProductsPath, productBody("SAV08", "Negatif",
      bindings = %*{"product.savings.min_balance": "-1.0000"}), makerToken)
    check negative.code == 400
    let graceTooBig = postJson(ProductsPath, productBody("SAV10", "Grace",
      bindings = %*{"product.savings.grace_period_days": 999}), makerToken)
    check graceTooBig.code == 400
    let wrongKind = postJson(ProductsPath, productBody("SAV11", "Tipe Nilai",
      bindings = %*{"product.savings.min_balance": 1000}), makerToken)
    check wrongKind.code == 400

  test "batas schema rate dihitung dalam persen (1% = 10_000 unit)":
    execDb(sql"""INSERT INTO platform.param_definition
      (key, module, value_type, json_schema, allowed_scopes, description_key,
       since_version, requires_approval, sensitivity)
      VALUES ('product.savings.__rate_test', 'product', 'rate',
              '{"minimum": 1, "maximum": 12}'::jsonb, '{GLOBAL,INSTITUTION}',
              'test.rate', '0.0.0', false, 'NORMAL')
      ON CONFLICT (key) DO NOTHING""")
    let below = postJson(ProductsPath, productBody("SAV-R1", "Rate Bawah",
      bindings = %*{"product.savings.__rate_test": "0.5"}), makerToken)
    check below.code == 400
    checkProblem(ProductsPath, "POST", "400", below.body)
    let above = postJson(ProductsPath, productBody("SAV-R2", "Rate Atas",
      bindings = %*{"product.savings.__rate_test": "12.5"}), makerToken)
    check above.code == 400
    checkProblem(ProductsPath, "POST", "400", above.body)
    let atMin = postJson(ProductsPath, productBody("SAV-R4", "Rate Minimum",
      bindings = %*{"product.savings.__rate_test": "1"}), makerToken)
    check atMin.code == 201
    let ok = postJson(ProductsPath, productBody("SAV-R3", "Rate Pas",
      bindings = %*{"product.savings.__rate_test": "12"}), makerToken)
    check ok.code == 201
    check versionOf(ok.body, 1)["bindings"][0]["value"].getStr() == "12"
    execDb(sql"""DELETE FROM platform.param_definition
                  WHERE key = 'product.savings.__rate_test'""")

  test "kode duplikat → 409":
    let reply = postJson(ProductsPath, productBody("SAV01", "Duplikat"), makerToken)
    check reply.code == 409
    checkProblem(ProductsPath, "POST", "409", reply.body)

  test "produk tidak ada → 404, versi untuk produk tidak ada → 404":
    let detail = getJson(DetailPath.replace("{code}", "TIDAKADA"), makerToken)
    check detail.code == 404
    let version = postJson(VersionsPath.replace("{code}", "TIDAKADA"),
      %*{"effectiveFrom": "2026-11-01", "bindings": {"product.savings.min_balance": "1.0000"}},
      makerToken)
    check version.code == 404
    checkProblem(VersionsPath, "POST", "404", version.body)

  test "approve versi tak dikenal → 404, id bukan UUID → 404":
    let unknown = postJson(fill(ApprovePath, "SAV01", "00000000-0000-0000-0000-000000000000"),
      newJObject(), approverToken)
    check unknown.code == 404
    checkProblem(ApprovePath, "POST", "404", unknown.body)
    let notUuid = postJson(fill(ApprovePath, "SAV01", "bukan-uuid"), newJObject(), approverToken)
    check notUuid.code == 404
    checkProblem(ApprovePath, "POST", "404", notUuid.body)

suite "product: grant bercabang":
  test "grant dibatasi cabang → 403 pada baca & tulis":
    let conn = dbPool.acquire()
    try:
      conn.exec(sql"""
        UPDATE platform.user_role ur SET branch_id = 'cabang-uji'
          FROM platform.app_user u, platform.role r
         WHERE ur.user_id = u.user_id AND ur.role_id = r.role_id
           AND u.username = 'dev.maker' AND r.code = 'platform_admin'""")
      let list = getJson(ProductsPath, makerToken)
      check list.code == 403
      checkProblem(ProductsPath, "GET", "403", list.body)
      check list.body["params"]["reason"].getStr() == "branch_not_allowed"
      let create = postJson(ProductsPath, productBody("SAV09", "Cabang"), makerToken)
      check create.code == 403
      checkProblem(ProductsPath, "POST", "403", create.body)
    finally:
      conn.exec(sql"""
        UPDATE platform.user_role ur SET branch_id = NULL
          FROM platform.app_user u, platform.role r
         WHERE ur.user_id = u.user_id AND ur.role_id = r.role_id
           AND u.username = 'dev.maker' AND r.code = 'platform_admin'""")
      dbPool.release(conn)
    check getJson(ProductsPath, makerToken).code == 200
