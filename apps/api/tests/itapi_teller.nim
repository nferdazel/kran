## Test integrasi HTTP transaksi tunai teller (T-088b) — butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi/izin (401/403), validasi 400, akun tidak ada 404, setor/tarik 201 dengan saldo
## yang benar, konflik 409 `insufficient_funds`, idempotency (replay 200 + `Idempotent-Replayed`,
## isi beda 409, tanpa header 400), dan periode CLOSED → 409 `period_closed` **tanpa** perubahan
## saldo/baris/jurnal (bukti satu transaksi DB).
##
## Test me-reset seluruh schema, menyiapkan seed pack `base`, seed pengguna dev, satu party + produk
## `SAV-DEP` ber-versi ACTIVE, periode Oktober OPEN, dan beberapa rekening sintetis. Business date
## dikunci lewat `FakeClock` (2026-10-22) supaya periode uji deterministik.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids, money, result]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import deposit/domain/account
import deposit/infrastructure/account_repo
import ledger/domain/period
import ledger/infrastructure/ledger_repo
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

import ../src/[context, deposit_posting, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  CashPath = "/api/v1/teller/cash-transactions"
  TransferPath = "/api/v1/teller/transfers"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "11111111-1111-7111-8111-111111111111"
  OtherBranchId = "22222222-2222-7222-8222-222222222222"
  ProductCode = "SAV-DEP"
  BusinessDate = "2026-10-22"
  ## Cukup untuk seluruh suite (tiap test memakai rekening segar); fixture di bawah menyiapkan
  ## sebanyak ini.
  AccountFixtures = 30

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_teller: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

var fixtureActor: Id
var
  PartyId: string
  AccountIds: seq[string]
  BrokenAccountId: string
  OtherBranchAccountId: string
  HighMinAccountId: string

# --- penyiapan DB: skema bersih + seed pack + fixture party/produk/rekening --------------------
block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))
  # `dev.maker` hanya memegang `param_maker` di seed; jalur sukses diuji dengan `platform_admin`
  # (pemegang seluruh izin, termasuk izin teller dari migrasi `platform/0024`).
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.maker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

  # Pengguna ber-scope cabang lain: `requirePermission` lolos (grant ada), tetapi
  # `authorizedAtBranch` harus menolak rekening cabang `BranchId`.
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

  # Pengguna yang izin teller-nya hanya di `BranchId`: dipakai membuktikan gerbang cabang
  # **tujuan** PB (sumber boleh, tujuan cabang lain harus 403).
  execScript(db, """
    INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                                   password_updated_at, must_change_password)
    SELECT gen_random_uuid(), 'dev.branchmaker2', 'Dev Branch Maker 2', password_algo,
           password_hash, password_updated_at, false
      FROM platform.app_user WHERE username = 'dev.maker'
  """)
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, '""" & BranchId & """'
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.branchmaker2' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

  let fixtureClock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))
  fixtureActor = Id("77777777-7777-7777-8777-777777777777")
  let approver = Id("88888888-8888-7888-8888-888888888888")
  let party = newParty(newId(fixtureClock), pkPerson, "Budi Santoso", Id(BranchId),
    "{seq:6}{check}", nextCifSeq(db))
  discard insertParty(db, party, fixtureActor)

  let prod = Product(productId: newId(fixtureClock), code: ProductCode,
    name: "Simpanan Sukarela", productType: ptSavings)
  let ver = ProductVersion(versionId: newId(fixtureClock), productId: prod.productId,
    versionNo: 1, effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prod, fixtureActor)
    insertVersion(d, ver, fixtureActor)
    insertBinding(d, ver.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"0.0000"))
    1)
  doAssert approveVersion(db, ver.versionId, approver), "versi produk uji gagal di-approve"

  discard insertPeriod(db,
    Period(periodId: newId(fixtureClock), startsOn: "2026-10-01", endsOn: "2026-10-31"),
    fixtureActor)

  # Rekening sintetis untuk diuji; saldo awal 0. Dibuat lewat repo (bukan HTTP) supaya id stabil.
  proc seedAccount(partyId: Id, productId: Id, versionId: Id, branch = Id(BranchId),
      code = ProductCode): Id =
    let a = newAccount(newId(fixtureClock), partyId, productId, versionId, code,
      branch, "2026-10-01", nextAccountSeq(db))
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      insertAccount(d, a, fixtureActor)
      1)
    a.accountId

  var accountIds: seq[Id]
  for _ in 0 ..< AccountFixtures:
    accountIds.add seedAccount(party.partyId, prod.productId, ver.versionId)

  # Produk dengan binding `min_balance` negatif (tidak sah): menguji pemetaan data server → 500.
  let prodRusak = Product(productId: newId(fixtureClock), code: "SAV-BROKEN",
    name: "Simpanan Rusak", productType: ptSavings)
  let verRusak = ProductVersion(versionId: newId(fixtureClock), productId: prodRusak.productId,
    versionNo: 1, effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prodRusak, fixtureActor)
    insertVersion(d, verRusak, fixtureActor)
    insertBinding(d, verRusak.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"-5.0000"))
    1)
  doAssert approveVersion(db, verRusak.versionId, approver), "versi rusak gagal di-approve"
  let akunRusak = newAccount(newId(fixtureClock), party.partyId, prodRusak.productId,
    verRusak.versionId, "SAV-BROKEN", Id(BranchId), "2026-10-01", nextAccountSeq(db))
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertAccount(d, akunRusak, fixtureActor)
    1)
  BrokenAccountId = $akunRusak.accountId

  # Party + rekening di cabang lain: tujuan PB untuk menguji gerbang cabang tujuan.
  let otherParty = newParty(newId(fixtureClock), pkPerson, "Siti Aminah", Id(OtherBranchId),
    "{seq:6}{check}", nextCifSeq(db))
  discard insertParty(db, otherParty, fixtureActor)
  OtherBranchAccountId = $seedAccount(otherParty.partyId, prod.productId, ver.versionId,
    Id(OtherBranchId))

  # Produk tujuan dengan min_balance tinggi: membuktikan aturan memakai min_balance versi
  # produk **sumber**, bukan tujuan (kalau salah, PB 100 dari sumber min 0 akan 409).
  let prodDest = Product(productId: newId(fixtureClock), code: "SAV-DEST",
    name: "Simpanan Tujuan", productType: ptSavings)
  let verDest = ProductVersion(versionId: newId(fixtureClock), productId: prodDest.productId,
    versionNo: 1, effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prodDest, fixtureActor)
    insertVersion(d, verDest, fixtureActor)
    insertBinding(d, verDest.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"1000.0000"))
    1)
  doAssert approveVersion(db, verDest.versionId, approver), "versi tujuan gagal di-approve"
  HighMinAccountId = $seedAccount(party.partyId, prodDest.productId, verDest.versionId,
    Id(BranchId), "SAV-DEST")

  # Id rekening dipakai test lewat variabel global sederhana.
  AccountIds = newSeq[string](accountIds.len)
  for i, id in accountIds:
    AccountIds[i] = $id
  PartyId = $party.partyId
  dbPool.release(db)

