## Test integrasi HTTP modul `deposit` (T-088a) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi/izin (401/403), buka rekening dari produk SAVINGS versi ACTIVE, validasi 400,
## konflik 409 (`party_not_active`/`branch_mismatch`/`product_not_active`), baca satu + daftar per
## party, dan idempotency (replay 200 + `Idempotent-Replayed`, hash beda 409, tanpa header 400).
##
## Test ini me-reset seluruh schema modul, lalu menyiapkan seed pack `base`, seed pengguna dev, satu
## party + produk `SAV-DEP` ber-versi ACTIVE, dan grant `platform_admin` untuk `dev.maker`. Data dev
## murni sintetis.

import std/[httpclient, json, net, options, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import deposit/domain/account
import deposit/infrastructure/account_repo
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  AccountsPath = "/api/v1/deposit/accounts"
  AccountItemPath = "/api/v1/deposit/accounts/{accountId}"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "11111111-1111-7111-8111-111111111111"
  OtherBranchId = "22222222-2222-7222-8222-222222222222"
  ProductCode = "SAV-DEP"
  KindProductCode = "SAV-POKOK"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_deposit: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

var PartyId = ""

# --- penyiapan DB: skema bersih + seed pack + fixture party/produk ----------------------------
block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))
  # `dev.maker` hanya memegang `param_maker` di seed; untuk menguji jalur sukses ia diberi
  # `platform_admin` (pemegang seluruh izin, termasuk izin deposit) di DB uji.
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.maker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

  # Pengguna ber-scope cabang untuk menguji gerbang `authorizedAtBranch` (bukan hanya
  # `authorizedAnyBranch`). Password disalin dari dev.maker supaya login memakai kredensial dev.
  execScript(db, """
    INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                                   password_updated_at, must_change_password)
    SELECT gen_random_uuid(), 'dev.branchmaker', 'Dev Branch Maker', password_algo, password_hash,
           password_updated_at, false
      FROM platform.app_user WHERE username = 'dev.maker'
  """)
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, '""" & OtherBranchId & """'
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.branchmaker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

  let fixtureClock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))
  let actor = Id("77777777-7777-7777-8777-777777777777")
  let approver = Id("88888888-8888-7888-8888-888888888888")
  let party = newParty(newId(fixtureClock), pkPerson, "Budi Santoso", Id(BranchId),
    "{seq:6}{check}", nextCifSeq(db))
  discard insertParty(db, party, actor)
  PartyId = $party.partyId

  let prod = Product(productId: newId(fixtureClock), code: ProductCode,
    name: "Simpanan Sukarela", productType: ptSavings)
  let ver = ProductVersion(versionId: newId(fixtureClock), productId: prod.productId,
    versionNo: 1, effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prod, actor)
    insertVersion(d, ver, actor)
    insertBinding(d, ver.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"0.0000"))
    1)
  doAssert approveVersion(db, ver.versionId, approver), "versi produk uji gagal di-approve"

  # Produk berklasifikasi POKOK (T-111): rekeningnya harus membawa `savingsKind` hasil join produk.
  let prodPokok = Product(productId: newId(fixtureClock), code: KindProductCode,
    name: "Simpanan Pokok", productType: ptSavings, savingsKind: some(skPokok))
  let verPokok = ProductVersion(versionId: newId(fixtureClock), productId: prodPokok.productId,
    versionNo: 1, effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prodPokok, actor)
    insertVersion(d, verPokok, actor)
    insertBinding(d, verPokok.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"0.0000"))
    1)
  doAssert approveVersion(db, verPokok.versionId, approver), "versi produk pokok gagal di-approve"
  dbPool.release(db)

var app = AppContext(version: "itapi-deposit-0.0.0", role: "api", startedAt: epochTime(),
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
    replayed: string

var idemCounter = 0

proc autoIdemKey(): string =
  inc idemCounter
  "it-deposit-" & $idemCounter

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

proc getJson(path: string, token = ""): Reply =
  call("GET", path, "", token)

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

proc dbCount(query: SqlQuery, args: varargs[string, `$`]): int =
  let conn = dbPool.acquire()
  try:
    parseInt(conn.getValue(query, args))
  finally:
    dbPool.release(conn)

proc dbText(query: SqlQuery, args: varargs[string, `$`]): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args)
  finally:
    dbPool.release(conn)

