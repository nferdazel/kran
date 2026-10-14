## Test integrasi HTTP T-012 (butuh `CBS_DATABASE_URL`): login → ubah parameter (maker-checker) →
## audit → peristiwa realtime ke klien bersesi.
##
## Yang dibuktikan di sini adalah **jalur penuh lewat HTTP**, bukan pemanggilan lapisan langsung:
## cookie sesi benar-benar menyetir identitas, izin efektif menentukan 401/403, dan penyetuju
## kedua (`checker <> maker`) ditegakkan. Bentuk setiap respons divalidasi terhadap kontrak
## OpenAPI (`packages/contracts/openapi/cbs-api.yaml`) supaya handler dan kontrak tidak bisa
## menyimpang diam-diam.
##
## Test ini **menghapus schema `platform`** di DB yang ditunjuk `CBS_DATABASE_URL` (DB dev), lalu
## menyiapkan ulang: migrasi + seed pack `base` + seed pengguna dev
## (`packs/base/seed/0001_dev_users.sql`). Data dev murni sintetis.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy

import dbtools/lib
import kernel/clock
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[access, context, events, readiness, server]
import ./wsclient

const
  ContractPath = "packages/contracts/openapi/cbs-api.yaml"
  EventsSchemaPath = "packages/contracts/events/realtime-envelope.v1.schema.json"
  EventsPath = "/api/v1/events/stream"
  LoginPath = "/api/v1/auth/login"
  SessionPath = "/api/v1/auth/session"
  LogoutPath = "/api/v1/auth/logout"
  ParamsPath = "/api/v1/params"
  AuditPath = "/api/v1/audit"
  ParamKey = "platform.security.max_failed_logins"
  SessionIdleKey = "platform.security.session_idle_minutes"
  SessionAbsoluteKey = "platform.security.session_absolute_minutes"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "cbs_session"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_auth: CBS_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let eventsSchema = loadSchemaFile(EventsSchemaPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

# --- penyiapan DB: skema bersih + seed pack + seed pengguna dev -------------------------------
block:
  let db = dbPool.acquire()
  execScript(db, "DROP SCHEMA IF EXISTS platform CASCADE")
  discard applyMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))