var app = AppContext(version: "itapi-teller-0.0.0", role: "api", startedAt: epochTime(),
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
  "it-teller-" & $idemCounter

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

proc balanceOf(accountId: string): string =
  dbText(sql"SELECT balance::text FROM deposit.account_balance WHERE account_id = ?", accountId)

proc journalLines(journalId: string): seq[tuple[gl, debit, credit: string]] =
  let conn = dbPool.acquire()
  try:
    for row in conn.getAllRows(sql"""
      SELECT gl_account, debit::text, credit::text FROM ledger.journal_line
       WHERE journal_id = ? ORDER BY line_no""", journalId):
      result.add((row[0], row[1], row[2]))
  finally:
    dbPool.release(conn)

proc outboxAccountingHeaders(txId: string): int =
  dbCount(sql"""
    SELECT count(*)::text FROM platform.outbox
     WHERE aggregate_id = ? AND jsonb_exists(headers, 'accounting')""", txId)

proc auditCount(action: string): int =
  dbCount(sql"SELECT count(*)::text FROM platform.audit_log WHERE action = ?", action)

proc txCount(accountId: string): int =
  dbCount(sql"SELECT count(*)::text FROM deposit.transaction WHERE account_id = ?", accountId)

proc transferCount(accountId: string): int =
  dbCount(sql"""
    SELECT count(*)::text FROM deposit.transfer
     WHERE source_account_id = ? OR destination_account_id = ?""", accountId, accountId)

proc journalCount(eventType: string): int =
  dbCount(sql"SELECT count(*)::text FROM ledger.journal WHERE source_event = ?", eventType)

var accountCursor = 0

proc freshAccount(): string =
  doAssert accountCursor < AccountIds.len, "rekening fixture habis"
  result = AccountIds[accountCursor]
  inc accountCursor

proc cashBody(accountId, direction, amount: string, narration = ""): JsonNode =
  result = %*{"accountId": accountId, "direction": direction, "amount": amount}
  if narration.len > 0:
    result["narration"] = %narration

proc transferBody(sourceId, destinationId, amount: string, narration = ""): JsonNode =
  result = %*{"sourceAccountId": sourceId, "destinationAccountId": destinationId,
    "amount": amount}
  if narration.len > 0:
    result["narration"] = %narration

# --- suite ------------------------------------------------------------------------------------

suite "teller: autentikasi & izin":
  test "tanpa sesi → 401":
    let reply = postJson(CashPath, cashBody(AccountIds[0], "DEPOSIT", "10.0000"))
    check reply.code == 401
    checkProblem(CashPath, "POST", "401", reply.body)

  test "pemegang izin lain → 403 (params.permission)":
    let checker = login(CheckerUser)
    check checker.code == 200
    let reply = postJson(CashPath, cashBody(AccountIds[0], "DEPOSIT", "10.0000"),
      tokenOf(checker))
    check reply.code == 403
    checkProblem(CashPath, "POST", "403", reply.body)
    check reply.body["params"]["permission"].getStr() == "teller.transaction.post"

suite "teller: validasi & bukan ditemukan":
  test "badan/arah/nominal/narration tidak sah → 400":
    let token = tokenOf(login(MakerUser))
    check token.len > 0

    let badId = postJson(CashPath,
      %*{"accountId": "bukan-uuid", "direction": "DEPOSIT", "amount": "10.0000"}, token)
    check badId.code == 400
    checkProblem(CashPath, "POST", "400", badId.body)

    let badDirection = postJson(CashPath,
      %*{"accountId": AccountIds[0], "direction": "TRANSFER", "amount": "10.0000"}, token)
    check badDirection.code == 400

    for bad in ["0.0000", "-5.0000", "abc", "1.00001"]:
      let reply = postJson(CashPath,
        %*{"accountId": AccountIds[0], "direction": "DEPOSIT", "amount": bad}, token)
      check reply.code == 400
      checkProblem(CashPath, "POST", "400", reply.body)

    let longNarration = postJson(CashPath,
      cashBody(AccountIds[0], "DEPOSIT", "10.0000", repeat('n', 201)), token)
    check longNarration.code == 400

    let tanpaKunci = postJson(CashPath, cashBody(AccountIds[0], "DEPOSIT", "10.0000"), token,
      sendKey = false)
    check tanpaKunci.code == 400
    checkProblem(CashPath, "POST", "400", tanpaKunci.body)

  test "rekening tidak ada → 404":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(CashPath,
      cashBody("99999999-9999-7999-8999-999999999999", "DEPOSIT", "10.0000"), token)
    check reply.code == 404
    checkProblem(CashPath, "POST", "404", reply.body)

suite "teller: setor & tarik":
  test "setor 201 → saldo naik, satu baris + satu jurnal":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let reply = postJson(CashPath, cashBody(accountId, "DEPOSIT", "100.0000", "setor tunai"),
      token)
    check reply.code == 201
    checkJson(CashPath, "POST", "201", reply.body)
    check reply.body["direction"].getStr() == "DEPOSIT"
    check reply.body["amount"].getStr() == "100.0000"
    check reply.body["balanceAfter"].getStr() == "100.0000"
    check reply.body["businessDate"].getStr() == BusinessDate
    check balanceOf(accountId) == "100.0000"
    check txCount(accountId) == 1
    check journalCount("DepositPosted") == 1
    let depositLines = journalLines(reply.body["journalId"].getStr())
    check depositLines == @[("101", "100.0000", "0.0000"), ("201", "0.0000", "100.0000")]
    # M2: event outbox tidak boleh ber-header `accounting` (kalau tidak worker memposting jurnal kedua).
    let txId = reply.body["transactionId"].getStr()
    let journalId = reply.body["journalId"].getStr()
    check outboxAccountingHeaders(txId) == 0
    check outboxAccountingHeaders(journalId) == 0
    check dbCount(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE aggregate_id = ? AND event_type = 'CashTransactionPosted'""", txId) == 1
    check dbCount(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE aggregate_id = ? AND event_type = 'journal.posted'""", journalId) == 1
    # Satu baris transaksi menunjuk jurnal yang dilaporkan.
    check dbText(sql"SELECT journal_id::text FROM deposit.transaction WHERE account_id = ?",
      accountId) == reply.body["journalId"].getStr()

  test "tarik 201 → saldo turun; tarik melebihi saldo 409 tanpa ubah apa pun":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let deposit = postJson(CashPath, cashBody(accountId, "DEPOSIT", "100.0000"), token)
    check deposit.code == 201

    let withdraw = postJson(CashPath, cashBody(accountId, "WITHDRAWAL", "60.0000"), token)
    check withdraw.code == 201
    checkJson(CashPath, "POST", "201", withdraw.body)
    check withdraw.body["direction"].getStr() == "WITHDRAWAL"
    check withdraw.body["balanceAfter"].getStr() == "40.0000"
    check balanceOf(accountId) == "40.0000"
    check txCount(accountId) == 2
    check journalCount("DepositWithdrawn") == 1
    let withdrawLines = journalLines(withdraw.body["journalId"].getStr())
    check withdrawLines == @[("201", "60.0000", "0.0000"), ("101", "0.0000", "60.0000")]

    let rowsBefore = txCount(accountId)
    let journalsBefore = journalCount("DepositWithdrawn")
    let tooMuch = postJson(CashPath, cashBody(accountId, "WITHDRAWAL", "100.0000"), token)
    check tooMuch.code == 409
    checkProblem(CashPath, "POST", "409", tooMuch.body)
    check tooMuch.body["params"]["reason"].getStr() == "insufficient_funds"
    # Rollback: saldo, baris, dan jurnal tidak berubah.
    check balanceOf(accountId) == "40.0000"
    check txCount(accountId) == rowsBefore
    check journalCount("DepositWithdrawn") == journalsBefore

suite "teller: idempotency":
  test "replay 200 + Idempotent-Replayed, tepat satu jurnal; isi beda 409":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let body = cashBody(accountId, "DEPOSIT", "25.0000")
    let key = "idem-teller-1"

    let journalsBefore = journalCount("DepositPosted")
    let auditsBefore = auditCount("deposit.transaction.post")
    let first = postJson(CashPath, body, token, key)
    check first.code == 201
    let txId = first.body["transactionId"].getStr()
    let journalId = first.body["journalId"].getStr()
    check txCount(accountId) == 1
    check journalCount("DepositPosted") == journalsBefore + 1
    let auditsAfterFirst = auditCount("deposit.transaction.post")
    check auditsAfterFirst == auditsBefore + 1

    let replay = postJson(CashPath, body, token, key)
    check replay.code == 200
    check replay.replayed == "true"
    check replay.body["transactionId"].getStr() == txId
    check replay.body["journalId"].getStr() == journalId
    # Replay tidak menambah transaksi/jurnal/audit kedua.
    check txCount(accountId) == 1
    check journalCount("DepositPosted") == journalsBefore + 1
    check auditCount("deposit.transaction.post") == auditsAfterFirst
    check balanceOf(accountId) == "25.0000"

    # Isi beda pada kunci yang sama → 409.
    let mismatch = postJson(CashPath, cashBody(accountId, "DEPOSIT", "30.0000"), token, key)
    check mismatch.code == 409
    checkProblem(CashPath, "POST", "409", mismatch.body)

suite "teller: pemindahbukuan (PB)":
  test "PB 201 → saldo kedua sisi benar, satu jurnal (D=K=amount), satu baris transfer":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "100.0000"), token).code == 201
    let journalsBefore = journalCount("DepositTransferred")

    let reply = postJson(TransferPath,
      transferBody(source, destination, "60.0000", "PB uji"), token)
    check reply.code == 201
    checkJson(TransferPath, "POST", "201", reply.body)
    check reply.body["sourceAccountId"].getStr() == source
    check reply.body["destinationAccountId"].getStr() == destination
    check reply.body["amount"].getStr() == "60.0000"
    check reply.body["sourceBalanceAfter"].getStr() == "40.0000"
    check reply.body["destinationBalanceAfter"].getStr() == "60.0000"
    check reply.body["businessDate"].getStr() == BusinessDate
    check balanceOf(source) == "40.0000"
    check balanceOf(destination) == "60.0000"
    check transferCount(source) == 1
    check transferCount(destination) == 1
    check journalCount("DepositTransferred") == journalsBefore + 1
    # Kedua sisi GL akun 201 (net-nol di GL); yang pindah per rekening = baris `deposit.transfer`.
    let lines = journalLines(reply.body["journalId"].getStr())
    check lines == @[("201", "60.0000", "0.0000"), ("201", "0.0000", "60.0000")]

    let transferId = reply.body["transferId"].getStr()
    let journalId = reply.body["journalId"].getStr()
    check outboxAccountingHeaders(transferId) == 0
    check outboxAccountingHeaders(journalId) == 0
    check dbCount(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE aggregate_id = ? AND event_type = 'TransferPosted'""", transferId) == 1
    check dbCount(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE aggregate_id = ? AND event_type = 'journal.posted'""", journalId) == 1
    check auditCount("deposit.transfer.post") >= 1
    check dbText(sql"SELECT journal_id::text FROM deposit.transfer WHERE transfer_id = ?",
      transferId) == journalId

  test "akun sama / nominal / kunci tidak sah → 400":
    let token = tokenOf(login(MakerUser))
    let a = freshAccount()
    let b = freshAccount()

    let same = postJson(TransferPath, transferBody(a, a, "10.0000"), token)
    check same.code == 400
    checkProblem(TransferPath, "POST", "400", same.body)

    for bad in ["0.0000", "-5.0000", "abc", "1.00001"]:
      let reply = postJson(TransferPath, transferBody(a, b, bad), token)
      check reply.code == 400
      checkProblem(TransferPath, "POST", "400", reply.body)

    let badId = postJson(TransferPath,
      %*{"sourceAccountId": "bukan-uuid", "destinationAccountId": b, "amount": "1.0000"}, token)
    check badId.code == 400
    checkProblem(TransferPath, "POST", "400", badId.body)

    let longNarration = postJson(TransferPath,
      transferBody(a, b, "10.0000", repeat('n', 201)), token)
    check longNarration.code == 400

    let tanpaKunci = postJson(TransferPath, transferBody(a, b, "10.0000"), token, sendKey = false)
    check tanpaKunci.code == 400
    checkProblem(TransferPath, "POST", "400", tanpaKunci.body)

  test "izin hanya di cabang lain → 403 branch_not_allowed":
    let token = tokenOf(login("dev.branchmaker"))
    let a = freshAccount()
    let b = freshAccount()
    let reply = postJson(TransferPath, transferBody(a, b, "1.0000"), token,
      "branch-transfer-" & $epochTime())
    check reply.code == 403
    checkProblem(TransferPath, "POST", "403", reply.body)
    check reply.body["params"]["reason"].getStr() == "branch_not_allowed"

  test "izin hanya di cabang sumber, tujuan cabang lain → 403 tanpa mutasi":
    let token = tokenOf(login("dev.branchmaker2"))
    let source = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "50.0000"), tokenOf(login(
        MakerUser))).code == 201
    let reply = postJson(TransferPath, transferBody(source, OtherBranchAccountId, "10.0000"),
      token, "branch-dest-" & $epochTime())
    check reply.code == 403
    checkProblem(TransferPath, "POST", "403", reply.body)
    check reply.body["params"]["reason"].getStr() == "branch_not_allowed"
    check balanceOf(source) == "50.0000"
    check balanceOf(OtherBranchAccountId) == "0.0000"
    check transferCount(source) == 0

  test "min_balance memakai versi produk sumber, bukan tujuan":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "100.0000"), token).code == 201
    # Tujuan punya min_balance 1000; kalau handler salah memakainya, PB 100 akan 409.
    let reply = postJson(TransferPath, transferBody(source, HighMinAccountId, "100.0000"), token,
      "highmin-" & $epochTime())
    check reply.code == 201
    check reply.body["sourceBalanceAfter"].getStr() == "0.0000"
    check balanceOf(source) == "0.0000"
    check balanceOf(HighMinAccountId) == "100.0000"

  test "rekening sumber CLOSED → 409 account_not_active":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "50.0000"), token).code == 201
    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = ?", source)
      1)
    let reply = postJson(TransferPath, transferBody(source, destination, "10.0000"), token)
    check reply.code == 409
    check reply.body["params"]["reason"].getStr() == "account_not_active"
    check balanceOf(source) == "50.0000"
    check transferCount(source) == 0

  test "rekening tidak ada → 404":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(TransferPath,
      transferBody("99999999-9999-7999-8999-999999999999", freshAccount(), "1.0000"), token)
    check reply.code == 404
    checkProblem(TransferPath, "POST", "404", reply.body)

  test "saldo sumber kurang → 409 insufficient_funds tanpa perubahan":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "30.0000"), token).code == 201
    let before = transferCount(source)

    let reply = postJson(TransferPath, transferBody(source, destination, "40.0000"), token)
    check reply.code == 409
    checkProblem(TransferPath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "insufficient_funds"
    # Rollback: saldo kedua sisi & baris transfer tidak berubah.
    check balanceOf(source) == "30.0000"
    check balanceOf(destination) == "0.0000"
    check transferCount(source) == before

  test "rekening tujuan CLOSED → 409 account_not_active tanpa mutasi":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "50.0000"), token).code == 201
    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = ?", destination)
      1)

    let reply = postJson(TransferPath, transferBody(source, destination, "10.0000"), token)
    check reply.code == 409
    checkProblem(TransferPath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "account_not_active"
    check balanceOf(source) == "50.0000"
    check balanceOf(destination) == "0.0000"
    check transferCount(destination) == 0

  test "replay 200 + Idempotent-Replayed, tepat satu jurnal/transfer; isi beda 409":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "100.0000"), token).code == 201
    let body = transferBody(source, destination, "25.0000")
    let key = "idem-transfer-1"
    let journalsBefore = journalCount("DepositTransferred")
    let auditsBefore = auditCount("deposit.transfer.post")

    let first = postJson(TransferPath, body, token, key)
    check first.code == 201
    let transferId = first.body["transferId"].getStr()
    let journalId = first.body["journalId"].getStr()
    check transferCount(source) == 1
    check journalCount("DepositTransferred") == journalsBefore + 1
    check auditCount("deposit.transfer.post") == auditsBefore + 1

    let replay = postJson(TransferPath, body, token, key)
    check replay.code == 200
    check replay.replayed == "true"
    check replay.body["transferId"].getStr() == transferId
    check replay.body["journalId"].getStr() == journalId
    # Replay tidak menambah baris/jurnal kedua dan tidak menggeser saldo lagi.
    check transferCount(source) == 1
    check journalCount("DepositTransferred") == journalsBefore + 1
    check auditCount("deposit.transfer.post") == auditsBefore + 1
    check balanceOf(source) == "75.0000"
    check balanceOf(destination) == "25.0000"

    let mismatch = postJson(TransferPath, transferBody(source, destination, "30.0000"), token, key)
    check mismatch.code == 409
    checkProblem(TransferPath, "POST", "409", mismatch.body)