proc accountBody(partyId = PartyId, productCode = ProductCode,
    branchId = BranchId): JsonNode =
  %*{"partyId": partyId, "productCode": productCode, "branchId": branchId}

# --- suite ------------------------------------------------------------------------------------

suite "deposit: autentikasi & izin":
  test "tanpa sesi → 401":
    let create = postJson(AccountsPath, accountBody())
    check create.code == 401
    checkProblem(AccountsPath, "POST", "401", create.body)

    let read = getJson(AccountsPath & "/" & PartyId)
    check read.code == 401
    checkProblem(AccountItemPath, "GET", "401", read.body)

  test "pemegang izin lain → 403":
    let checker = login(CheckerUser)
    check checker.code == 200
    let create = postJson(AccountsPath, accountBody(), tokenOf(checker))
    check create.code == 403
    checkProblem(AccountsPath, "POST", "403", create.body)

suite "deposit: gerbang cabang":
  test "pengguna ber-scope cabang lain ditolak saat membuat & membaca rekening":
    let maker = login(MakerUser)
    check maker.code == 200
    let created = postJson(AccountsPath, accountBody(branchId = BranchId), tokenOf(maker))
    check created.code == 201
    let accountId = created.body["accountId"].getStr()

    let scoped = login("dev.branchmaker")
    check scoped.code == 200
    let token = tokenOf(scoped)

    let create = postJson(AccountsPath, accountBody(branchId = BranchId), token,
      "branch-create-" & $epochTime())
    check create.code == 403
    checkProblem(AccountsPath, "POST", "403", create.body)
    check create.body["params"]["reason"].getStr() == "branch_not_allowed"

    let read = getJson(AccountsPath & "/" & accountId, token)
    check read.code == 403
    checkProblem(AccountItemPath, "GET", "403", read.body)
    check read.body["params"]["reason"].getStr() == "branch_not_allowed"

    let listed = getJson(AccountsPath & "?partyId=" & PartyId, token)
    check listed.code == 200
    checkJson(AccountsPath, "GET", "200", listed.body)
    check listed.body["items"].len == 0

  test "klaim idempotency tidak tersisa saat request gagal":
    let maker = login(MakerUser)
    check maker.code == 200
    let key = "deposit-fail-claim-" & $epochTime()
    let bad = postJson(AccountsPath, accountBody(branchId = OtherBranchId), tokenOf(maker), key)
    check bad.code == 409
    let good = postJson(AccountsPath, accountBody(branchId = BranchId), tokenOf(maker), key)
    check good.code == 201