# --- server dengan pool, jam, dan kebijakan realtime berbasis sesi ----------------------------
var app = AppContext(version: "itapi-auth-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: systemClock(), readiness: databaseProbe())
app.events = newEventService(realtimePolicy(app), dbPool)
startPump(app.events)

type
  ServeArgs = object
    server: Server
    port: int

var apiServer: Server
var serverThread: Thread[ServeArgs]
var baseUrl: string

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

block:
  let port = freePort()
  baseUrl = "http://127.0.0.1:" & $port
  apiServer = newApiServer(app)
  createThread(serverThread, serveInThread, ServeArgs(server: apiServer, port: port))
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

# --- klien HTTP kecil -------------------------------------------------------------------------

type
  Reply = object
    code: int
    body: JsonNode
    setCookie: string

proc call(verb, path, payload, token: string): Reply =
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
    response = client.post(baseUrl & path, payload)
  result.code = response.code.int
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

proc getJson(path: string, token = ""): Reply =
  call("GET", path, "", token)

proc postJson(path: string, payload: JsonNode, token = ""): Reply =
  call("POST", path, $payload, token)

proc portOf(url: string): int =
  ## Port dari `http://127.0.0.1:<port>` — dipakai klien WebSocket (yang memakai host/port,
  ## bukan URL).
  let afterScheme = url.split("//")[1]
  parseInt(afterScheme.split(':')[1])

proc tokenOf(reply: Reply): string =
  ## Token sesi dari header `Set-Cookie` — klien uji tidak memakai cookie jar, jadi token dibaca
  ## eksplisit dan dikirim ulang sebagai header `Cookie`.
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc login(username: string, password = DevPassword): Reply =
  postJson(LoginPath, %*{"username": username, "password": password})

proc checkJson(path, verb, status: string, body: JsonNode) =
  ## Bentuk respons sukses vs skema kontrak (`application/json`).
  let problems = contract.validateValue(contract.responseSchema(path, verb, status), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc checkProblem(path, verb, status: string, body: JsonNode) =
  ## Error memakai `application/problem+json` (spec §13) — kontrak pun mendefinisikannya di tipe
  ## isi itu, jadi skema yang dicek harus yang di sana (bukan `application/json`).
  let problems = contract.validateValue(
    contract.responseSchema(path, verb, status, "application/problem+json"), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc paramItems(body: JsonNode): seq[JsonNode] =
  for item in body["items"]:
    result.add item

proc itemWith(body: JsonNode, key: string): seq[JsonNode] =
  for item in paramItems(body):
    if item["key"].getStr() == key:
      result.add item

proc activeValueOf(body: JsonNode, key: string): JsonNode =
  for item in itemWith(body, key):
    if item["status"].getStr() == "ACTIVE":
      return item["value"]
  newJNull()

suite "login & sesi lewat HTTP":
  test "login benar menyetel cookie HttpOnly+Secure+SameSite=Strict tanpa membocorkan token":
    let reply = login(MakerUser)
    check reply.code == 200
    checkJson(LoginPath, "POST", "200", reply.body)
    check reply.setCookie.contains("HttpOnly")
    check reply.setCookie.contains("Secure")
    check reply.setCookie.contains("SameSite=Strict")
    check tokenOf(reply).len >= 40
    check not reply.body.hasKey("token")

  test "login salah → 401 dengan amplop problem, tanpa membedakan akun":
    let reply = login(MakerUser, "password-salah-sekali")
    check reply.code == 401
    checkProblem(LoginPath, "POST", "401", reply.body)
    check reply.body["code"].getStr() == "UNAUTHORIZED"
    check reply.body["i18nKey"].getStr() == "error_unauthorized"
    check reply.body["params"]["reason"].getStr() == "invalid_credentials"
    check tokenOf(reply).len == 0

  test "sesi: tanpa cookie 401, dengan cookie memuat peran & izin efektif":
    let anonymous = getJson(SessionPath)
    check anonymous.code == 401
    checkProblem(SessionPath, "GET", "401", anonymous.body)

    let maker = login(MakerUser)
    let info = getJson(SessionPath, tokenOf(maker))
    check info.code == 200
    checkJson(SessionPath, "GET", "200", info.body)
    check info.body["username"].getStr() == MakerUser
    var permissions: seq[string]
    for p in info.body["permissions"]:
      permissions.add p.getStr()
    check "platform.param.submit" in permissions
    check "platform.param.read" in permissions
    check "platform.param.approve" notin permissions

    let checker = login(CheckerUser)
    let checkerInfo = getJson(SessionPath, tokenOf(checker))
    check checkerInfo.code == 200
    var checkerPermissions: seq[string]
    for p in checkerInfo.body["permissions"]:
      checkerPermissions.add p.getStr()
    check "platform.param.approve" in checkerPermissions
    check "platform.param.submit" notin checkerPermissions

  test "logout mencabut sesi (bukan hanya menghapus cookie di browser)":
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    check getJson(SessionPath, token).code == 200
    let loggedOut = postJson(LogoutPath, newJObject(), token)
    check loggedOut.code == 204
    check loggedOut.setCookie.contains("Max-Age=0")
    check getJson(SessionPath, token).code == 401

suite "parameter maker-checker lewat HTTP":
  test "daftar parameter memuat nilai aktif dari seed pack":
    let maker = login(MakerUser)
    let reply = getJson(ParamsPath, tokenOf(maker))
    check reply.code == 200
    checkJson(ParamsPath, "GET", "200", reply.body)
    check itemWith(reply.body, ParamKey).len >= 1
    check activeValueOf(reply.body, ParamKey).kind == JInt

  test "tanpa izin yang cukup (tanpa cookie) → 401":
    check getJson(ParamsPath).code == 401

  test "pengajuan tanpa reason ditolak 400 (alasan wajib untuk audit)":
    let maker = login(MakerUser)
    let reply = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": 9}, tokenOf(maker))
    check reply.code == 400
    checkProblem("/api/v1/params/{key}/changes", "POST", "400", reply.body)

  test "pengajuan maker → PENDING, pengesahan sendiri ditolak, checker lain mengaktifkan":
    let maker = login(MakerUser)
    let makerToken = tokenOf(maker)
    let checker = login(CheckerUser)
    let checkerToken = tokenOf(checker)

    let before = activeValueOf(getJson(ParamsPath, makerToken).body, ParamKey)
    check before.kind == JInt
    let target = before.getInt() + 1

    let submitted = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": target, "reason": "uji otomatis: naikkan batas gagal login"}, makerToken)
    check submitted.code == 201
    checkJson("/api/v1/params/{key}/changes", "POST", "201", submitted.body)
    check submitted.body["status"].getStr() == "PENDING"
    let paramValueId = submitted.body["paramValueId"].getStr()

    # Maker melihat pengajuannya sebagai PENDING, tetapi nilainya belum aktif.
    let afterSubmit = getJson(ParamsPath, makerToken).body
    check activeValueOf(afterSubmit, ParamKey).getInt() == before.getInt()
    var foundPending = false
    for item in itemWith(afterSubmit, ParamKey):
      if item["paramValueId"].getStr() == paramValueId:
        foundPending = item["status"].getStr() == "PENDING"
    check foundPending

    # Pengesahan sendiri ditolak skema DB (spec §10.2: dua orang).
    let selfApprove = postJson("/api/v1/params/changes/" & paramValueId & "/approve",
      newJObject(), makerToken)
    check selfApprove.code == 403 # maker tidak punya izin approve
    checkProblem("/api/v1/params/changes/{paramValueId}/approve", "POST", "403",
      selfApprove.body)

    # Checker tanpa izin submit tidak bisa mengajukan (bukti izin benar-benar memisahkan peran).
    let checkerSubmit = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": target + 1, "reason": "checker mencoba mengajukan"}, checkerToken)
    check checkerSubmit.code == 403

    let approved = postJson("/api/v1/params/changes/" & paramValueId & "/approve",
      newJObject(), checkerToken)
    check approved.code == 200
    checkJson("/api/v1/params/changes/{paramValueId}/approve", "POST", "200",
      approved.body)
    check approved.body["status"].getStr() == "ACTIVE"

    # Nilai baru kini aktif, dan approve ulang bukan lagi 200 (bukan state PENDING).
    check activeValueOf(getJson(ParamsPath, makerToken).body, ParamKey).getInt() == target
    let twice = postJson("/api/v1/params/changes/" & paramValueId & "/approve",
      newJObject(), checkerToken)
    check twice.code == 409
    check twice.body["params"]["reason"].getStr() == "not_pending"
    checkProblem("/api/v1/params/changes/{paramValueId}/approve", "POST", "409", twice.body)

    # paramValueId asing → 404.
    let missing = postJson(
      "/api/v1/params/changes/00000000-0000-7000-8000-000000000000/approve",
      newJObject(), checkerToken)
    check missing.code == 404

  test "nilai yang melanggar schema definisi ditolak 400":
    let maker = login(MakerUser)
    let reply = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": "bukan-angka", "reason": "uji validasi schema"}, tokenOf(maker))
    check reply.code == 400
    check reply.body["code"].getStr() == "BAD_REQUEST"

  test "key tak dikenal ditolak 400":
    let maker = login(MakerUser)
    let reply = postJson("/api/v1/params/platform.tidak.ada/changes",
      %*{"value": 1, "reason": "uji key tak dikenal"}, tokenOf(maker))
    check reply.code == 400

suite "aturan lintas-parameter kebijakan sesi lewat HTTP":
  test "pengajuan yang membuat idle > absolut ditolak 400, tanpa efek samping":
    let maker = login(MakerUser)
    let makerToken = tokenOf(maker)
    let params = getJson(ParamsPath, makerToken).body
    let idle = activeValueOf(params, SessionIdleKey).getInt()
    let absolute = activeValueOf(params, SessionAbsoluteKey).getInt()
    # Kombinasi tidak sah: idle di atas absolut, tetapi masih di dalam schema (1..1440).
    let badIdle = max(absolute + 1, idle + 1)
    check badIdle > absolute
    check badIdle <= 1440

    let reply = postJson("/api/v1/params/" & SessionIdleKey & "/changes",
      %*{"value": badIdle, "reason": "uji otomatis: kombinasi kebijakan sesi tidak sah"},
      makerToken)
    check reply.code == 400
    checkProblem("/api/v1/params/{key}/changes", "POST", "400", reply.body)

    # Ditolak berarti tidak ada baris PENDING yang tertinggal, dan konfigurasi lama tetap berlaku:
    # login berikutnya tetap 200 (kalau nilai buruk sempat aktif, login gagal 500).
    for item in itemWith(getJson(ParamsPath, makerToken).body, SessionIdleKey):
      check item["status"].getStr() != "PENDING"
    check activeValueOf(getJson(ParamsPath, makerToken).body, SessionIdleKey).getInt() == idle
    check login(MakerUser).code == 200

  test "persetujuan yang membuat kombinasi tidak sah ditolak 409 (dua pengajuan sah)":
    # Dua pengajuan yang masing-masing sah saat diajukan, tetapi kombinasinya tidak setelah yang
    # pertama aktif. Inilah alasan pemeriksaan harus ada di **persetujuan**, bukan hanya pengajuan.
    let maker = login(MakerUser)
    let makerToken = tokenOf(maker)
    let checker = login(CheckerUser)
    let checkerToken = tokenOf(checker)

    let absoluteAwal = activeValueOf(getJson(ParamsPath, makerToken).body,
      SessionAbsoluteKey).getInt()
    let idleAwal = activeValueOf(getJson(ParamsPath, makerToken).body, SessionIdleKey).getInt()
    let absoluteBaru = max(5, absoluteAwal - 1) # masih >= idle lama (idle <= absolutBaru)
    check idleAwal <= absoluteBaru
    let idleBaru = absoluteBaru + 1 # sah terhadap absolut LAMA, tidak sah terhadap absolut BARU
    check idleBaru <= absoluteAwal

    let ajukanAbsolut = postJson("/api/v1/params/" & SessionAbsoluteKey & "/changes",
      %*{"value": absoluteBaru, "reason": "uji otomatis: turunkan batas absolut"},
      makerToken)
    check ajukanAbsolut.code == 201
    let ajukanIdle = postJson("/api/v1/params/" & SessionIdleKey & "/changes",
      %*{"value": idleBaru, "reason": "uji otomatis: naikkan batas idle"},
      makerToken)
    check ajukanIdle.code == 201

    let setujuiAbsolut = postJson("/api/v1/params/changes/" &
      ajukanAbsolut.body["paramValueId"].getStr() & "/approve", newJObject(), checkerToken)
    check setujuiAbsolut.code == 200

    let setujuiIdle = postJson("/api/v1/params/changes/" &
      ajukanIdle.body["paramValueId"].getStr() & "/approve", newJObject(), checkerToken)
    check setujuiIdle.code == 409
    check setujuiIdle.body["params"]["reason"].getStr() == "invalid_combination"
    checkProblem("/api/v1/params/changes/{paramValueId}/approve", "POST", "409",
      setujuiIdle.body)
    # Nilai yang ditolak tetap PENDING (bisa ditinjau manusia), dan kebijakan aktif tetap sah.
    var masihPending = false
    for item in itemWith(getJson(ParamsPath, makerToken).body, SessionIdleKey):
      if item["paramValueId"].getStr() == ajukanIdle.body["paramValueId"].getStr():
        masihPending = item["status"].getStr() == "PENDING"
    check masihPending
    check login(MakerUser).code == 200

  test "perubahan ber-tanggal depan dinilai pada tanggal efektifnya (bukan hanya hari ini)":
    let maker = login(MakerUser)
    let makerToken = tokenOf(maker)
    let checker = login(CheckerUser)
    let checkerToken = tokenOf(checker)
    let besok = (now().utc + initDuration(days = 1)).format("yyyy-MM-dd")

    # Batas absolut diturunkan **mulai besok**: kombinasi yang berlaku mulai besok jadi
    # (idle hari itu, 200). Kandidat idle 300 yang diajukan mulai HARI INI sah terhadap nilai hari
    # ini (300 <= 479) tetapi tidak sah mulai besok (300 > 200) — hanya pemeriksaan pada tanggal
    # efektif sisi lain yang bisa menangkapnya.
    let turunkanAbsolut = postJson("/api/v1/params/" & SessionAbsoluteKey & "/changes",
      %*{"value": 200, "reason": "uji otomatis: batas absolut untuk besok",
         "effectiveFrom": besok}, makerToken)
    check turunkanAbsolut.code == 201
    check postJson("/api/v1/params/changes/" & turunkanAbsolut.body["paramValueId"].getStr() &
      "/approve", newJObject(), checkerToken).code == 200

    let idleTerlaluTinggi = postJson("/api/v1/params/" & SessionIdleKey & "/changes",
      %*{"value": 300, "reason": "uji otomatis: idle di atas absolut mulai besok"}, makerToken)
    check idleTerlaluTinggi.code == 400
    checkProblem("/api/v1/params/{key}/changes", "POST", "400", idleTerlaluTinggi.body)
    check login(MakerUser).code == 200

suite "audit lewat HTTP":
  test "jejak submit & approve parameter terbaca kembali lengkap":
    let checker = login(CheckerUser)
    let reply = getJson(AuditPath & "?limit=50&action=param.", tokenOf(checker))
    check reply.code == 200
    checkJson(AuditPath, "GET", "200", reply.body)

    var actions: seq[string]
    for item in reply.body["items"]:
      actions.add item["action"].getStr()
      check item["seq"].getInt() > 0
      check item["recordedAt"].getStr().endsWith("Z")
    check "param.submit" in actions
    check "param.approve" in actions

  test "limit di luar rentang ditolak 400":
    let checker = login(CheckerUser)
    let reply = getJson(AuditPath & "?limit=100000", tokenOf(checker))
    check reply.code == 400
    checkProblem(AuditPath, "GET", "400", reply.body)

suite "realtime dengan sesi":
  test "tanpa cookie handshake ditolak 401":
    let handshake = wsclient.handshake("127.0.0.1", portOf(baseUrl), EventsPath)
    check handshake.status == 401

  test "topik di luar izin dilaporkan ditolak, bukan dibuang diam-diam":
    let maker = login(MakerUser)
    var client = wsclient.connect("127.0.0.1", portOf(baseUrl), EventsPath,
      [("Cookie", CookieName & "=" & tokenOf(maker))])
    defer: client.close()
    client.sendText( $ %*{"type": "subscribe", "topics": ["param.changed", "ledger.posted"]})
    let subscribed = client.nextOfType("subscribed", 5000)
    var accepted: seq[string]
    for topic in subscribed["topics"]:
      accepted.add topic.getStr()
    var denied: seq[string]
    for topic in subscribed["denied"]:
      denied.add topic.getStr()
    check "param.changed" in accepted
    check "ledger.posted" in denied

  test "peristiwa param.changed sampai ke klien bersesi setelah checker menyetujui":
    let maker = login(MakerUser)
    let makerToken = tokenOf(maker)
    let checker = login(CheckerUser)
    let checkerToken = tokenOf(checker)

    var client = wsclient.connect("127.0.0.1", portOf(baseUrl), EventsPath,
      [("Cookie", CookieName & "=" & checkerToken)])
    defer: client.close()
    client.sendText( $ %*{"type": "subscribe", "topics": ["param.changed"]})
    let subscribed = client.nextOfType("subscribed", 5000)
    var accepted: seq[string]
    for topic in subscribed["topics"]:
      accepted.add topic.getStr()
    check "param.changed" in accepted

    let before = activeValueOf(getJson(ParamsPath, makerToken).body, ParamKey)
    let target = before.getInt() + 1
    # `effectiveFrom` = besok: nilai yang disetujui di suite sebelumnya mulai hari ini dan belum
    # punya akhir, jadi periode hari ini sudah terpakai (constraint EXCLUDE — spec §10.4).
    # Nilai bertanggal besok memangkas (`SUPERSEDED`) nilai hari ini, bukan bertabrakan.
    let tomorrow = format(utcNow() + initDuration(days = 1), "yyyy-MM-dd")
    let submitted = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": target, "effectiveFrom": tomorrow,
         "reason": "uji realtime: perubahan disetujui"}, makerToken)
    check submitted.code == 201
    let paramValueId = submitted.body["paramValueId"].getStr()

    # Peristiwa pertama datang dari **pengajuan** (status PENDING) — bukti klien menerima
    # perubahan begitu durable, bukan menunggu dispatcher/aktivasi.
    let submitFrame = client.nextOfType("event", 8000)
    check submitFrame["topic"].getStr() == "param.changed"
    check submitFrame["payload"]["key"].getStr() == ParamKey
    check submitFrame["payload"]["status"].getStr() == "PENDING"
    var problems = eventsSchema.validateValue(eventsSchema.doc["$defs"]["Event"], submitFrame, "$")
    check problems.len == 0
    for problem in problems:
      checkpoint problem

    check postJson("/api/v1/params/changes/" & paramValueId & "/approve",
      newJObject(), checkerToken).code == 200

    # Peristiwa kedua dari **persetujuan** (status ACTIVE) — inilah yang membuat UI bisa
    # memperbarui nilai tanpa reload (spec §19.2).
    let approveFrame = client.nextOfType("event", 8000)
    check approveFrame["topic"].getStr() == "param.changed"
    check approveFrame["payload"]["key"].getStr() == ParamKey
    check approveFrame["payload"]["status"].getStr() == "ACTIVE"
    check approveFrame["payload"]["value"].getInt() == target
    problems = eventsSchema.validateValue(eventsSchema.doc["$defs"]["Event"], approveFrame, "$")
    check problems.len == 0
    for problem in problems:
      checkpoint problem
