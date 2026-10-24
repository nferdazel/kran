## Test integrasi HTTP administrasi pengguna & role (T-117) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: 401 tanpa sesi, 403 tanpa izin `platform.user.manage` (pemegang `param_maker`),
## bentuk daftar (tanpa password hash), tugaskan/cabut role (scope + grant persis), penjagaan admin
## terakhir, transisi status (disable/enable/unlock), dan audit action yang sama dengan `ctl`.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  UsersPath = "/api/v1/users"
  RolesPath = "/api/v1/roles"
  AssignPath = "/api/v1/users/{userId}/roles"
  RevokePath = "/api/v1/users/{userId}/roles/{role}"
  DisablePath = "/api/v1/users/{userId}/disable"
  EnablePath = "/api/v1/users/{userId}/enable"
  UnlockPath = "/api/v1/users/{userId}/unlock"
  LoginPath = "/api/v1/auth/login"
  AdminUser = "itapi.admin"
  PlainUser = "dev.maker" # param_maker: tanpa `platform.user.manage`
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  NoSuchUser = "00000000-0000-4000-8000-000000000000"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_users: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

proc userUid(username: string): string =
  ## Id akun yang sudah ada (dibaca dari DB) — dipakai test untuk memanggil rute by-id.
  let conn = dbPool.acquire()
  try:
    conn.getValue(sql"SELECT user_id::text FROM platform.app_user WHERE username = ?", username)
  finally:
    dbPool.release(conn)

