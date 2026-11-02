## Test integrasi laporan pinjaman (T-171): tunggakan/aging, penyisihan, rekonsiliasi.
##
## Yang dibuktikan di sini bukan bentuk JSON, melainkan **angkanya**:
##   1. tunggakan dihitung dari jadwal aktif yang lewat jatuh tempo — angsuran masa depan tidak ikut,
##      dan DPD = umur tunggakan tertua;
##   2. golongan pada laporan = golongan hasil task regrading tanggal itu (bukan tanggal lain);
##   3. penyisihan pada laporan = `ppap_snapshot` tanggal itu, dan tarifnya benar-benar dari parameter
##      (`500.000,00` = 10% × 5.000.000,00);
##   4. rekonsiliasi: saldo GL `110`/`111` dari jurnal sama dengan subledger pinjaman — angka yang
##      tidak boleh berbeda tanpa alarm;
##   5. laporan agregat menolak pemegang izin satu cabang (403), dan `asOf` tidak sah → 400.
##
## Pinjaman dibuat lewat API (submit → approve → disburse) supaya jurnal, jadwal, dan saldo berasal
## dari jalur nyata, bukan baris yang dikarang untuk laporan. Suite ini me-reset seluruh schema.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/[clock, dayclose, result]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import daycloser/domain/[registry, types]

import ../src/[context, daycloser_lending, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  LoansPath = "/api/v1/lending/loans"
  ApprovePath = "/api/v1/lending/loans/{loanId}/approve"
  DisbursePath = "/api/v1/lending/loans/{loanId}/disburse"
  ArrearsPath = "/api/v1/lending/reports/arrears"
  AllowancePath = "/api/v1/lending/reports/allowance"
  ReconPath = "/api/v1/lending/reports/reconciliation"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  ApproverUser = "dev.approver"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "11111111-1111-7111-8111-111111111111"
  PartyId = "22222222-2222-7222-8222-222222222222"
  ActorId = "77777777-7777-7777-8777-777777777777"
  MakerId = "88888888-8888-7888-8888-888888888888"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_lending_reports: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))
let businessDate = format(now().utc, "yyyy-MM-dd")

var
  versionActive = ""
  accountId = ""

