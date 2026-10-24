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

import std/[httpclient, json, net, options, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, ids, money, result]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import deposit/domain/account
import deposit/infrastructure/account_repo
import ledger/domain/[coa, period, posting]
import ledger/infrastructure/[ledger_repo, posting_repo]
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo
import teller/domain/session
import teller/infrastructure/session_repo

import ../src/[context, deposit_posting, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  CashPath = "/api/v1/teller/cash-transactions"
  SlipPath = "/api/v1/teller/cash-transactions/{transactionId}"
  TransferPath = "/api/v1/teller/transfers"
  StatementPath = "/api/v1/deposit/accounts/{accountId}/statement"
  ReversalPath = "/api/v1/ledger/journals/{journalId}/reversal"
  SessionsPath = "/api/v1/teller/sessions"
  SessionClosePath = "/api/v1/teller/sessions/{sessionId}/close"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  SessionTellerUser = "dev.sessionteller"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "11111111-1111-7111-8111-111111111111"
  OtherBranchId = "22222222-2222-7222-8222-222222222222"
  SessionBranchId = "33333333-3333-7333-8333-333333333333"
  ProductCode = "SAV-DEP"
  BusinessDate = "2026-10-22"
  ## Cukup untuk seluruh suite (tiap test memakai rekening segar); fixture di bawah menyiapkan
  ## sebanyak ini.
  AccountFixtures = 48

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
  SessionBranchAccountId: string
  ProductRuleAccountId: string
  PokokAccountId: string
  PokokTransferAccountId: string
  WajibAccountId: string
  SukarelaKindAccountId: string
  TabunganKindAccountId: string

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
      branch, "001", "2026-10-01", nextAccountSeq(db))
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
    verRusak.versionId, "SAV-BROKEN", Id(BranchId), "111", "2026-10-01", nextAccountSeq(db))
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

  # Produk + akun + rule posting **produk-spesifik** (T-104): membuktikan `postJournalSync` mengirim
  # konteks produk sehingga rule ber-`product_code` benar-benar terpilih, bukan rule generik.
  let prodRule = Product(productId: newId(fixtureClock), code: "SAV-PROD",
    name: "Simpanan Aturan Khusus", productType: ptSavings)
  let verRule = ProductVersion(versionId: newId(fixtureClock), productId: prodRule.productId,
    versionNo: 1, effectiveFrom: "2020-01-01")
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertProduct(d, prodRule, fixtureActor)
    insertVersion(d, verRule, fixtureActor)
    insertBinding(d, verRule.versionId, ParamBinding(paramKey: "product.savings.min_balance",
      value: %"0.0000"))
    1)
  doAssert approveVersion(db, verRule.versionId, approver), "versi rule produk gagal di-approve"
  ProductRuleAccountId = $seedAccount(party.partyId, prodRule.productId, verRule.versionId,
    Id(BranchId), "SAV-PROD")
  # GL 102/202 (bukan 101.2/201 rule generik) supaya pemilihan rule produk bisa dibedakan di test.
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    insertRule(d, PostingRule(ruleId: newId(fixtureClock), eventType: "DepositPosted",
      productCode: "SAV-PROD", conditions: %*{}, priority: 100,
      lines: @[
        PostingRuleLine(lineNo: 1, side: nsDebit, glAccount: "102"),
        PostingRuleLine(lineNo: 2, side: nsCredit, glAccount: "202")]), fixtureActor)
    1)

  # T-111: produk berklasifikasi simpanan (POKOK/WAJIB/SUKARELA). Rekening POKOK/WAJIB disetor ke
  # akun ekuitas 301.1/301.2 (rule berkondisi), dan tarik/PB **dari** keduanya diblokir.
  proc seedKindProduct(code: string, kind: SavingsKind): Id =
    var p = Product(productId: newId(fixtureClock), code: code, name: "Simpanan " & code,
      productType: ptSavings, savingsKind: some(kind))
    let v = ProductVersion(versionId: newId(fixtureClock), productId: p.productId,
      versionNo: 1, effectiveFrom: "2020-01-01")
    discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
      insertProduct(d, p, fixtureActor)
      insertVersion(d, v, fixtureActor)
      insertBinding(d, v.versionId, ParamBinding(paramKey: "product.savings.min_balance",
        value: %"0.0000"))
      1)
    doAssert approveVersion(db, v.versionId, approver), "versi " & code & " gagal di-approve"
    seedAccount(party.partyId, p.productId, v.versionId, Id(BranchId), code)

  PokokAccountId = $seedKindProduct("SAV-POKOK", skPokok)
  PokokTransferAccountId = $seedKindProduct("SAV-POKOK-2", skPokok)
  WajibAccountId = $seedKindProduct("SAV-WAJIB", skWajib)
  SukarelaKindAccountId = $seedKindProduct("SAV-SUKA", skSukarela)
  TabunganKindAccountId = $seedKindProduct("SAV-TAB", skTabungan)

  # --- T-093b: sesi kas. Transaksi tunai WAJIB sesi OPEN, jadi fixture membukanya lewat
  # repo/domain (bukan flag bypass gate). `dev.maker` (aktor test sukses) memakai `BranchId`;
  # `dev.sessionteller` memakai `SessionBranchId` untuk kasus tanpa sesi / tutup / replay.
  execScript(db, """
    INSERT INTO platform.app_user (user_id, username, full_name, password_algo, password_hash,
                                   must_change_password)
    SELECT gen_random_uuid(), 'dev.sessionteller', 'Dev Session Teller', password_algo,
           password_hash, false
      FROM platform.app_user WHERE username = 'dev.maker'
  """)
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.sessionteller' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)
  for branch in [BranchId, SessionBranchId]:
    execScript(db, "INSERT INTO teller.vault (branch_id, balance) VALUES ('" & branch &
      "', '1000000.0000') ON CONFLICT (branch_id) DO UPDATE SET balance = EXCLUDED.balance")
  SessionBranchAccountId = $seedAccount(party.partyId, prod.productId, ver.versionId,
    Id(SessionBranchId))

  let makerUserId = parseId(db.getValue(
    sql"SELECT user_id::text FROM platform.app_user WHERE username = 'dev.maker'")).value()
  let makerSession = newOpenSession(newId(fixtureClock), Id(BranchId), makerUserId, BusinessDate,
    zero(), makerUserId)
  discard dbPool.withTx(proc(d: DbConn): int {.closure.} =
    doAssert debitVault(d, Id(BranchId), zero()).isSome
    doAssert insertOpenSession(d, makerSession), "sesi fixture dev.maker gagal dibuka"
    1)

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

