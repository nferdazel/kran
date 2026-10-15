## Test integrasi endpoint realtime `GET /api/v1/events/stream` (butuh `CBS_DATABASE_URL`).
##
## Kriteria T-009: peristiwa dari outbox sampai ke **klien** dan reconnect tidak kehilangan
## peristiwa. Jadi di sini dibuktikan jalur penuh: INSERT outbox → trigger NOTIFY (migration 0007)
## → pump → hub → frame WebSocket → klien TCP nyata (klien WS minimal di `wsclient.nim`).
##
## Diuji juga jalur penolakan (426 tanpa upgrade, 401 tanpa identitas, 403 tanpa izin), pelaporan
## topik yang ditolak, dan `resync` ketika peristiwa yang terlewat melebihi batas replay.
##
## Test ini **tidak** mengubah schema (migrasi dijalankan lewat runner resmi) dan hanya menambah
## baris outbox dengan `dedup_key` unik, jadi aman dijalankan berulang di `cbs_dev`.

import std/[httpclient, json, net, os, random, strutils, times, unittest]

import db_connector/db_postgres
import mummy

import dbtools/lib
import kernel/[clock, ids]
import openapi/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"
import platform/domain/event
import platform/infrastructure/[outbox_listener, outbox_repo]

import ../src/[context, events, server]
import ./wsclient

const
  ContractPath = "packages/contracts/openapi/cbs-api.yaml"
  EventsSchemaPath = "packages/contracts/events/realtime-envelope.v1.schema.json"
  EventsPath = "/api/v1/events/stream"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_ws: CBS_DATABASE_URL kosong — dilewati"
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

proc startServer(service: EventService): int =
  let port = freePort()
  let server = newApiServer(AppContext(version: "itapi-ws-0.0.0", role: "api",
                                       startedAt: epochTime(), events: service))
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

proc denyTopics(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  discard requested
  @[]

proc allowOpen(identity: string): bool {.gcsafe.} =
  identity.len > 0

proc allowTopics(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  requested

proc allowSession(identity: string): bool {.gcsafe.} =
  discard identity
  true

## Sesi yang bisa "dicabut" dari test (O-036): pump memeriksa lewat closure ini.
var sessionMasihSah = true
proc gatedSession(identity: string): bool {.gcsafe.} =
  discard identity
  sessionMasihSah

proc paramTopicsOnly(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  for topic in requested:
    if topic == "param.changed":
      result.add topic

# --- layanan & server ---------------------------------------------------------------------------

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
discard applyMigrations(db, ".")
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

proc uniqueTopic(): string =
  "test.realtime." & $epochTime() & "." & $rand(1_000_000)

proc appendTestEvent(eventType: string, payload: JsonNode): string =
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

proc assertProblem(status: int, body: JsonNode, expectedCode: string) =
  let problems = contract.validateValue(
    contract.responseSchema(EventsPath, "GET", $status, "application/problem+json"), body, "$")
  check problems.len == 0
  check body["code"].getStr() == expectedCode
  check body["i18nKey"].getStr() == "error_" & expectedCode.toLowerAscii()

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
    let response = handshake("127.0.0.1", denyPort, EventsPath, @[("Cookie", "cbs_session=uji")])
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
    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "cbs_session=uji")])
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
    var client = connect("127.0.0.1", paramPort, EventsPath, @[("Cookie", "cbs_session=uji")])
    defer: client.close()
    client.sendText("""{"type":"subscribe","topics":["param.changed","audit.appended"]}""")
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["topics"].len == 1
    check subscribed["topics"][0].getStr() == "param.changed"
    check subscribed["denied"].len == 1
    check subscribed["denied"][0].getStr() == "audit.appended"

  test "pesan protokol tidak valid -> frame error dengan kode + kunci i18n":
    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "cbs_session=uji")])
    defer: client.close()
    client.sendText("bukan json")
    let frame = client.nextOfType("error", 5000)
    check frame["code"].getStr() == "REALTIME_INVALID_JSON"
    check frame["i18nKey"].getStr() == "error_realtime_invalid_json"
    let problems = eventsSchema.validateValue(eventsSchema.doc["$defs"]["Error"], frame, "$")
    check problems.len == 0

  test "unsubscribe menghentikan pengiriman":
    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "cbs_session=uji")])
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

    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "cbs_session=uji")])
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

    var client = connect("127.0.0.1", tinyReplayPort, EventsPath, @[("Cookie", "cbs_session=uji")])
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

    var client = connect("127.0.0.1", mainPort, EventsPath, @[("Cookie", "cbs_session=uji")])
    defer: client.close()
    client.sendText(subscribeJson(topic, "00000000-0000-0000-0000-000000000000"))
    let replayed = client.nextOfType("event", 10000)
    check replayed["id"].getStr() == eventId

suite "realtime: sesi berakhir setelah handshake (O-036)":
  test "sesi dicabut → amplop error, soket ditutup, langganan dilepas":
    let topic = uniqueTopic()
    var client = connect("127.0.0.1", gatedPort, EventsPath, @[("Cookie", "cbs_session=uji")])
    client.sendText(subscribeJson(topic, ""))
    let subscribed = client.nextOfType("subscribed", 5000)
    check subscribed["topics"][0].getStr() == topic
    check gatedService.connectionCount() == 1

    # Sesi tidak lagi sah (mis. logout/dicabut di tempat lain) — tanpa peristiwa apa pun.
    sessionMasihSah = false

    let frame = client.nextOfType("error", 5000)
    check frame["code"].getStr() == "REALTIME_SESSION_ENDED"
    check frame["i18nKey"].getStr() == "error_unauthorized"
    # close frame: `nextText` mengembalikan "" untuk opcode 8.
    check client.nextText(5000).len == 0
    check gatedService.connectionCount() == 0

    # Kembalikan keadaan supaya test lain (bila ada) tidak terpengaruh.
    sessionMasihSah = true
    client.close()
