## Test integrasi HTTP vault kas cabang (T-107) + top-up maker-checker (T-118).
## Butuh `KRAN_DATABASE_URL`.
##
## Jalur penuh: sesi/izin (401/403 cabang), validasi 400 (amount ≤ 0, bukan desimal, `branchId`,
## kunci, note kosong, akun sumber bukan ASSET postable), 404 `vault_not_configured` /
## `topup_request_not_found`, 201 pengajuan `PENDING` **tanpa** mengubah saldo, 200 persetujuan
## akun lain yang menulis saldo vault + jurnal `D 101.1 / K source`, penolakan beralasan, guard
## `self_approval`, idempotensi (replay 200 + `Idempotent-Replayed`, isi beda 409), audit + event
## outbox, dan **dua persetujuan bersamaan** (satu baris vault terkunci, increment atomik).
##
## Test me-reset seluruh schema, menyiapkan seed pack `base` + pengguna dev, periode buku besar
## OPEN untuk tanggal bisnis jam palsu (`2026-10-22`), beberapa vault cabang, dan role
## `platform_admin` untuk pengaju (`dev.maker`), penyetuju kedua (`dev.checker`), dan aktor
## ber-cabang-tunggal (`dev.branchmaker`).
##
## **HUMAN-REVIEW-REQUIRED**: mutasi saldo vault kas + jurnal GL (AGENTS.md §8).

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
  CheckerUser = "dev.checker"
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

  # `dev.maker` (pengaju) dan `dev.checker` (penyetuju kedua, T-118) memegang seluruh izin tanpa
  # batas cabang; `dev.branchmaker` hanya di `OtherBranch` → `authorizedAtBranch` harus menolak
  # `BranchA`.
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username IN ('dev.maker', 'dev.checker') AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

  # Persetujuan top-up memposting jurnal GL, jadi tanggal bisnis jam palsu wajib punya periode OPEN
  # (trigger `ledger.assert_journal_period_open`). Seed `0003_dev_ledger.sql` memakai tahun berjalan
  # sungguhan, bukan 2026.
  execScript(db, """
    INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
    SELECT md5('itapi-teller-vault|2026')::uuid, '2026-01-01'::date, '2026-12-31'::date, 'OPEN',
           md5('itapi-teller-vault|fixture')::uuid, md5('itapi-teller-vault|fixture')::uuid
    WHERE NOT EXISTS (
      SELECT 1 FROM ledger.period
       WHERE starts_on <= '2026-10-22'::date AND ends_on >= '2026-10-22'::date)
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

proc topUpBody(branch, amount: string, note = "Setoran bank ke kas operasional",
    sourceAccount = "102"): JsonNode =
  result = %*{"branchId": branch, "amount": amount, "sourceAccount": sourceAccount}
  if note.len > 0:
    result["note"] = %note

proc submitTopUp(token, branch, amount: string, key = ""): Reply =
  postJson(TopUpsPath, topUpBody(branch, amount), token, key)

proc approveTopUp(token, requestId: string, key = ""): Reply =
  postJson(TopUpsPath & "/" & requestId & "/approve", %*{}, token, key)

proc rejectTopUp(token, requestId, reason: string): Reply =
  postJson(TopUpsPath & "/" & requestId & "/reject", %*{"reason": reason}, token)

proc listTopUps(token, branch: string, status = ""): Reply =
  var path = TopUpsPath & "?branchId=" & branch
  if status.len > 0:
    path.add "&status=" & status
  call("GET", path, "", token)

proc requestIdOf(reply: Reply): string =
  reply.body["requestId"].getStr()

proc getVault(token, branch: string): Reply =
  call("GET", VaultPath & "?branchId=" & branch, "", token)

proc dbCount(query: SqlQuery, args: varargs[string, `$`]): int =
  let conn = dbPool.acquire()
  try:
    parseInt(conn.getValue(query, args))
  finally:
    dbPool.release(conn)

proc setVaultGlAccount(value: string) =
  ## Ubah parameter akun vault langsung di DB (uji guard konfigurasi berubah antar pengajuan).
  let conn = dbPool.acquire()
  try:
    exec(conn, sql"""UPDATE platform.param_value SET value = ?::jsonb
                      WHERE key = 'teller.vault.cash_account' AND scope_type = 'GLOBAL'""",
      "\"" & value & "\"")
  finally:
    dbPool.release(conn)

proc pendingCount(branch: string): int =
  dbCount(sql"""SELECT count(*)::text FROM teller.vault_topup_request
                 WHERE branch_id = ? AND status = 'PENDING'""", branch)

proc auditCount(action: string): int =
  dbCount(sql"SELECT count(*)::text FROM platform.audit_log WHERE action = ?", action)

proc outboxCount(eventType: string): int =
  dbCount(sql"SELECT count(*)::text FROM platform.outbox WHERE event_type = ?", eventType)

proc reasonOf(reply: Reply): string =
  reply.body["params"]["reason"].getStr()

suite "vault: autentikasi & izin":
  test "tanpa sesi → 401":
    let reply = submitTopUp("", BranchA, "10.0000")
    check reply.code == 401
    checkProblem(TopUpsPath, "POST", "401", reply.body)

  test "pengajuan izin hanya di cabang lain → 403 branch_not_allowed":
    let token = tokenOf(login(BranchMakerUser))
    check token.len > 0
    let reply = submitTopUp(token, BranchA, "10.0000", "vault-403-" & $epochTime())
    check reply.code == 403
    checkProblem(TopUpsPath, "POST", "403", reply.body)
    check reasonOf(reply) == "branch_not_allowed"

  test "persetujuan izin hanya di cabang lain → 403 branch_not_allowed":
    let maker = tokenOf(login(MakerUser))
    let submitted = submitTopUp(maker, BranchA, "10.0000", "vault-approve-403-" & $epochTime())
    check submitted.code == 201
    let requestId = requestIdOf(submitted)

    let scoped = tokenOf(login(BranchMakerUser))
    let reply = approveTopUp(scoped, requestId, "vault-approve-403-b-" & $epochTime())
    check reply.code == 403
    checkProblem(TopUpsPath & "/{requestId}/approve", "POST", "403", reply.body)
    check reasonOf(reply) == "branch_not_allowed"
    check vaultOf(BranchA) == "1000.0000"

  test "baca izin hanya di cabang lain → 403 branch_not_allowed (saldo & daftar)":
    let token = tokenOf(login(BranchMakerUser))
    let read = getVault(token, BranchA)
    check read.code == 403
    checkProblem(VaultPath, "GET", "403", read.body)
    check reasonOf(read) == "branch_not_allowed"

    let listed = listTopUps(token, BranchA)
    check listed.code == 403
    checkProblem(TopUpsPath, "GET", "403", listed.body)
    check reasonOf(listed) == "branch_not_allowed"

suite "vault: validasi 400":
  test "amount ≤ 0 / bukan desimal / branchId salah / note kosong / akun sumber salah / tanpa kunci → 400":
    let token = tokenOf(login(MakerUser))
    check token.len > 0

    for bad in ["0.0000", "-5.0000", "abc", "1.00001", ""]:
      let reply = submitTopUp(token, BranchA, bad)
      check reply.code == 400
      checkProblem(TopUpsPath, "POST", "400", reply.body)

    let badBranch = submitTopUp(token, "bukan-uuid", "10.0000")
    check badBranch.code == 400
    checkProblem(TopUpsPath, "POST", "400", badBranch.body)

    # Bukti sumber dana wajib: pengajuan tanpa alasan tidak bisa ditelaah approver.
    let noNote = postJson(TopUpsPath, %*{"branchId": BranchA, "amount": "10.0000",
      "sourceAccount": "102"}, token)
    check noNote.code == 400
    checkProblem(TopUpsPath, "POST", "400", noNote.body)

    let longNote = postJson(TopUpsPath, topUpBody(BranchA, "10.0000", repeat('n', 201)), token)
    check longNote.code == 400
    checkProblem(TopUpsPath, "POST", "400", longNote.body)

    # Akun sumber harus akun COA ASSET aktif yang postable (`201` = LIABILITY, `999` = tidak ada),
    # dan **bukan** akun vault itu sendiri: D/K akun yang sama membuat saldo vault naik sementara
    # jurnal netto nol (buku besar tidak lagi mengikat saldo).
    for badSource in ["999", "201", "1", "101.1"]:
      let reply = postJson(TopUpsPath, topUpBody(BranchA, "10.0000", "bukti", badSource), token)
      check reply.code == 400
      checkProblem(TopUpsPath, "POST", "400", reply.body)
      check reasonOf(reply) == "source_account_invalid"

    let tanpaKunci = postJson(TopUpsPath, topUpBody(BranchA, "10.0000"), token, sendKey = false)
    check tanpaKunci.code == 400
    checkProblem(TopUpsPath, "POST", "400", tanpaKunci.body)

  test "baca/list tanpa/keliru branchId → 400":
    let token = tokenOf(login(MakerUser))
    let missing = call("GET", VaultPath, "", token)
    check missing.code == 400
    checkProblem(VaultPath, "GET", "400", missing.body)
    let bad = call("GET", VaultPath & "?branchId=nope", "", token)
    check bad.code == 400
    let badList = call("GET", TopUpsPath & "?branchId=nope", "", token)
    check badList.code == 400
    let badStatus = call("GET", TopUpsPath & "?branchId=" & BranchA & "&status=DONE", "", token)
    check badStatus.code == 400

suite "vault: baca, ajukan, setujui":
  test "vault belum dikonfigurasi → 404 vault_not_configured (baca & ajukan)":
    let token = tokenOf(login(MakerUser))

    let read = getVault(token, BranchNoVault)
    check read.code == 404
    checkProblem(VaultPath, "GET", "404", read.body)
    check reasonOf(read) == "vault_not_configured"

    let top = submitTopUp(token, BranchNoVault, "10.0000", "vault-novault-" & $epochTime())
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

  test "ajukan → PENDING tanpa ubah saldo; setujui akun lain → saldo + jurnal + audit + event":
    let maker = tokenOf(login(MakerUser))
    let checker = tokenOf(login(CheckerUser))
    let before = vaultOf(BranchA)
    let submitAudits = auditCount("teller.vault.topup.submit")
    let approveAudits = auditCount("teller.vault.topup.approve")
    let requested = outboxCount("TellerVaultTopUpRequested")
    let topped = outboxCount("TellerVaultTopedUp")

    let submitted = submitTopUp(maker, BranchA, "250.0000", "vault-add-" & $epochTime())
    check submitted.code == 201
    checkJson(TopUpsPath, "POST", "201", submitted.body)
    check submitted.body["status"].getStr() == "PENDING"
    check submitted.body["branchId"].getStr() == BranchA
    check submitted.body["sourceAccount"].getStr() == "102"
    check submitted.body["requestedBy"].getStr().len == 36
    check submitted.body["journalId"].getStr() == ""
    # Pengajuan belum menyentuh saldo.
    check vaultOf(BranchA) == before
    check auditCount("teller.vault.topup.submit") == submitAudits + 1
    check outboxCount("TellerVaultTopUpRequested") == requested + 1

    let requestId = requestIdOf(submitted)
    let approved = approveTopUp(checker, requestId, "vault-approve-" & $epochTime())
    check approved.code == 200
    checkJson(TopUpsPath & "/{requestId}/approve", "POST", "200", approved.body)
    check approved.body["balanceAfter"].getStr() == "1250.0000"
    check approved.body["request"]["status"].getStr() == "APPROVED"
    check approved.body["request"]["journalId"].getStr().len == 36
    check vaultOf(BranchA) == "1250.0000"
    check auditCount("teller.vault.topup.approve") == approveAudits + 1
    check outboxCount("TellerVaultTopedUp") == topped + 1

    # Jurnal GL: D 101.1 KAS DI VAULT / K 102 BANK, nominal = pengajuan.
    let journalId = approved.body["request"]["journalId"].getStr()
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal_line
                         WHERE journal_id = ?::uuid AND gl_account = '101.1' AND debit = 250""",
      journalId) == 1
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal_line
                         WHERE journal_id = ?::uuid AND gl_account = '102' AND credit = 250""",
      journalId) == 1

    # Persetujuan kedua (kunci baru) ditolak: pengajuan sudah diputuskan.
    let again = approveTopUp(checker, requestId, "vault-approve-again-" & $epochTime())
    check again.code == 409
    checkProblem(TopUpsPath & "/{requestId}/approve", "POST", "409", again.body)
    check reasonOf(again) == "topup_request_not_pending"

  test "pengaju tidak boleh menyetujui pengajuannya sendiri → 409 self_approval":
    let maker = tokenOf(login(MakerUser))
    let submitted = submitTopUp(maker, BranchB, "25.0000", "vault-self-" & $epochTime())
    check submitted.code == 201
    let reply = approveTopUp(maker, requestIdOf(submitted), "vault-self-" & $epochTime())
    check reply.code == 409
    checkProblem(TopUpsPath & "/{requestId}/approve", "POST", "409", reply.body)
    check reasonOf(reply) == "self_approval"
    check vaultOf(BranchB) == "100.0000"

  test "tolak pengajuan: alasan wajib, saldo tidak berubah, approve setelahnya 409":
    let maker = tokenOf(login(MakerUser))
    let checker = tokenOf(login(CheckerUser))
    let submitted = submitTopUp(maker, BranchB, "40.0000", "vault-reject-" & $epochTime())
    check submitted.code == 201
    let requestId = requestIdOf(submitted)

    let noReason = postJson(TopUpsPath & "/" & requestId & "/reject", %*{"reason": ""}, checker)
    check noReason.code == 400

    let rejected = rejectTopUp(checker, requestId, "Bukti setoran bank tidak dilampirkan")
    check rejected.code == 200
    checkJson(TopUpsPath & "/{requestId}/reject", "POST", "200", rejected.body)
    check rejected.body["request"]["status"].getStr() == "REJECTED"
    check rejected.body["request"]["decisionNote"].getStr() == "Bukti setoran bank tidak dilampirkan"
    check rejected.body["request"]["journalId"].getStr() == ""
    check vaultOf(BranchB) == "100.0000"

    let afterReject = approveTopUp(checker, requestId, "vault-after-reject-" & $epochTime())
    check afterReject.code == 409
    check reasonOf(afterReject) == "topup_request_not_pending"

  test "daftar pengajuan: status filter + bentuk kontrak":
    let maker = tokenOf(login(MakerUser))
    let submitted = submitTopUp(maker, BranchA, "5.0000", "vault-list-" & $epochTime())
    check submitted.code == 201

    let all = listTopUps(maker, BranchA)
    check all.code == 200
    checkJson(TopUpsPath, "GET", "200", all.body)
    check all.body["items"].len > 0
    check all.body["items"][0]["status"].getStr() in ["PENDING", "APPROVED"]

    let pending = listTopUps(maker, BranchA, "PENDING")
    check pending.code == 200
    for item in pending.body["items"]:
      check item["status"].getStr() == "PENDING"

  test "parameter akun vault berubah ke akun sumber → persetujuan 409, saldo tidak berubah":
    let maker = tokenOf(login(MakerUser))
    let checker = tokenOf(login(CheckerUser))
    let submitted = submitTopUp(maker, BranchB, "35.0000", "vault-cfg-" & $epochTime())
    check submitted.code == 201
    let requestId = requestIdOf(submitted)
    let before = vaultOf(BranchB)

    # Akun vault dipindah ke `102` (akun sumber pengajuan) tepat sebelum persetujuan: jurnal akan
    # menjadi D 102 / K 102.
    setVaultGlAccount("102")
    let blocked = approveTopUp(checker, requestId, "vault-cfg-a-" & $epochTime())
    check blocked.code == 409
    checkProblem(TopUpsPath & "/{requestId}/approve", "POST", "409", blocked.body)
    check reasonOf(blocked) == "source_account_invalid"
    check vaultOf(BranchB) == before
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal
                         WHERE source_event = 'TellerVaultTopUp' AND source_ref = ?::uuid""",
      requestId) == 0

    # Kembalikan konfigurasi → pengajuan yang sama bisa disetujui.
    setVaultGlAccount("101.1")
    let approved = approveTopUp(checker, requestId, "vault-cfg-b-" & $epochTime())
    check approved.code == 200
    check approved.body["request"]["status"].getStr() == "APPROVED"

  test "approve pengajuan yang tidak ada → 404 topup_request_not_found":
    let checker = tokenOf(login(CheckerUser))
    let reply = approveTopUp(checker, "01a1694e-0000-4000-8000-000000000000",
      "vault-missing-" & $epochTime())
    check reply.code == 404
    checkProblem(TopUpsPath & "/{requestId}/approve", "POST", "404", reply.body)
    check reasonOf(reply) == "topup_request_not_found"