proc cashMovementCount(sessionId: string): int =
  dbCount(sql"SELECT count(*)::text FROM teller.cash_movement WHERE session_id = ?", sessionId)

proc cashMovementTypeCount(sessionId, movementType: string): int =
  dbCount(sql"""SELECT count(*)::text FROM teller.cash_movement
                 WHERE session_id = ? AND movement_type = ?""", sessionId, movementType)

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

proc statementUrl(accountId, fromDate, toDate: string): string =
  StatementPath.replace("{accountId}", accountId) & "?from=" & fromDate & "&to=" & toDate

proc seedStatementBulk(tag, accountId, otherId: string, cashCount, transferCount: int) =
  ## Menanam baris statement **langsung** lewat SQL (bukan ratusan request HTTP, T-112):
  ## `cashCount` transaksi tunai + `transferCount` PB pada `BusinessDate`, masing-masing dengan
  ## jurnal **seimbang** (2 baris, akun 201) karena FK `*.journal_id` menuntutnya. Satu skrip =
  ## satu transaksi implisit `pqexec` (pernyataan gagal membatalkan seluruh batch). `tag`
  ## membedakan batch supaya `ledger.journal.idempotency_key` tidak bentrok.
  ##
  ## Beware: baris ditanam untuk rekening yang **khusus** test ini; memakai rekening fixture milik
  ## test lain akan membocorkan baris ke statement-nya (semua test memakai `BusinessDate`).
  const actor = "77777777-7777-7777-8777-777777777777"
  let db = dbPool.acquire()
  try:
    execScript(db, """
      INSERT INTO ledger.journal
        (journal_id, business_date, value_date, source_event, source_ref, idempotency_key, created_by)
      SELECT gen_random_uuid(), '""" & BusinessDate & """'::date, '""" & BusinessDate &
        """'::date,
             'test.statement.bulk.cash', gen_random_uuid(),
             't112-""" & tag & """-cash-' || g, '""" & actor &
        """'::uuid
        FROM generate_series(1, """ & $cashCount &
        """) g;

      INSERT INTO ledger.journal_line (journal_id, line_no, gl_account, branch_id, debit, credit)
      SELECT journal_id, 1, '201', '""" & BranchId &
        """'::uuid, 1, 0
        FROM ledger.journal WHERE idempotency_key LIKE 't112-""" & tag &
        """-cash-%'
      UNION ALL
      SELECT journal_id, 2, '201', '""" & BranchId &
        """'::uuid, 0, 1
        FROM ledger.journal WHERE idempotency_key LIKE 't112-""" & tag &
        """-cash-%';

      INSERT INTO deposit.transaction
        (transaction_id, tx_type, account_id, amount, business_date, narration, journal_id, created_by)
      SELECT gen_random_uuid(), 'CASH_DEPOSIT', '""" & accountId &
        """', 1,
             '""" & BusinessDate & """'::date, 'bulk', journal_id, '""" & actor &
        """'::uuid
        FROM ledger.journal WHERE idempotency_key LIKE 't112-""" & tag &
        """-cash-%';

      INSERT INTO ledger.journal
        (journal_id, business_date, value_date, source_event, source_ref, idempotency_key, created_by)
      SELECT gen_random_uuid(), '""" & BusinessDate & """'::date, '""" & BusinessDate &
        """'::date,
             'test.statement.bulk.pb', gen_random_uuid(),
             't112-""" & tag & """-pb-' || g, '""" & actor &
        """'::uuid
        FROM generate_series(1, """ & $transferCount &
        """) g;

      INSERT INTO ledger.journal_line (journal_id, line_no, gl_account, branch_id, debit, credit)
      SELECT journal_id, 1, '201', '""" & BranchId &
        """'::uuid, 1, 0
        FROM ledger.journal WHERE idempotency_key LIKE 't112-""" & tag &
        """-pb-%'
      UNION ALL
      SELECT journal_id, 2, '201', '""" & BranchId &
        """'::uuid, 0, 1
        FROM ledger.journal WHERE idempotency_key LIKE 't112-""" & tag &
        """-pb-%';

      INSERT INTO deposit.transfer
        (transfer_id, source_account_id, destination_account_id, amount, business_date, narration,
         journal_id, created_by)
      SELECT gen_random_uuid(), '""" & accountId & """', '""" & otherId &
        """', 1,
             '""" & BusinessDate & """'::date, 'bulk', journal_id, '""" & actor &
        """'::uuid
        FROM ledger.journal WHERE idempotency_key LIKE 't112-""" & tag & """-pb-%';
    """)
  finally:
    dbPool.release(db)

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
    check depositLines == @[("101.2", "100.0000", "0.0000"), ("201", "0.0000", "100.0000")]
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
    check withdrawLines == @[("201", "60.0000", "0.0000"), ("101.2", "0.0000", "60.0000")]

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

