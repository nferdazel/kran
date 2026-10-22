## Test integrasi HTTP party (T-070) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan lewat jalur penuh: sesi menyetir identitas, izin `party.party.create`/`read`
## menentukan 401/403, CIF dibentuk dari parameter `party.cif.format` + sequence DB, respons
## divalidasi terhadap kontrak OpenAPI, dan audit + event outbox ditulis tanpa nama tampil (PII).
##
## Test ini **menghapus schema `platform` dan `party`** di DB dev, lalu menyiapkan ulang migrasi,
## seed pack `base`, seed pengguna dev, dan satu pemberian role `platform_admin` untuk `dev.maker`.
## Data dev murni sintetis.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/clock
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import party/domain/cif

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  PartyPath = "/api/v1/parties"
  PartyItemPath = "/api/v1/parties/{partyId}"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "11111111-1111-7111-8111-111111111111"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_party: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

# --- penyiapan DB: skema bersih + seed pack + seed pengguna dev -------------------------------
block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))
  # `dev.maker` hanya memegang `param_maker` di seed; untuk menguji jalur sukses party ia diberi
  # `platform_admin` (pemegang seluruh izin) di DB uji, bukan dengan melonggarkan migrasi.
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.maker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

var app = AppContext(version: "itapi-party-0.0.0", role: "api", startedAt: epochTime(),
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
    discard # proses test berakhir dengan sendirinya (lihat O-025)

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

# --- klien HTTP kecil -------------------------------------------------------------------------

type
  Reply = object
    code: int
    body: JsonNode
    setCookie: string
    replayed: string

var idemCounter = 0

proc autoIdemKey(): string =
  inc idemCounter
  "it-party-" & $idemCounter

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

proc partyBody(kind = "PERSON", name = "Budi Santoso"): JsonNode =
  %*{"kind": kind, "displayName": name, "branchId": BranchId}

proc setCifPatternDirect(raw: string) =
  ## Jalan pintas uji: mengubah nilai aktif parameter langsung di DB. Jalur resmi (maker-checker)
  ## menolak perubahan **kedua** pada hari bisnis yang sama (`period_conflict`), jadi hanya cara ini
  ## yang bisa membuat konfigurasi rusak; yang dinilai tetap perilaku HTTP-nya.
  let conn = dbPool.acquire()
  try:
    conn.exec(sql"UPDATE platform.param_value SET value = ?::jsonb WHERE key = 'party.cif.format'",
      raw)
  finally:
    dbPool.release(conn)

proc countSql(query: SqlQuery, args: varargs[string, `$`]): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args)
  finally:
    dbPool.release(conn)

proc cifSeqValue(): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(sql"SELECT last_value::text FROM party.cif_seq")
  finally:
    dbPool.release(conn)

# --- suite ------------------------------------------------------------------------------------

suite "party: autentikasi & izin":
  test "tanpa sesi → 401":
    let create = postJson(PartyPath, partyBody())
    check create.code == 401
    checkProblem(PartyPath, "POST", "401", create.body)

    let read = getJson(PartyPath & "/" & BranchId)
    check read.code == 401
    checkProblem(PartyItemPath, "GET", "401", read.body)

  test "pemegang izin lain → 403":
    let checker = login(CheckerUser)
    check checker.code == 200
    let create = postJson(PartyPath, partyBody(), tokenOf(checker))
    check create.code == 403
    checkProblem(PartyPath, "POST", "403", create.body)

