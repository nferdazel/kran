## Test integrasi HTTP T-012 (butuh `KRAN_DATABASE_URL`): login → ubah parameter (maker-checker) →
## audit → peristiwa realtime ke klien bersesi.
##
## Yang dibuktikan di sini adalah **jalur penuh lewat HTTP**, bukan pemanggilan lapisan langsung:
## cookie sesi benar-benar menyetir identitas, izin efektif menentukan 401/403, dan penyetuju
## kedua (`checker <> maker`) ditegakkan. Bentuk setiap respons divalidasi terhadap kontrak
## OpenAPI (`packages/contracts/openapi/kran-api.yaml`) supaya handler dan kontrak tidak bisa
## menyimpang diam-diam.
##
## Test ini **menghapus schema `platform`** di DB yang ditunjuk `KRAN_DATABASE_URL` (DB dev), lalu
## menyiapkan ulang: migrasi + seed pack `base` + seed pengguna dev
## (`packs/base/seed/0001_dev_users.sql`). Data dev murni sintetis.

import std/[httpclient, json, net, options, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/clock
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import kernel/[clock, ids]
import platform/infrastructure/[auth_repo, param_repo, password_hasher]

import ../src/[access, context, events, readiness, server]
import ./wsclient

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  EventsSchemaPath = "packages/contracts/events/realtime-envelope.v1.schema.json"
  EventsPath = "/api/v1/events/stream"
  LoginPath = "/api/v1/auth/login"
  SessionPath = "/api/v1/auth/session"
  LogoutPath = "/api/v1/auth/logout"
  PasswordPath = "/api/v1/auth/password"
  ParamsPath = "/api/v1/params"
  AuditPath = "/api/v1/audit"
  ParamKey = "platform.security.max_failed_logins"
  SessionIdleKey = "platform.security.session_idle_minutes"
  SessionAbsoluteKey = "platform.security.session_absolute_minutes"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  ## User seed yang `must_change_password = true`: dipakai alur wajib-ganti. Passwordnya sama.
  FirstLoginUser = "dev.firstlogin"
  PasswordBaru = "kata-sandi-baru-panjang"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_auth: KRAN_DATABASE_URL kosong — dilewati"
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

proc paramSchemaBound(key, bound: string): int =
  ## Batas schema sebuah parameter dibaca dari **definisi** yang tersemai (asal
  ## `packs/base/generated/param_definitions.sql`), bukan angka yang disalin ke test (O-042).
  let conn = dbPool.acquire()
  try:
    result = definitionOf(conn, key).get().schema[bound].getInt
  finally:
    dbPool.release(conn)

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
    # Alasan berkode stabil supaya UI bisa menerjemahkan per-field (O-045).
    check reply.body["params"]["reason"].getStr() == "value_invalid"

  test "penolakan tingkat-field menyebut alasan berkode stabil (O-045)":
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    # Field `reason` kosong.
    let tanpaAlasan = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": 1, "reason": ""}, token)
    check tanpaAlasan.code == 400
    check tanpaAlasan.body["params"]["reason"].getStr() == "reason_missing"
    # Tanggal bentuk salah.
    let tanggalBuruk = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": 1, "reason": "uji tanggal", "effectiveFrom": "31-12-2026"}, token)
    check tanggalBuruk.code == 400
    check tanggalBuruk.body["params"]["reason"].getStr() == "effective_from_invalid"
    # Periode terbalik.
    let periodeTerbalik = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": 1, "reason": "uji periode", "effectiveFrom": "2026-12-31",
        "effectiveTo": "2026-12-01"}, token)
    check periodeTerbalik.code == 400
    check periodeTerbalik.body["params"]["reason"].getStr() == "period_invalid"

  test "key tak dikenal ditolak 400":
    let maker = login(MakerUser)
    let reply = postJson("/api/v1/params/platform.tidak.ada/changes",
      %*{"value": 1, "reason": "uji key tak dikenal"}, tokenOf(maker))
    check reply.code == 400
    check reply.body["params"]["reason"].getStr() == "value_invalid"