suite "teller: jurnal subledger tidak bisa dibalik (T-123)":
  test "jurnal transaksi tunai & PB ditolak 409 journal_owned_by_subledger":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    let deposit = postJson(CashPath, cashBody(source, "DEPOSIT", "100.0000"), token)
    check deposit.code == 201
    let cashJournal = deposit.body["journalId"].getStr()

    let denied = postJson(ReversalPath.replace("{journalId}", cashJournal),
      %*{"reason": "uji guard subledger"}, token)
    check denied.code == 409
    checkProblem(ReversalPath, "POST", "409", denied.body)
    check denied.body["params"]["reason"].getStr() == "journal_owned_by_subledger"
    check denied.body["params"]["subledger"].getStr() == "deposit.transaction"
    # Tidak ada jurnal pembalik yang lahir dari penolakan itu.
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal
                         WHERE reversal_of = ?::uuid""", cashJournal) == 0

    # PB juga punya subledger sendiri: pembalik hanya akan membuat GL dan baris transfer berbeda.
    let transfer = postJson(TransferPath,
      transferBody(source, destination, "10.0000", "PB uji guard"), token)
    check transfer.code == 201
    let transferJournal = transfer.body["journalId"].getStr()
    let deniedTransfer = postJson(ReversalPath.replace("{journalId}", transferJournal),
      %*{"reason": "uji guard subledger"}, token)
    check deniedTransfer.code == 409
    check deniedTransfer.body["params"]["reason"].getStr() == "journal_owned_by_subledger"
    check deniedTransfer.body["params"]["subledger"].getStr() == "deposit.transfer"

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

  test "replay setelah TTL idempotensi lewat → 409 terdefinisi, bukan 500 (T-102)":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let body = cashBody(accountId, "DEPOSIT", "25.0000")
    let key = "idem-expire-1"
    let journalsBefore = journalCount("DepositPosted")

    let first = postJson(CashPath, body, token, key)
    check first.code == 201
    check balanceOf(accountId) == "25.0000"
    check txCount(accountId) == 1

    # Paksa klaim platform kedaluwarsa (TTL lewat): geser `created_at`/`expires_at` ke masa lalu.
    # Kunci jurnal `teller:<principal>:<key>` tetap unik selamanya — tanpa pemetaan, replay ini
    # menabrak `journal_idempotency_uq` dan jadi 500.
    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"""
        UPDATE platform.idempotency_key
           SET created_at = created_at - interval '2 days',
               expires_at = created_at - interval '1 day'
         WHERE key = ?
           AND principal_id =
             (SELECT user_id FROM platform.app_user WHERE username = 'dev.maker')""", key)
      1)

    let replay = postJson(CashPath, body, token, key)
    check replay.code == 409
    checkProblem(CashPath, "POST", "409", replay.body)
    check replay.body["params"]["reason"].getStr() == "idempotency_replay_expired"
    # Rollback: tidak ada mutasi saldo / baris / jurnal kedua.
    check balanceOf(accountId) == "25.0000"
    check txCount(accountId) == 1
    check journalCount("DepositPosted") == journalsBefore + 1

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
          fixtureActor, "SAV-DEP", "SAVINGS", "")
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

suite "teller: sesi kas menggerbang transaksi tunai (T-093b)":
  test "tanpa sesi OPEN → 409 no_open_session, saldo & jurnal tidak berubah":
    let token = tokenOf(login(SessionTellerUser))
    check token.len > 0
    let accountId = SessionBranchAccountId
    let journalsBefore = journalCount("DepositPosted")

    let reply = postJson(CashPath, cashBody(accountId, "DEPOSIT", "10.0000"), token)
    check reply.code == 409
    checkProblem(CashPath, "POST", "409", reply.body)
    check reply.body["params"]["reason"].getStr() == "no_open_session"
    check balanceOf(accountId) == "0.0000"
    check txCount(accountId) == 0
    check journalCount("DepositPosted") == journalsBefore

  test "sesi OPEN tanggal bisnis lain → 409 session_business_date_mismatch":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let journalsBefore = journalCount("DepositPosted")
    let tellerId = dbText(sql"""
      SELECT teller_user_id::text FROM teller.teller_session
       WHERE status = 'OPEN' AND branch_id = ?
         AND teller_user_id = (SELECT user_id FROM platform.app_user WHERE username = 'dev.maker')""",
      BranchId)
    # Restore wajib walau assertion gagal, supaya kegagalan tidak menular ke test tunai lain.
    try:
      discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
        exec(d, sql"""
          UPDATE teller.teller_session SET business_date = '2026-10-21'
           WHERE teller_user_id = ?::uuid AND status = 'OPEN'""", tellerId)
        1)
      let current = call("GET", SessionsPath & "/current?branchId=" & BranchId, "", token)
      check current.code == 200
      check current.body["businessDate"].getStr() == "2026-10-21"
      let reply = postJson(CashPath, cashBody(accountId, "DEPOSIT", "10.0000"), token)
      check reply.code == 409
      checkProblem(CashPath, "POST", "409", reply.body)
      check reply.body["params"]["reason"].getStr() == "session_business_date_mismatch"
      check balanceOf(accountId) == "0.0000"
      check txCount(accountId) == 0
      check journalCount("DepositPosted") == journalsBefore
    finally:
      discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
        exec(d, sql"""
          UPDATE teller.teller_session SET business_date = ?::date
           WHERE teller_user_id = ?::uuid AND status = 'OPEN'""", BusinessDate, tellerId)
        1)

  test "sesi dibuka → transaksi mencatat CASH_IN/CASH_OUT; tutup menghitung expected":
    let token = tokenOf(login(SessionTellerUser))
    let openResp = postJson(SessionsPath,
      %*{"branchId": SessionBranchId, "openingFloat": "100.0000"}, token)
    check openResp.code == 201
    checkJson(SessionsPath, "POST", "201", openResp.body)
    check openResp.body["status"].getStr() == "OPEN"
    check openResp.body["branchId"].getStr() == SessionBranchId
    let sessionId = openResp.body["sessionId"].getStr()

    # Sesi kedua di cabang yang sama untuk teller yang sama ditolak.
    let dup = postJson(SessionsPath, %*{"branchId": SessionBranchId, "openingFloat": "0.0000"},
      token)
    check dup.code == 409
    check dup.body["params"]["reason"].getStr() == "session_already_open"

    let deposit = postJson(CashPath, cashBody(SessionBranchAccountId, "DEPOSIT", "50.0000"), token)
    check deposit.code == 201
    let withdraw = postJson(CashPath,
      cashBody(SessionBranchAccountId, "WITHDRAWAL", "20.0000"), token)
    check withdraw.code == 201

    # Plafon per transaksi (K-5/O-099) dicek sebelum saldo/jurnal: di atas plafon = 409 tanpa
    # movement baru, dan alasannya plafon (bukan saldo kurang).
    let overDeposit = postJson(CashPath,
      cashBody(SessionBranchAccountId, "DEPOSIT", "10000000.0001"), token)
    check overDeposit.code == 409
    checkProblem(CashPath, "POST", "409", overDeposit.body)
    check overDeposit.body["params"]["reason"].getStr() == "cash_limit_exceeded"
    let overWithdraw = postJson(CashPath,
      cashBody(SessionBranchAccountId, "WITHDRAWAL", "5000000.0001"), token)
    check overWithdraw.code == 409
    check overWithdraw.body["params"]["reason"].getStr() == "cash_limit_exceeded"

    check cashMovementCount(sessionId) == 2
    check cashMovementTypeCount(sessionId, "CASH_IN") == 1
    check cashMovementTypeCount(sessionId, "CASH_OUT") == 1

    # expected = 100 float + 50 masuk - 20 keluar = 130.
    let closeResp = postJson(SessionsPath & "/" & sessionId & "/close",
      %*{"countedCash": "130.0000"}, token)
    check closeResp.code == 200
    checkJson(SessionClosePath, "POST", "200", closeResp.body)
    check closeResp.body["expectedCash"].getStr() == "130.0000"
    check closeResp.body["countedCash"].getStr() == "130.0000"
    check closeResp.body["variance"].getStr() == "0.0000"
    check closeResp.body["status"].getStr() == "CLOSED"

    # Tutup kedua ditolak.
    let closeAgain = postJson(SessionsPath & "/" & sessionId & "/close",
      %*{"countedCash": "130.0000"}, token)
    check closeAgain.code == 409
    check closeAgain.body["params"]["reason"].getStr() == "session_not_open"

  test "T-118: buka/tutup sesi + selisih kas berjurnal (vault, laci, selisih)":
    let token = tokenOf(login(SessionTellerUser))
    let openResp = postJson(SessionsPath,
      %*{"branchId": SessionBranchId, "openingFloat": "100.0000"}, token)
    check openResp.code == 201
    let sessionId = openResp.body["sessionId"].getStr()

    let deposit = postJson(CashPath, cashBody(SessionBranchAccountId, "DEPOSIT", "50.0000"), token)
    check deposit.code == 201

    # expected = 150, counted = 140 → selisih kurang 10.
    let closeResp = postJson(SessionsPath & "/" & sessionId & "/close",
      %*{"countedCash": "140.0000"}, token)
    check closeResp.code == 200
    check closeResp.body["variance"].getStr() == "-10.0000"

    # Float: laci bertambah, vault berkurang.
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal j
                          JOIN ledger.journal_line l ON l.journal_id = j.journal_id
                         WHERE j.source_event = 'TellerSessionOpened' AND j.source_ref = ?::uuid
                           AND l.gl_account = '101.2' AND l.debit = 100""", sessionId) == 1
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal j
                          JOIN ledger.journal_line l ON l.journal_id = j.journal_id
                         WHERE j.source_event = 'TellerSessionOpened' AND j.source_ref = ?::uuid
                           AND l.gl_account = '101.1' AND l.credit = 100""", sessionId) == 1
    # Kas fisik kembali ke vault sebesar counted.
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal j
                          JOIN ledger.journal_line l ON l.journal_id = j.journal_id
                         WHERE j.source_event = 'TellerSessionClosed' AND j.source_ref = ?::uuid
                           AND l.gl_account = '101.1' AND l.debit = 140""", sessionId) == 1
    # Kaki selisih memakai akun laci sehingga saldo 101.2 kembali nol setelah tutup.
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal j
                          JOIN ledger.journal_line l ON l.journal_id = j.journal_id
                         WHERE j.source_event = 'TellerCashShortage' AND j.source_ref = ?::uuid
                           AND l.gl_account = '101.9' AND l.debit = 10""", sessionId) == 1
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal j
                          JOIN ledger.journal_line l ON l.journal_id = j.journal_id
                         WHERE j.source_event = 'TellerCashShortage' AND j.source_ref = ?::uuid
                           AND l.gl_account = '101.2' AND l.credit = 10""", sessionId) == 1

    # Saldo GL laci untuk cabang ini = 0 setelah sesi tutup (float + transaksi - penutupan - selisih).
    check dbCount(sql"""SELECT count(*)::text FROM (
                          SELECT sum(l.debit - l.credit) AS net FROM ledger.journal_line l
                            JOIN ledger.journal j ON j.journal_id = l.journal_id
                           WHERE l.gl_account = '101.2' AND l.branch_id = ?::uuid
                          HAVING sum(l.debit - l.credit) <> 0) x""", SessionBranchId) == 0

  test "setelah tutup: transaksi baru 409, replay transaksi lama tetap 200":
    let token = tokenOf(login(SessionTellerUser))
    let openResp = postJson(SessionsPath,
      %*{"branchId": SessionBranchId, "openingFloat": "0.0000"}, token)
    check openResp.code == 201
    let sessionId = openResp.body["sessionId"].getStr()

    let body = cashBody(SessionBranchAccountId, "DEPOSIT", "10.0000")
    let key = "teller-session-replay-1"
    let first = postJson(CashPath, body, token, key)
    check first.code == 201
    let transactionId = first.body["transactionId"].getStr()
    check cashMovementCount(sessionId) == 1

    let closeResp = postJson(SessionsPath & "/" & sessionId & "/close",
      %*{"countedCash": "10.0000"}, token)
    check closeResp.code == 200
    check closeResp.body["expectedCash"].getStr() == "10.0000"

    # Sesi sudah CLOSED: transaksi tunai baru ditolak dan tidak menyentuh jurnal.
    let journalsBefore = journalCount("DepositPosted")
    let afterClose = postJson(CashPath, cashBody(SessionBranchAccountId, "DEPOSIT", "5.0000"),
      token)
    check afterClose.code == 409
    checkProblem(CashPath, "POST", "409", afterClose.body)
    check afterClose.body["params"]["reason"].getStr() == "no_open_session"
    check journalCount("DepositPosted") == journalsBefore

    # Replay yang sah setelah tutup harus mengembalikan respons tersimpan (bukan 409):
    # gerbang sesi berada DI DALAM blok idempotensi.
    let replay = postJson(CashPath, body, token, key)
    check replay.code == 200
    check replay.replayed == "true"
    check replay.body["transactionId"].getStr() == transactionId