suite "vault: idempotensi":
  test "submitted: replay kunci+isi sama → 200 tanpa pengajuan baru; isi beda → 409":
    let token = tokenOf(login(MakerUser))
    let key = "vault-idem-" & $epochTime()
    let first = submitTopUp(token, BranchB, "25.0000", key)
    check first.code == 201
    let requestsAfterFirst = pendingCount(BranchB)

    let replay = submitTopUp(token, BranchB, "25.0000", key)
    check replay.code == 200
    check replay.replayed == "true"
    check replay.body["requestId"].getStr() == first.body["requestId"].getStr()
    check pendingCount(BranchB) == requestsAfterFirst

    let mismatch = submitTopUp(token, BranchB, "30.0000", key)
    check mismatch.code == 409
    checkProblem(TopUpsPath, "POST", "409", mismatch.body)

  test "approve: replay kunci sama → 200 tanpa menambah vault/jurnal lagi":
    let maker = tokenOf(login(MakerUser))
    let checker = tokenOf(login(CheckerUser))
    let submitted = submitTopUp(maker, BranchB, "15.0000", "vault-approve-idem-" & $epochTime())
    check submitted.code == 201
    let requestId = requestIdOf(submitted)
    let key = "vault-approve-idem-key-" & $epochTime()

    let first = approveTopUp(checker, requestId, key)
    check first.code == 200
    let balanceAfter = vaultOf(BranchB)

    let replay = approveTopUp(checker, requestId, key)
    check replay.code == 200
    check replay.replayed == "true"
    check replay.body["balanceAfter"].getStr() == first.body["balanceAfter"].getStr()
    check vaultOf(BranchB) == balanceAfter

