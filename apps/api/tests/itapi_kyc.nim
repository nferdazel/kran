## Test integrasi HTTP KYC/dokumen identitas (T-071) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan lewat jalur penuh: nomor dokumen tidak pernah tersimpan plaintext (diperiksa di
## kolom DB + badan respons), blind index & izin, duplikat → 409, *unmask* butuh izin + alasan dan
## meninggalkan audit tanpa nomor, rating risiko menulis audit + event outbox, dan **tanpa KEK**
## endpoint enkripsi menjawab 501 (fail-closed).
##
## **HUMAN-REVIEW-REQUIRED**: menyentuh field crypto (ADR-017, D-048).
##
## Test ini menghapus schema `platform` dan `party` di DB dev, lalu menyiapkan ulang migrasi,
## seed pack, seed pengguna dev, dan satu pemberian `platform_admin` untuk `dev.maker`.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/clock
import openapi/lib
import "platform-lib/crypto/fieldcrypto"
import "platform-lib/db/config"
import "platform-lib/db/pool"

import party/domain/kyc

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  PartyPath = "/api/v1/parties"
  DocPath = "/api/v1/parties/{partyId}/identity-docs"
  KycPath = "/api/v1/parties/{partyId}/kyc"
  RiskPath = "/api/v1/parties/{partyId}/risk-rating"
  UnmaskPath = "/api/v1/parties/{partyId}/identity-docs/{docId}/unmask"
  LoginPath = "/api/v1/auth/login"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  BranchId = "66666666-6666-7666-8666-666666666666"
  Nik = "3201234567890001"
  ## Kunci KEK uji: 32 byte 0x00..0x1f dalam base64 (pola sama dengan `itapi_mfa`/`tfieldcrypto`).
  KekB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_kyc: KRAN_DATABASE_URL kosong — dilewati"
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
  # `dev.maker` di seed hanya memegang `param_maker`; DB uji memberinya `platform_admin`
  # (pemegang seluruh izin) supaya jalur sukses bisa diuji tanpa melonggarkan migrasi.
  execScript(db, """
    INSERT INTO platform.user_role (user_id, role_id, branch_id)
    SELECT u.user_id, r.role_id, NULL
      FROM platform.app_user u, platform.role r
     WHERE u.username = 'dev.maker' AND r.code = 'platform_admin'
    ON CONFLICT DO NOTHING
  """)

# --- keyring uji lewat jalur startup nyata (berkas mode 600) ----------------------------------
block:
  let path = getTempDir() / "kran-itapi-kyc-kek.txt"
  writeFile(path, "v1:" & KekB64 & "\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite})
  putEnv("KRAN_KEK_FILE", path)

var app = AppContext(version: "itapi-kyc-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: systemClock(), readiness: databaseProbe())
app.fieldCrypto = fieldCryptoFromProcessEnv()
doAssert app.fieldCrypto.isConfigured, "keyring uji tidak terbaca"

## Server kedua **tanpa** keyring: membuktikan endpoint enkripsi fail-closed (501), bukan
## menyimpan plaintext atau gagal 500.
var appNoKey = AppContext(version: "itapi-kyc-nokey-0.0.0", role: "api", startedAt: epochTime(),
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
    discard # proses test berakhir dengan sendirinya (lihat O-025)

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

block:
  baseUrl = startServer(app, 0)
  baseUrlNoKey = startServer(appNoKey, 1)

# --- klien HTTP kecil -------------------------------------------------------------------------

type
  Reply = object
    code: int
    raw: string
    body: JsonNode
    setCookie: string

proc call(base, verb, path, payload, token: string): Reply =
  let client = newHttpClient(timeout = 15000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
  var response: Response
  if verb == "GET":
    response = client.get(base & path)
  else:
    if payload.len > 0:
      client.headers["Content-Type"] = "application/json"
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

proc getJson(path: string, token = ""): Reply =
  call(baseUrl, "GET", path, "", token)

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

proc isoToday(): string =
  let now = systemClock().now()
  format(now, "yyyy-MM-dd")

# --- alur utama -------------------------------------------------------------------------------

let maker = login(MakerUser)
doAssert maker.code == 200, "login dev.maker gagal — seed dev terpasang?"

let makerToken = tokenOf(maker)
let checkerToken = tokenOf(login(CheckerUser))

proc createParty(name: string): JsonNode =
  let reply = postJson(PartyPath, %*{"kind": "PERSON", "displayName": name,
    "branchId": BranchId}, makerToken)
  doAssert reply.code == 201, "buat party gagal: " & $reply.code & " " & reply.raw
  reply.body

let party = createParty("Nasabah KYC")
let partyId = party["partyId"].getStr()

suite "kyc: gerbang autentikasi & izin":
  test "tanpa sesi → 401":
    # `identity-docs` hanya menerima POST — jadi tanpa sesi yang diperiksa adalah POST-nya.
    check postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "KTP", "number": Nik}).code == 401
    check getJson(KycPath.replace("{partyId}", partyId)).code == 401
    check postJson(RiskPath.replace("{partyId}", partyId),
      %*{"level": "HIGH", "reason": "x"}).code == 401

  test "tanpa izin KYC → 403":
    let doc = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "KTP", "number": Nik}, checkerToken)
    check doc.code == 403
    checkProblem(DocPath, "POST", "403", doc.body)

