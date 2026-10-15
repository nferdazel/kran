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

import std/[atomics, json, locks, monotimes, os, strutils, tables, times]

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

  ## Backoff penyambungan ulang pump setelah koneksinya putus (O-029): mulai kecil supaya gangguan
  ## sekejap pulih cepat, dibatasi supaya DB yang benar-benar mati tidak dibombardir.
  pumpReconnectMinMs* = 250
  pumpReconnectMaxMs* = 5_000
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
    pumpPid: Atomic[int]                       ## pid backend koneksi pump (diagnostik + uji pemutusan koneksi)
    pumpStartedNs: Atomic[int64]               ## waktu pump mulai (ns monotonik); 0 = belum pernah dijalankan
    pumpLastReadyNs: Atomic[int64]             ## waktu pump terakhir siap (ns monotonik); 0 = belum pernah
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

proc monoNs(): int64 =
  ## Waktu monotonik (ns). Tahan terhadap perubahan jam sistem, dan cukup untuk mengukur "sudah
  ## berapa lama pump tidak siap".
  getMonoTime().ticks

proc pumpDegradedSeconds*(svc: EventService): int64 =
  ## `0` = pump siap; `-1` = pump memang tidak dijalankan (realtime tidak aktif); `> 0` = sudah berapa
  ## detik pump tidak siap. Dipakai readiness (O-029) supaya realtime yang mati terlihat operator,
  ## tanpa membuat gangguan penyambungan ulang sekejap mencabut instance dari trafik.
  if svc.pumpStartedNs.load() == 0:
    return -1
  if svc.ready.load():
    return 0
  let sejak = max(svc.pumpStartedNs.load(), svc.pumpLastReadyNs.load())
  (monoNs() - sejak) div 1_000_000_000

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
  ##
  ## **Ketergantungan yang tidak dijanjikan API publik** (O-049): `WebSocket.send` dipanggil dari
  ## thread lain (pump) sementara handler Mummy memakai soket yang sama; yang membuatnya aman adalah
  ## antrean kirim per koneksi itu. Bila Mummy menaikkan versi minor, uji di
  ## `apps/api/tests/itapi_ws.nim` (suite "banyak klien diputus serentak") wajib dijalankan lebih
  ## dulu — lihat daftar periksa upgrade di docs/DECISIONS.md (D-037).
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
  ##
  ## **Ketergantungan yang tidak dijanjikan API publik** (O-049): `WebSocket.close` di sini dipanggil
  ## dari thread pump/handler, bukan dari thread yang memegang koneksi itu. Aman pada Mummy 0.4.8
  ## (close frame dimasukkan ke antrean kirim), dan `forget` setelahnya membuat pemanggilan ganda
  ## tidak menutup soket milik klien lain. Daftar periksa upgrade: docs/DECISIONS.md (D-037).
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
  ## kebijakan yang sama dengan handshake (`canOpen`, `allowedTopics`) supaya definisi "identitas sah"
  ## dan "topik boleh" hanya satu.
  ##
  ## Dua hal diperiksa, dan keduanya bisa berubah tanpa soket terputus:
  ##   1. sesi masih sah (O-036);
  ##   2. izin atas topik yang **sudah diberikan** masih ada (O-046) — tanpa ini, pencabutan izin hanya
  ##      berlaku untuk langganan berikutnya, sementara langganan yang sedang terbuka terus menerima
  ##      data yang sudah tidak boleh dilihat.
  ## Catatan skala: satu pemeriksaan = satu resolusi principal (beberapa query); bila jumlah klien
  ## nyata bertambah besar, cache principal berumur pendek adalah langkah berikutnya.
  var candidates: seq[tuple[clientId: uint64, identity: string, topics: seq[string]]]
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
      candidates.add (clientId, state.identity, state.topics)
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
      continue

    # Belum ada topik = belum ada yang bisa dicabut (klien yang seluruh langganannya ditolak tetap
    # terhubung, hanya tidak menerima apa pun — sama seperti saat handshake).
    if candidate.topics.len == 0:
      continue
    var diizinkan: seq[string]
    try:
      diizinkan = svc.policy.allowedTopics(candidate.identity, candidate.topics)
    except CatchableError:
      # Sama seperti pemeriksaan sesi: gagal memverifikasi bukan alasan memutus langganan.
      continue
    if splitAllowed(candidate.topics, diizinkan).denied.len > 0:
      # Langganan ditutup, bukan disaring per peristiwa: klien akan menyambung ulang dan
      # berlangganan ulang dengan izin yang berlaku saat itu (langganan yang tidak lagi sah tidak
      # dibiarkan hidup setengah).
      svc.dropClient(candidate.clientId, "REALTIME_FORBIDDEN", "error_forbidden")

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