suite "deposit: buka & baca rekening":
  test "buka rekening → 201, nomor provisoris, saldo 0":
    let maker = login(MakerUser)
    check maker.code == 200
    let token = tokenOf(maker)

    let created = postJson(AccountsPath, accountBody(), token)
    check created.code == 201
    checkJson(AccountsPath, "POST", "201", created.body)
    check created.body["accountType"].getStr() == "SAVINGS"
    check created.body["status"].getStr() == "ACTIVE"
    check created.body["balance"].getStr() == "0.0000"
    check created.body["productCode"].getStr() == ProductCode
    check created.body["branchId"].getStr() == BranchId
    check created.body["partyId"].getStr() == PartyId
    check created.body["openedOn"].getStr().len == 10
    let accountNo = created.body["accountNo"].getStr()
    check accountNo.len == 10
    check accountNo.allCharsInSet({'0' .. '9'})

    let accountId = created.body["accountId"].getStr()
    check accountId.len == 36

    # Saldo awal benar-benar 0 di DB (bukan hanya di respons).
    check dbText(sql"""
      SELECT balance::text FROM deposit.account_balance WHERE account_id = ?""",
      accountId) == "0.0000"
    check dbCount(sql"""
      SELECT count(*)::text FROM deposit.account WHERE party_id = ?""",
      PartyId) >= 1

    # Baca lewat HTTP harus sama dengan yang dibuat.
    let read = getJson(AccountsPath & "/" & accountId, token)
    check read.code == 200
    checkJson(AccountItemPath, "GET", "200", read.body)
    check read.body == created.body

  test "rekening membawa savingsKind produk; tanpa klasifikasi → null (T-111)":
    let token = tokenOf(login(MakerUser))
    let pokok = postJson(AccountsPath, accountBody(productCode = KindProductCode), token)
    check pokok.code == 201
    checkJson(AccountsPath, "POST", "201", pokok.body)
    check pokok.body["savingsKind"].getStr() == "POKOK"

    let plain = postJson(AccountsPath, accountBody(), token)
    check plain.code == 201
    check plain.body["savingsKind"].kind == JNull

  test "daftar rekening per party + validasi partyId":
    let token = tokenOf(login(MakerUser))
    let listed = getJson(AccountsPath & "?partyId=" & PartyId, token)
    check listed.code == 200
    checkJson(AccountsPath, "GET", "200", listed.body)
    check listed.body["items"].len >= 1

    let missing = getJson(AccountsPath, token)
    check missing.code == 400
    checkProblem(AccountsPath, "GET", "400", missing.body)

    let badUuid = getJson(AccountsPath & "?partyId=bukan-uuid", token)
    check badUuid.code == 400
    checkProblem(AccountsPath, "GET", "400", badUuid.body)

  test "cari rekening per nomor: sendiri, cabang lain, tidak ada, validasi":
    let token = tokenOf(login(MakerUser))
    let created = postJson(AccountsPath, accountBody(), token)
    check created.code == 201
    let accountNo = created.body["accountNo"].getStr()

    let own = getJson(AccountsPath & "?accountNo=" & accountNo, token)
    check own.code == 200
    checkJson(AccountsPath, "GET", "200", own.body)
    check own.body["items"].len == 1
    check own.body["items"][0]["accountId"].getStr() == created.body["accountId"].getStr()

    # Cabang lain: hasil kosong, bukan 403/404 (tidak membocorkan keberadaan).
    let scoped = tokenOf(login("dev.branchmaker"))
    let hidden = getJson(AccountsPath & "?accountNo=" & accountNo, scoped)
    check hidden.code == 200
    check hidden.body["items"].len == 0

    let missing = getJson(AccountsPath & "?accountNo=9999999999", token)
    check missing.code == 200
    check missing.body["items"].len == 0

    let both = getJson(AccountsPath & "?partyId=" & PartyId & "&accountNo=" & accountNo, token)
    check both.code == 400
    checkProblem(AccountsPath, "GET", "400", both.body)

    let tooLong = getJson(AccountsPath & "?accountNo=" & "9".repeat(33), token)
    check tooLong.code == 400
    checkProblem(AccountsPath, "GET", "400", tooLong.body)

  test "rekening tidak ada → 404":
    let token = tokenOf(login(MakerUser))
    let missing = getJson(AccountsPath & "/99999999-9999-7999-8999-999999999999", token)
    check missing.code == 404
    checkProblem(AccountItemPath, "GET", "404", missing.body)