suite "teller: posting rule produk-spesifik (T-104)":
  test "setor memakai rule `product_code` akun, bukan rule generik":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(CashPath, cashBody(ProductRuleAccountId, "DEPOSIT", "10.0000"), token)
    check reply.code == 201
    checkJson(CashPath, "POST", "201", reply.body)
    # Rule produk SAV-PROD (D 102 / K 202) harus terpilih. Bila `postJournalSync` mengirim payload
    # kosong, rule produk tidak cocok dan rule generik (101.2/201) yang dipakai → assertion gagal.
    let lines = journalLines(reply.body["journalId"].getStr())
    check lines == @[("102", "10.0000", "0.0000"), ("202", "0.0000", "10.0000")]

suite "teller: klasifikasi simpanan koperasi (T-111)":
  test "setor POKOK → ekuitas 301.1 (rule generik tidak terpilih)":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(CashPath, cashBody(PokokAccountId, "DEPOSIT", "50.0000"), token)
    check reply.code == 201
    checkJson(CashPath, "POST", "201", reply.body)
    check balanceOf(PokokAccountId) == "50.0000"
    # Tanpa rule berkondisi yang terpilih, jurnal akan memakai 101.2/201 (generik).
    let lines = journalLines(reply.body["journalId"].getStr())
    check lines == @[("101.2", "50.0000", "0.0000"), ("301.1", "0.0000", "50.0000")]

  test "setor WAJIB → ekuitas 301.2":
    let token = tokenOf(login(MakerUser))
    let reply = postJson(CashPath, cashBody(WajibAccountId, "DEPOSIT", "25.0000"), token)
    check reply.code == 201
    checkJson(CashPath, "POST", "201", reply.body)
    let lines = journalLines(reply.body["journalId"].getStr())
    check lines == @[("101.2", "25.0000", "0.0000"), ("301.2", "0.0000", "25.0000")]

  test "tarik dari POKOK/WAJIB → 409 savings_kind_locked tanpa ubah saldo":
    let token = tokenOf(login(MakerUser))
    let pokokBefore = balanceOf(PokokAccountId)
    let pokokTxBefore = txCount(PokokAccountId)
    let pokok = postJson(CashPath, cashBody(PokokAccountId, "WITHDRAWAL", "10.0000"), token)
    check pokok.code == 409
    checkProblem(CashPath, "POST", "409", pokok.body)
    check pokok.body["params"]["reason"].getStr() == "savings_kind_locked"
    check balanceOf(PokokAccountId) == pokokBefore
    check txCount(PokokAccountId) == pokokTxBefore

    let wajibBefore = balanceOf(WajibAccountId)
    let wajib = postJson(CashPath, cashBody(WajibAccountId, "WITHDRAWAL", "5.0000"), token)
    check wajib.code == 409
    check wajib.body["params"]["reason"].getStr() == "savings_kind_locked"
    check balanceOf(WajibAccountId) == wajibBefore

  test "PB menyentuh POKOK/WAJIB → 409 locked; PB SUKARELA↔TABUNGAN → 409 mismatch":
    let token = tokenOf(login(MakerUser))

    let fromPokok = postJson(TransferPath,
      transferBody(PokokTransferAccountId, SukarelaKindAccountId, "1.0000"), token)
    check fromPokok.code == 409
    checkProblem(TransferPath, "POST", "409", fromPokok.body)
    check fromPokok.body["params"]["reason"].getStr() == "savings_kind_locked"

    # Sumber SUKARELA (tidak terkunci) ke tujuan POKOK: tujuan yang terkunci menolak lebih dulu.
    let cross = postJson(TransferPath,
      transferBody(SukarelaKindAccountId, PokokAccountId, "1.0000"), token)
    check cross.code == 409
    checkProblem(TransferPath, "POST", "409", cross.body)
    check cross.body["params"]["reason"].getStr() == "savings_kind_locked"

    # Dua jenis yang sama-sama liabilitas tetapi berbeda label (SUKARELA vs TABUNGAN): aturan
    # "satu jenis" tetap berlaku, dan inilah satu-satunya cabang yang memakai `transfer_kind_mismatch`.
    let bedaLabel = postJson(TransferPath,
      transferBody(SukarelaKindAccountId, TabunganKindAccountId, "1.0000"), token)
    check bedaLabel.code == 409
    checkProblem(TransferPath, "POST", "409", bedaLabel.body)
    check bedaLabel.body["params"]["reason"].getStr() == "transfer_kind_mismatch"
    check balanceOf(TabunganKindAccountId) == "0.0000"

    # Rollback: tidak ada mutasi saldo/baris transfer di kedua sisi.
    check balanceOf(SukarelaKindAccountId) == "0.0000"
    check balanceOf(PokokTransferAccountId) == "0.0000"
    check transferCount(SukarelaKindAccountId) == 0
    check transferCount(PokokTransferAccountId) == 0

  test "PB NULL (produk lama) <-> SUKARELA boleh; tujuan POKOK tetap diblokir":
    let token = tokenOf(login(MakerUser))
    proc saldo(accountId: string): Money = moneyFromString(balanceOf(accountId)).value()
    # Rekening dari produk tanpa `savings_kind` (NULL) diperlakukan sebagai simpanan generik.
    let nullAccount = AccountIds[0]
    let awalNull = saldo(nullAccount)
    let awalSukarela = saldo(SukarelaKindAccountId)
    let setor = postJson(CashPath, cashBody(nullAccount, "DEPOSIT", "10.0000"), token)
    check setor.code == 201

    let keSukarela = postJson(TransferPath,
      transferBody(nullAccount, SukarelaKindAccountId, "3.0000"), token)
    check keSukarela.code == 201
    check saldo(nullAccount) == awalNull + money(70_000)
    check saldo(SukarelaKindAccountId) == awalSukarela + money(30_000)

    let balik = postJson(TransferPath,
      transferBody(SukarelaKindAccountId, nullAccount, "1.0000"), token)
    check balik.code == 201
    check saldo(nullAccount) == awalNull + money(80_000)
    check saldo(SukarelaKindAccountId) == awalSukarela + money(20_000)

    # Tujuan POKOK diblokir walaupun sumbernya NULL: dana tidak boleh masuk ekuitas lewat PB.
    let kePokok = postJson(TransferPath,
      transferBody(nullAccount, PokokAccountId, "1.0000"), token)
    check kePokok.code == 409
    check kePokok.body["params"]["reason"].getStr() == "savings_kind_locked"
    check saldo(nullAccount) == awalNull + money(80_000)