proc logPump(msg: string) =
  ## Pump berjalan di thread sendiri dan modul ini tidak memegang `Logger` (itu milik `main.nim`).
  ## Satu baris ke stderr jauh lebih berguna daripada kegagalan senyap seperti sebelumnya (O-029).
  stderr.writeLine "kran-api realtime pump: " & msg

proc sleepUnlessStopped(svc: EventService, ms: int) =
  ## Tidur yang bisa dibatalkan: penutupan proses tidak boleh tertunda oleh backoff (lihat
  ## `stopPump` dan T-032 soal drain).
  var left = ms
  while left > 0 and svc.running.load():
    let step = min(left, 100)
    sleep(step)
    left -= step

proc pumpLoop(svc: EventService) {.thread, gcsafe.} =
  ## Satu koneksi LISTEN + baca tabel, **dengan penyambungan ulang** bila koneksi putus.
  ##
  ## `LISTEN` terikat koneksi, jadi koneksi dipinjam selama satu masa hidup sambungan — bukan
  ## seumur proses. Sebelum ini, kegagalan apa pun pada koneksi itu membuat pump berhenti
  ## permanen: realtime mati senyap, dan `sweepSessions` (pemeriksaan ulang sesi) ikut berhenti
  ## (O-029). Sekarang kegagalan hanya berarti "sambungan ini habis", bukan "pump selesai".
  ##
  ## Titik mulai (`lastEventId`) **hanya** ditetapkan pada sambungan pertama: kalau di-reset saat
  ## menyambung ulang, peristiwa yang terbit selama gangguan akan dianggap riwayat dan tidak pernah
  ## dikirim ke klien yang sudah berlangganan.
  var backoff = pumpReconnectMinMs
  var firstConnect = true
  while svc.running.load():
    var db: DbConn = nil
    try:
      db = svc.pool.acquire()
      listenOutbox(db)
      svc.pumpPid.store(parseInt(db.getValue(sql"select pg_backend_pid()")))
      if firstConnect:
        # Backlog lama tidak disemprotkan ke klien baru; klien yang butuh riwayat memintanya lewat
        # `resumeFrom` atau HTTP.
        svc.lastEventId = latestEventId(db)
        firstConnect = false
      svc.ready.store(true)
      svc.pumpLastReadyNs.store(monoNs())
      if backoff > pumpReconnectMinMs:
        logPump("tersambung lagi")
      backoff = pumpReconnectMinMs
      while svc.running.load():
        discard pollOutbox(db, timeoutMs = pumpPollMs)
        let fetched = eventsAfter(db, svc.lastEventId, svc.resumeLimit)
        if fetched.len > 0:
          svc.dispatch(fetched)
        svc.sweepSessions()
    except CatchableError as e:
      logPump("koneksi terputus (" & e.msg & "); menyambung ulang dalam " & $backoff & " ms")
    finally:
      svc.ready.store(false)
      if not db.isNil:
        try:
          svc.pool.release(db)
        except CatchableError:
          discard # koneksi sudah mati; pool membuang yang mati saat diambil lagi
    if svc.running.load():
      sleepUnlessStopped(svc, backoff)
      backoff = min(backoff * 2, pumpReconnectMaxMs)

proc startPump*(svc: EventService) =
  ## Menyalakan pump. Idempoten; tanpa pool (DB belum dikonfigurasi) tidak melakukan apa pun.
  if svc.pool.isNil or svc.pumping:
    return
  svc.pumping = true
  svc.running.store(true)
  svc.pumpStartedNs.store(monoNs())
  createThread(svc.pump, pumpLoop, svc)

proc pumpBackendPid*(svc: EventService): int =
  ## Pid backend koneksi pump saat ini (0 bila pump belum pernah tersambung). Dipakai uji yang
  ## memutus koneksinya paksa, dan untuk menelusuri masalah di server.
  svc.pumpPid.load()

proc pumpReady*(svc: EventService): bool =
  ## True setelah pump menyalakan LISTEN dan menetapkan titik mulai: peristiwa yang dibuat
  ## **sesudah** ini akan dialirkan langsung. Sebelum itu, peristiwa terbaru dianggap riwayat
  ## (klien memintanya lewat `resumeFrom`) — jadi uji yang bergantung pada pengiriman langsung
  ## harus menunggu sinyal ini, bukan menebak lewat `sleep`.
  svc.ready.load()

proc stopPump*(svc: EventService) =
  ## Hanya untuk uji: pump berhenti dalam ≤ `pumpPollMs`.
  svc.running.store(false)