var approveCodes: array[2, int]

type ApproveArgs = object
  token: string
  requestId: string
  key: string
  slot: int

proc approveWorker(args: ApproveArgs) {.thread.} =
  {.cast(gcsafe).}:
    let client = newHttpClient(timeout = 15000)
    client.headers["Cookie"] = CookieName & "=" & args.token
    client.headers["Content-Type"] = "application/json"
    client.headers["Idempotency-Key"] = args.key
    let response = client.post(baseUrl & TopUpsPath & "/" & args.requestId & "/approve", "{}")
    approveCodes[args.slot] = response.code.int
    client.close()

proc blockedByHolder(pid: string): int =
  ## Jumlah sesi yang menunggu lock `pid`, **transitif** (pola `ittransfer`): `pg_blocking_pids`
  ## hanya memberi penghalang langsung (penunggu kedua bisa mengantre di belakang penunggu pertama),
  ## jadi rantainya ditelusuri rekursif. Ini sinkronisasi deterministik tanpa `sleep` sebagai penentu.
  let conn = dbPool.acquire()
  try:
    parseInt(conn.getValue(sql"""
      WITH RECURSIVE blocked(pid) AS (
        SELECT a.pid FROM pg_stat_activity a
         WHERE a.datname = current_database() AND a.pid <> pg_backend_pid()
           AND ?::int = ANY(pg_blocking_pids(a.pid))
        UNION
        SELECT a.pid FROM pg_stat_activity a
          JOIN blocked b ON b.pid = ANY(pg_blocking_pids(a.pid))
      )
      SELECT count(*)::text FROM blocked""", pid))
  finally:
    dbPool.release(conn)