block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))
  # Admin dengan hash dev yang murah (iterasi 1000, seed `dev.maker`). Hanya akun ini yang memegang
  # `platform_admin` di suite ini, sehingga penjagaan "admin terakhir" deterministik.
  execScript(db, """
    INSERT INTO platform.app_user
      (user_id, username, full_name, password_algo, password_hash, must_change_password)
    SELECT gen_random_uuid(), 'itapi.admin', 'Uji Admin (itapi)',
           password_algo, password_hash, false
      FROM platform.app_user WHERE username = 'dev.maker'
  """)
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'itapi.admin' AND r.code = 'platform_admin'
  """)
  dbPool.release(db)

var app = AppContext(version: "itapi-users-0.0.0", role: "api", startedAt: epochTime(),
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

block:
  let port = freePort()
  let server = newApiServer(app)
  createThread(serverThread, serveInThread, ServeArgs(server: server, port: port))
  baseUrl = "http://127.0.0.1:" & $port
  let deadline = epochTime() + 10.0
  var up = false
  while epochTime() < deadline and not up:
    try:
      let probe = newHttpClient(timeout = 1000)
      defer: probe.close()
      up = probe.get(baseUrl & "/healthz").code.int == 200
    except CatchableError:
      discard
    if not up:
      sleep(50)
  doAssert up, "server test tidak pernah siap"

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
  case verb
  of "GET": response = client.get(baseUrl & path)
  of "DELETE": response = client.request(baseUrl & path, httpMethod = HttpDelete)
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
proc postJson(path: string, payload: JsonNode, token = ""): Reply =
  call("POST", path, $payload, token)
proc postEmpty(path: string, token = ""): Reply = call("POST", path, "{}", token)
proc deleteJson(path: string, token = ""): Reply = call("DELETE", path, "", token)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc login(username: string): string =
  let reply = postJson(LoginPath, %*{"username": username, "password": DevPassword})
  doAssert reply.code == 200, "login gagal untuk " & username
  tokenOf(reply)

proc fill(pathTemplate, userId, role: string): string =
  pathTemplate.replace("{userId}", userId).replace("{role}", role)

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

proc dbExec(query: SqlQuery, args: varargs[string, `$`]) =
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

proc newUser(username, fullName: string): string =
  ## Akun tanpa role (dibuat lewat SQL: rute create-user belum ada di API), dikembalikan id-nya.
  let uid = $newId(systemClock())
  dbExec(sql"""
    INSERT INTO platform.app_user
      (user_id, username, full_name, password_algo, password_hash, must_change_password)
    VALUES (?::uuid, ?, ?, 'pbkdf2-hmac-sha256', 'x', false)""", uid, username, fullName)
  uid

proc dropUser(uid: string) =
  dbExec(sql"DELETE FROM platform.user_role WHERE user_id = ?::uuid", uid)
  dbExec(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)

let adminToken = login(AdminUser)
let plainToken = login(PlainUser)

suite "administrasi pengguna: authz (T-117)":
  test "tanpa sesi → 401; tanpa izin platform.user.manage → 403":
    let anon = getJson(UsersPath)
    check anon.code == 401
    checkProblem(UsersPath, "GET", "401", anon.body)

    let denied = getJson(UsersPath, plainToken)
    check denied.code == 403
    checkProblem(UsersPath, "GET", "403", denied.body)

    # Katalog role tunduk pada gerbang yang sama.
    check getJson(RolesPath, plainToken).code == 403
    check postJson(fill(AssignPath, NoSuchUser, ""), %*{"role": "teller"}, plainToken).code == 403

suite "administrasi pengguna: daftar & katalog (T-117)":
  test "daftar pengguna memuat bentuk kontrak tanpa hash kata sandi":
    let reply = getJson(UsersPath, adminToken)
    check reply.code == 200
    checkJson(UsersPath, "GET", "200", reply.body)
    check reply.body["items"].len > 0
    var admin: JsonNode = nil
    for item in reply.body["items"]:
      check not item.hasKey("passwordHash")
      check not item.hasKey("password")
      check item["roles"].kind == JArray
      if item["username"].getStr() == AdminUser:
        admin = item
    check admin != nil
    check admin["status"].getStr() == "ACTIVE"
    var hasAdmin = false
    for g in admin["roles"]:
      if g["role"].getStr() == "platform_admin":
        hasAdmin = true
        check g["branchId"].kind == JNull # grant institusi
    check hasAdmin

  test "katalog role memuat scope; teller BRANCH, platform_admin INSTITUTION":
    let reply = getJson(RolesPath, adminToken)
    check reply.code == 200
    checkJson(RolesPath, "GET", "200", reply.body)
    var tellerScope, adminScope = ""
    for item in reply.body["items"]:
      if item["code"].getStr() == "teller": tellerScope = item["scope"].getStr()
      if item["code"].getStr() == "platform_admin": adminScope = item["scope"].getStr()
    check tellerScope == "BRANCH"
    check adminScope == "INSTITUTION"

suite "master cabang: baca (T-121/O-101)":
  test "admin melihat daftar; tanpa izin 403; role BRANCH boleh membaca":
    const BranchesPath = "/api/v1/branches"
    let ok = getJson(BranchesPath, adminToken)
    check ok.code == 200
    checkJson(BranchesPath, "GET", "200", ok.body)
    var codes: seq[string]
    for item in ok.body["items"]:
      codes.add item["code"].getStr()
      check item["branchId"].getStr().len > 0
      check item["name"].getStr().len > 0
      check item["status"].getStr() in ["ACTIVE", "INACTIVE"]
    check "001" in codes

    let denied = getJson(BranchesPath, plainToken)
    check denied.code == 403
    checkProblem(BranchesPath, "GET", "403", denied.body)

    # Pemegang role ber-scope BRANCH justru pengguna yang butuh daftar ini. Izinnya diberikan ke
    # role (bukan ke user), dan handler sengaja tidak menuntut grant tanpa batas cabang.
    check dbValue(sql"""SELECT count(*)::text FROM platform.role_permission rp
                          JOIN platform.role r ON r.role_id = rp.role_id
                          JOIN platform.permission p ON p.permission_id = rp.permission_id
                         WHERE r.code = 'teller' AND p.code = 'platform.branch.read'""") == "1"

suite "administrasi pengguna: tugaskan & cabut role (T-117)":
  test "scope, duplikat, dan pencabutan grant persis":
    let branch = "b0000000-0000-4000-8000-0000000000aa"
    let other = "b0000000-0000-4000-8000-0000000000bb"
    let uid = newUser("itapi-assign", "Uji Assign")
    defer: dropUser(uid)

    # Role tak dikenal → 400 role_not_found.
    let unknown = postJson(fill(AssignPath, uid, ""), %*{"role": "role-tidak-ada"}, adminToken)
    check unknown.code == 400
    check unknown.body["params"]["reason"].getStr() == "role_not_found"
    checkProblem(AssignPath, "POST", "400", unknown.body)

    # Role BRANCH tanpa cabang & role INSTITUTION dengan cabang → 400 role_scope.
    check postJson(fill(AssignPath, uid, ""), %*{"role": "teller"}, adminToken).code == 400
    check postJson(fill(AssignPath, uid, ""),
      %*{"role": "product_checker", "branchId": branch}, adminToken).code == 400
    check dbValue(sql"""SELECT count(*) FROM platform.user_role WHERE user_id = ?::uuid""",
      uid) == "0"

    # Penugasan sah (institution) → 201, audit ditulis.
    let okInstitution = postJson(fill(AssignPath, uid, ""), %*{"role": "product_checker"},
      adminToken)
    check okInstitution.code == 201
    checkJson(AssignPath, "POST", "201", okInstitution.body)
    check okInstitution.body["branchId"].kind == JNull
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'user.role_grant'
                           AND after_value->>'role' = 'product_checker'
                           AND resource_id = ?""", uid) == "1"

    # Duplikat → 409 already_granted.
    let dup = postJson(fill(AssignPath, uid, ""), %*{"role": "product_checker"}, adminToken)
    check dup.code == 409
    check dup.body["params"]["reason"].getStr() == "already_granted"
    checkProblem(AssignPath, "POST", "409", dup.body)

    # Cabang persis tersimpan untuk role BRANCH.
    check postJson(fill(AssignPath, uid, ""), %*{"role": "teller", "branchId": branch},
      adminToken).code == 201
    check dbValue(sql"""SELECT coalesce(branch_id, '') FROM platform.user_role ur
                          JOIN platform.role r ON r.role_id = ur.role_id
                         WHERE ur.user_id = ?::uuid AND r.code = 'teller'""", uid) == branch

    # Cabut grant persis: cabang salah → 409 not_granted; cabang benar → 204.
    let wrong = deleteJson(fill(RevokePath, uid, "teller") & "?branchId=" & other, adminToken)
    check wrong.code == 409
    check wrong.body["params"]["reason"].getStr() == "not_granted"
    checkProblem(RevokePath, "DELETE", "409", wrong.body)

    let revoked = deleteJson(fill(RevokePath, uid, "teller") & "?branchId=" & branch, adminToken)
    check revoked.code == 204
    check dbValue(sql"""SELECT count(*) FROM platform.user_role ur
                          JOIN platform.role r ON r.role_id = ur.role_id
                         WHERE ur.user_id = ?::uuid AND r.code = 'teller'""", uid) == "0"
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'user.role_revoke' AND resource_id = ?""", uid) == "1"

    # Pengguna tak ada → 404.
    check postJson(fill(AssignPath, NoSuchUser, ""), %*{"role": "product_checker"},
      adminToken).code == 404

  test "penjagaan admin terakhir: cabut role & nonaktifkan admin terakhir ditolak":
    let adminId = userUid(AdminUser)
    check dbValue(sql"""SELECT count(DISTINCT ur.user_id) FROM platform.user_role ur
                          JOIN platform.role r ON r.role_id = ur.role_id
                         WHERE r.code = 'platform_admin'""") == "1"
    let revoke = deleteJson(fill(RevokePath, adminId, "platform_admin"), adminToken)
    check revoke.code == 409
    check revoke.body["params"]["reason"].getStr() == "last_admin"
    checkProblem(RevokePath, "DELETE", "409", revoke.body)
    check dbValue(sql"""SELECT count(*) FROM platform.user_role ur
                          JOIN platform.role r ON r.role_id = ur.role_id
                         WHERE ur.user_id = ?::uuid AND r.code = 'platform_admin'""",
      adminId) == "1"

    let disable = postEmpty(fill(DisablePath, adminId, ""), adminToken)
    check disable.code == 409
    check disable.body["params"]["reason"].getStr() == "last_admin"

  test "penjaga pengelola terakhir mengikuti izin platform.user.manage (T-118, K-7)":
    # Satu-satunya pengelola memakai `ops_admin` (bukan `platform_admin`): penjaganya harus tetap
    # menolak, membuktikan ia mengikuti izin, bukan kode role. `itapi.admin` diparkir dulu supaya
    # jumlah pengelola aktif tepat satu, lalu masuk sebagai pengelola `ops_admin` itu sendiri.
    let uname = "itapi.opsmanager"
    let opsUid = $newId(systemClock())
    dbExec(sql"""
      INSERT INTO platform.app_user
        (user_id, username, full_name, password_algo, password_hash, must_change_password)
      SELECT ?::uuid, ?, 'Uji Ops Manager (itapi)', password_algo, password_hash, false
        FROM platform.app_user WHERE username = 'dev.maker'""", opsUid, uname)
    dbExec(sql"""
      INSERT INTO platform.user_role (user_id, role_id, branch_id)
      SELECT ?::uuid, r.role_id, NULL FROM platform.role r WHERE r.code = 'ops_admin'""", opsUid)
    defer: dropUser(opsUid)

    let adminId = userUid(AdminUser)
    let adminBranch = dbValue(sql"""
      SELECT coalesce(ur.branch_id, '') FROM platform.user_role ur
        JOIN platform.role r ON r.role_id = ur.role_id
       WHERE ur.user_id = ?::uuid AND r.code = 'platform_admin'""", adminId)
    dbExec(sql"""
      DELETE FROM platform.user_role ur USING platform.role r
       WHERE ur.role_id = r.role_id AND ur.user_id = ?::uuid AND r.code = 'platform_admin'""",
      adminId)
    defer: dbExec(sql"""
      INSERT INTO platform.user_role (user_id, role_id, branch_id)
      SELECT ?::uuid, r.role_id, NULLIF(?, '')::uuid FROM platform.role r
       WHERE r.code = 'platform_admin'""", adminId, adminBranch)

    check dbValue(sql"""
      SELECT count(DISTINCT ur.user_id) FROM platform.app_user u
        JOIN platform.user_role ur ON ur.user_id = u.user_id
        JOIN platform.role_permission rp ON rp.role_id = ur.role_id
        JOIN platform.permission p ON p.permission_id = rp.permission_id
       WHERE u.status = 'ACTIVE' AND p.code = 'platform.user.manage'""") == "1"

    let opsToken = login(uname)
    let revoke = deleteJson(fill(RevokePath, opsUid, "ops_admin"), opsToken)
    check revoke.code == 409
    check revoke.body["params"]["reason"].getStr() == "last_admin"
    checkProblem(RevokePath, "DELETE", "409", revoke.body)
    let disable = postEmpty(fill(DisablePath, opsUid, ""), opsToken)
    check disable.code == 409
    check disable.body["params"]["reason"].getStr() == "last_admin"

suite "administrasi pengguna: siklus status (T-117)":
  test "disable mencabut sesi; enable hanya INACTIVE; unlock hanya LOCKED":
    let uid = newUser("itapi-status", "Uji Status")
    defer: dropUser(uid)
    let nowIso = getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    for i in 1 .. 2:
      dbExec(sql"""INSERT INTO platform.session
                     (session_id, user_id, token_hash, expires_at, absolute_expires_at)
                   VALUES (gen_random_uuid(), ?::uuid, ?, ?::timestamptz, ?::timestamptz)""",
        uid, "token-status-" & uid & "-" & $i, nowIso, nowIso)

    # enable/unlock pada akun ACTIVE → 409 dengan alasan yang tepat.
    let enableActive = postEmpty(fill(EnablePath, uid, ""), adminToken)
    check enableActive.code == 409
    check enableActive.body["params"]["reason"].getStr() == "not_inactive"
    checkProblem(EnablePath, "POST", "409", enableActive.body)

    let unlockActive = postEmpty(fill(UnlockPath, uid, ""), adminToken)
    check unlockActive.code == 409
    check unlockActive.body["params"]["reason"].getStr() == "not_locked"

    # disable → INACTIVE + seluruh sesi dicabut.
    let disabled = postEmpty(fill(DisablePath, uid, ""), adminToken)
    check disabled.code == 200
    checkJson(DisablePath, "POST", "200", disabled.body)
    check disabled.body["status"].getStr() == "INACTIVE"
    check dbValue(sql"""SELECT count(*) FROM platform.session
                         WHERE user_id = ?::uuid AND revoked_at IS NULL""", uid) == "0"
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'user.disable' AND resource_id = ?""", uid) == "1"

    # enable → ACTIVE; kedua kali ditolak.
    let enabled = postEmpty(fill(EnablePath, uid, ""), adminToken)
    check enabled.code == 200
    check enabled.body["status"].getStr() == "ACTIVE"
    check postEmpty(fill(EnablePath, uid, ""), adminToken).code == 409
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'user.enable' AND resource_id = ?""", uid) == "1"

    # LOCKED → unlock mengembalikan ACTIVE dan mengosongkan penghitung.
    dbExec(sql"""UPDATE platform.app_user
                    SET status = 'LOCKED', failed_attempts = 3 WHERE user_id = ?::uuid""", uid)
    let unlocked = postEmpty(fill(UnlockPath, uid, ""), adminToken)
    check unlocked.code == 200
    check unlocked.body["status"].getStr() == "ACTIVE"
    check dbValue(sql"SELECT failed_attempts::text FROM platform.app_user WHERE user_id = ?::uuid",
      uid) == "0"
    check postEmpty(fill(UnlockPath, uid, ""), adminToken).code == 409
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'user.unlock' AND resource_id = ?""", uid) == "1"

    # Pengguna tak ada → 404 untuk semua aksi.
    check postEmpty(fill(DisablePath, NoSuchUser, ""), adminToken).code == 404
    check postEmpty(fill(EnablePath, NoSuchUser, ""), adminToken).code == 404
    check postEmpty(fill(UnlockPath, NoSuchUser, ""), adminToken).code == 404