block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))
  execScript(db, """
    INSERT INTO platform.app_user
      (user_id, username, full_name, password_algo, password_hash, must_change_password)
    SELECT md5('dev|dev.approver')::uuid, 'dev.approver', 'Uji Approver (dev)',
           password_algo, password_hash, false
      FROM platform.app_user WHERE username = 'dev.maker'
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
    VALUES ('""" & PartyId &
      """', 'LNR0001', 'PERSON', 'Anggota Laporan', 'ACTIVE',
            '""" & BranchId & """', '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO lending.loan_product (product_id, code, name, created_by)
    VALUES (md5('report|product')::uuid, 'LNREPORT', 'Pinjaman Laporan',
            '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO lending.loan_product_version
      (version_id, product_id, version_no, status, schedule_method, tenor_months, annual_rate,
       allocation_order, created_by, approved_by)
    VALUES (md5('report|version')::uuid, md5('report|product')::uuid, 1, 'ACTIVE', 'ANNUITY', 12,
            150000, 'INTEREST,PRINCIPAL,PENALTY', '""" & MakerId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  # Rekening simpanan tujuan pencairan: versi lahir DRAFT lalu disahkan seperti `approveVersion`.
  execScript(db, """
    INSERT INTO product.product (product_id, code, name, product_type, created_by, updated_by)
    VALUES (md5('report|savings')::uuid, 'SAVREPORT', 'Simpanan Laporan', 'SAVINGS',
            '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO product.product_version
      (version_id, product_id, version_no, effective_from, sealed, published_by, status, maker)
    VALUES (md5('report|savings-version')::uuid, md5('report|savings')::uuid, 1,
            DATE '2020-01-01', false, '""" & MakerId & """', 'DRAFT', '""" & MakerId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO product.product_param_binding (version_id, param_key, value)
    VALUES (md5('report|savings-version')::uuid, 'product.savings.min_balance', '"0.00"'::jsonb)
    ON CONFLICT DO NOTHING;
    UPDATE product.product_version
       SET status = 'ACTIVE', checker = '""" & ActorId & """', approved_at = now(), sealed = true
     WHERE version_id = md5('report|savings-version')::uuid AND status = 'DRAFT';
  """)
  execScript(db, """
    INSERT INTO deposit.account
      (account_id, account_no, party_id, product_id, product_version_id, branch_id,
       account_type, status, opened_on, created_by, updated_by)
    VALUES (md5('report|account')::uuid, '0002222222', '""" & PartyId &
      """',
            md5('report|savings')::uuid, md5('report|savings-version')::uuid,
            '""" & BranchId & """', 'SAVINGS', 'ACTIVE', DATE '2020-01-01',
            '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  execScript(db, """
    INSERT INTO deposit.account_balance (account_id, balance)
    VALUES (md5('report|account')::uuid, 0) ON CONFLICT DO NOTHING
  """)
  # Periode akuntansi yang mencakup tanggal buku: jurnal pencairan dan penyisihan butuh itu.
  execScript(db, """
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    VALUES (md5('report|period')::uuid, date_trunc('year', current_date)::date,
            (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
            'OPEN', '""" & ActorId & """', '""" & ActorId & """')
    ON CONFLICT DO NOTHING
  """)
  versionActive = db.getValue(sql"SELECT md5('report|version')::uuid::text")
  accountId = db.getValue(sql"SELECT md5('report|account')::uuid::text")
  dbPool.release(db)

var app = AppContext(version: "itapi-lending-reports-0.0.0", role: "api", startedAt: epochTime(),
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
  call("POST", path, $payload, token, idemKey)

proc getJson(path, token: string): Reply =
  call("GET", path, "", token)

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

proc taskOf(id: string): DayCloseTask =
  let reg = newRegistry()
  registerLendingTasks(reg, dbPool)
  for t in reg.all():
    if t.id == id:
      return t
  raise newException(ValueError, "task tidak terdaftar: " & id)

proc ctxOn(businessDate: string; chunkSize = 1000): TaskContext =
  TaskContext(runId: "33333333-3333-4333-8333-333333333333", scopeType: "INSTITUTION",
    scopeId: "", businessDate: businessDate, levels: {clEOD}, mode: rmReal, chunkSize: chunkSize)

proc runTask(id: string; businessDate: string) =
  let outcome = taskOf(id).run(ctxOn(businessDate), Chunk(chunkNo: 0))
  doAssert outcome.isOk, "task " & id & " gagal: " & outcome.error.message

let
  makerToken = tokenOf(postJson(LoginPath, %*{"username": MakerUser, "password": DevPassword}))
  approverToken = tokenOf(postJson(LoginPath, %*{"username": ApproverUser,
    "password": DevPassword}))

doAssert makerToken.len > 0 and approverToken.len > 0, "login fixture gagal"

# Pinjaman uji: 5.000.000,00 anuitas 12 bulan; dua angsuran dibuat lewat jatuh tempo
# (100 dan 30 hari) supaya laporan punya tunggakan nyata.
var loanId = ""
block:
  let created = postJson(LoansPath, %*{"partyId": PartyId, "productVersionId": versionActive,
    "principal": "5000000.00"}, makerToken)
  doAssert created.code == 201, "pengajuan gagal: " & $created.code & " " & $created.body
  loanId = created.body["loanId"].getStr()
  doAssert postJson(fill(ApprovePath, loanId), %*{}, approverToken).code == 200, "persetujuan gagal"
  let disbursed = postJson(fill(DisbursePath, loanId), %*{"accountId": accountId}, makerToken,
    "report-disburse-" & loanId)
  doAssert disbursed.code == 200, "pencairan gagal: " & $disbursed.code & " " & $disbursed.body

execDb(sql"""
  UPDATE lending.installment SET due_on = ?::date - 100 WHERE loan_id = ? AND no = 1""",
  businessDate, loanId)
execDb(sql"""
  UPDATE lending.installment SET due_on = ?::date - 30 WHERE loan_id = ? AND no = 2""",
  businessDate, loanId)

# Snapshot kolektibilitas + penyisihan tanggal buku ini, lewat task day-close yang sebenarnya.
runTask("lending.dpd_regrade", businessDate)
runTask("lending.ppap_provision", businessDate)

suite "laporan pinjaman: tunggakan & aging (T-171)":
  test "tunggakan hanya dari angsuran lewat jatuh tempo, DPD = tunggakan tertua":
    let r = getJson(ArrearsPath & "?asOf=" & businessDate, makerToken)
    check r.code == 200
    checkJson(ArrearsPath, "GET", "200", r.body)
    check r.body["asOf"].getStr() == businessDate
    check r.body["items"].len == 1
    let item = r.body["items"][0]
    check item["loanId"].getStr() == loanId
    check item["dpd"].getInt() == 100
    check item["grade"].getStr() == "SUBSTANDARD"
    # Angsuran 1 + 2 saja; 10 angsuran berikutnya belum jatuh tempo dan tidak boleh ikut.
    let expectedPrincipal = dbValue(sql"""
      SELECT sum(principal_due)::numeric(24,2)::text FROM lending.installment
       WHERE loan_id = ? AND no IN (1, 2)""", loanId)
    let expectedInterest = dbValue(sql"""
      SELECT sum(interest_due)::numeric(24,2)::text FROM lending.installment
       WHERE loan_id = ? AND no IN (1, 2)""", loanId)
    check item["principal"].getStr() == expectedPrincipal
    check item["interest"].getStr() == expectedInterest
    check item["penalty"].getStr() == "0.00"
    check r.body["totals"]["principal"].getStr() == expectedPrincipal
    check r.body["totals"]["loans"].getInt() == 1
    # Aging per golongan: satu keranjang (SUBSTANDARD), bukan semua keranjang bernilai nol.
    check r.body["aging"].len == 1
    check r.body["aging"][0]["grade"].getStr() == "SUBSTANDARD"
    check r.body["aging"][0]["total"].getStr() == r.body["totals"]["total"].getStr()

  test "asOf tidak sah ditolak 400, bukan diabaikan":
    check getJson(ArrearsPath & "?asOf=2026-13-40", makerToken).code == 400
    check getJson(AllowancePath & "?asOf=bukan-tanggal", makerToken).code == 400

suite "laporan pinjaman: penyisihan (T-171)":
  test "penyisihan = tarif parameter × pokok berjalan pada golongan itu":
    let r = getJson(AllowancePath & "?asOf=" & businessDate, makerToken)
    check r.code == 200
    checkJson(AllowancePath, "GET", "200", r.body)
    check r.body["lines"].len == 1
    let line = r.body["lines"][0]
    check line["grade"].getStr() == "SUBSTANDARD"
    check line["loans"].getInt() == 1
    # 10% dari 5.000.000,00 — tarif dari parameter `lending.ppap.rates`, bukan angka di kode.
    check line["rateMicro"].getInt() == 100000
    check line["base"].getStr() == "5000000.00"
    check line["allowance"].getStr() == "500000.00"
    check r.body["total"].getStr() == "500000.00"
    check r.body["baseTotal"].getStr() == "5000000.00"
    check r.body["mixedRates"].len == 0

  test "laporan tanggal lain tidak memakai snapshot hari ini":
    # Sehari sebelum regrading: belum ada snapshot, jadi tidak ada baris penyisihan.
    let r = getJson(AllowancePath & "?asOf=" & dbValue(sql"SELECT (?::date - 1)::text",
      businessDate), makerToken)
    check r.code == 200
    check r.body["lines"].len == 0
    check r.body["total"].getStr() == "0.00"

suite "laporan pinjaman: rekonsiliasi GL vs subledger (T-171)":
  test "saldo 110/111 dari jurnal sama dengan subledger":
    let r = getJson(ReconPath, makerToken)
    check r.code == 200
    checkJson(ReconPath, "GET", "200", r.body)
    check r.body["loanReceivableGl"].getStr() == "5000000.00"
    check r.body["loanReceivableSubledger"].getStr() == "5000000.00"
    check r.body["receivableDiff"].getStr() == "0.00"
    check r.body["allowanceGl"].getStr() == "500000.00"
    check r.body["allowanceSubledger"].getStr() == "500000.00"
    check r.body["allowanceWrittenOff"].getStr() == "0.00"
    check r.body["allowanceDiff"].getStr() == "0.00"
    check r.body["balanced"].getBool() == true

suite "laporan pinjaman: otorisasi":
  test "tanpa sesi → 401":
    check getJson(ArrearsPath, "").code == 401
    check getJson(ReconPath, "").code == 401

  test "pemegang izin satu cabang tidak boleh membaca laporan institusi":
    # `lending_maker` diberikan **hanya di cabang uji**: izin ada, tetapi tidak pada tingkat
    # institusi; laporan agregat lintas cabang bukan haknya.
    execDb(sql"""
      INSERT INTO platform.app_user
        (user_id, username, full_name, password_algo, password_hash, must_change_password)
      SELECT md5('report|branch-reader')::uuid, 'report.reader', 'Uji Laporan Cabang (dev)',
             password_algo, password_hash, false
        FROM platform.app_user WHERE username = 'dev.maker'
      ON CONFLICT (username) DO UPDATE SET must_change_password = false, status = 'ACTIVE'""")
    execDb(sql"""
      INSERT INTO platform.user_role (user_id, role_id, branch_id)
      SELECT u.user_id, r.role_id, ?::uuid
        FROM platform.app_user u, platform.role r
       WHERE u.username = 'report.reader' AND r.code = 'lending_maker'
      ON CONFLICT DO NOTHING""", BranchId)
    let readerToken = tokenOf(postJson(LoginPath, %*{"username": "report.reader",
      "password": DevPassword}))
    check readerToken.len > 0
    let r = getJson(ArrearsPath, readerToken)
    check r.code == 403
    check getJson(AllowancePath, readerToken).code == 403
    check getJson(ReconPath, readerToken).code == 403
