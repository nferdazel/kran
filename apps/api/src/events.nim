## Endpoint realtime: `GET /api/v1/events/stream` (WebSocket) — spec §19.1, ADR-002/D-019.
##
## Alur satu koneksi:
##   1. `openStream` (handler rute, thread Mummy): cek `Upgrade: websocket`, ambil identitas sesi,
##      tanyakan kebijakan topik (`TopicPolicy`), lalu `upgradeToWebSocket()` dan daftarkan koneksi.
##   2. Klien mengirim `{"type":"subscribe","topics":[...],"resumeFrom":"<id>"}`.
##      Topik difilter otorisasi per langganan (`splitAllowed`) — permintaan `*` tidak otomatis
##      diizinkan; yang ditolak dilaporkan di balasan `subscribed.denied`.
##   3. Pump (satu thread `LISTEN` + baca outbox) menyebarkan peristiwa baru ke langganan yang
##      cocok. Reconnect tidak kehilangan peristiwa: klien mengirim `resumeFrom` = id terakhir yang
##      ia terima, dan server memutar ulang dari outbox.
##
## Identitas koneksi: Mummy tidak mengekspos `clientId`-nya, jadi layanan ini memberi id sendiri
## (`nextId`) dan memakai `WebSocket` sebagai kunci tabel — pola yang sama dipakai Mummy untuk
## antrean event per koneksi.
##
## Kebijakan default (`denyPolicy`) **menolak semua**: sampai sesi nyata terpasang (T-012),
## endpoint ini tidak bisa dipakai siapa pun — tertutup lebih baik daripada terbuka.
##
## Kontrak amplop pesan: `packages/contracts/events/realtime-envelope.v1.schema.json`.

import std/[atomics, json, locks, monotimes, strutils, tables, times]

import mummy
import db_connector/db_postgres

import kernel/result
import platform/application/realtime
import platform/infrastructure/[outbox_listener, outbox_repo]
import "platform-lib/db/pool"

import ./db_bridge
import ./identity
import ./problem

export identity

const
  ## Batas pesan langganan (pertahanan protokol, bukan parameter bisnis): 32 topik per langganan,
  ## panjang topik maksimum 128 karakter. Diberikan ke lapisan application lewat
  ## `SubscriptionLimits` supaya nilainya tidak menjadi literal di sana (spec §10.4).
  subscriptionLimits* = SubscriptionLimits(maxTopics: 32, maxTopicLen: 128)
  ## Jeda tunggu notifikasi per putaran pump (ms); juga interval pemulihan bila notifikasi hilang.
  pumpPollMs* = 250
  ## Interval pemeriksaan ulang sesi per klien (detik) — satu query sesi per klien per interval.
  ## Nilai **teknis** (O-036): sesi bisa dicabut/kedaluwarsa setelah handshake, dan soket yang sudah
  ## terbuka tidak boleh terus menerima peristiwa. Bukan ambang bisnis; dicatat supaya bisa diukur
  ## dan diubah bila jumlah klien bertambah.
  defaultSessionRecheckSeconds* = 5

type
  TopicPolicy* = object
    ## Otorisasi realtime. Dua fase karena informasinya tersedia di waktu berbeda: keanggotaan
    ## stream diketahui saat handshake, topik yang diminta baru diketahui setelah klien
    ## mengirim pesan `subscribe`.
    canOpen*: proc(identity: string): bool {.gcsafe.}
    allowedTopics*: proc(identity: string, requested: seq[string]): seq[string] {.gcsafe.}
    sessionValid*: proc(identity: string): bool {.gcsafe.}
      ## Diperiksa **berkala** oleh pump, bukan sekali saat handshake: sesi bisa dicabut atau
      ## kedaluwarsa di tengah umur koneksi (O-036). Wajib ada (bukan opsional) supaya tidak ada
      ## jalur yang lupa mengisinya.

  ConnectionState = object
    id*: uint64
    identity*: string
    topics*: seq[string]
    lastSessionCheck*: MonoTime ## kapan sesi terakhir diperiksa (pump, berkala)

  EventService* = ref object
    ## Bidang yang disentuh lebih dari satu thread dilindungi `lock`; `lastEventId` hanya pump.
    hub: Hub
    lock: Lock
    nextId: uint64
    streams: Table[WebSocket, ConnectionState] ## kunci soket → keadaan koneksi
    sockets: Table[uint64, WebSocket]          ## id layanan → soket (untuk mengirim dari pump)
    policy: TopicPolicy
    pool: DbPool
    lastEventId: string
    resumeLimit: int
    maxResumeBatches: int
    sessionRecheckSeconds: int                 ## interval periksa ulang sesi per klien (detik)
    running: Atomic[bool]
    ready: Atomic[bool] ## pump sudah LISTEN + menentukan titik mulai (dipakai uji & diagnostik)
    pumping: bool                              ## hanya dibaca/ditulis saat start (satu thread)
    pump: Thread[EventService]

