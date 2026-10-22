## Test integrasi endpoint realtime `GET /api/v1/events/stream` (butuh `KRAN_DATABASE_URL`).
##
## Kriteria T-009: peristiwa dari outbox sampai ke **klien** dan reconnect tidak kehilangan
## peristiwa. Jadi di sini dibuktikan jalur penuh: INSERT outbox → trigger NOTIFY (migration 0007)
## → pump → hub → frame WebSocket → klien TCP nyata (klien WS minimal di `wsclient.nim`).
##
## Diuji juga jalur penolakan (426 tanpa upgrade, 401 tanpa identitas, 403 tanpa izin), pelaporan
## topik yang ditolak, dan `resync` ketika peristiwa yang terlewat melebihi batas replay.
##
## Test ini **tidak** mengubah schema (migrasi dijalankan lewat runner resmi) dan hanya menambah
## baris outbox dengan `dedup_key` unik, jadi aman dijalankan berulang di `kran_dev`.

import std/[atomics, httpclient, json, net, os, random, strutils, times, unittest]

import db_connector/db_postgres
import mummy

import dbtools/lib
import kernel/[clock, ids]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"
import platform/domain/event
import platform/infrastructure/[outbox_listener, outbox_repo]

import ../src/[context, events, readiness, server]
import ./wsclient

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  EventsSchemaPath = "packages/contracts/events/realtime-envelope.v1.schema.json"
  EventsPath = "/api/v1/events/stream"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_ws: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

randomize(20261014)

let contract = loadContractFile(ContractPath)
let eventsSchema = loadSchemaFile(EventsSchemaPath)

type
  ServeArgs = object
    server: Server
    port: int

var serverThread: Thread[ServeArgs]

proc serveInThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard # proses test berakhir dengan sendirinya (lihat catatan O-025 di docs/OPEN_ITEMS.md)

proc freePort(): int =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = int(socket.getLocalAddr()[1])
  socket.close()

proc startServer(service: EventService; readiness: ReadinessProbe = nil): int =
  let port = freePort()
  let server = newApiServer(AppContext(version: "itapi-ws-0.0.0", role: "api",
                                       startedAt: epochTime(), events: service,
                                       readiness: readiness))
  createThread(serverThread, serveInThread, ServeArgs(server: server, port: port))
  port

proc waitUntilServing(port: int) =
  let deadline = epochTime() + 5.0
  while epochTime() < deadline:
    try:
      let probe = newHttpClient(timeout = 1000)
      defer: probe.close()
      if probe.get("http://127.0.0.1:" & $port & "/healthz").code == Http200:
        return
    except CatchableError:
      discard
    sleep(50)
  check false # server tidak pernah siap

# --- kebijakan topik untuk uji: bukan konfigurasi produksi (default = menolak semua) ------------

proc denyOpen(identity: string): bool {.gcsafe.} =
  discard identity
  false