suite "teller: slip cetak ulang (T-094a)":
  test "baca transaksi tunai → 200, field slip, tanpa saldo":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let created = postJson(CashPath, cashBody(accountId, "DEPOSIT", "40.0000", "setor slip"),
      token)
    check created.code == 201
    let txId = created.body["transactionId"].getStr()

    let reply = call("GET", CashPath & "/" & txId, "", token)
    check reply.code == 200
    checkJson(SlipPath, "GET", "200", reply.body)
    check reply.body["transactionId"].getStr() == txId
    check reply.body["journalId"].getStr() == created.body["journalId"].getStr()
    check reply.body["direction"].getStr() == "DEPOSIT"
    check reply.body["amount"].getStr() == "40.0000"
    check reply.body["businessDate"].getStr() == BusinessDate
    check reply.body["narration"].getStr() == "setor slip"
    # `balanceAfter` sengaja tidak ada: saldo per transaksi tidak disimpan (D-127).
    check not reply.body.hasKey("balanceAfter")

  test "tanpa sesi → 401":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let created = postJson(CashPath, cashBody(accountId, "DEPOSIT", "5.0000"), token)
    check created.code == 201
    let reply = call("GET", CashPath & "/" & created.body["transactionId"].getStr(), "", "")
    check reply.code == 401
    checkProblem(SlipPath, "GET", "401", reply.body)

  test "cabang lain → 403; id tidak ada / id PB → 404":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let created = postJson(CashPath, cashBody(accountId, "DEPOSIT", "5.0000"), token)
    check created.code == 201
    let txId = created.body["transactionId"].getStr()

    let branchToken = tokenOf(login("dev.branchmaker"))
    check branchToken.len > 0
    let denied = call("GET", CashPath & "/" & txId, "", branchToken)
    check denied.code == 403
    checkProblem(SlipPath, "GET", "403", denied.body)
    check denied.body["params"]["reason"].getStr() == "branch_not_allowed"

    let missing = call("GET", CashPath & "/99999999-9999-7999-8999-999999999999", "", token)
    check missing.code == 404
    checkProblem(SlipPath, "GET", "404", missing.body)

    # Id PB bukan baris `deposit.transaction`: endpoint slip tidak menemukannya (404, bukan PB).
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "20.0000"), token).code == 201
    let pb = postJson(TransferPath, transferBody(source, destination, "5.0000"), token)
    check pb.code == 201
    let pbAsSlip = call("GET", CashPath & "/" & pb.body["transferId"].getStr(), "", token)
    check pbAsSlip.code == 404

