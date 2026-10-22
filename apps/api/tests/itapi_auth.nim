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
import platform/domain/scope
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
  PasswordBaru = "Kata-Sandi-Baru-Panjang"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_auth: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let eventsSchema = loadSchemaFile(EventsSchemaPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

proc dbValue(query: SqlQuery, args: varargs[string, `$`]): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(query, args)
  finally:
    dbPool.release(conn)

# --- penyiapan DB: skema bersih + seed pack + seed pengguna dev -------------------------------
block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))

  # Biaya KDF untuk test: parameter ini menentukan hash password **baru** (ganti kata sandi) dan
  # hash tiruan login akun tak dikenal. Nilai produksi (600.000) membuat suite ini ~90 detik CPU
  # tanpa menguji apa pun tentang biaya hashing — biaya KDF diuji di `tpassword`/`itpassword` dan
  # `./task bench-password`. Turunkan **hanya di DB test**; seed pack tetap 600.000.
  exec(db, sql"""UPDATE platform.param_value
                    SET value = '1000'::jsonb
                  WHERE key = 'platform.security.password_pbkdf2_iterations'
                    AND status = 'ACTIVE'""")

proc paramSchemaBound(key, bound: string): int =
  ## Batas schema sebuah parameter dibaca dari **definisi** yang tersemai (asal
  ## `packs/base/generated/param_definitions.sql`), bukan angka yang disalin ke test (O-042).
  let conn = dbPool.acquire()
  try:
    result = definitionOf(conn, key).get().schema[bound].getInt
  finally:
    dbPool.release(conn)

proc maxFailedLoginsValue(): int =
  ## Dibaca lewat **resolusi parameter yang sama dengan server** (`activeParamInt` + `lookupFor`),
  ## bukan query tulis-sendiri: begitu ada lebih dari satu baris `ACTIVE` ber-tanggal, query naif
  ## mengambil baris sembarang — dan test lain di berkas ini memang mengubah parameter ini (pernah
  ## terbaca 7 padahal nilai efektifnya 6).
  let conn = dbPool.acquire()
  try:
    result = conn.activeParamInt("platform.security.max_failed_logins",
      businessDateIso(systemClock()), lookupFor(institutionScope()))
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
    replayed: string

var idemCounter = 0

proc autoIdemKey(): string =
  inc idemCounter
  "it-auth-" & $idemCounter