suite "aturan lintas-parameter kebijakan sesi lewat HTTP":
  test "pengajuan yang membuat idle > absolut ditolak 400, tanpa efek samping":
    let maker = login(MakerUser)
    let makerToken = tokenOf(maker)
    let params = getJson(ParamsPath, makerToken).body
    let idle = activeValueOf(params, SessionIdleKey).getInt()
    let absolute = activeValueOf(params, SessionAbsoluteKey).getInt()
    # Kombinasi tidak sah: idle di atas absolut, tetapi masih di dalam batas schema. Batas atas
    # dibaca dari definisi (1..1440 untuk `session_idle_minutes`) alih-alih disalin (O-042).
    let badIdle = max(absolute + 1, idle + 1)
    check badIdle > absolute
    check badIdle <= paramSchemaBound(SessionIdleKey, "maximum")

    let reply = postJson("/api/v1/params/" & SessionIdleKey & "/changes",
      %*{"value": badIdle, "reason": "uji otomatis: kombinasi kebijakan sesi tidak sah"},
      makerToken)
    check reply.code == 400
    check reply.body["params"]["reason"].getStr() == "invalid_combination"
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

suite "validasi bentuk permintaan parameter (O-035)":
  test "tanggal, periode, dan scope yang tidak sah dijawab 400, bukan 500":
    # Sebelum perbaikan, semuanya berakhir di cast `?::date`/`?::uuid` atau CHECK skema → DbError →
    # 500. Sekarang diperiksa di handler: kontrak sudah menyediakan 400 untuk operasi ini.
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    let path = "/api/v1/params/" & ParamKey & "/changes"
    let kasus = [
      ("efektif bukan tanggal", %*{"value": 9, "reason": "uji", "effectiveFrom": "2026-13-45"}),
      ("tanggal tidak ada di kalender", %*{"value": 9, "reason": "uji",
        "effectiveFrom": "2026-02-31"}),
      ("effectiveTo bukan tanggal", %*{"value": 9, "reason": "uji",
        "effectiveFrom": "2026-12-01", "effectiveTo": "besok"}),
      ("periode terbalik", %*{"value": 9, "reason": "uji", "effectiveFrom": "2026-12-31",
        "effectiveTo": "2026-01-01"}),
      ("periode kosong (from = to)", %*{"value": 9, "reason": "uji",
        "effectiveFrom": "2026-12-01", "effectiveTo": "2026-12-01"}),
      ("scope tidak dikenal", %*{"value": 9, "reason": "uji", "scopeType": "BOGUS"}),
      ("scopeId pada GLOBAL", %*{"value": 9, "reason": "uji", "scopeType": "GLOBAL",
        "scopeId": "inst-1"}),
      ("scope non-GLOBAL tanpa scopeId", %*{"value": 9, "reason": "uji",
        "scopeType": "INSTITUTION"}),
    ]
    for (nama, body) in kasus:
      checkpoint nama
      let reply = postJson(path, body, token)
      check reply.code == 400
      check reply.body.hasKey("code") # amplop problem+json, bukan 500 tanpa bentuk
      checkProblem("/api/v1/params/{key}/changes", "POST", "400", reply.body)

  test "paramValueId bukan UUID dijawab 404, bukan 500":
    let checker = login(CheckerUser)
    let reply = postJson("/api/v1/params/changes/bukan-uuid/approve", newJObject(),
      tokenOf(checker))
    check reply.code == 404
    checkProblem("/api/v1/params/changes/{paramValueId}/approve", "POST", "404", reply.body)

  test "kontrol: pengajuan dengan tanggal & scope yang sah tetap 201":
    let maker = login(MakerUser)
    let reply = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": 9, "reason": "kontrol validasi bentuk", "effectiveFrom": "2027-03-01"},
      tokenOf(maker))
    check reply.code == 201
    checkJson("/api/v1/params/{key}/changes", "POST", "201", reply.body)

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

  test "logout mengakhiri stream yang sudah terbuka (O-036)":
    # Sesi dicabut **setelah** handshake: pump memeriksa ulang tiap ≤ `defaultSessionRecheckSeconds`
    # (5 detik), mengirim amplop `error`, lalu menutup soket. Tanpa pemeriksaan itu, klien dengan
    # cookie yang sudah dicabut terus menerima peristiwa parameter.
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    var client = wsclient.connect("127.0.0.1", portOf(baseUrl), EventsPath,
      [("Cookie", CookieName & "=" & token)])
    client.sendText( $ %*{"type": "subscribe", "topics": ["param.changed"]})
    check client.nextOfType("subscribed", 5000)["topics"][0].getStr() == "param.changed"

    check postJson(LogoutPath, newJObject(), token).code == 204

    let frame = client.nextOfType("error", 15000)
    check frame["code"].getStr() == "REALTIME_SESSION_ENDED"
    check frame["i18nKey"].getStr() == "error_unauthorized"
    check client.nextText(5000).len == 0 # close frame dari server
    client.close()

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