suite "party: buat & baca":
  test "buat party → CIF dari parameter, audit + event tanpa nama":
    let maker = login(MakerUser)
    check maker.code == 200
    let token = tokenOf(maker)

    let created = postJson(PartyPath, partyBody(), token)
    check created.code == 201
    checkJson(PartyPath, "POST", "201", created.body)
    check created.body["kind"].getStr() == "PERSON"
    check created.body["displayName"].getStr() == "Budi Santoso"
    check created.body["status"].getStr() == "ACTIVE"
    check created.body["branchId"].getStr() == BranchId

    # Pola seed `{seq:6}{check}`: enam digit + digit Luhn. Dicek dengan fungsi yang sama yang
    # dipakai produksi, bukan regex yang menebak.
    let cif = created.body["cif"].getStr()
    check cif.len == 7
    check cif[0 ..< 6].allCharsInSet({'0' .. '9'})
    check luhnCheckDigit(cif[0 ..< 6]) == cif[6]

    let partyId = created.body["partyId"].getStr()
    check partyId.len == 36

    # Audit tidak boleh memuat nama tampil (PII); event juga tidak.
    check dbCount(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.create' AND resource_id = ?""", partyId) == 1
    check dbCount(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.create' AND resource_id = ?
         AND (after_value::text LIKE ? OR before_value::text LIKE ?)""",
      partyId, "%Budi Santoso%", "%Budi Santoso%") == 0
    check dbCount(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'party.onboarded' AND aggregate_id = ?""", partyId) == 1

    # Baca lewat HTTP harus sama dengan yang dibuat.
    let read = getJson(PartyPath & "/" & partyId, token)
    check read.code == 200
    checkJson(PartyItemPath, "GET", "200", read.body)
    check read.body == created.body

  test "nomor CIF naik antar party":
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    let first = postJson(PartyPath, partyBody(name = "Siti Aminah"), token)
    let second = postJson(PartyPath, partyBody(name = "Agus Salim"), token)
    check first.code == 201
    check second.code == 201
    let a = first.body["cif"].getStr()
    let b = second.body["cif"].getStr()
    check a.len == b.len
    check a != b
    check parseInt(a[0 ..< 6]) + 1 == parseInt(b[0 ..< 6])

  test "party tidak ada → 404":
    let maker = login(MakerUser)
    let missing = getJson(PartyPath & "/99999999-9999-7999-8999-999999999999", tokenOf(maker))
    check missing.code == 404
    checkProblem(PartyItemPath, "GET", "404", missing.body)

  test "badan tidak sah → 400":
    let maker = login(MakerUser)
    let token = tokenOf(maker)

    let badKind = postJson(PartyPath, partyBody(kind = "ROBOT"), token)
    check badKind.code == 400
    checkProblem(PartyPath, "POST", "400", badKind.body)

    let badName = postJson(PartyPath, partyBody(name = " "), token)
    check badName.code == 400
    checkProblem(PartyPath, "POST", "400", badName.body)

    let badBranch = postJson(PartyPath,
      %*{"kind": "PERSON", "displayName": "Budi", "branchId": "bukan-uuid"}, token)
    check badBranch.code == 400
    checkProblem(PartyPath, "POST", "400", badBranch.body)

suite "party: konfigurasi parameter":
  test "pola CIF tidak sah → 500 (bukan 400) dan nomor urut tidak terpakai":
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    let seqBefore = cifSeqValue()

    setCifPatternDirect("\"tanpa-token\"")
    try:
      let reply = postJson(PartyPath, partyBody(name = "CIF Rusak"), token)
      check reply.code == 500
      checkProblem(PartyPath, "POST", "500", reply.body)
      # Pesan problem tidak boleh membocorkan nama parameter/internal (spec §13).
      check not reply.body["detail"].getStr().contains("party.cif.format")
      # Salah konfigurasi tidak boleh membakar nomor urut.
      check cifSeqValue() == seqBefore
    finally:
      setCifPatternDirect("\"{seq:6}{check}\"")

    # Setelah pola dipulihkan, jalur normal jalan lagi (bukti pemulihan, bukan asumsi).
    let ok = postJson(PartyPath, partyBody(name = "CIF Pulih"), token)
    check ok.code == 201

test "idempotency: kunci sama replay, isi beda 409, tanpa header 400":
  let token = tokenOf(login(MakerUser))
  let body = partyBody(name = "Idem Party")
  let first = postJson(PartyPath, body, token, "idem-party-1")
  check first.code == 201
  let partyId = first.body["partyId"].getStr()

  # Duplikat party memakai UUID baru, jadi hitung **total** — bukan per partyId.
  let parties = "SELECT count(*)::text FROM party.party"
  let audits = "SELECT count(*)::text FROM platform.audit_log WHERE action = 'party.create'"
  let events = "SELECT count(*)::text FROM platform.outbox WHERE event_type = 'party.onboarded'"
  let partiesBefore = countSql(sql(parties))
  let auditsBefore = countSql(sql(audits))
  let eventsBefore = countSql(sql(events))

  let replay = postJson(PartyPath, body, token, "idem-party-1")
  check replay.code == 200
  check replay.replayed == "true"
  check replay.body["partyId"].getStr() == partyId
  # Replay tidak menulis objek/audit/event kedua.
  check countSql(sql(parties)) == partiesBefore
  check countSql(sql(audits)) == auditsBefore
  check countSql(sql(events)) == eventsBefore

  let conflict = postJson(PartyPath, partyBody(name = "Idem Party Lain"), token,
    "idem-party-1")
  check conflict.code == 409
  checkProblem(PartyPath, "POST", "409", conflict.body)

  let tanpaKunci = postJson(PartyPath, partyBody(name = "Tanpa Kunci"), token,
    sendKey = false)
  check tanpaKunci.code == 400
  checkProblem(PartyPath, "POST", "400", tanpaKunci.body)