proc call(verb, path, payload, token: string, idempotencyKey = "",
    sendKey = true): Reply =
  # Endpoint kata sandi menjalankan PBKDF2 (verifikasi + riwayat N) dan biner debug ±20x lebih
  # lambat dari release (T-060/O-068: ganti kata sandi saja ≈ 13,6 s). Batas 15 s membuat test
  # gagal karena waktu, bukan perilaku → 60 s; assertion tidak dilonggarkan.
  let client = newHttpClient(timeout = 60_000)
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

  test "checker menolak pengajuan: REJECTED, audit + event, nilai aktif tetap":
    let maker = login(MakerUser)
    let makerToken = tokenOf(maker)
    let checkerToken = tokenOf(login(CheckerUser))
    let before = activeValueOf(getJson(ParamsPath, makerToken).body, ParamKey)
    let target = before.getInt() + 1

    let submitted = postJson("/api/v1/params/" & ParamKey & "/changes",
      %*{"value": target, "reason": "uji otomatis: pengajuan untuk ditolak"}, makerToken)
    check submitted.code == 201
    let paramValueId = submitted.body["paramValueId"].getStr()
    let rejectPath = "/api/v1/params/changes/" & paramValueId & "/reject"

    # Alasan wajib dan hanya checker yang boleh menolak.
    let noReason = postJson(rejectPath, newJObject(), checkerToken)
    check noReason.code == 400
    check noReason.body["params"]["reason"].getStr() == "reason_missing"
    let makerReject = postJson(rejectPath, %*{"reason": "bukan wewenang"}, makerToken)
    check makerReject.code == 403

    let rejected = postJson(rejectPath, %*{"reason": "salah ketik nilai"}, checkerToken)
    check rejected.code == 200
    checkJson("/api/v1/params/changes/{paramValueId}/reject", "POST", "200", rejected.body)
    check rejected.body["status"].getStr() == "REJECTED"

    # Nilai aktif tidak berubah, dan pengajuan itu tidak bisa ditolak dua kali.
    check activeValueOf(getJson(ParamsPath, makerToken).body, ParamKey).getInt() == before.getInt()
    let twice = postJson(rejectPath, %*{"reason": "ulang"}, checkerToken)
    check twice.code == 409
    check twice.body["params"]["reason"].getStr() == "not_pending"

    # Jejak audit + event memakai id pengajuan yang sama.
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = 'param.reject' AND resource_id = ?""", paramValueId) == "1"
    check dbValue(sql"""
      SELECT count(*)::text FROM platform.outbox
       WHERE event_type = 'param.changed' AND aggregate_id = ?""", paramValueId) >= "2"

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

  test "kata sandi lama salah dicatat: penghitung naik + audit `user.password_change.failure`":
    # Login yang berhasil mengosongkan penghitung, jadi angka di bawah pasti dari percobaan ini.
    let sesi = login(MakerUser)
    let token = tokenOf(sesi)
    let salah = postJson(PasswordPath,
      %*{"oldPassword": "kata-sandi-salah-panjang", "newPassword": PasswordBaru}, token)
    check salah.code == 403
    check salah.body["params"]["reason"].getStr() == "old_password_mismatch"

    let db = dbPool.acquire()
    try:
      check db.getValue(sql"""SELECT failed_attempts FROM platform.app_user
                               WHERE username = ?""", MakerUser) == "1"
      # `reason` di kolom adalah alasan sesi; alasan percobaan ada di muatan auditnya (`after_value`).
      let muatan = parseJson(db.getValue(sql"""SELECT after_value::text FROM platform.audit_log
                                                WHERE action = 'user.password_change.failure'
                                                ORDER BY seq DESC LIMIT 1"""))
      check muatan["reason"].getStr() == "old_password_mismatch"
      check muatan["failed_attempts"].getInt() == 1
      check muatan["status"].getStr() == "ACTIVE"
    finally:
      dbPool.release(db)

  test "kata sandi lama salah sampai batas parameter mengunci akun":
    # Pengguna sintetis: akunnya memang akan terkunci, jadi user seed yang masih dipakai test lain
    # tidak boleh jadi korban. Hash-nya disalin supaya kata sandinya diketahui.
    block:
      let db = dbPool.acquire()
      try:
        execScript(db, """INSERT INTO platform.app_user
            (user_id, username, full_name, password_algo, password_hash)
          SELECT gen_random_uuid(), 'itapi-lockout', 'Uji Lockout', password_algo, password_hash
            FROM platform.app_user WHERE username = 'dev.maker'""")
      finally:
        dbPool.release(db)

    let sesi = login("itapi-lockout")
    check sesi.code == 200
    let token = tokenOf(sesi)
    for i in 1 .. maxFailedLoginsValue():
      let salah = postJson(PasswordPath,
        %*{"oldPassword": "kata-sandi-salah-panjang", "newPassword": PasswordBaru}, token)
      check salah.code == 403

    block:
      let db = dbPool.acquire()
      try:
        check db.getValue(sql"""SELECT status FROM platform.app_user
                                 WHERE username = ?""", "itapi-lockout") == "LOCKED"
        check db.getValue(sql"""SELECT failed_attempts::text FROM platform.app_user
                                 WHERE username = ?""", "itapi-lockout") ==
          $maxFailedLoginsValue()
      finally:
        dbPool.release(db)

    # Kuncinya nyata: login dengan kata sandi yang benar sekalipun ditolak (`locked`, 403).
    let masuk = login("itapi-lockout")
    check masuk.code == 403
    check masuk.body["params"]["reason"].getStr() == "locked"

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
    let baruLagi = "Kata-Sandi-Ketiga-Panjang"

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

  test "kata sandi lama tidak bisa dipakai ulang: yang berlaku maupun yang di riwayat (O-052)":
    # `dev.firstlogin` sudah melewati dua penggantian di atas, jadi riwayatnya memuat kata sandi
    # seed; yang diuji di sini dua-duanya: kata sandi yang **sedang berlaku** dan yang **sudah
    # digantikan**. Keduanya lewat HTTP, bukan pemanggilan lapisan langsung.
    const Ketiga = "Kata-Sandi-Ketiga-Panjang"
    let sesi = login(FirstLoginUser, Ketiga)
    check sesi.code == 200
    let token = tokenOf(sesi)

    let berlaku = postJson(PasswordPath,
      %*{"oldPassword": Ketiga, "newPassword": Ketiga}, token)
    check berlaku.code == 400
    check berlaku.body["params"]["reason"].getStr() == "password_policy"
    checkProblem(PasswordPath, "POST", "400", berlaku.body)

    let dariRiwayat = postJson(PasswordPath,
      %*{"oldPassword": Ketiga, "newPassword": DevPassword}, token)
    check dariRiwayat.code == 400
    check dariRiwayat.body["params"]["reason"].getStr() == "password_policy"

    # Kontrol: kata sandi baru yang belum pernah dipakai tetap diterima — supaya 400 di atas
    # benar-benar karena aturan riwayat, bukan karena tidak ada yang bisa lolos.
    let segar = "Kata-Sandi-Keempat-Panjang"
    check postJson(PasswordPath, %*{"oldPassword": Ketiga, "newPassword": segar}, token).code == 204
    check login(FirstLoginUser, segar).code == 200
    check login(FirstLoginUser, Ketiga).code == 401

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

suite "scoping cabang di jalur HTTP (T-058, D-062)":
  const
    BranchKey = "platform.calendar.weekend_days" # allowed_scopes: GLOBAL, BRANCH
    SandiUji = "Kata-Sandi-Uji-Cabang1"

  proc buatUser(username: string): string =
    ## Pengguna uji + kata sandi yang diketahui. Iterasi PBKDF2 kecil: ini test, bukan produksi.
    let uid = $newId(systemClock())
    let db = dbPool.acquire()
    try:
      doAssert insertUser(db, NewUser(userId: uid, username: username,
        fullName: "Uji " & username, passwordHash: $hashPassword(SandiUji, 1000)))
    finally:
      dbPool.release(db)
    uid

  proc beriRole(uid, role, cabang: string) =
    let db = dbPool.acquire()
    try:
      doAssert grantRole(db, uid, role, cabang, "")
    finally:
      dbPool.release(db)

  proc pastikanRolePembaca() =
    ## Peran uji baca-saja. Dibutuhkan sejak D-113: satu pengguna tidak boleh memegang
    ## `param_maker` + `param_checker` (SoD), padahal test gerbang cabang perlu izin baca di
    ## cabang lain tanpa memberi wewenang submit/approve di sana.
    let db = dbPool.acquire()
    try:
      db.exec(sql"""
        INSERT INTO platform.role (role_id, code, name_key, is_system)
        VALUES (gen_random_uuid(), 'param_reader_uji', 'role.param_reader_uji', false)
        ON CONFLICT (code) DO NOTHING""")
      db.exec(sql"""
        INSERT INTO platform.role_permission (role_id, permission_id)
        SELECT r.role_id, p.permission_id FROM platform.role r, platform.permission p
         WHERE r.code = 'param_reader_uji' AND p.code = 'platform.param.read'
        ON CONFLICT DO NOTHING""")
    finally:
      dbPool.release(db)

  proc ajukanCabang(token, cabang: string): Reply =
    postJson(ParamsPath & "/" & BranchKey & "/changes",
      %*{"value": [5, 6], "scopeType": "BRANCH", "scopeId": cabang,
         "reason": "uji otomatis: scoping cabang"}, token)

  proc adaSeq(body: JsonNode, seq: int64): bool =
    for item in body["items"]:
      if item["seq"].getBiggestInt == seq:
        return true

  proc seqAudit(action, cabang: string): int64 =
    ## `seq` baris audit yang benar-benar bercabang itu — dibaca dari DB: daftar audit tidak
    ## memuat kolom cabang, jadi atribusinya hanya bisa dibuktikan di sini.
    let db = dbPool.acquire()
    try:
      result = parseBiggestInt(db.getValue(sql"""
        SELECT coalesce(max(seq), 0)::text FROM platform.audit_log
         WHERE action = ? AND branch_id = ?::uuid""", action, cabang))
    finally:
      dbPool.release(db)

  test "grant khusus cabang: boleh di cabangnya, 403 `branch_not_allowed` di cabang lain":
    let cabangA = $newId(systemClock())
    let cabangB = $newId(systemClock())
    # Maker di A, pembaca baca-saja di B (bukan checker: D-113 melarang satu orang memegang
    # maker+checker). Izin **baca** ada di kedua cabang, jadi pemeriksaan D-047 (`mayReadScope`)
    # lolos dan 403 di bawah benar-benar datang dari gerbang cabang pengajuan — bukan dari aturan
    # scope.
    let uid = buatUser("itapi-cabang-dua")
    pastikanRolePembaca()
    beriRole(uid, "param_maker", cabangA)
    beriRole(uid, "param_reader_uji", cabangB)
    let token = tokenOf(login("itapi-cabang-dua", SandiUji))
    check token.len > 0

    let diA = ajukanCabang(token, cabangA)
    check diA.code == 201
    check diA.body["scopeId"].getStr() == cabangA
    checkJson(ParamsPath & "/{key}/changes", "POST", "201", diA.body)

    let diB = ajukanCabang(token, cabangB)
    check diB.code == 403
    check diB.body["params"]["reason"].getStr() == "branch_not_allowed"
    checkProblem(ParamsPath & "/{key}/changes", "POST", "403", diB.body)

    # Aksi tingkat institusi ("") tetap menuntut grant **tanpa** batas cabang — grant khusus cabang
    # tidak boleh diam-diam menjadi izin institusi.
    let institusi = postJson(ParamsPath & "/" & BranchKey & "/changes",
      %*{"value": [5, 6], "reason": "uji otomatis: aksi tingkat institusi"}, token)
    check institusi.code == 403
    check institusi.body["params"]["reason"].getStr() == "branch_not_allowed"

  test "menyetujui nilai cabang lain ditolak 403; barisnya tetap ber-branch_id cabangnya":
    let cabangA = $newId(systemClock())
    let cabangB = $newId(systemClock())
    let pengaju = ajukanCabang(tokenOf(login(MakerUser)), cabangA)
    check pengaju.code == 201
    let pvId = pengaju.body["paramValueId"].getStr()

    # Penyetuju ber-cabang B dan pembaca baca-saja di A: gerbang izin lolos, gerbang cabang
    # menolak. Tidak memakai `param_maker` di A karena D-113 melarang maker+checker satu orang.
    let uid = buatUser("itapi-cabang-penyetuju")
    pastikanRolePembaca()
    beriRole(uid, "param_checker", cabangB)
    beriRole(uid, "param_reader_uji", cabangA)
    let tokenB = tokenOf(login("itapi-cabang-penyetuju", SandiUji))
    let tolak = postJson("/api/v1/params/changes/" & pvId & "/approve", newJObject(), tokenB)
    check tolak.code == 403
    check tolak.body["params"]["reason"].getStr() == "branch_not_allowed"
    checkProblem("/api/v1/params/changes/{paramValueId}/approve", "POST", "403", tolak.body)

    # Kontrol: penyetuju tanpa batas cabang menyetujui nilai yang sama → 200. Tanpa kontrol ini,
    # 403 di atas tidak membedakan "gerbang cabang" dari "apa pun tidak boleh".
    let setuju = postJson("/api/v1/params/changes/" & pvId & "/approve", newJObject(),
      tokenOf(login(CheckerUser)))
    check setuju.code == 200
    check seqAudit("param.approve", cabangA) > 0

  test "jejak audit bercabang terbaca hanya oleh pembaca cabang itu (D-055 temuan 1)":
    let cabangA = $newId(systemClock())
    let cabangB = $newId(systemClock())
    # Pengenal cabang berbentuk uuid: `audit_log.branch_id` bertipe uuid, jadi hanya pengenal
    # seperti ini yang bisa tercatat sebagai cabang (O-017 mencatat kesenjangan tipe ini).
    check ajukanCabang(tokenOf(login(MakerUser)), cabangA).code == 201
    check ajukanCabang(tokenOf(login(MakerUser)), cabangB).code == 201
    let seqA = seqAudit("param.submit", cabangA)
    let seqB = seqAudit("param.submit", cabangB)
    check seqA > 0
    check seqB > 0

    let hanyaA = buatUser("itapi-hanya-a")
    beriRole(hanyaA, "param_maker", cabangA)
    let hanyaB = buatUser("itapi-hanya-b")
    beriRole(hanyaB, "param_maker", cabangB)

    let daftarA = getJson(AuditPath & "?limit=200", tokenOf(login("itapi-hanya-a", SandiUji)))
    check daftarA.code == 200
    check adaSeq(daftarA.body, seqA)
    check not adaSeq(daftarA.body, seqB)

    let daftarB = getJson(AuditPath & "?limit=200", tokenOf(login("itapi-hanya-b", SandiUji)))
    check daftarB.code == 200
    check adaSeq(daftarB.body, seqB)
    check not adaSeq(daftarB.body, seqA)

  test "pembacaan lintas-cabang tercatat di cabang yang dibaca (D-055 butir 5)":
    let cabangA = $newId(systemClock())
    let cabangB = $newId(systemClock())
    let pengaju = ajukanCabang(tokenOf(login(MakerUser)), cabangA)
    check pengaju.code == 201
    check postJson("/api/v1/params/changes/" & pengaju.body["paramValueId"].getStr() &
      "/approve", newJObject(), tokenOf(login(CheckerUser))).code == 200

    # Pembaca **tanpa** batas cabang membaca daftar: baris cabang A dibaca dari luar cabang tugasnya.
    let daftar = getJson(ParamsPath & "?status=ACTIVE", tokenOf(login(MakerUser)))
    check daftar.code == 200
    let seqBaca = seqAudit("param.read_cross_branch", cabangA)
    check seqBaca > 0
    check seqAudit("param.read_cross_branch", cabangB) == 0

    # Jejak itu milik cabang **yang dibaca**, bukan cabang tugas pembacanya: cabang lain tidak
    # melihatnya, walaupun pembacanya pengguna pusat.
    let uidA = buatUser("itapi-lintas-a")
    beriRole(uidA, "param_maker", cabangA)
    let uidB = buatUser("itapi-lintas-b")
    beriRole(uidB, "param_maker", cabangB)
    let lihatA = getJson(AuditPath & "?limit=200", tokenOf(login("itapi-lintas-a", SandiUji)))
    check lihatA.code == 200
    check adaSeq(lihatA.body, seqBaca)
    let lihatB = getJson(AuditPath & "?limit=200", tokenOf(login("itapi-lintas-b", SandiUji)))
    check lihatB.code == 200
    check not adaSeq(lihatB.body, seqBaca)

  test "pengenal cabang non-uuid tidak dipaksa ke kolom uuid (O-017)":
    # Pengenal cabang di tempat lain bertipe teks (`param_value.scope_id`, `user_role.branch_id`).
    # Otorisasi tetap bekerja dengan teks; yang tidak bisa hanyalah kolom audit yang bertipe uuid —
    # jadi barisnya tetap tanpa cabang, dan pengenalnya tetap utuh di payload (tidak ada cast paksa
    # yang membuat permintaan sah berakhir 500).
    let pengaju = ajukanCabang(tokenOf(login(MakerUser)), "itapi-cabang-teks")
    check pengaju.code == 201
    let pvId = pengaju.body["paramValueId"].getStr()
    let db = dbPool.acquire()
    try:
      check db.getValue(sql"""
        SELECT coalesce(branch_id::text, 'NULL') FROM platform.audit_log
         WHERE action = 'param.submit' AND resource_id = ?""", pvId) == "NULL"
      check db.getValue(sql"""
        SELECT after_value->>'scope_id' FROM platform.audit_log
         WHERE action = 'param.submit' AND resource_id = ?""", pvId) == "itapi-cabang-teks"
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
    # Urutan yang sah: penerus diajukan lebih dulu (masih PENDING). Menyetujui penerus lebih dulu
    # bukan buntu, tetapi memangkas nilai GLOBAL terbuka sampai `effective_from` penerus, sehingga
    # nilai terbatas di dalam rentang itu tidak bisa lagi diaktifkan (bertabrakan dengan riwayat
    # pangkasan itu, EXCLUDE).
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

test "idempotency param submit: replay, konflik, tanpa header":
  let token = tokenOf(login("dev.maker"))
  let path = "/api/v1/params/platform.realtime.max_topics/changes"
  let body = %*{"value": 40, "reason": "uji idempotensi pengajuan"}

  let first = postJson(path, body, token, key = "idem-param-1")
  check first.code == 201
  let paramValueId = first.body["paramValueId"].getStr()

  let paramRows = """SELECT count(*)::text FROM platform.param_value
    WHERE key = 'platform.realtime.max_topics'"""
  let rowsBefore = dbValue(sql(paramRows))

  let replay = postJson(path, body, token, key = "idem-param-1")
  check replay.code == 200
  check replay.replayed == "true"
  check replay.body["paramValueId"].getStr() == paramValueId
  check dbValue(sql(paramRows)) == rowsBefore

  let conflict = postJson(path, %*{"value": 41, "reason": "beda isi"}, token,
    key = "idem-param-1")
  check conflict.code == 409

  let noKey = postJson(path, body, token, sendKey = false)
  check noKey.code == 400