suite "anti-enumerasi akun lewat HTTP (O-034)":
  test "status terkunci/tidak aktif hanya dibalas setelah kata sandi benar":
    let db = dbPool.acquire()
    let terkunci = $newId(systemClock())
    let nonaktif = $newId(systemClock())
    let sandi = "kata-sandi-uji-panjang"

    check insertUser(db, NewUser(userId: terkunci, username: "itapi-terkunci",
      fullName: "Uji Terkunci", passwordHash: $hashPassword(sandi, 1000)))
    check setUserStatus(db, terkunci, "LOCKED")
    check insertUser(db, NewUser(userId: nonaktif, username: "itapi-nonaktif",
      fullName: "Uji Nonaktif", passwordHash: $hashPassword(sandi, 1000)))
    check setUserStatus(db, nonaktif, "INACTIVE")

    # Kata sandi salah → 401 generik untuk keduanya: status akun tidak boleh bocor.
    for nama in ["itapi-terkunci", "itapi-nonaktif"]:
      let salah = login(nama, "kata-sandi-salah-sekali")
      check salah.code == 401
      check salah.body["params"]["reason"].getStr() == "invalid_credentials"
      checkProblem(LoginPath, "POST", "401", salah.body)

    # Kata sandi benar → baru statusnya diberitahukan (pemilik akun berhak tahu kenapa ditolak).
    let kunci = login("itapi-terkunci", sandi)
    check kunci.code == 403
    check kunci.body["params"]["reason"].getStr() == "locked"
    checkProblem(LoginPath, "POST", "403", kunci.body)

    let mati = login("itapi-nonaktif", sandi)
    check mati.code == 403
    check mati.body["params"]["reason"].getStr() == "inactive"
    checkProblem(LoginPath, "POST", "403", mati.body)

    discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid",
      terkunci)
    discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid",
      nonaktif)
    dbPool.release(db)