suite "kyc: dokumen identitas":
  test "registrasi menyimpan terenkripsi dan hanya mengembalikan bentuk tersamar":
    let reply = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "ktp", "number": Nik, "issuedAt": "2020-01-15"}, makerToken)
    check reply.code == 201
    checkJson(DocPath, "POST", "201", reply.body)
    check reply.body["docType"].getStr() == "KTP"
    check reply.body["numberLast2"].getStr() == "01"
    check reply.body["issuedAt"].getStr() == "2020-01-15"
    # Nomor asli tidak boleh muncul di respons mana pun.
    check not reply.raw.contains(Nik)

    let docId = reply.body["docId"].getStr()
    let storedEnc = dbValue(sql"SELECT number_enc FROM party.identity_doc WHERE doc_id = ?::uuid",
      docId)
    let storedBidx = dbValue(sql"SELECT number_bidx FROM party.identity_doc WHERE doc_id = ?::uuid",
      docId)
    check storedEnc.startsWith("kran:enc:v1:")
    check not storedEnc.contains(Nik)
    check storedBidx.len == 64
    # Audit hanya menyebut jenis + id.
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.identity.add' AND resource_id = ?""", docId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.identity.add'
         AND (after_value::text LIKE ? OR before_value::text LIKE ?)""",
      "%" & Nik & "%", "%" & Nik & "%") == "0"

  test "docType di luar parameter dan panjang salah → 400":
    let unknown = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "SIM", "number": Nik}, makerToken)
    check unknown.code == 400
    checkProblem(DocPath, "POST", "400", unknown.body)

    let short = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "KTP", "number": "12345"}, makerToken)
    check short.code == 400
    checkProblem(DocPath, "POST", "400", short.body)

  test "tanggal tidak sah dan urutan tanggal terbalik → 400 (bukan 500)":
    let badDate = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "PASSPORT", "number": "A1234567B", "issuedAt": "2026-13-45"}, makerToken)
    check badDate.code == 400
    checkProblem(DocPath, "POST", "400", badDate.body)

    let reversed = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "PASSPORT", "number": "A1234568B", "issuedAt": "2024-01-01",
         "expiresAt": "2020-01-01"}, makerToken)
    check reversed.code == 400
    checkProblem(DocPath, "POST", "400", reversed.body)

    # Tanggal yang tidak dicatat dikirim `null`, bukan string kosong.
    let noDates = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "PASSPORT", "number": "A1234569B"}, makerToken)
    check noDates.code == 201
    checkJson(DocPath, "POST", "201", noDates.body)
    check noDates.body["issuedAt"].kind == JNull
    check noDates.body["expiresAt"].kind == JNull

  test "nomor yang sama pada party lain → 409":
    let other = createParty("Nasabah Ganda")
    let duplicate = postJson(DocPath.replace("{partyId}", other["partyId"].getStr()),
      %*{"docType": "KTP", "number": Nik}, makerToken)
    check duplicate.code == 409
    checkProblem(DocPath, "POST", "409", duplicate.body)

suite "kyc: profil & rating risiko":
  test "profil awal terlihat dari daftar parameter":
    let reply = getJson(KycPath.replace("{partyId}", partyId), makerToken)
    check reply.code == 200
    checkJson(KycPath, "GET", "200", reply.body)
    check reply.body["status"].getStr() == "PENDING"
    check reply.body["riskLevel"].getStr() == "LOW"
    check reply.body["nextReviewDue"].getStr() == reviewDueDate(isoToday(), 36)
    # Belum pernah dinilai → `null` (kontrak nullable), bukan string kosong.
    check reply.body["riskAssessedAt"].kind == JNull
    # Dokumen KTP mendahului yang lain (urut `created_at`), dan hanya bentuk tersamar yang tampak.
    check reply.body["documents"].len >= 1
    check reply.body["documents"][0]["docType"].getStr() == "KTP"
    check reply.body["documents"][0]["numberLast2"].getStr() == "01"
    # Daftar dokumen tidak memuat nomor asli.
    check not reply.raw.contains(Nik)

  test "penilaian risiko menulis audit + event dan menggeser jadwal re-KYC":
    let reply = postJson(RiskPath.replace("{partyId}", partyId),
      %*{"level": "high", "reason": "transaksi tidak wajar"}, makerToken)
    check reply.code == 201
    checkJson(RiskPath, "POST", "201", reply.body)
    check reply.body["level"].getStr() == "HIGH"
    check reply.body["nextReviewDue"].getStr() == reviewDueDate(isoToday(), 6)
    check reply.body["assessedAt"].getStr().len >= 20

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.risk.change' AND resource_id = ?""",
      reply.body["ratingId"].getStr()) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'party.risk_changed' AND aggregate_id = ?""", partyId) == "1"

    let kyc = getJson(KycPath.replace("{partyId}", partyId), makerToken)
    check kyc.code == 200
    check kyc.body["riskLevel"].getStr() == "HIGH"
    check kyc.body["riskHistory"].len == 1
    check kyc.body["riskHistory"][0]["reason"].getStr() == "transaksi tidak wajar"

  test "level di luar parameter dan alasan kosong → 400":
    let badLevel = postJson(RiskPath.replace("{partyId}", partyId),
      %*{"level": "EXTREME", "reason": "coba"}, makerToken)
    check badLevel.code == 400
    checkProblem(RiskPath, "POST", "400", badLevel.body)

    let noReason = postJson(RiskPath.replace("{partyId}", partyId),
      %*{"level": "LOW", "reason": "   "}, makerToken)
    check noReason.code == 400
    checkProblem(RiskPath, "POST", "400", noReason.body)

suite "kyc: unmask (izin + alasan + audit)":
  test "membuka nomor menulis audit tanpa nomor":
    let docs = getJson(KycPath.replace("{partyId}", partyId), makerToken)
    let docId = docs.body["documents"][0]["docId"].getStr()
    let path = UnmaskPath.replace("{partyId}", partyId).replace("{docId}", docId)

    let reply = postJson(path, %*{"reason": "verifikasi nasabah di teller"}, makerToken)
    check reply.code == 200
    checkJson(UnmaskPath, "POST", "200", reply.body)
    check reply.body["number"].getStr() == Nik

    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.identity.unmask' AND resource_id = ?""", docId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.identity.unmask'
         AND (after_value::text LIKE ? OR before_value::text LIKE ?)""",
      "%" & Nik & "%", "%" & Nik & "%") == "0"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.identity.unmask' AND reason = ?""",
      "verifikasi nasabah di teller") == "1"

  test "dokumen milik party lain → 404 dan tanpa jejak audit":
    # Dua party berbeda: jalur party A + docId party B harus 404 (bukan 403) dan **tidak**
    # meninggalkan baris audit unmask — id dokumen tidak boleh jadi alat menghitung data.
    let other = createParty("Nasabah Lain")
    let otherId = other["partyId"].getStr()
    let otherDoc = postJson(DocPath.replace("{partyId}", otherId),
      %*{"docType": "NPWP", "number": "987654321098765"}, makerToken)
    check otherDoc.code == 201
    let otherDocId = otherDoc.body["docId"].getStr()

    let cross = postJson(UnmaskPath.replace("{partyId}", partyId).replace("{docId}", otherDocId),
      %*{"reason": "coba lintas party"}, makerToken)
    check cross.code == 404
    checkProblem(UnmaskPath, "POST", "404", cross.body)
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'party.identity.unmask' AND resource_id = ?""", otherDocId) == "0"

  test "alasan kosong, izin kurang, dan party salah → 400/403/404":
    let docs = getJson(KycPath.replace("{partyId}", partyId), makerToken)
    let docId = docs.body["documents"][0]["docId"].getStr()
    let path = UnmaskPath.replace("{partyId}", partyId).replace("{docId}", docId)

    let noReason = postJson(path, %*{"reason": "  "}, makerToken)
    check noReason.code == 400
    checkProblem(UnmaskPath, "POST", "400", noReason.body)

    let noPerm = postJson(path, %*{"reason": "coba"}, checkerToken)
    check noPerm.code == 403
    checkProblem(UnmaskPath, "POST", "403", noPerm.body)

    let wrongParty = postJson(UnmaskPath.replace("{partyId}", BranchId).replace("{docId}", docId),
      %*{"reason": "coba"}, makerToken)
    check wrongParty.code == 404
    checkProblem(UnmaskPath, "POST", "404", wrongParty.body)

suite "kyc: tanpa KEK (fail-closed)":
  test "registrasi & unmask → 501, bukan menyimpan plaintext atau 500":
    let add = postJson(DocPath.replace("{partyId}", partyId),
      %*{"docType": "NPWP", "number": "012345678901234"}, makerToken, baseUrlNoKey)
    check add.code == 501
    checkProblem(DocPath, "POST", "501", add.body)

    let docs = getJson(KycPath.replace("{partyId}", partyId), makerToken)
    let docId = docs.body["documents"][0]["docId"].getStr()
    let unmask = postJson(UnmaskPath.replace("{partyId}", partyId).replace("{docId}", docId),
      %*{"reason": "coba"}, makerToken, baseUrlNoKey)
    check unmask.code == 501
    checkProblem(UnmaskPath, "POST", "501", unmask.body)

    # Tidak ada dokumen NPWP party ini yang setengah tersimpan (party lain boleh punya).
    check dbValue(sql"""
      SELECT count(*)::text FROM party.identity_doc
       WHERE doc_type = 'NPWP' AND party_id = ?::uuid""", partyId) == "0"
    # Profil KYC (tanpa PII) tetap bisa dibaca walau kunci belum ada.
    check getJson(KycPath.replace("{partyId}", partyId), makerToken).code == 200
