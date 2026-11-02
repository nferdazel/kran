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
  DisbursePath = "/api/v1/lending/loans/{loanId}/disburse"
  PaymentsPath = "/api/v1/lending/loans/{loanId}/payments"
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
var accountId = ""
var otherAccountId = ""
var zeroAccountId = ""

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
  # Rekening simpanan untuk pencairan (T-164): produk + versi ACTIVE dengan satu binding
  # (constraint "minimal satu binding" bersifat deferred), lalu rekening + saldo nol.
  execScript(db, """
    INSERT INTO product.product (product_id, code, name, product_type, created_by, updated_by)
    VALUES (md5('lending|savings-product')::uuid, 'SAVLN', 'Simpanan Pencairan', 'SAVINGS',
            '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  # Versi lahir DRAFT (trigger `product` menolak versi baru yang langsung ACTIVE), lalu disahkan
  # seperti `approveVersion`: checker berbeda + approved_at + sealed.
  execScript(db, """
    INSERT INTO product.product_version
      (version_id, product_id, version_no, effective_from, sealed, published_by, status, maker)
    VALUES (md5('lending|savings-version')::uuid, md5('lending|savings-product')::uuid, 1,
            DATE '2020-01-01', false, '""" & MakerId & """', 'DRAFT',
            '""" & MakerId & """')
    ON CONFLICT DO NOTHING
  """)
  # Binding wajib minimal satu (constraint deferred), jadi ditulis di skrip yang sama dengan
  # pengesahan versi supaya commit-nya satu.
  execScript(db, """
    INSERT INTO product.product_param_binding (version_id, param_key, value)
    VALUES (md5('lending|savings-version')::uuid, 'product.savings.min_balance', '"0.00"'::jsonb)
    ON CONFLICT DO NOTHING;
    UPDATE product.product_version
       SET status = 'ACTIVE', checker = '""" & ActorId & """', approved_at = now(), sealed = true
     WHERE version_id = md5('lending|savings-version')::uuid AND status = 'DRAFT';
  """)
  execScript(db, """
    INSERT INTO deposit.account
      (account_id, account_no, party_id, product_id, product_version_id, branch_id,
       account_type, status, opened_on, created_by, updated_by)
    VALUES
      (md5('lending|account')::uuid, '0001111111', '""" & PartyId &
      """',
       md5('lending|savings-product')::uuid, md5('lending|savings-version')::uuid,
       '""" & BranchId & """', 'SAVINGS', 'ACTIVE', DATE '2020-01-01',
       '""" & ActorId & """', '""" & ActorId &
      """'),
      (md5('lending|account-other')::uuid, '0001111112', '""" & PartySuspendedId &
      """',
       md5('lending|savings-product')::uuid, md5('lending|savings-version')::uuid,
       '""" & BranchId & """', 'SAVINGS', 'ACTIVE', DATE '2020-01-01',
       '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  # Rekening ketiga: milik peminjam juga, saldo nol — dipakai membuktikan penolakan saldo tidak
  # cukup, bukan penolakan kepemilikan rekening (itu diuji dengan `account-other`).
  execScript(db, """
    INSERT INTO deposit.account
      (account_id, account_no, party_id, product_id, product_version_id, branch_id,
       account_type, status, opened_on, created_by, updated_by)
    VALUES (md5('lending|account-zero')::uuid, '0001111113', '""" & PartyId &
      """',
            md5('lending|savings-product')::uuid, md5('lending|savings-version')::uuid,
            '""" & BranchId & """', 'SAVINGS', 'ACTIVE', DATE '2020-01-01',
            '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO deposit.account_balance (account_id, balance)
    VALUES (md5('lending|account')::uuid, 0), (md5('lending|account-other')::uuid, 0),
           (md5('lending|account-zero')::uuid, 0)
    ON CONFLICT DO NOTHING
  """)
  # Jurnal pencairan butuh periode akuntansi OPEN yang mencakup tanggal buku. Seed test ini tidak
  # memakai seed dev ledger (yang juga membuat jurnal demo), jadi periodenya dibuat sendiri.
  execScript(db, """
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    VALUES (md5('lending|period')::uuid, date_trunc('year', current_date)::date,
            (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
            'OPEN', '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  accountId = db.getValue(sql"SELECT md5('lending|account')::uuid::text")
  otherAccountId = db.getValue(sql"SELECT md5('lending|account-other')::uuid::text")
  zeroAccountId = db.getValue(sql"SELECT md5('lending|account-zero')::uuid::text")
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

proc call(verb, path, payload, token: string, idemKey = ""): Reply =
  let client = newHttpClient(timeout = 60_000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
  if idemKey.len > 0:
    client.headers["Idempotency-Key"] = idemKey
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

proc postJson(path: string, payload: JsonNode, token = "", idemKey = ""): Reply =
  ## `idemKey` hanya dipakai operasi yang mewajibkan `Idempotency-Key` (pencairan, T-164).
  call("POST", path, $payload, token, idemKey)

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

suite "lending: pencairan (T-164)":
  proc approvedLoan(amount = "9000000.00"): string =
    let created = postJson(LoansPath, loanBody(PartyId, versionActive, amount), makerToken)
    check created.code == 201
    let loanId = created.body["loanId"].getStr()
    check postJson(fill(ApprovePath, loanId), %*{}, approverToken).code == 200
    loanId

  test "pencairan sah: jadwal, jurnal, subledger, saldo, audit, event":
    let loanId = approvedLoan()
    let key = "itapi-lending-disburse-" & loanId
    let r = postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken, key)
    check r.code == 200
    checkJson(DisbursePath, "POST", "200", r.body)
    check r.body["loan"]["status"].getStr() == "ACTIVE"
    check r.body["installmentCount"].getInt() == 12
    check r.body["accountId"].getStr() == accountId
    let journalId = r.body["journalId"].getStr()
    let maturityOn = r.body["maturityOn"].getStr()

    # Pinjaman berjalan: tanggal cair + jatuh tempo terisi.
    check dbValue(sql"SELECT status FROM lending.loan WHERE loan_id = ?", loanId) == "ACTIVE"
    check dbValue(sql"SELECT maturity_on::text FROM lending.loan WHERE loan_id = ?", loanId) ==
      maturityOn

    # Jadwal 12 baris, setiap baris punya kewajiban positif, jumlah pokok tepat.
    check dbValue(sql"SELECT count(*) FROM lending.installment WHERE loan_id = ?", loanId) == "12"
    check dbValue(sql"""SELECT sum(principal_due)::numeric(24,2)::text
                          FROM lending.installment WHERE loan_id = ?""", loanId) == "9000000.00"
    check dbValue(sql"""SELECT count(*) FROM lending.installment
                         WHERE loan_id = ? AND principal_due + interest_due > 0""", loanId) == "12"

    # Jurnal seimbang D 110 / K 201, dari posting rule (bukan konstanta kode).
    check dbValue(sql"SELECT source_event FROM ledger.journal WHERE journal_id = ?", journalId) ==
      "LoanDisbursed"
    check dbValue(sql"""
      SELECT string_agg(gl_account || ':' || CASE WHEN debit > 0 THEN 'DEBIT' ELSE 'CREDIT' END,
                        ',' ORDER BY line_no)
        FROM ledger.journal_line WHERE journal_id = ?""", journalId) == "110:DEBIT,201:CREDIT"
    check dbValue(sql"""
      SELECT (sum(debit) - sum(credit))::numeric(24,2)::text
        FROM ledger.journal_line WHERE journal_id = ?""", journalId) == "0.00"

    # Subledger + cache saldo rekening bertambah sebesar pokok.
    check dbValue(sql"""SELECT tx_type FROM deposit.transaction
                         WHERE journal_id = ?""", journalId) == "LOAN_DISBURSEMENT"
    check dbValue(sql"SELECT balance::numeric(24,2)::text FROM deposit.account_balance WHERE account_id = ?",
      accountId) == "9000000.00"

    # Audit + event.
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'lending.loan.disburse' AND resource_id = ?""", loanId) == "1"
    check dbValue(sql"""SELECT count(*) FROM platform.outbox
                         WHERE event_type = 'LoanDisbursed' AND aggregate_id = ?""", loanId) == "1"

  test "replay Idempotency-Key sama mengembalikan respons asli, bukan mencairkan lagi":
    let loanId = approvedLoan("1000000.00")
    let key = "itapi-lending-replay-" & loanId
    let first = postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken, key)
    check first.code == 200
    let second = postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken, key)
    check second.code == 200
    check second.body["journalId"].getStr() == first.body["journalId"].getStr()
    check dbValue(sql"SELECT count(*) FROM lending.installment WHERE loan_id = ?", loanId) == "12"
    check dbValue(sql"""SELECT count(*) FROM deposit.transaction
                         WHERE journal_id = ?""", first.body["journalId"].getStr()) == "1"

  test "pencairan kedua dengan kunci lain ditolak":
    let loanId = approvedLoan("1000000.00")
    check postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken,
      "itapi-lending-a-" & loanId).code == 200
    let again = postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken,
      "itapi-lending-b-" & loanId)
    check again.code == 409
    check again.body["params"]["reason"].getStr() == "already_disbursed"
    checkProblem(DisbursePath, "POST", "409", again.body)

  test "pinjaman yang belum disetujui tidak bisa dicairkan":
    let created = postJson(LoansPath, loanBody(PartyId, versionActive, "1000000.00"), makerToken)
    let loanId = created.body["loanId"].getStr()
    let r = postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken,
      "itapi-lending-applied-" & loanId)
    check r.code == 409
    check r.body["params"]["reason"].getStr() == "not_approved"

  test "rekening milik anggota lain ditolak":
    let loanId = approvedLoan("1000000.00")
    let r = postJson(fill(DisbursePath, loanId), %*{"accountId": otherAccountId}, makerToken,
      "itapi-lending-other-" & loanId)
    check r.code == 409
    check r.body["params"]["reason"].getStr() == "account_party_mismatch"

  test "tanpa Idempotency-Key ditolak 400; accountId bukan uuid → 400":
    let loanId = approvedLoan("1000000.00")
    check postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken).code == 400
    check postJson(fill(DisbursePath, loanId), %*{"accountId": "bukan-uuid"}, makerToken,
      "itapi-lending-bad-" & loanId).code == 400