suite "deposit: konflik & validasi":
  test "cabang beda dengan party → 409 branch_mismatch":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(AccountsPath, accountBody(branchId = OtherBranchId), token)
    check reply.code == 409
    checkProblem(AccountsPath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "branch_mismatch"

  test "party tidak ada → 409 party_not_active":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(AccountsPath,
      accountBody(partyId = "99999999-9999-7999-8999-999999999999"), token)
    check reply.code == 409
    check reply.body["params"]["reason"].getStr() == "party_not_active"

  test "produk tidak ada → 409 product_not_active":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(AccountsPath, accountBody(productCode = "TIDAK-ADA"), token)
    check reply.code == 409
    check reply.body["params"]["reason"].getStr() == "product_not_active"

  test "badan tidak sah → 400":
    let token = tokenOf(login(MakerUser))

    let badParty = postJson(AccountsPath,
      %*{"partyId": "bukan-uuid", "productCode": ProductCode, "branchId": BranchId}, token)
    check badParty.code == 400
    checkProblem(AccountsPath, "POST", "400", badParty.body)

    let noProduct = postJson(AccountsPath,
      %*{"partyId": PartyId, "branchId": BranchId}, token)
    check noProduct.code == 400
    checkProblem(AccountsPath, "POST", "400", noProduct.body)

test "idempotency: kunci sama replay, isi beda 409, tanpa header 400":
  let token = tokenOf(login(MakerUser))
  let body = accountBody()
  let first = postJson(AccountsPath, body, token, "idem-deposit-1")
  check first.code == 201
  let accountId = first.body["accountId"].getStr()

  let accounts = "SELECT count(*)::text FROM deposit.account"
  let audits = "SELECT count(*)::text FROM platform.audit_log " &
    "WHERE action = 'deposit.account.open'"
  let accountsBefore = dbCount(sql(accounts))
  let auditsBefore = dbCount(sql(audits))

  let replay = postJson(AccountsPath, body, token, "idem-deposit-1")
  check replay.code == 200
  check replay.replayed == "true"
  check replay.body["accountId"].getStr() == accountId
  # Replay tidak menulis rekening/audit kedua.
  check dbCount(sql(accounts)) == accountsBefore
  check dbCount(sql(audits)) == auditsBefore

  # Isi beda pada kunci yang sama → 409. Body ini sendiri sah (kode produk dinormalkan handler),
  # jadi 409 hanya bisa datang dari cabang idempotensi, bukan dari validasi bisnis.
  let mismatch = postJson(AccountsPath, accountBody(productCode = "sav-dep"), token,
    "idem-deposit-1")
  check mismatch.code == 409
  checkProblem(AccountsPath, "POST", "409", mismatch.body)

  let tanpaKunci = postJson(AccountsPath, accountBody(), token, sendKey = false)
  check tanpaKunci.code == 400
  checkProblem(AccountsPath, "POST", "400", tanpaKunci.body)

suite "deposit: data server rusak → 500 (T-099)":
  test "nomor urut sequence melebihi lebar → 500, bukan 400, tanpa rekening baru":
    let token = tokenOf(login(MakerUser))
    let accountsBefore = dbCount(sql"SELECT count(*)::text FROM deposit.account")
    let seqBefore = dbText(sql"SELECT last_value::text FROM deposit.account_seq")
    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      discard d.getValue(sql"SELECT setval('deposit.account_seq', 9999999999)")
      1)
    try:
      let reply = postJson(AccountsPath, accountBody(), token, "overflow-seq-" & $epochTime())
      check reply.code == 500
      checkProblem(AccountsPath, "POST", "500", reply.body)
      # Transaksi di-rollback: tidak ada rekening setengah jadi.
      check dbCount(sql"SELECT count(*)::text FROM deposit.account") == accountsBefore
    finally:
      discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
        discard d.getValue(sql"SELECT setval('deposit.account_seq', ?::bigint)", seqBefore)
        1)

suite "deposit: batas daftar rekening (T-100)":
  test "?partyId= dibatasi 200 baris walau party punya lebih banyak rekening":
    let token = tokenOf(login(MakerUser))
    let actor = Id("77777777-7777-7777-8777-777777777777")
    let clock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))
    let productId = Id(dbText(sql"""
      SELECT product_id::text FROM product.product WHERE code = ?""", ProductCode))
    let versionId = Id(dbText(sql"""
      SELECT v.version_id::text
        FROM product.product_version v
        JOIN product.product p ON p.product_id = v.product_id
       WHERE p.code = ?
       ORDER BY v.version_no DESC
       LIMIT 1""", ProductCode))

    # Seed langsung lewat repo: 205 POST HTTP jauh lebih lambat dan tidak menambah cakupan.
    let seedConn = dbPool.acquire()
    try:
      exec(seedConn, sql"BEGIN")
      for _ in 0 ..< 205:
        let a = newAccount(newId(clock), Id(PartyId), productId, versionId, ProductCode,
          Id(BranchId), "2026-10-01", nextAccountSeq(seedConn))
        insertAccount(seedConn, a, actor)
      exec(seedConn, sql"COMMIT")
    finally:
      dbPool.release(seedConn)

    check dbCount(sql"SELECT count(*)::text FROM deposit.account WHERE party_id = ?",
      PartyId) > 200
    let listed = getJson(AccountsPath & "?partyId=" & PartyId, token)
    check listed.code == 200
    checkJson(AccountsPath, "GET", "200", listed.body)
    check listed.body["items"].len == 200