suite "deposit: statement subledger (T-094b)":
  test "gabungan tunai + PB, arah relatif rekening, urut tanggal, hanya rekening itu":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let otherId = freshAccount()

    check postJson(CashPath, cashBody(accountId, "DEPOSIT", "100.0000", "setor"), token).code == 201
    check postJson(CashPath, cashBody(accountId, "WITHDRAWAL", "40.0000", "tarik"), token).code ==
      201
    let outbound = postJson(TransferPath, transferBody(accountId, otherId, "10.0000", "pb keluar"),
      token)
    check outbound.code == 201
    let inbound = postJson(TransferPath, transferBody(otherId, accountId, "3.0000", "pb masuk"),
      token)
    check inbound.code == 201

    let reply = call("GET", statementUrl(accountId, BusinessDate, BusinessDate), "", token)
    check reply.code == 200
    checkJson(StatementPath, "GET", "200", reply.body)
    check reply.body["accountNo"].getStr().len == 10
    check reply.body["status"].getStr() == "ACTIVE"
    check reply.body["from"].getStr() == BusinessDate
    check reply.body["to"].getStr() == BusinessDate
    check reply.body["rows"].len == 4

    # Tanggal tidak menurun (urut) dan tiap baris persis satu referensi terisi.
    var previous = ""
    var inflow = 0
    var outflow = 0
    var foundOutbound = false
    var foundInbound = false
    for row in reply.body["rows"]:
      let businessDate = row["businessDate"].getStr()
      check businessDate >= previous
      previous = businessDate
      let hasTx = row["transactionId"].kind == JString
      let hasTransfer = row["transferId"].kind == JString
      check hasTx xor hasTransfer
      if row["direction"].getStr() == "IN": inc inflow
      else: inc outflow
      if hasTransfer and row["transferId"].getStr() == outbound.body["transferId"].getStr():
        check row["direction"].getStr() == "OUT"
        foundOutbound = true
      if hasTransfer and row["transferId"].getStr() == inbound.body["transferId"].getStr():
        check row["direction"].getStr() == "IN"
        foundInbound = true
    check inflow == 2
    check outflow == 2
    check foundOutbound
    check foundInbound
    # Baris rekening lain tidak bocor: rekening tujuan hanya punya PB masuk (tidak muncul di sini).

  test "rumah: rekening lain jadi barisnya sendiri (PB di kedua sisi)":
    let token = tokenOf(login(MakerUser))
    let source = freshAccount()
    let destination = freshAccount()
    check postJson(CashPath, cashBody(source, "DEPOSIT", "30.0000"), token).code == 201
    check postJson(TransferPath, transferBody(source, destination, "7.0000"), token).code == 201

    let destinationStatement =
      call("GET", statementUrl(destination, BusinessDate, BusinessDate), "", token)
    check destinationStatement.code == 200
    check destinationStatement.body["rows"].len == 1
    check destinationStatement.body["rows"][0]["direction"].getStr() == "IN"
    check destinationStatement.body["rows"][0]["kind"].getStr() == "TRANSFER"
    check destinationStatement.body["rows"][0]["transactionId"].kind == JNull
    check destinationStatement.body["rows"][0]["transferId"].kind == JString

  test "rentang wajib/format salah/terbalik → 400":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    for query in ["", "?from=" & BusinessDate, "?to=" & BusinessDate,
                  "?from=2026-02-31&to=2026-03-01",
                  "?from=" & BusinessDate & "&to=2026-01-01"]:
      let reply = call("GET", StatementPath.replace("{accountId}", accountId) & query, "", token)
      check reply.code == 400
      checkProblem(StatementPath, "GET", "400", reply.body)

  test "tanpa sesi → 401; cabang lain → 403; rekening tidak ada → 404":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()

    let anonymous = call("GET", statementUrl(accountId, BusinessDate, BusinessDate), "", "")
    check anonymous.code == 401
    checkProblem(StatementPath, "GET", "401", anonymous.body)

    let branchToken = tokenOf(login("dev.branchmaker"))
    let denied = call("GET", statementUrl(accountId, BusinessDate, BusinessDate), "", branchToken)
    check denied.code == 403
    checkProblem(StatementPath, "GET", "403", denied.body)
    check denied.body["params"]["reason"].getStr() == "branch_not_allowed"

    let missing = call("GET",
      statementUrl("99999999-9999-7999-8999-999999999999", BusinessDate, BusinessDate), "", token)
    check missing.code == 404
    checkProblem(StatementPath, "GET", "404", missing.body)

  test "di atas batas 500 gabungan kas + PB (tiap sumber < 501) → 400, bukan potong diam-diam":
    let token = tokenOf(login(MakerUser))
    let accountId = freshAccount()
    let otherId = freshAccount() # hanya agar PB punya tujuan berbeda (account_source <> dest)

    # 250 kas + 250 PB = 500 baris: **tepat** di batas `maxStatementRows` → 200 dengan 500 baris.
    # Tiap kueri sumber hanya mengembalikan 250 (< probeLimit 501), jadi 200 membuktikan batas
    # dihitung dari **gabungan**, bukan per sumber.
    seedStatementBulk("b500", accountId, otherId, 250, 250)
    let atLimit = call("GET", statementUrl(accountId, BusinessDate, BusinessDate), "", token)
    check atLimit.code == 200
    checkJson(StatementPath, "GET", "200", atLimit.body)
    check atLimit.body["rows"].len == 500

    # +1 kas → 251 kas + 250 PB = 501 (> 500) padahal **setiap** sumber < 501. Inilah inti
    # `probeLimit = maxStatementRows + 1`: batas per kueri tidak cukup; handler harus menolak
    # gabungan yang melewati batas, bukan memotong separuh.
    seedStatementBulk("b501", accountId, otherId, 1, 0)
    let over = call("GET", statementUrl(accountId, BusinessDate, BusinessDate), "", token)
    check over.code == 400
    checkProblem(StatementPath, "GET", "400", over.body)
    # Handler tidak memakai `params.reason` untuk 400 ini (lihat `handleGetAccountStatement`):
    # pembedanya ada di `detail`. Jangan mengarang reason yang tidak ditulis kode.
    check over.body["detail"].getStr().contains("500")
    # Tanpa respons separuh: 400 hanya problem+json, tidak membawa `rows`.
    check not over.body.hasKey("rows")