suite "lending: pembayaran angsuran (T-165)":
  proc disbursedLoan(amount = "9000000.00"): string =
    let created = postJson(LoansPath, loanBody(PartyId, versionActive, amount), makerToken)
    check created.code == 201
    let loanId = created.body["loanId"].getStr()
    check postJson(fill(ApprovePath, loanId), %*{}, approverToken).code == 200
    let paid = postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken,
      "itapi-lending-pay-disburse-" & loanId)
    check paid.code == 200
    loanId

  proc balanceOf(id: string): string =
    dbValue(sql"""SELECT balance::numeric(24,2)::text FROM deposit.account_balance
                  WHERE account_id = ?""", id)

  test "pembayaran sebagian: alokasi, jurnal per komponen, saldo, cache, audit, event":
    let loanId = disbursedLoan()
    let before = balanceOf(accountId)
    let r = postJson(fill(PaymentsPath, loanId), %*{"accountId": accountId,
      "amount": "1500000.00"}, makerToken, "itapi-lending-pay-" & loanId)
    check r.code == 200
    checkJson(PaymentsPath, "POST", "200", r.body)
    let paymentId = r.body["paymentId"].getStr()
    check r.body["amount"].getStr() == "1500000.00"
    # INTEREST,PRINCIPAL,PENALTY: bunga baris 1 tertutup penuh lebih dulu.
    check r.body["interestPaid"].getStr().len > 0
    check r.body["journalIds"].len == 2 # tanpa denda: pokok + bunga

    let principalPaid = r.body["principalPaid"].getStr()
    let interestPaid = r.body["interestPaid"].getStr()
    check dbValue(sql"""SELECT (principal_paid + interest_paid + penalty_paid)::numeric(24,2)::text
                          FROM lending.payment WHERE payment_id = ?""", paymentId) == "1500000.00"
    check dbValue(sql"""SELECT principal_paid::numeric(24,2)::text FROM lending.payment
                         WHERE payment_id = ?""", paymentId) == principalPaid
    check dbValue(sql"""SELECT count(*) FROM lending.payment_allocation WHERE payment_id = ?""",
      paymentId) != "0"

    # Baris 1 tertutup (bunga penuh + sebagian pokok), tanggal lunas belum diisi karena pokok belum.
    check dbValue(sql"""SELECT (principal_due - paid_principal)::numeric(24,2)::text
                          FROM lending.installment WHERE loan_id = ? AND no = 1""", loanId) != "0"
    check dbValue(sql"""SELECT (interest_due - paid_interest)::numeric(24,2)::text
                          FROM lending.installment WHERE loan_id = ? AND no = 1""", loanId) == "0.00"

    # Jurnal: debit 201 sebesar nominal, kredit 110 (pokok) + 401 (bunga).
    check dbValue(sql"""
      SELECT coalesce(sum(l.debit), 0)::numeric(24,2)::text
        FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
       WHERE j.source_ref = ? AND j.source_event IN
             ('LoanPrincipalPaid', 'LoanInterestPaid', 'LoanPenaltyPaid')""", paymentId) ==
      "1500000.00"
    check dbValue(sql"""
      SELECT string_agg(DISTINCT gl_account, ',' ORDER BY gl_account)
        FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
       WHERE j.source_ref = ? AND l.credit > 0 AND j.source_event IN
             ('LoanPrincipalPaid', 'LoanInterestPaid', 'LoanPenaltyPaid')""", paymentId) == "110,401"

    # Saldo rekening turun tepat sebesar nominal; subledger LOAN_PAYMENT satu baris per komponen.
    check balanceOf(accountId) == (parseFloat(before) - 1_500_000.0).formatFloat(ffDecimal, 2)
    check dbValue(sql"""
      SELECT count(*) FROM deposit.transaction t
        JOIN ledger.journal j USING (journal_id)
       WHERE j.source_ref = ? AND t.tx_type = 'LOAN_PAYMENT'""", paymentId) == "2"

    # Cache saldo pinjaman turun sebesar pokok yang dibayar.
    check dbValue(sql"""SELECT principal_outstanding::numeric(24,2)::text
                          FROM lending.loan_balance WHERE loan_id = ?""", loanId) ==
      (9_000_000.0 - parseFloat(principalPaid)).formatFloat(ffDecimal, 2)
    check dbValue(sql"""SELECT count(*) FROM platform.audit_log
                         WHERE action = 'lending.loan.pay' AND resource_id = ?""", loanId) == "1"
    check dbValue(sql"""SELECT count(*) FROM platform.outbox
                         WHERE event_type = 'LoanInstallmentPaid' AND aggregate_id = ?""",
      loanId) == "1"

  test "pelunasan: sisa pokok 0,00 dan status tetap ACTIVE":
    let loanId = disbursedLoan("600000.00")
    let outstanding = dbValue(sql"""SELECT principal_outstanding::numeric(24,2)::text
                                      FROM lending.loan_balance WHERE loan_id = ?""", loanId)
    # Bayar seluruh sisa kewajiban: pokok + bunga jadwal (dibaca dari jadwal, bukan dihitung test).
    let owed = dbValue(sql"""SELECT sum(principal_due + interest_due + penalty_due - paid_principal
                                    - paid_interest - paid_penalty)::numeric(24,2)::text
                               FROM lending.installment WHERE loan_id = ?""", loanId)
    let r = postJson(fill(PaymentsPath, loanId), %*{"accountId": accountId, "amount": owed},
      makerToken, "itapi-lending-settle-" & loanId)
    check r.code == 200
    check r.body["principalOutstanding"].getStr() == "0.00"
    check r.body["principalPaid"].getStr() == outstanding
    check dbValue(sql"""SELECT count(*) FROM lending.installment
                         WHERE loan_id = ? AND (paid_principal < principal_due
                                             OR paid_interest < interest_due
                                             OR paid_penalty < penalty_due)""", loanId) == "0"
    check dbValue(sql"SELECT status FROM lending.loan WHERE loan_id = ?", loanId) == "ACTIVE"

  test "nominal melebihi sisa kewajiban ditolak, saldo tidak berubah":
    let loanId = disbursedLoan("300000.00")
    let before = balanceOf(accountId)
    let over = postJson(fill(PaymentsPath, loanId), %*{"accountId": accountId,
      "amount": "99000000.00"}, makerToken, "itapi-lending-over-" & loanId)
    check over.code == 409
    check over.body["params"]["reason"].getStr() == "amount_exceeds_outstanding"
    checkProblem(PaymentsPath, "POST", "409", over.body)
    check balanceOf(accountId) == before

  test "replay Idempotency-Key sama tidak membayar dua kali":
    let loanId = disbursedLoan("1200000.00")
    let key = "itapi-lending-pay-replay-" & loanId
    let first = postJson(fill(PaymentsPath, loanId), %*{"accountId": accountId,
      "amount": "100000.00"}, makerToken, key)
    check first.code == 200
    let balanceAfterFirst = balanceOf(accountId)
    let second = postJson(fill(PaymentsPath, loanId), %*{"accountId": accountId,
      "amount": "100000.00"}, makerToken, key)
    check second.code == 200
    check second.body["paymentId"].getStr() == first.body["paymentId"].getStr()
    check balanceOf(accountId) == balanceAfterFirst
    check dbValue(sql"""SELECT count(*) FROM lending.payment WHERE loan_id = ?""", loanId) == "1"

  test "saldo tidak cukup, rekening anggota lain, dan pinjaman belum cair ditolak":
    let loanId = disbursedLoan("400000.00")
    let poor = postJson(fill(PaymentsPath, loanId), %*{"accountId": zeroAccountId,
      "amount": "100000.00"}, makerToken, "itapi-lending-poor-" & loanId)
    check poor.code == 409
    check poor.body["params"]["reason"].getStr() == "insufficient_balance"

    let other = postJson(fill(PaymentsPath, loanId), %*{"accountId": otherAccountId,
      "amount": "100000.00"}, makerToken, "itapi-lending-other-day-" & loanId)
    check other.code == 409
    check other.body["params"]["reason"].getStr() == "account_party_mismatch"

    let created = postJson(LoansPath, loanBody(PartyId, versionActive, "200000.00"), makerToken)
    let freshLoan = created.body["loanId"].getStr()
    check postJson(fill(ApprovePath, freshLoan), %*{}, approverToken).code == 200
    let notYet = postJson(fill(PaymentsPath, freshLoan), %*{"accountId": accountId,
      "amount": "10000.00"}, makerToken, "itapi-lending-notdisbursed-" & freshLoan)
    check notYet.code == 409
    check notYet.body["params"]["reason"].getStr() == "not_disbursed"

  test "tanpa Idempotency-Key dan amount tidak sah → 400":
    let loanId = disbursedLoan("200000.00")
    check postJson(fill(PaymentsPath, loanId), %*{"accountId": accountId,
      "amount": "10000.00"}, makerToken).code == 400
    check postJson(fill(PaymentsPath, loanId), %*{"accountId": accountId, "amount": "0"},
      makerToken, "itapi-lending-badpay-" & loanId).code == 400