suite "vault: dua persetujuan bersamaan deterministik (T-113/T-118)":
  test "kedua persetujuan menunggu lock baris vault yang sama; increment atomik dijumlahkan":
    let maker = tokenOf(login(MakerUser))
    let checker = tokenOf(login(CheckerUser))
    check maker.len > 0
    check checker.len > 0

    # Saldo awal dipatok eksplisit supaya assertion tidak bergantung urutan suite lain.
    discard dbPool.withConn(proc(d: DbConn): int {.closure.} =
      exec(d, sql"UPDATE teller.vault SET balance = 100.0000 WHERE branch_id = ?", BranchRace)
      1)
    check vaultOf(BranchRace) == "100.0000"

    let first = submitTopUp(maker, BranchRace, "30.0000", "vault-det-s1-" & $epochTime())
    let second = submitTopUp(maker, BranchRace, "20.0000", "vault-det-s2-" & $epochTime())
    check first.code == 201
    check second.code == 201

    # Koneksi penahan lock: memegang baris vault `FOR UPDATE`. Selama dipegang, `creditVault`
    # (`UPDATE teller.vault SET balance = balance + ?`) pada pekerja mana pun **wajib menunggu** di
    # baris ini — bukan sekadar kebetulan berurutan. Inilah yang membuat uji atomisitas deterministik
    # (klaim T-113: dua request tanpa penahanan bisa berurutan dan tidak membuktikan apa pun).
    let side = dbPool.acquire()
    defer: dbPool.release(side)
    exec(side, sql"BEGIN")
    discard side.getValue(sql"""
      SELECT 1 FROM teller.vault WHERE branch_id = ? FOR UPDATE""", BranchRace)
    let holderPid = side.getValue(sql"SELECT pg_backend_pid()")

    approveCodes = [0, 0]
    var w1, w2: Thread[ApproveArgs]
    createThread(w1, approveWorker, ApproveArgs(token: checker, requestId: requestIdOf(first),
      key: "vault-det-a1-" & $epochTime(), slot: 0))
    createThread(w2, approveWorker, ApproveArgs(token: checker, requestId: requestIdOf(second),
      key: "vault-det-a2-" & $epochTime(), slot: 1))

    # Tunggu **kedua** pekerja benar-benar menunggu lock penahan (transitif), bukan menebak timing.
    var blocked = 0
    let deadline = epochTime() + 5.0
    while epochTime() < deadline and blocked < 2:
      blocked = blockedByHolder(holderPid)
      if blocked < 2:
        sleep(20)

    # Lepaskan lock lebih dulu (tanpa syarat) supaya pekerja tidak pernah menggantung, baru nilai.
    exec(side, sql"COMMIT")
    joinThread(w1)
    joinThread(w2)

    check blocked == 2
    var codes = @[approveCodes[0], approveCodes[1]]
    codes.sort()
    check codes == @[200, 200]
    # 100 + 30 + 20 = 150. **Mutation check** (jangan dijalankan): ganti `balance = balance + ?`
    # menjadi read-then-write (`balance = ?`). Kedua pekerja membaca 100 sebelum menunggu lock lalu
    # menulis 130/120 → saldo akhir != 150, dan assertion ini GAGAL (lost update).
    check vaultOf(BranchRace) == "150.0000"

    # Satu jurnal per pengajuan, tidak ada jurnal ganda dari replay/balapan.
    check dbCount(sql"""SELECT count(*)::text FROM ledger.journal
                         WHERE source_event = 'TellerVaultTopUp' AND source_ref IN (?::uuid, ?::uuid)""",
      requestIdOf(first), requestIdOf(second)) == 2