suite "teller: otorisasi cabang & keadaan rekening":
  test "izin hanya di cabang lain → 403 branch_not_allowed":
    let token = tokenOf(login("dev.branchmaker"))
    let reply = postJson(CashPath, cashBody(AccountIds[0], "DEPOSIT", "10.0000"), token,
      "branch-teller-" & $epochTime())
    check reply.code == 403
    checkProblem(CashPath, "POST", "403", reply.body)
    check reply.body["params"]["reason"].getStr() == "branch_not_allowed"

  test "rekening CLOSED → 409 account_not_active tanpa mutasi":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"UPDATE deposit.account SET status = 'CLOSED' WHERE account_id = ?", accountId)
      1)
    let reply = postJson(CashPath, cashBody(accountId, "DEPOSIT", "10.0000"), token)
    check reply.code == 409
    checkProblem(CashPath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "account_not_active"
    check balanceOf(accountId) == "0.0000"
    check txCount(accountId) == 0

  test "event tanpa posting rule → ValueError, tanpa jurnal":
    var raised = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
        discard postJournalSync(d, app.clock, "EventTanpaRule", moneyFromString("1.0000").value(),
          parseId(BranchId).value(), newId(app.clock), BusinessDate, "tanpa-rule-1",
          fixtureActor)
        1)
    except ValueError:
      raised = true
    check raised
    check journalCount("EventTanpaRule") == 0