suite "ganti kata sandi lewat HTTP":
  test "tanpa cookie → 401":
    let reply = postJson(PasswordPath,
      %*{"oldPassword": DevPassword, "newPassword": PasswordBaru})
    check reply.code == 401
    checkProblem(PasswordPath, "POST", "401", reply.body)

  test "badan tidak lengkap → 400":
    let sesi = login(MakerUser)
    let reply = postJson(PasswordPath, %*{"oldPassword": DevPassword}, tokenOf(sesi))
    check reply.code == 400
    checkProblem(PasswordPath, "POST", "400", reply.body)

  test "kata sandi lama salah → 403 `old_password_mismatch` dan sesi tidak dicabut":
    let sesi = login(MakerUser)
    let token = tokenOf(sesi)
    let reply = postJson(PasswordPath,
      %*{"oldPassword": "kata-sandi-salah-panjang", "newPassword": PasswordBaru}, token)
    check reply.code == 403
    check reply.body["params"]["reason"].getStr() == "old_password_mismatch"
    checkProblem(PasswordPath, "POST", "403", reply.body)
    # Sengaja 403, bukan 401: klien yang memperlakukan 401 sebagai "sesi berakhir" tidak boleh
    # mengeluarkan pengguna hanya karena salah mengetik kata sandi lama.
    check getJson(SessionPath, token).code == 200

  test "kata sandi baru melanggar kebijakan → 400 `password_policy`":
    let sesi = login(MakerUser)
    let reply = postJson(PasswordPath,
      %*{"oldPassword": DevPassword, "newPassword": "pendek"}, tokenOf(sesi))
    check reply.code == 400
    check reply.body["params"]["reason"].getStr() == "password_policy"
    checkProblem(PasswordPath, "POST", "400", reply.body)
    # Kata sandi lama tetap berlaku setelah percobaan yang gagal.
    check login(MakerUser, DevPassword).code == 200

  test "wajib ganti: rute ber-izin ditolak, sesi & alur ganti tetap terbuka":
    let pertama = login(FirstLoginUser)
    check pertama.code == 200
    let token = tokenOf(pertama)

    let info = getJson(SessionPath, token)
    check info.code == 200
    check info.body["mustChangePassword"].getBool()

    let ditolak = getJson(ParamsPath, token)
    check ditolak.code == 403
    check ditolak.body["params"]["reason"].getStr() == "password_change_required"
    checkProblem(ParamsPath, "GET", "403", ditolak.body)

    # Langganan realtime memakai definisi "sesi yang boleh bekerja" yang sama, jadi sesi
    # berkata-sandi-sementara tidak bisa menyedot data lewat jalur itu.
    check not sessionCanWork(app, token)

    # Ganti bukan sekadar boleh: itu satu-satunya jalan keluar dari keadaan ini.
    let ganti = postJson(PasswordPath,
      %*{"oldPassword": DevPassword, "newPassword": PasswordBaru}, token)
    check ganti.code == 204
    let sesudah = getJson(SessionPath, token)
    check sesudah.code == 200
    check not sesudah.body["mustChangePassword"].getBool()
    check getJson(ParamsPath, token).code == 200
    check sessionCanWork(app, token)

  test "berhasil: sesi lain dicabut, kata sandi lama mati, audit tercatat":
    let sesiA = login(FirstLoginUser, PasswordBaru)
    let sesiB = login(FirstLoginUser, PasswordBaru)
    check sesiA.code == 200
    check sesiB.code == 200
    let tokenA = tokenOf(sesiA)
    let tokenB = tokenOf(sesiB)
    let baruLagi = "kata-sandi-ketiga-panjang"

    let ganti = postJson(PasswordPath,
      %*{"oldPassword": PasswordBaru, "newPassword": baruLagi}, tokenA)
    check ganti.code == 204

    # Sesi yang dipakai tetap hidup; sesi lain milik pengguna yang sama dicabut.
    check getJson(SessionPath, tokenA).code == 200
    check getJson(SessionPath, tokenB).code == 401

    # Kata sandi lama tidak bisa dipakai lagi; yang baru bisa.
    check login(FirstLoginUser, PasswordBaru).code == 401
    check login(FirstLoginUser, baruLagi).code == 200

    # Jejak auditnya terlihat lewat API, bukan cuma dipercaya dari kode repo.
    let audit = getJson(AuditPath & "?action=user.password_change", tokenA)
    check audit.code == 200
    var adaJejak = false
    for item in audit.body["items"]:
      if item["action"].getStr() == "user.password_change":
        adaJejak = true
    check adaJejak

suite "wewenang scope parameter lewat HTTP (O-032, O-044/D-047)":
  const
    WeekEndKey = "platform.calendar.weekend_days" # allowed_scopes: GLOBAL, BRANCH
    CabangB = "itapi-cabang-b"

  test "scope tanpa model keanggotaan ditolak 403 `scope_not_readable` (gagal-tertutup)":
    # D-055: PRODUCT/SEGMENT/ROLE belum punya model keanggotaan, jadi setiap pengajuan ke sana
    # ditolak sebagai **tidak berwenang** — dan penolakannya terjadi sebelum validasi definisi,
    # supaya tidak membocorkan (key, scope) mana yang didukung.
    let maker = login(MakerUser)
    let reply = postJson(ParamsPath & "/" & WeekEndKey & "/changes",
      %*{"value": [5, 6], "scopeType": "PRODUCT", "scopeId": "itapi-produk-1",
         "reason": "uji otomatis: scope tanpa model keanggotaan"}, tokenOf(maker))
    check reply.code == 403
    check reply.body["params"]["reason"].getStr() == "scope_not_readable"
    checkProblem(ParamsPath & "/{key}/changes", "POST", "403", reply.body)

  test "nilai bercabang: maker-checker, lalu pembacaannya tercatat sebagai lintas-cabang":
    let makerToken = tokenOf(login(MakerUser))
    let checkerToken = tokenOf(login(CheckerUser))

    let submitted = postJson(ParamsPath & "/" & WeekEndKey & "/changes",
      %*{"value": [5, 6], "scopeType": "BRANCH", "scopeId": CabangB,
         "reason": "uji otomatis: nilai khusus satu cabang"}, makerToken)
    check submitted.code == 201
    checkJson(ParamsPath & "/{key}/changes", "POST", "201", submitted.body)
    let paramValueId = submitted.body["paramValueId"].getStr()

    let approved = postJson("/api/v1/params/changes/" & paramValueId & "/approve",
      newJObject(), checkerToken)
    check approved.code == 200
    check approved.body["status"].getStr() == "ACTIVE"

    # Grant tanpa batas cabang menutupi semua cabang: nilai GLOBAL + nilai cabang itu terlihat.
    let body = getJson(ParamsPath, makerToken).body
    check itemWith(body, WeekEndKey).len == 2

    # D-046 butir 6: pembacaan cabang di luar cabang tugas pemanggil meninggalkan jejak audit —
    # diperiksa di DB, bukan dari respons, karena daftar audit tidak memuat kolom cabang.
    let db = dbPool.acquire()
    try:
      let jejak = db.getValue(sql"""
        SELECT count(*) FROM platform.audit_log
         WHERE action = 'param.read_cross_branch' AND resource_id = ?""", CabangB)
      check jejak != "0"
      check db.getValue(sql"""
        SELECT reason FROM platform.audit_log
         WHERE action = 'param.read_cross_branch' AND resource_id = ?
         ORDER BY seq DESC LIMIT 1""", CabangB) == "cross_branch_read"
    finally:
      dbPool.release(db)