# ---------------------------------------------------------------------------------------------
# Kebijakan default
# ---------------------------------------------------------------------------------------------

proc denyOpen(identity: string): bool {.gcsafe.} =
  discard identity
  false

proc denyTopics(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  discard requested
  @[]

proc denySession(identity: string): bool {.gcsafe.} =
  discard identity
  false

proc allowSession(identity: string): bool {.gcsafe.} =
  discard identity
  true

proc denyPolicy*(): TopicPolicy =
  ## Belum ada sesi nyata (T-012) → tidak ada identitas yang boleh membuka stream.
  TopicPolicy(canOpen: denyOpen, allowedTopics: denyTopics, sessionValid: denySession)

proc allowAllPolicy*(): TopicPolicy =
  ## Semua identitas non-anonim boleh membuka stream dan berlangganan topik apa pun.
  ## Dipakai **hanya** oleh uji transport; bukan konfigurasi default.
  proc allowOpen(identity: string): bool {.gcsafe.} =
    identity.len > 0

  proc allowTopics(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
    discard identity
    requested

  TopicPolicy(canOpen: allowOpen, allowedTopics: allowTopics, sessionValid: allowSession)

# ---------------------------------------------------------------------------------------------
# Identitas & header
# ---------------------------------------------------------------------------------------------

proc hasToken(value, token: string): bool =
  ## Token daftar header (`Connection: keep-alive, Upgrade`), tidak peduli huruf besar/kecil.
  for part in value.split(','):
    if cmpIgnoreCase(part.strip(), token) == 0:
      return true
  false

proc newEventService*(policy: TopicPolicy, pool: DbPool, resumeLimit = 200,
                      maxResumeBatches = 10,
                      sessionRecheckSeconds = defaultSessionRecheckSeconds): EventService =
  ## `resumeLimit` = peristiwa per putaran replay; `maxResumeBatches` = batas putaran sebelum
  ## klien diminta mulai dari awal (lihat `replayTo`); `sessionRecheckSeconds` = interval periksa
  ## ulang sesi (uji memakai nilai kecil/0 supaya tidak menunggu).
  if policy.sessionValid.isNil:
    # Gagal keras di sini, bukan crash senyap saat pump memeriksa sesi: tipe tidak bisa memaksa
    # closure terisi, dan lupa mengisinya = lubang O-036 kembali terbuka tanpa jejak.
    raise newException(ValueError, "TopicPolicy.sessionValid wajib diisi (lihat O-036)")
  new(result)
  result.hub = newHub()
  initLock(result.lock)
  result.streams = initTable[WebSocket, ConnectionState]()
  result.sockets = initTable[uint64, WebSocket]()
  result.policy = policy
  result.pool = pool
  result.resumeLimit = max(1, resumeLimit)
  result.maxResumeBatches = max(1, maxResumeBatches)
  result.sessionRecheckSeconds = max(0, sessionRecheckSeconds)
  result.running.store(false)
  result.ready.store(false)

proc connectionCount*(svc: EventService): int =
  withLock svc.lock:
    result = svc.streams.len

proc topicsOf*(svc: EventService, clientId: uint64): seq[string] =
  withLock svc.lock:
    if svc.sockets.hasKey(clientId) and svc.streams.hasKey(svc.sockets[clientId]):
      result = svc.streams[svc.sockets[clientId]].topics

proc sendMessage(svc: EventService, clientId: uint64, node: JsonNode) =
  ## Ambil soket di dalam lock, kirim di luarnya: `send` sudah aman antar-thread (Mummy memakai
  ## antrean berlokasi), dan menahan lock saat I/O hanya membuat pump & handler saling menunggu.
  var socket: WebSocket
  var found = false
  withLock svc.lock:
    if svc.sockets.hasKey(clientId):
      socket = svc.sockets[clientId]
      found = true
  if found:
    socket.send($node)

proc fetchBatch(svc: EventService, token: string): seq[RealtimeEvent] =
  withDbConn(svc.pool, proc(db: DbConn): seq[RealtimeEvent] {.gcsafe.} =
    eventsAfter(db, token, svc.resumeLimit))

proc replayTo(svc: EventService, clientId: uint64, resumeFrom: string,
              topics: seq[string]): tuple[resumed: int, resync: bool] =
  ## Putar ulang peristiwa yang terlewat setelah `resumeFrom`. Dibatasi `maxResumeBatches` putaran;
  ## kalau masih ada sisa, klien diminta mulai dari awal (`resync`) daripada menahan koneksi terlalu
  ## lama sambil membanjiri soket.
  var token = resumeFrom
  for _ in 0 ..< svc.maxResumeBatches:
    let batch = svc.fetchBatch(token)
    if batch.len == 0:
      return
    for event in batch:
      if matches(topics, event.topic):
        svc.sendMessage(clientId, encodeEvent(event.outbound()))
        inc result.resumed
      token = event.eventId
    if batch.len < svc.resumeLimit:
      return
  result.resync = true

proc handleSubscription(svc: EventService, socket: WebSocket, identity: string,
                        subscription: Subscription): JsonNode =
  var clientId = 0'u64
  withLock svc.lock:
    if svc.streams.hasKey(socket):
      clientId = svc.streams[socket].id

  if subscription.kind == skUnsubscribe:
    withLock svc.lock:
      if svc.streams.hasKey(socket):
        svc.streams[socket].topics = @[]
      svc.hub.subscribe($clientId, @[]) # hub tanpa topik = tidak menerima apa pun
    return encodeSubscribed(@[], @[], 0, svc.resumeLimit)

  let allowed = svc.policy.allowedTopics(identity, subscription.topics)
  let split = splitAllowed(subscription.topics, allowed)
  withLock svc.lock:
    if svc.streams.hasKey(socket):
      svc.streams[socket].topics = split.granted
    # Hub adalah yang menyaring saat pump menyebar; kalau langganan di hub tidak ikut
    # diperbarui, topik yang "disetujui" tidak menghasilkan peristiwa apa pun.
    svc.hub.subscribe($clientId, split.granted)
  var resumed = 0
  if subscription.resumeFrom.len > 0 and split.granted.len > 0:
    let replay = svc.replayTo(clientId, subscription.resumeFrom, split.granted)
    resumed = replay.resumed
    if replay.resync:
      # Kehilangan terlalu banyak: klien harus menyegarkan keadaan lewat HTTP lalu mulai lagi.
      svc.sendMessage(clientId, encodeResync("replay_limit_exceeded"))
  encodeSubscribed(split.granted, split.denied, resumed, svc.resumeLimit)

proc forget(svc: EventService, socket: WebSocket) =
  withLock svc.lock:
    if svc.streams.hasKey(socket):
      let clientId = svc.streams[socket].id
      svc.sockets.del(clientId)
      svc.streams.del(socket)
      svc.hub.unsubscribe($clientId)

proc dropClient(svc: EventService, clientId: uint64, code, i18nKey: string) =
  ## Amplop `error` lalu tutup soket. Klien menerjemahkan `i18nKey`, dan penutupan memicu
  ## pemeriksaan sesi di sisi klien (`realtime.ts handleClose` → `/auth/session` 401 → kembali ke
  ## login), sehingga soket yang sesinya berakhir tidak berputar-ulang menyambung tanpa akhir.
  svc.sendMessage(clientId, encodeError(code, i18nKey))
  # `WebSocket` adalah object (bukan ref), jadi "ada/tidak" dilacak eksplisit.
  var socket: WebSocket
  var ada = false
  withLock svc.lock:
    if svc.sockets.hasKey(clientId):
      socket = svc.sockets[clientId]
      ada = true
  if ada:
    socket.close() # aman dari thread lain: Mummy memasukkan close frame ke antrean kirim
    svc.forget(socket)

proc sweepSessions(svc: EventService) =
  ## Sesi bisa dicabut atau kedaluwarsa **setelah** handshake. Tanpa pemeriksaan berkala, soket yang
  ## sudah terbuka terus menerima peristiwa sampai klien menutupnya sendiri (O-036).
  ##
  ## Tiap klien diperiksa paling sering sekali per `sessionRecheckSeconds` (bukan setiap peristiwa),
  ## dan pemeriksaan dijalankan **di luar lock** supaya I/O DB tidak menahan hub. Penilaian memakai
  ## kebijakan yang sama dengan handshake (`canOpen`) supaya definisi "identitas sah" hanya satu.
  ## Catatan skala: satu pemeriksaan = satu resolusi principal (beberapa query); bila jumlah klien
  ## nyata bertambah besar, cache principal berumur pendek adalah langkah berikutnya.
  var candidates: seq[tuple[clientId: uint64, identity: string]]
  withLock svc.lock:
    for clientId, socket in svc.sockets:
      if not svc.streams.hasKey(socket):
        continue
      let state = svc.streams[socket]
      if state.identity.len == 0:
        continue
      if (getMonoTime() - state.lastSessionCheck).inSeconds < svc.sessionRecheckSeconds:
        continue
      svc.streams[socket].lastSessionCheck = getMonoTime()
      candidates.add (clientId, state.identity)
  for candidate in candidates: # nimpretty-ignore: gaya destructuring tuple
    var sah = true
    try:
      sah = svc.policy.sessionValid(candidate.identity)
    except CatchableError:
      # Gagal memverifikasi (DB/pool sedang bermasalah) **bukan** alasan memutus langganan atau
      # mematikan pump: soket dibiarkan, pemeriksaan diulang pada interval berikutnya. Pemadaman DB
      # tetap terlihat dari jalur lain, sebab pump juga membaca tabel (O-029).
      continue
    if not sah:
      svc.dropClient(candidate.clientId, "REALTIME_SESSION_ENDED", "error_unauthorized")

proc onWebSocketEvent(svc: EventService, socket: WebSocket, event: WebSocketEvent,
                      message: Message) {.gcsafe.} =
  case event
  of OpenEvent:
    discard # menunggu pesan `subscribe`
  of MessageEvent:
    var clientId = 0'u64
    var identity = ""
    withLock svc.lock:
      if svc.streams.hasKey(socket):
        clientId = svc.streams[socket].id
        identity = svc.streams[socket].identity
    if message.kind != TextMessage:
      svc.sendMessage(clientId,
                      encodeError("REALTIME_UNSUPPORTED_FRAME", "error_realtime_unsupported_frame"))
      return
    let parsed = decodeSubscription(message.data, subscriptionLimits)
    if parsed.isErr:
      svc.sendMessage(clientId, encodeError(parsed.error.code, parsed.error.i18nKey))
      return
    svc.sendMessage(clientId, svc.handleSubscription(socket, identity, parsed.value))
  of ErrorEvent, CloseEvent:
    svc.forget(socket)

proc websocketHandler*(svc: EventService): WebSocketHandler =
  ## Satu handler untuk semua koneksi; Mummy mengirim event per koneksi secara serial.
  return proc(socket: WebSocket, event: WebSocketEvent, message: Message) {.gcsafe.} =
    svc.onWebSocketEvent(socket, event, message)

proc openStream*(svc: EventService, req: Request) {.gcsafe.} =
  ## Handler rute `GET /api/v1/events/stream`.
  if not hasToken(req.headers["Connection"], "upgrade") or
     not hasToken(req.headers["Upgrade"], "websocket"):
    req.respondProblem(pkUpgradeRequired, "Upgrade Required",
      "endpoint ini hanya menerima WebSocket (Upgrade: websocket)")
    return

  let identity = identityFromRequest(req)
  if identity.len == 0:
    req.respondProblem(pkUnauthorized, "Unauthorized", "identitas sesi tidak ditemukan")
    return
  if not svc.policy.canOpen(identity):
    req.respondProblem(pkForbidden, "Forbidden", "identitas ini tidak diizinkan membuka stream")
    return

  let socket = req.upgradeToWebSocket()
  withLock svc.lock:
    svc.nextId += 1
    let clientId = svc.nextId
    svc.streams[socket] = ConnectionState(id: clientId, identity: identity,
      lastSessionCheck: getMonoTime())
    svc.sockets[clientId] = socket
    svc.hub.subscribe($clientId, @[]) # belum ada topik sampai klien mengirim `subscribe`

# ---------------------------------------------------------------------------------------------
# Pump: outbox → hub → klien
# ---------------------------------------------------------------------------------------------

proc stillSubscribed(svc: EventService, clientId: uint64, topic: string): bool =
  ## Rencana kirim dibuat di dalam lock, tetapi `unsubscribe` bisa datang setelahnya.
  ## Periksa ulang tepat sebelum menulis ke soket supaya klien yang sudah berhenti berlangganan
  ## tidak menerima peristiwa susulan.
  withLock svc.lock:
    if svc.sockets.hasKey(clientId) and svc.streams.hasKey(svc.sockets[clientId]):
      result = matches(svc.streams[svc.sockets[clientId]].topics, topic)

proc dispatch(svc: EventService, events: seq[RealtimeEvent]) =
  var plan: seq[Delivery]
  withLock svc.lock:
    plan = svc.hub.fanout(events)
    svc.lastEventId = events[^1].eventId
  for delivery in plan:
    try:
      let clientId = parseBiggestUInt(delivery.subscriberId)
      if svc.stillSubscribed(clientId, delivery.message.topic):
        svc.sendMessage(clientId, encodeEvent(delivery.message))
    except ValueError:
      discard # id langganan selalu berasal dari `nextId`; ini hanya jaring pengaman

proc pumpLoop(svc: EventService) {.thread, gcsafe.} =
  ## Satu koneksi LISTEN + baca tabel. `LISTEN` terikat koneksi, jadi koneksi ini dipinjam untuk
  ## seumur pump (bukan per query).
  try:
    let db = svc.pool.acquire()
    listenOutbox(db)
    # Titik mulai: peristiwa terakhir yang sudah ada. Backlog lama tidak disemprotkan ke klien
    # baru; klien yang butuh riwayat memintanya lewat `resumeFrom` atau HTTP.
    svc.lastEventId = latestEventId(db)
    svc.ready.store(true)
    while svc.running.load():
      discard pollOutbox(db, timeoutMs = pumpPollMs)
      let fetched = eventsAfter(db, svc.lastEventId, svc.resumeLimit)
      if fetched.len > 0:
        svc.dispatch(fetched)
      svc.sweepSessions()
    svc.ready.store(false)
  except CatchableError:
    # Pump mati: stream tidak lagi mendorong peristiwa, tetapi proses tetap melayani HTTP dan
    # klien yang reconnect akan memutar ulang dari outbox (docs/OPEN_ITEMS.md O-029).
    svc.ready.store(false)

proc startPump*(svc: EventService) =
  ## Menyalakan pump. Idempoten; tanpa pool (DB belum dikonfigurasi) tidak melakukan apa pun.
  if svc.pool.isNil or svc.pumping:
    return
  svc.pumping = true
  svc.running.store(true)
  createThread(svc.pump, pumpLoop, svc)

proc pumpReady*(svc: EventService): bool =
  ## True setelah pump menyalakan LISTEN dan menetapkan titik mulai: peristiwa yang dibuat
  ## **sesudah** ini akan dialirkan langsung. Sebelum itu, peristiwa terbaru dianggap riwayat
  ## (klien memintanya lewat `resumeFrom`) — jadi uji yang bergantung pada pengiriman langsung
  ## harus menunggu sinyal ini, bukan menebak lewat `sleep`.
  svc.ready.load()

proc stopPump*(svc: EventService) =
  ## Hanya untuk uji: pump berhenti dalam ≤ `pumpPollMs`.
  svc.running.store(false)