suite "lending: restrukturisasi & hapus buku (T-168)":
  const
    RestructurePath = "/api/v1/lending/loans/{loanId}/restructure"
    WriteOffPath = "/api/v1/lending/loans/{loanId}/write-off"

  proc newActiveLoan(amount = "9000000.00"): string =
    let created = postJson(LoansPath, loanBody(PartyId, versionActive, amount), makerToken)
    check created.code == 201
    let loanId = created.body["loanId"].getStr()
    check postJson(fill(ApprovePath, loanId), %*{}, approverToken).code == 200
    check postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken,
      "it168-disburse-" & loanId).code == 200
    loanId

  proc activePrincipalOutstanding(loanId: string): string =
    dbValue(sql"""
      SELECT coalesce(sum(principal_due - paid_principal), 0)::numeric(24,2)::text
        FROM lending.installment WHERE loan_id = ? AND superseded_on IS NULL""", loanId)

  proc unpayedTotal(loanId: string): string =
    dbValue(sql"""
      SELECT coalesce(sum(principal_due - paid_principal + interest_due - paid_interest
                         + penalty_due - paid_penalty), 0)::numeric(24,2)::text
        FROM lending.installment WHERE loan_id = ? AND superseded_on IS NULL""", loanId)

  test "restrukturisasi membuat versi jadwal baru dan mengarsipkan yang lama":
    let loanId = newActiveLoan()
    let r = postJson(fill(RestructurePath, loanId),
      %*{"tenorMonths": 6, "reason": "penurunan kemampuan bayar"}, makerToken,
      "it168-restructure-" & loanId)
    check r.code == 200
    checkJson(RestructurePath, "POST", "200", r.body)
    check r.body["scheduleVersion"].getInt() == 2
    check r.body["installmentCount"].getInt() == 6
    check r.body["firstInstallmentNo"].getInt() == 13 # lanjutan nomor jadwal lama
    check r.body["supersededInstallments"].getInt() == 12
    # Jadwal lama diarsipkan, bukan dihapus; jadwal baru aktif.
    check dbValue(sql"""
      SELECT count(*) FROM lending.installment
       WHERE loan_id = ? AND superseded_on IS NOT NULL""", loanId) == "12"
    check dbValue(sql"""
      SELECT count(*) FROM lending.installment
       WHERE loan_id = ? AND superseded_on IS NULL""", loanId) == "6"
    # Sisa pokok terurai tepat sama di jadwal baru.
    check activePrincipalOutstanding(loanId) == "9000000.00"
    check dbValue(sql"SELECT maturity_on::text FROM lending.loan WHERE loan_id = ?", loanId) ==
      r.body["maturityOn"].getStr()
    check dbValue(sql"SELECT count(*) FROM lending.loan_schedule WHERE loan_id = ?", loanId) == "2"
    check dbValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'lending.loan.restructure' AND resource_id = ?""", loanId) == "1"
    check dbValue(sql"""
      SELECT count(*) FROM platform.outbox
       WHERE event_type = 'LoanRestructured' AND aggregate_id = ?""", loanId) == "1"

  test "pembayaran lama tetap utuh, pembayaran berikutnya masuk jadwal baru":
    let loanId = newActiveLoan("6000000.00")
    let paid = postJson(fill(PaymentsPath, loanId),
      %*{"accountId": accountId, "amount": "500000.00"}, makerToken, "it168-pay-" & loanId)
    check paid.code == 200
    let paidBefore = dbValue(sql"""
      SELECT sum(paid_principal + paid_interest + paid_penalty)::numeric(24,2)::text
        FROM lending.installment WHERE loan_id = ?""", loanId)
    let principalBefore = activePrincipalOutstanding(loanId)

    check postJson(fill(RestructurePath, loanId),
      %*{"tenorMonths": 3, "reason": "tenor diperpanjang"}, makerToken,
      "it168-restructure2-" & loanId).code == 200
    # Pembayaran lama tidak berubah sedikit pun (trigger 0089 menjaga kewajiban & paid_*).
    check dbValue(sql"""
      SELECT sum(paid_principal + paid_interest + paid_penalty)::numeric(24,2)::text
        FROM lending.installment WHERE loan_id = ?""", loanId) == paidBefore
    check activePrincipalOutstanding(loanId) == principalBefore

    let oldAllocations = dbValue(sql"""
      SELECT count(*) FROM lending.payment_allocation pa
        JOIN lending.payment p USING (payment_id)
       WHERE p.loan_id = ? AND pa.installment_no < 13""", loanId)
    check oldAllocations != "0" # pembayaran pertama memang menyentuh jadwal lama
    let after = postJson(fill(PaymentsPath, loanId),
      %*{"accountId": accountId, "amount": "200000.00"}, makerToken, "it168-pay2-" & loanId)
    check after.code == 200
    # Pembayaran baru tidak boleh menyentuh jadwal lama (yang sudah diarsipkan) sama sekali.
    check dbValue(sql"""
      SELECT count(*) FROM lending.payment_allocation pa
        JOIN lending.payment p USING (payment_id)
       WHERE p.loan_id = ? AND pa.installment_no < 13""", loanId) == oldAllocations
    check dbValue(sql"""
      SELECT count(*) FROM lending.payment_allocation pa
        JOIN lending.payment p USING (payment_id)
       WHERE p.loan_id = ? AND pa.installment_no >= 13""", loanId) != "0"

  test "replay kunci restrukturisasi tidak membuat jadwal kedua":
    let loanId = newActiveLoan("1200000.00")
    let key = "it168-restructure-replay-" & loanId
    let first = postJson(fill(RestructurePath, loanId),
      %*{"tenorMonths": 2, "reason": "uji replay"}, makerToken, key)
    check first.code == 200
    let before = dbValue(sql"SELECT count(*) FROM lending.loan_schedule WHERE loan_id = ?", loanId)
    let second = postJson(fill(RestructurePath, loanId),
      %*{"tenorMonths": 2, "reason": "uji replay"}, makerToken, key)
    check second.code == 200
    check second.body["scheduleVersion"].getInt() == first.body["scheduleVersion"].getInt()
    check dbValue(sql"SELECT count(*) FROM lending.loan_schedule WHERE loan_id = ?", loanId) == before

  test "pinjaman yang belum cair dan badan tidak sah ditolak":
    let created = postJson(LoansPath, loanBody(PartyId, versionActive, "500000.00"), makerToken)
    let pendingLoan = created.body["loanId"].getStr()
    check postJson(fill(ApprovePath, pendingLoan), %*{}, approverToken).code == 200
    let notYet = postJson(fill(RestructurePath, pendingLoan),
      %*{"tenorMonths": 3, "reason": "uji"}, makerToken, "it168-pending-" & pendingLoan)
    check notYet.code == 409
    check notYet.body["params"]["reason"].getStr() == "not_disbursed"

    let loanId = newActiveLoan("300000.00")
    check postJson(fill(RestructurePath, loanId), %*{"tenorMonths": 0, "reason": "x"},
      makerToken, "it168-bad-tenor-" & loanId).code == 400
    check postJson(fill(RestructurePath, loanId), %*{"tenorMonths": 3},
      makerToken, "it168-no-reason-" & loanId).code == 400
    check postJson(fill(RestructurePath, loanId), %*{"tenorMonths": 3, "reason": "x"},
      makerToken).code == 400

  test "hapus buku memakai penyisihan lebih dulu, sisanya beban":
    let loanId = newActiveLoan("3000000.00")
    let total = unpayedTotal(loanId)
    check dbValue(sql"""
      UPDATE lending.loan SET collectibility = 'LOSS' WHERE loan_id = ? RETURNING loan_id::text""",
      loanId) == loanId
    execDb(sql"""
      INSERT INTO lending.ppap_snapshot
        (loan_id, business_date, grade, base_amount, rate_micro, allowance)
      VALUES (?, current_date, 'LOSS', 3000000.00, 500000, 1500000.00)""", loanId)

    let r = postJson(fill(WriteOffPath, loanId), %*{"reason": "tidak ada harapan tertagih"},
      approverToken, "it168-writeoff-" & loanId)
    check r.code == 200
    checkJson(WriteOffPath, "POST", "200", r.body)
    check r.body["status"].getStr() == "WRITTEN_OFF"
    check r.body["total"].getStr() == total
    check r.body["allowanceApplied"].getStr() == "1500000.00"
    check r.body["expense"].getStr() == (parseFloat(total) - 1_500_000.0).formatFloat(ffDecimal, 2)
    check r.body["journalIds"].len == 2 # penyisihan + beban

    check dbValue(sql"SELECT status FROM lending.loan WHERE loan_id = ?", loanId) == "WRITTEN_OFF"
    check dbValue(sql"""
      SELECT written_off_on IS NOT NULL AND written_off_by IS NOT NULL
             AND written_off_reason IS NOT NULL
        FROM lending.loan WHERE loan_id = ?""", loanId) == "t"
    check dbValue(sql"""
      SELECT (principal_outstanding + interest_overdue + penalty_outstanding)::numeric(24,2)::text
        FROM lending.loan_balance WHERE loan_id = ?""", loanId) == "0.00"
    check dbValue(sql"""
      SELECT allowance_applied + expense_amount = principal_amount + interest_amount + penalty_amount
        FROM lending.writeoff WHERE loan_id = ?""", loanId) == "t"

    # Kedua jurnal mengkredit 110 sebesar nilai yang dihapus; tidak ada sisi negatif.
    check dbValue(sql"""
      SELECT coalesce(sum(credit), 0)::numeric(24,2)::text
        FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
       WHERE j.source_ref = ? AND j.source_event IN
             ('LoanWriteOffProvisioned', 'LoanWriteOffExpense')""", loanId) == total
    check dbValue(sql"""
      SELECT string_agg(gl_account || ':' ||
               CASE WHEN debit > 0 THEN 'DEBIT' ELSE 'CREDIT' END, ',' ORDER BY line_no)
        FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
       WHERE j.source_ref = ? AND j.source_event = 'LoanWriteOffProvisioned'""", loanId) ==
      "111:DEBIT,110:CREDIT"
    check dbValue(sql"""
      SELECT string_agg(gl_account || ':' ||
               CASE WHEN debit > 0 THEN 'DEBIT' ELSE 'CREDIT' END, ',' ORDER BY line_no)
        FROM ledger.journal_line l JOIN ledger.journal j USING (journal_id)
       WHERE j.source_ref = ? AND j.source_event = 'LoanWriteOffExpense'""", loanId) ==
      "504:DEBIT,110:CREDIT"
    check dbValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'lending.loan.write_off' AND resource_id = ?""", loanId) == "1"

  test "replay kunci hapus buku tidak menjurnal dua kali":
    let loanId = newActiveLoan("1200000.00")
    check dbValue(sql"""
      UPDATE lending.loan SET collectibility = 'LOSS' WHERE loan_id = ? RETURNING loan_id::text""",
      loanId) == loanId
    let key = "it168-writeoff-replay-" & loanId
    let first = postJson(fill(WriteOffPath, loanId), %*{"reason": "uji replay"}, approverToken, key)
    check first.code == 200
    let journals = dbValue(sql"""
      SELECT count(*) FROM ledger.journal WHERE source_ref = ?""", loanId)
    let second = postJson(fill(WriteOffPath, loanId), %*{"reason": "uji replay"}, approverToken, key)
    check second.code == 200
    check second.body["total"].getStr() == first.body["total"].getStr()
    check dbValue(sql"SELECT count(*) FROM ledger.journal WHERE source_ref = ?", loanId) == journals
    check dbValue(sql"SELECT count(*) FROM lending.writeoff WHERE loan_id = ?", loanId) == "1"

  test "hapus buku ditolak: bukan LOSS, bukan penyetuju, tanpa kunci":
    let loanId = newActiveLoan("600000.00")
    # Belum dinilai → ditolak, bukan dianggap LOSS.
    let ungraded = postJson(fill(WriteOffPath, loanId), %*{"reason": "uji"}, approverToken,
      "it168-ungraded-" & loanId)
    check ungraded.code == 409
    check ungraded.body["params"]["reason"].getStr() == "not_loss"

    check dbValue(sql"""
      UPDATE lending.loan SET collectibility = 'LOSS' WHERE loan_id = ? RETURNING loan_id::text""",
      loanId) == loanId
    # Pemisahan tugas ada di data RBAC: `lending_maker` **tidak** memegang izin hapus buku
    # (migrasi `platform/0096`). Fixture test memberi `dev.maker` `platform_admin`, jadi pengujian
    # di sini memeriksa aturan perannya, bukan grant dev itu.
    check dbValue(sql"""
      SELECT count(*) FROM platform.role_permission rp
        JOIN platform.role r USING (role_id)
        JOIN platform.permission p USING (permission_id)
       WHERE r.code = 'lending_maker' AND p.code = 'lending.loan.write_off'""") == "0"
    check dbValue(sql"""
      SELECT count(*) FROM platform.role_permission rp
        JOIN platform.role r USING (role_id)
        JOIN platform.permission p USING (permission_id)
       WHERE r.code = 'lending_maker' AND p.code = 'lending.loan.restructure'""") == "1"
    # Pengguna tanpa izin sama sekali tetap ditolak.
    check postJson(fill(WriteOffPath, loanId), %*{"reason": "uji"}, checkerToken,
      "it168-checker-" & loanId).code == 403
    check postJson(fill(WriteOffPath, loanId), %*{"reason": "uji"}, approverToken).code == 400
    check postJson(fill(WriteOffPath, loanId), %*{}, approverToken,
      "it168-empty-" & loanId).code == 400