suite "akhir periode tanpa penerus lewat HTTP (O-043, D-046 butir 8)":
  const
    AkhirKey = "platform.calendar.weekend_days" # allowed_scopes: GLOBAL, BRANCH

  proc ajukan(makerToken, mulai, sampai: string): Reply =
    var body = %*{"value": [5, 6], "effectiveFrom": mulai,
      "reason": "uji otomatis: akhir periode"}
    if sampai.len > 0:
      body["effectiveTo"] = %sampai
    postJson(ParamsPath & "/" & AkhirKey & "/changes", body, makerToken)

  test "effectiveTo tanpa penerus ditolak 400":
    # Nilai GLOBAL yang masih terbuka **tidak** menolong: persetujuan nilai ini justru memangkasnya
    # di `effectiveFrom`, sehingga tanggal setelah `effectiveTo` tidak punya nilai berlaku.
    let reply = ajukan(tokenOf(login(MakerUser)), "2026-12-01", "2026-12-31")
    check reply.code == 400
    check reply.body["params"]["reason"].getStr() == "effective_to_without_successor"
    checkProblem(ParamsPath & "/{key}/changes", "POST", "400", reply.body)

  test "penerus yang sudah diajukan membuat nilai terbatas diterima":
    let makerToken = tokenOf(login(MakerUser))
    # Urutan yang sah: penerus diajukan lebih dulu. Ia belum bisa disetujui, sebab nilai GLOBAL
    # yang masih terbuka akan bersinggungan dengannya (EXCLUDE) sampai nilai terbatas diaktifkan.
    let penerus = ajukan(makerToken, "2027-02-01", "")
    check penerus.code == 201

    let terbatas = ajukan(makerToken, "2027-01-01", "2027-02-01")
    check terbatas.code == 201
    checkJson(ParamsPath & "/{key}/changes", "POST", "201", terbatas.body)

  test "penerus yang hilang sebelum persetujuan ditolak 409":
    let makerToken = tokenOf(login(MakerUser))
    let checkerToken = tokenOf(login(CheckerUser))

    let penerus = ajukan(makerToken, "2027-04-01", "")
    check penerus.code == 201
    let terbatas = ajukan(makerToken, "2027-03-01", "2027-04-01")
    check terbatas.code == 201
    let terbatasId = terbatas.body["paramValueId"].getStr()

    # Kehilangan penerus disimulasikan langsung di DB: belum ada endpoint HTTP untuk menolak
    # pengajuan (`rejectValue` hanya ada di repo), sedangkan keadaan inilah yang dijaga oleh
    # pemeriksaan ulang saat persetujuan.
    let db = dbPool.acquire()
    try:
      execScript(db, "UPDATE platform.param_value SET status = 'REJECTED' WHERE param_value_id = '" &
        penerus.body["paramValueId"].getStr() & "'")
    finally:
      dbPool.release(db)

    let approve = postJson("/api/v1/params/changes/" & terbatasId & "/approve",
      newJObject(), checkerToken)
    check approve.code == 409
    check approve.body["params"]["reason"].getStr() == "effective_to_without_successor"
    checkProblem("/api/v1/params/changes/{paramValueId}/approve", "POST", "409", approve.body)
