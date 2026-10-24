## Test integrasi HTTP detail party (T-078) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan lewat jalur penuh: detail PII tidak pernah tersimpan plaintext (diperiksa di
## kolom DB + badan respons), bentuk tersamar pada `GET`, validasi per jenis party → 400, izin
## menentukan 401/403, `unmask` butuh izin + alasan dan meninggalkan audit tanpa PII, dan **tanpa
## KEK** endpoint enkripsi menjawab 501 (fail-closed).
##
## **HUMAN-REVIEW-REQUIRED**: menyentuh field crypto / PII (ADR-017, D-069).
##
## CATATAN: berkas ini **belum dijalankan** pada sesi T-078 (suite `it*` me-reset schema Postgres
## bersama, dilarang selama task paralel) — jalankan `./task test itapi_detail` di DB dev.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/clock
import openapi/lib
import "platform-lib/crypto/fieldcrypto"
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  PartyPath = "/api/v1/parties"
  DetailPath = "/api/v1/parties/{partyId}/detail"
  UnmaskPath = "/api/v1/parties/{partyId}/detail/unmask"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "66666666-6666-7666-8666-666666666666"
  LegalName = "Budi Santoso"
  ## Kunci KEK uji: 32 byte 0x00..0x1f dalam base64 (pola sama dengan `itapi_kyc`).
  KekB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_detail: KRAN_DATABASE_URL kosong — dilewati"
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
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.maker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