proc denyTopics(identity: string; requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  discard requested
  @[]

proc allowOpen(identity: string): bool {.gcsafe.} =
  identity.len > 0

proc allowTopics(identity: string; requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  requested

proc allowSession(identity: string): bool {.gcsafe.} =
  discard identity
  true

## Sesi yang bisa "dicabut" dari test (O-036): pump memeriksa lewat closure ini. Ditulis thread test
## dan dibaca thread pump, jadi memakai `Atomic` (bukan `bool` global polos).
var sessionMasihSah: Atomic[bool]
sessionMasihSah.store(true)
proc gatedSession(identity: string): bool {.gcsafe.} =
  discard identity
  sessionMasihSah.load()

## Izin topik yang bisa "dicabut" dari test (O-046): sesi tetap sah, hanya izinnya hilang.
var izinTopikMasihAda: Atomic[bool]
izinTopikMasihAda.store(true)
proc gatedTopics(identity: string; requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  if izinTopikMasihAda.load():
    result = requested

proc paramTopicsOnly(identity: string; requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  for topic in requested:
    if topic == "param.changed":
      result.add topic

# --- layanan & server ---------------------------------------------------------------------------

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
discard applyAllMigrations(db, ".")
let sysClock = systemClock()

let mainService = newEventService(TopicPolicy(canOpen: allowOpen, allowedTopics: allowTopics,
                            sessionValid: allowSession), dbPool)
startPump(mainService)
# Uji di bawah hanya menguji **pengiriman langsung**; peristiwa yang masuk sebelum pump menetapkan
# titik mulai dianggap riwayat (by design), jadi tunggu sinyal kesiapan lebih dulu.
proc waitForPump(service: EventService) =
  let deadline = epochTime() + 10.0
  while epochTime() < deadline and not service.pumpReady():
    sleep(20)
  check service.pumpReady()

waitForPump(mainService)
let mainPort = startServer(mainService)
waitUntilServing(mainPort)

# Penolakan akses: kebijakan "semua ditolak" dan kebijakan yang hanya mengizinkan satu topik.
let denyService = newEventService(TopicPolicy(canOpen: denyOpen, allowedTopics: denyTopics,
                            sessionValid: allowSession), nil)
let denyPort = startServer(denyService)
waitUntilServing(denyPort)

let paramService = newEventService(
  TopicPolicy(canOpen: allowOpen, allowedTopics: paramTopicsOnly, sessionValid: allowSession), nil)
let paramPort = startServer(paramService)
waitUntilServing(paramPort)

# Batas replay kecil: untuk menguji jalur `resync` tanpa menyiapkan ratusan peristiwa.
let tinyReplayService = newEventService(TopicPolicy(canOpen: allowOpen, allowedTopics: allowTopics,
                                                    sessionValid: allowSession),
                                        dbPool, resumeLimit = 1, maxResumeBatches = 1)
let tinyReplayPort = startServer(tinyReplayService)
waitUntilServing(tinyReplayPort)

# Sesi berakhir di tengah umur koneksi (O-036): interval 0 supaya setiap putaran pump memeriksa.
let gatedService = newEventService(
  TopicPolicy(canOpen: allowOpen, allowedTopics: allowTopics, sessionValid: gatedSession),
  dbPool, sessionRecheckSeconds = 0)
startPump(gatedService)
waitForPump(gatedService)
let gatedPort = startServer(gatedService)
waitUntilServing(gatedPort)

# Izin dicabut di tengah umur koneksi (O-046): sesi sengaja tetap sah supaya yang diuji benar-benar
# jalur izin, bukan jalur sesi.
let izinService = newEventService(
  TopicPolicy(canOpen: allowOpen, allowedTopics: gatedTopics, sessionValid: allowSession),
  dbPool, sessionRecheckSeconds = 0)
startPump(izinService)
waitForPump(izinService)
let izinPort = startServer(izinService)
waitUntilServing(izinPort)

## Uji pemutusan serentak (O-049) memerlukan beberapa klien sekaligus pada satu service.
const stressClients = 8

proc uniqueTopic(): string =
  "test.realtime." & $epochTime() & "." & $rand(1_000_000)

proc appendTestEvent(eventType: string; payload: JsonNode): string =
  ## Menulis satu peristiwa outbox dan mengembalikan idnya (resume token-nya).
  let event = newOutboxEvent(sysClock, eventType, "test", eventType, payload,
                             eventType & ":itapi_ws:" & $epochTime() & ":" & $rand(1_000_000))
  if not appendEvent(db, event):
    raise newException(IOError, "peristiwa tidak masuk outbox (dedup_key bentrok?)")
  $event.eventId

proc subscribeJson(topic, resumeFrom: string): string =
  ## Pesan langganan klien; `resumeFrom` opsional (token resume).
  result = "{\"type\":\"subscribe\",\"topics\":[\"" & topic & "\"]"
  if resumeFrom.len > 0:
    result.add ",\"resumeFrom\":\"" & resumeFrom & "\""
  result.add "}"

proc assertEventEnvelope(frame: JsonNode) =
  let problems = eventsSchema.validateValue(eventsSchema.doc["$defs"]["Event"], frame, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc assertProblem(status: int; body: JsonNode; expectedCode: string) =
  let problems = contract.validateValue(
    contract.responseSchema(EventsPath, "GET", $status, "application/problem+json"), body, "$")
  check problems.len == 0
  check body["code"].getStr() == expectedCode
  check body["i18nKey"].getStr() == "error_" & expectedCode.toLowerAscii()

suite "realtime: pump menyambung ulang (O-029)":
  test "koneksi pump diputus paksa → peristiwa berikutnya tetap terkirim":
    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    let topic = uniqueTopic()
    client.sendText(subscribeJson(topic, ""))
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["denied"].len == 0

    # Pump harus benar-benar tersambung sebelum diputus.
    let pidLama = mainService.pumpBackendPid()
    check pidLama > 0

    # Putus paksa koneksi pump: ini yang terjadi saat restart DB/jaringan blip, dan dulu membuat
    # realtime berhenti permanen sampai proses di-restart.
    check db.getValue(sql"select pg_terminate_backend(?)", pidLama) == "t"

    # Peristiwa diterbitkan **setelah** sesi pump diakhiri di sisi server dan **sebelum** pump
    # menyambung ulang — inilah peristiwa yang hilang kalau titik mulai (`lastEventId`) di-reset saat
    # menyambung ulang. Ditulis langsung setelah `pg_terminate_backend` supaya deterministik: sesi
    # lama pump sudah mati di server, jadi ia tidak mungkin sempat melihat baris ini.
    let eventId = appendTestEvent(topic, %*{"key": "x", "n": 2})

    # Pump harus menyadari, menyambung ulang (pid baru), dan menandai dirinya siap lagi.
    var pulih = false
    let tenggat = epochTime() + 15.0
    while epochTime() < tenggat and not pulih:
      pulih = mainService.pumpReady() and mainService.pumpBackendPid() > 0 and
        mainService.pumpBackendPid() != pidLama
      if not pulih:
        sleep(100)
    check pulih

    # Peristiwa dari masa gangguan tetap sampai ke klien yang sudah berlangganan — tanpa klien perlu
    # menyambung ulang.
    let frame = client.nextOfType("event", 15000)
    check frame["id"].getStr() == eventId
    check frame["topic"].getStr() == topic
    check frame["payload"]["n"].getInt() == 2
    assertEventEnvelope(frame)

    # Pemeriksaan sesi berkala hidup lagi (dulu ikut mati bersama pump).
    check mainService.pumpReady()

    # Readiness realtime memakai service nyata: pump siap -> ok (O-029).
    let probe = realtimeProbe(mainService)
    check probe().len == 1
    check probe()[0].status == csOk

    # Dan klien kedua yang baru menyambung tetap dilayani setelah semua ini.
    var klienKedua = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: klienKedua.close()
    let topicKedua = uniqueTopic()
    klienKedua.sendText(subscribeJson(topicKedua, ""))
    let langganan = klienKedua.nextOfType("subscribed", 5000)
    check langganan["denied"].len == 0
    let eventIdKedua = appendTestEvent(topicKedua, %*{"key": "y", "n": 3})
    check klienKedua.nextOfType("event", 10000)["id"].getStr() == eventIdKedua

suite "realtime: izin langganan diperiksa ulang (O-046)":
  test "izin dicabut di tengah langganan → langganan ditutup, sesi tetap sah":
    izinTopikMasihAda.store(true)
    let topic = uniqueTopic()
    var client = connect("127.0.0.1", izinPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    client.sendText(subscribeJson(topic, ""))
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["topics"][0].getStr() == topic
    check subscribed["denied"].len == 0
    check izinService.connectionCount() == 1

    # Kontrol: selama izin masih ada, langganan hidup (tidak ada soket yang ditutup).
    sleep(300)
    check izinService.connectionCount() == 1

    # Izin dicabut — sesi tetap sah, jadi yang berubah hanya hak atas topiknya.
    izinTopikMasihAda.store(false)
    let frame = client.nextOfType("error", 5000)
    check frame["code"].getStr() == "REALTIME_FORBIDDEN"
    check izinService.connectionCount() == 0

    # Setelah ditutup, klien yang menyambung ulang akan ditolak saat berlangganan (bukan drop):
    # perilaku handshake tidak berubah.
    var ulang = connect("127.0.0.1", izinPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: ulang.close()
    ulang.sendText(subscribeJson(uniqueTopic(), ""))
    let lagi = ulang.nextOfType("subscribed", 5000)
    check lagi["topics"].len == 0
    check lagi["denied"].len == 1

    izinTopikMasihAda.store(true)

suite "realtime: banyak klien diputus serentak (O-049)":
  test "8 klien diputus bersamaan sambil peristiwa mengalir → server tetap melayani":
    # Penjaga regresi untuk ketergantungan pada internal Mummy: `send`/`close` dipanggil dari thread
    # pump sementara handler memakai soket yang sama. Yang dicari bukan nilai balik tertentu,
    # melainkan "tidak macet, tidak crash, dan proses tetap melayani klien baru" — sifat yang paling
    # mudah rusak saat Mummy naik versi.
    sessionMasihSah.store(true)
    let topik = uniqueTopic()
    var klien: seq[WsClient]
    for _ in 1 .. stressClients:
      var c = connect("127.0.0.1", gatedPort, EventsPath, @[("Cookie", "kran_session=uji")])
      c.sendText(subscribeJson(topik, ""))
      let subscribed = c.nextOfType("subscribed", 5000)
      check subscribed["denied"].len == 0
      klien.add c
    check gatedService.connectionCount() == stressClients

    # Peristiwa mengalir **bersamaan** dengan pencabutan sesi: pump mengirim sementara soket ditutup.
    for i in 1 .. 20:
      discard appendTestEvent(topik, %*{"key": "x", "n": i})
    sessionMasihSah.store(false)

    # Semua langganan harus habis, tanpa menggantung.
    var habis = false
    let tenggat = epochTime() + 15.0
    while epochTime() < tenggat and not habis:
      habis = gatedService.connectionCount() == 0
      if not habis:
        sleep(50)
    check habis
    for c in klien.mitems:
      c.close()

    # Sesi dipulihkan **sebelum** klien baru menyambung: dengan `sessionRecheckSeconds = 0`, klien
    # yang menyambung saat sesi masih dicabut akan langsung ditutup sweep — bukan yang ingin diuji.
    sessionMasihSah.store(true)

    # Dan server masih hidup: klien baru tetap dilayani peristiwa.
    let topikBaru = uniqueTopic()
    var klienBaru = connect("127.0.0.1", gatedPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: klienBaru.close()
    klienBaru.sendText(subscribeJson(topikBaru, ""))
    let langganan = klienBaru.nextOfType("subscribed", 5000)
    check langganan["denied"].len == 0
    let eventId = appendTestEvent(topikBaru, %*{"key": "y", "n": 1})
    check klienBaru.nextOfType("event", 10_000)["id"].getStr() == eventId
    check gatedService.pumpReady()

suite "realtime: penolakan sebelum upgrade":
  test "GET tanpa Upgrade -> 426 problem+json sesuai kontrak":
    let client = newHttpClient(timeout = 5000)
    defer: client.close()
    let response = client.get("http://127.0.0.1:" & $mainPort & EventsPath)
    check response.code.int == 426
    check "application/problem+json" in response.headers["Content-Type"]
    assertProblem(426, parseJson(response.body), "UPGRADE_REQUIRED")

  test "handshake tanpa identitas sesi -> 401":
    let response = handshake("127.0.0.1", mainPort, EventsPath)
    check response.status == 401
    assertProblem(401, parseJson(response.body), "UNAUTHORIZED")

  test "identitas tanpa izin -> 403":
    let response = handshake("127.0.0.1", denyPort, EventsPath, @[("Cookie", "kran_session=uji")])
    check response.status == 403
    assertProblem(403, parseJson(response.body), "FORBIDDEN")

  test "identitas dari header Authorization: Bearer juga dikenali":
    let anonymous = handshake("127.0.0.1", denyPort, EventsPath)
    check anonymous.status == 401 # tanpa identitas sama sekali

    # Dengan Bearer identitas terbaca, jadi yang menentukan sekarang kebijakan topik (menolak 403).
    let withBearer = handshake("127.0.0.1", denyPort, EventsPath,
                               @[("Authorization", "Bearer token-uji")])
    check withBearer.status == 403

suite "realtime: peristiwa sampai ke klien":
  test "peristiwa outbox dikirim ke klien yang berlangganan topiknya":
    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    let topic = uniqueTopic()
    client.sendText(subscribeJson(topic, ""))
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["topics"][0].getStr() == topic
    check subscribed["denied"].len == 0
    check subscribed["resumed"].getInt() == 0

    let eventId = appendTestEvent(topic, %*{"key": "x", "n": 1})
    let frame = client.nextOfType("event", 10000)
    check frame["id"].getStr() == eventId
    check frame["topic"].getStr() == topic
    check frame["eventType"].getStr() == topic
    check frame["payload"]["key"].getStr() == "x"
    assertEventEnvelope(frame)

  test "topik yang ditolak dilaporkan eksplisit, bukan dibuang diam-diam":
    var client = connect("127.0.0.1", paramPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    client.sendText("""{"type":"subscribe","topics":["param.changed","audit.appended"]}""")
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["topics"].len == 1
    check subscribed["topics"][0].getStr() == "param.changed"
    check subscribed["denied"].len == 1
    check subscribed["denied"][0].getStr() == "audit.appended"

  test "pesan protokol tidak valid -> frame error dengan kode + kunci i18n":
    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    client.sendText("bukan json")
    let frame = client.nextOfType("error", 5000)
    check frame["code"].getStr() == "REALTIME_INVALID_JSON"
    check frame["i18nKey"].getStr() == "error_realtime_invalid_json"
    let problems = eventsSchema.validateValue(eventsSchema.doc["$defs"]["Error"], frame, "$")
    check problems.len == 0

  test "unsubscribe menghentikan pengiriman":
    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    let topic = uniqueTopic()
    client.sendText(subscribeJson(topic, ""))
    discard client.nextOfType("subscribed", 5000)
    client.sendText("""{"type":"unsubscribe"}""")
    let unsubscribed = client.nextOfType("subscribed", 5000)
    check unsubscribed["topics"].len == 0

    discard appendTestEvent(topic, %*{"n": 9})
    var sawEvent = false
    try:
      let frame = client.nextFrame(1500)
      sawEvent = frame{"type"}.getStr("") == "event"
    except TimeoutError:
      discard # tidak ada frame dalam batas waktu: itu yang diharapkan
    except IOError:
      discard # koneksi ditutup: juga berarti tidak ada peristiwa
    check not sawEvent

suite "realtime: resume tidak kehilangan peristiwa":
  test "reconnect dengan resumeFrom menerima peristiwa yang terlewat, berurutan":
    let topic = uniqueTopic()
    let first = appendTestEvent(topic, %*{"n": 1})
    let second = appendTestEvent(topic, %*{"n": 2})
    let third = appendTestEvent(topic, %*{"n": 3})

    # Tunggu pump (interval 250 ms) melewati peristiwa ini supaya yang diuji benar-benar jalur
    # **replay**, bukan pengiriman langsung. Tanpa jeda ini, klien bisa menerima peristiwa yang
    # sama dua kali (sekali dari replay, sekali dari pump) — dan itu bukan yang diuji di sini.
    sleep(1000)

    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    client.sendText(subscribeJson(topic, first))

    let replayed = client.nextOfType("event", 10000)
    check replayed["id"].getStr() == second
    let nextReplayed = client.nextOfType("event", 10000)
    check nextReplayed["id"].getStr() == third
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["resumed"].getInt() == 2

    # Peristiwa yang sudah diterima klien (token) tidak diulang.
    check replayed["id"].getStr() != first
    assertEventEnvelope(replayed)

  test "peristiwa yang terlewat melebihi batas replay -> resync":
    let topic = uniqueTopic()
    let anchor = appendTestEvent(topic, %*{"n": 0})
    let missed = appendTestEvent(topic, %*{"n": 1})
    discard appendTestEvent(topic, %*{"n": 2})

    var client = connect("127.0.0.1", tinyReplayPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    client.sendText(subscribeJson(topic, anchor))

    let replayed = client.nextOfType("event", 5000)
    check replayed["id"].getStr() == missed # hanya satu; batas replay = 1
    let resync = client.nextOfType("resync", 5000)
    check resync["reason"].getStr() == "replay_limit_exceeded"
    let problems = eventsSchema.validateValue(eventsSchema.doc["$defs"]["Resync"], resync, "$")
    check problems.len == 0
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["resumed"].getInt() == 1

  test "resume dengan token tak dikenal -> replay dari awal (klien de-dup by id)":
    let topic = uniqueTopic()
    let eventId = appendTestEvent(topic, %*{"n": 1})
    sleep(1000) # pump sudah melewatinya; jalur yang diuji adalah replay

    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "kran_session=uji")])
    defer: client.close()
    client.sendText(subscribeJson(topic, "00000000-0000-0000-0000-000000000000"))
    let replayed = client.nextOfType("event", 10000)
    check replayed["id"].getStr() == eventId

suite "realtime: sesi berakhir setelah handshake (O-036)":
  test "sesi dicabut → amplop error, soket ditutup, langganan dilepas":
    let topic = uniqueTopic()
    var client = connect("127.0.0.1", gatedPort, EventsPath, @[("Cookie", "kran_session=uji")])
    client.sendText(subscribeJson(topic, ""))
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["topics"][0].getStr() == topic
    check gatedService.connectionCount() == 1

    # Sesi tidak lagi sah (mis. logout/dicabut di tempat lain) — tanpa peristiwa apa pun.
    sessionMasihSah.store(false)

    let frame = client.nextOfType("error", 5000)
    check frame["code"].getStr() == "REALTIME_SESSION_ENDED"
    check frame["i18nKey"].getStr() == "error_unauthorized"
    # close frame: `nextText` mengembalikan "" untuk opcode 8.
    check client.nextText(5000).len == 0
    check gatedService.connectionCount() == 0

    # Kembalikan keadaan supaya test lain (bila ada) tidak terpengaruh.
    sessionMasihSah.store(true)
    client.close()

# ---------------------------------------------------------------------------------------------
# Readiness `/readyz`: migrasi + lag outbox (O-019)
# ---------------------------------------------------------------------------------------------

proc pendingMigrationRoot(caseName: string): string =
  ## Akar repo palsu berisi satu migrasi **expand** yang tidak ada di `platform.schema_migration`
  ## → probe migrasi harus melihatnya sebagai tertunda.
  result = ".build/itapi-ws-" & caseName
  if dirExists(result):
    removeDir(result)
  createDir(result / "modules" / "hello" / "migrations")
  writeFile(result / "modules" / "hello" / "migrations" / "0001_fake.sql", "SELECT 1;\n")

proc readyzOf(port: int): tuple[code: int; body: JsonNode] =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  let response = client.get("http://127.0.0.1:" & $port & "/readyz")
  result.code = response.code.int
  result.body = parseJson(response.body)

suite "readyz: migrasi & lag outbox (O-019)":
  test "migrasi terpasang sesuai repo -> probe ok":
    let probe = migrationProbe(dbPool, ".")
    check probe().len == 1
    check probe()[0].name == "migrations"
    check probe()[0].status == csOk

  test "migrasi expand tertunda -> probe failed":
    let root = pendingMigrationRoot("mig-pending")
    defer: removeDir(root)
    let probe = migrationProbe(dbPool, root)
    check probe().len == 1
    check probe()[0].status == csFailed
    check probe()[0].detail.contains("hello/0001_fake")

  test "akar migrasi tidak tersedia -> probe ok + detail eksplisit":
    let probe = migrationProbe(dbPool, ".build/itapi-ws-akar-tidak-ada")
    check probe().len == 1
    check probe()[0].status == csOk
    check probe()[0].detail.len > 0

  test "/readyz: migrasi expand tertunda -> 503; bersih -> 200":
    let root = pendingMigrationRoot("mig-http")
    defer: removeDir(root)

    let portBad = startServer(nil, migrationProbe(dbPool, root))
    waitUntilServing(portBad)
    let bad = readyzOf(portBad)
    check bad.code == 503
    check bad.body["status"].getStr() == "degraded"
    var foundFailed = false
    for checkItem in bad.body["checks"]:
      if checkItem["name"].getStr() == "migrations":
        foundFailed = true
        check checkItem["status"].getStr() == "failed"
    check foundFailed

    let portOk = startServer(nil, migrationProbe(dbPool, "."))
    waitUntilServing(portOk)
    let ok = readyzOf(portOk)
    check ok.code == 200
    check ok.body["status"].getStr() == "ok"

  test "lag outbox di bawah ambang -> probe ok (pump hidup)":
    let probe = pumpLagProbe(mainService, dbPool)
    check probe().len == 1
    check probe()[0].name == "outbox"
    check probe()[0].status == csOk

  test "lag outbox: pump macet + peristiwa tertua lewat ambang -> /readyz 503":
    # Konsumen macet ditiru secara deterministik: pump dinyalakan (menetapkan kursor ke titik mulai),
    # lalu **dihentikan** sebelum peristiwa tertua ditulis — jadi lag benar-benar terukur, tanpa
    # bergantung pada balapan waktu antara tulis dan putaran pump.
    #
    # Uji ini sengaja **terakhir** di suite: ia menulis lalu menghapus baris outbox, dan baris yang
    # dihapus bisa jadi kursor pump yang sedang hidup. `oldestUndeliveredSeconds` memperlakukan token
    # tak dikenal sebagai "dari awal" (sama seperti `fetchAfter`), jadi uji probe sehat harus
    # berjalan sebelum baris mana pun dihapus.
    let baseId = newId(sysClock)
    db.exec(sql"""INSERT INTO platform.outbox
                    (outbox_id, event_type, aggregate_type, aggregate_id, payload, dedup_key)
                  VALUES (?, 'test.lag.base', 'test', 'x', '{}'::jsonb, ?)""",
            $baseId, "itapi-lag-base-" & $baseId)
    let svc = newEventService(TopicPolicy(canOpen: allowOpen, allowedTopics: allowTopics,
                                          sessionValid: allowSession), dbPool)
    startPump(svc)
    waitForPump(svc)
    check svc.pumpCursor().len > 0
    svc.stopPump()
    let stopDeadline = epochTime() + 5.0
    while epochTime() < stopDeadline and svc.pumpReady():
      sleep(20)
    # Beri jeda supaya putaran pump terakhir benar-benar selesai membaca sebelum peristiwa ditulis.
    sleep(50)

    let oldId = newId(sysClock)
    try:
      db.exec(sql"""INSERT INTO platform.outbox
                      (outbox_id, occurred_at, event_type, aggregate_type, aggregate_id, payload,
                       dedup_key)
                    VALUES (?, now() - interval '2 minutes', 'test.lag.old', 'test', 'x',
                            '{}'::jsonb, ?)""",
              $oldId, "itapi-lag-old-" & $oldId)
      let port = startServer(nil, pumpLagProbe(svc, dbPool, thresholdSeconds = 30))
      waitUntilServing(port)
      let resp = readyzOf(port)
      check resp.code == 503
      check resp.body["status"].getStr() == "degraded"
      check resp.body["checks"][0]["name"].getStr() == "outbox"
      check resp.body["checks"][0]["status"].getStr() == "failed"
    finally:
      db.exec(sql"DELETE FROM platform.outbox WHERE outbox_id IN (?, ?)", $baseId, $oldId)