suite "teller: konfigurasi produk rusak":
  test "min_balance negatif → 500, bukan 400, tanpa mutasi":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(CashPath, cashBody(BrokenAccountId, "DEPOSIT", "10.0000"), token)
    check reply.code == 500
    check reply.body["detail"].getStr().len > 0
    check balanceOf(BrokenAccountId) == "0.0000"
    check txCount(BrokenAccountId) == 0

suite "teller: periode tertutup":
  test "periode CLOSED → 409 period_closed, tanpa perubahan (rollback)":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let journalsBefore = journalCount("DepositPosted")

    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"""
        UPDATE ledger.period SET status = 'CLOSED', closed_at = now(), closed_by = ?
         WHERE starts_on <= '2026-10-22'::date AND ends_on >= '2026-10-22'::date""",
        $fixtureActor)
      1)

    let reply = postJson(CashPath, cashBody(accountId, "DEPOSIT", "10.0000"), token)
    check reply.code == 409
    checkProblem(CashPath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "period_closed"
    check balanceOf(accountId) == "0.0000"
    check txCount(accountId) == 0
    check journalCount("DepositPosted") == journalsBefore

    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"""
        UPDATE ledger.period SET status = 'OPEN', closed_at = NULL, closed_by = NULL
         WHERE starts_on <= '2026-10-22'::date AND ends_on >= '2026-10-22'::date""")
      1)

  test "PB saat periode CLOSED → 409 period_closed, tanpa perubahan (rollback)":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "100.0000"), token).code == 201
    let journalsBefore = journalCount("DepositTransferred")

    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"""
        UPDATE ledger.period SET status = 'CLOSED', closed_at = now(), closed_by = ?
         WHERE starts_on <= '2026-10-22'::date AND ends_on >= '2026-10-22'::date""",
        $fixtureActor)
      1)

    let reply = postJson(TransferPath, transferBody(source, destination, "10.0000"), token)
    check reply.code == 409
    checkProblem(TransferPath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "period_closed"
    check balanceOf(source) == "100.0000"
    check balanceOf(destination) == "0.0000"
    check transferCount(source) == 0
    check journalCount("DepositTransferred") == journalsBefore

    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"""
        UPDATE ledger.period SET status = 'OPEN', closed_at = NULL, closed_by = NULL
         WHERE starts_on <= '2026-10-22'::date AND ends_on >= '2026-10-22'::date""")
      1)