block:
  let path = getTempDir() / "kran-itapi-detail-kek.txt"
  writeFile(path, "v1:" & KekB64 & "\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite})
  putEnv("KRAN_KEK_FILE", path)

var app = AppContext(version: "itapi-detail-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: systemClock(), readiness: databaseProbe())
app.fieldCrypto = fieldCryptoFromProcessEnv()
doAssert app.fieldCrypto.isConfigured, "keyring uji tidak terbaca"

var appNoKey = AppContext(version: "itapi-detail-nokey-0.0.0", role: "api", startedAt: epochTime(),
                          pool: dbPool, clock: systemClock(), readiness: databaseProbe())
doAssert not appNoKey.fieldCrypto.isConfigured

type
  ServeArgs = object
    server: Server
    port: int

var
  serverThreads: array[2, Thread[ServeArgs]]
  baseUrl = ""
  baseUrlNoKey = ""

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

proc startServer(a: AppContext, slot: int): string =
  let port = freePort()
  let server = newApiServer(a)
  createThread(serverThreads[slot], serveInThread, ServeArgs(server: server, port: port))
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

baseUrl = startServer(app, 0)
baseUrlNoKey = startServer(appNoKey, 1)

type
  Reply = object
    code: int
    raw: string
    body: JsonNode
    setCookie: string

var idemCounter = 0

proc autoIdemKey(): string =
  inc idemCounter
  "it-detail-" & $idemCounter

proc call(base, verb, path, payload, token: string): Reply =
  let client = newHttpClient(timeout = 15000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
  var response: Response
  if verb == "GET":
    response = client.get(base & path)
  elif verb == "PUT":
    if payload.len > 0:
      client.headers["Content-Type"] = "application/json"
    response = client.request(base & path, httpMethod = HttpPut, body = payload)
  else:
    if payload.len > 0:
      client.headers["Content-Type"] = "application/json"
    if path == PartyPath:
      client.headers["Idempotency-Key"] = autoIdemKey()
    response = client.post(base & path, payload)
  result.code = response.code.int
  result.raw = response.body
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  result.body = newJNull()
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

proc getJson(path: string, token = ""): Reply = call(baseUrl, "GET", path, "", token)
proc putJson(path: string, payload: JsonNode, token = "", base = baseUrl): Reply =
  call(base, "PUT", path, $payload, token)
proc postJson(path: string, payload: JsonNode, token = "", base = baseUrl): Reply =
  call(base, "POST", path, $payload, token)

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

proc dbValue(query: SqlQuery, args: varargs[string, `$`]): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args)
  finally:
    dbPool.release(conn)

let
  maker = login(MakerUser)
doAssert maker.code == 200, "login dev.maker gagal — seed dev terpasang?"
let makerToken = tokenOf(maker)
let checkerToken = tokenOf(login(CheckerUser))

proc createParty(name: string, kind = "PERSON"): JsonNode =
  let reply = postJson(PartyPath, %*{"kind": kind, "displayName": name, "branchId": BranchId},
    makerToken)
  doAssert reply.code == 201, "buat party gagal: " & $reply.code & " " & reply.raw
  reply.body

let person = createParty("Nasabah Detail")
let personId = person["partyId"].getStr()

proc personBody(legalName = LegalName, birthDate = "1990-01-15", sex = "male",
    occupation = "Petani"): JsonNode =
  %*{
    "person": {"legalName": legalName, "birthDate": birthDate, "sex": sex,
               "occupation": occupation},
    "address": {"line": "Jl. Merdeka 5", "city": "Bandung", "postalCode": "40115"},
  }

suite "detail: gerbang autentikasi & izin":
  test "tanpa sesi → 401":
    check putJson(DetailPath.replace("{partyId}", personId), personBody()).code == 401
    check getJson(DetailPath.replace("{partyId}", personId)).code == 401
    check postJson(UnmaskPath.replace("{partyId}", personId), %*{"reason": "x"}).code == 401

  test "tanpa izin → 403":
    let put = putJson(DetailPath.replace("{partyId}", personId), personBody(), checkerToken)
    check put.code == 403
    checkProblem(DetailPath, "PUT", "403", put.body)

suite "detail: simpan & baca tersamar":
  test "PUT menyimpan terenkripsi, respons memuat bentuk tersamar":
    let reply = putJson(DetailPath.replace("{partyId}", personId), personBody(), makerToken)
    check reply.code == 200
    checkJson(DetailPath, "PUT", "200", reply.body)
    check reply.body["person"]["legalNameLast2"].getStr() == "so"
    check not reply.raw.contains(LegalName)

    let storedEnc = dbValue(sql"""
      SELECT legal_name_enc FROM party.party_person WHERE party_id = ?::uuid""", personId)
    check storedEnc.startsWith("kran:enc:v1:")
    check not storedEnc.contains(LegalName)
    check dbValue(sql"""
      SELECT count(*)::text FROM party.party_person WHERE party_id = ?::uuid""", personId) == "1"

  test "GET mengembalikan bentuk tersamar tanpa nomor asli":
    let reply = getJson(DetailPath.replace("{partyId}", personId), makerToken)
    check reply.code == 200
    checkJson(DetailPath, "GET", "200", reply.body)
    check reply.body["kind"].getStr() == "PERSON"
    check reply.body["person"]["legalNameLast2"].getStr() == "so"
    check reply.body["org"].kind == JNull
    check not reply.raw.contains(LegalName)
    check not reply.raw.contains("Bandung")

  test "validasi jenis party & field → 400":
    let wrongKind = putJson(DetailPath.replace("{partyId}", personId),
      %*{"org": {"legalName": "PT Contoh"}}, makerToken)
    check wrongKind.code == 400
    checkProblem(DetailPath, "PUT", "400", wrongKind.body)

    let badDate = putJson(DetailPath.replace("{partyId}", personId),
      personBody(birthDate = "2026-13-40"), makerToken)
    check badDate.code == 400

    let futureBirth = putJson(DetailPath.replace("{partyId}", personId),
      personBody(birthDate = "2999-01-01"), makerToken)
    check futureBirth.code == 400

    let badSex = putJson(DetailPath.replace("{partyId}", personId),
      personBody(sex = "LAKI"), makerToken)
    check badSex.code == 400

  test "party ORG menyimpan blok org, menolak blok person":
    let org = createParty("Koperasi Detail", kind = "ORG")
    let orgId = org["partyId"].getStr()
    let ok = putJson(DetailPath.replace("{partyId}", orgId),
      %*{"org": {"legalName": "Koperasi Sejahtera"}}, makerToken)
    check ok.code == 200
    check ok.body["org"]["legalNameLast2"].getStr() == "ra"
    check ok.body["person"].kind == JNull
    let wrong = putJson(DetailPath.replace("{partyId}", orgId), personBody(), makerToken)
    check wrong.code == 400

  test "party tanpa detail → 404":
    let empty = createParty("Belum Detail")
    check getJson(DetailPath.replace("{partyId}", empty["partyId"].getStr()),
      makerToken).code == 404

suite "detail: unmask (izin + alasan + audit)":
  test "membuka nilai asli menulis audit tanpa PII":
    let path = UnmaskPath.replace("{partyId}", personId)
    let reply = postJson(path, %*{"reason": "verifikasi nasabah di teller"}, makerToken)
    check reply.code == 200
    checkJson(UnmaskPath, "POST", "200", reply.body)
    check reply.body["person"]["legalName"].getStr() == LegalName
    check reply.body["address"]["city"].getStr() == "Bandung"

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.detail.unmask' AND resource_id = ?""", personId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.detail.unmask'
         AND (after_value::text LIKE ? OR before_value::text LIKE ?)""",
      "%" & LegalName & "%", "%" & LegalName & "%") == "0"

  test "alasan kosong & izin kurang → 400/403":
    let path = UnmaskPath.replace("{partyId}", personId)
    check postJson(path, %*{"reason": "  "}, makerToken).code == 400
    let noPerm = postJson(path, %*{"reason": "coba"}, checkerToken)
    check noPerm.code == 403

suite "detail: tanpa KEK (fail-closed)":
  test "PUT & unmask → 501, GET tersamar tetap 200":
    let put = putJson(DetailPath.replace("{partyId}", personId), personBody(), makerToken,
      baseUrlNoKey)
    check put.code == 501
    checkProblem(DetailPath, "PUT", "501", put.body)

    let unmask = postJson(UnmaskPath.replace("{partyId}", personId), %*{"reason": "coba"},
      makerToken, baseUrlNoKey)
    check unmask.code == 501
    checkProblem(UnmaskPath, "POST", "501", unmask.body)

    check getJson(DetailPath.replace("{partyId}", personId), makerToken).code == 200
