## Hub realtime (spec §19.1): mengubah peristiwa outbox menjadi pesan **ber-topik** untuk klien.
##
## Murni — tanpa socket, tanpa DB. Transport (WebSocket) dan sumber peristiwa (LISTEN + baca
## outbox) disuntikkan pemanggil. Konsekuensinya logika topik, resume, dan backpressure dapat
## diuji tanpa I/O, dan mengganti transport (mis. ke SSE kembali) tidak menyentuh file ini.
##
## Kontrak pesan ke klien ada di `packages/contracts/events/realtime-envelope.v1.schema.json`
## (spec §12.4: skema event didokumentasikan di `packages/contracts/events`).
##
## Resume: klien mengirim `resumeFrom` (id event terakhir yang ia terima). Transport yang
## memutar ulang dari outbox (lewat port di infrastruktur); hub hanya menyimpan
## `lastSentId` per langganan supaya klien bisa memakainya saat reconnect tanpa menyimpan sendiri.

import std/[json, sets]

import kernel/paramkey
import kernel/result

const
  WildcardTopic* = "*"

type
  RealtimeEvent* = object
    ## Satu peristiwa outbox yang siap dikirim ke klien.
    eventId*: string ## `outbox_id` (UUIDv7 → urut waktu, dipakai sebagai resume token)
    topic*: string
    eventType*: string
    occurredAt*: string
    payload*: JsonNode

  OutboundMessage* = object
    ## Amplop `type: "event"` yang dikirim ke klien.
    eventId*: string
    topic*: string
    eventType*: string
    occurredAt*: string
    payload*: JsonNode

  Delivery* = object
    subscriberId*: string
    message*: OutboundMessage

  EventScope* = object
    ## Cakupan peristiwa yang boleh diterima satu langganan (O-070, keputusan pemilik 31 Okt 2026).
    ##
    ## Hanya peristiwa yang **memang milik satu cabang** yang disaring: `param.changed` dengan
    ## `scope_type = BRANCH`. Peristiwa lain tidak punya dimensi cabang, jadi tetap disaring topiknya
    ## saja. Default kosong = tidak ada cabang yang boleh, jadi lupa mengisi cakupan menutup
    ## peristiwa ber-cabang (gagal-tertutup), bukan membocorkannya.
    institutionWide*: bool
    branchIds*: seq[string]

  Subscriber* = object
    id*: string
    topics*: seq[string]
    lastSentId*: string
    scope*: EventScope

  Hub* = object
    subscribers*: seq[Subscriber]

  SubscriptionKind* = enum
    skSubscribe = "subscribe"
    skUnsubscribe = "unsubscribe"

  Subscription* = object
    ## Pesan kontrol dari klien (di luar amplop event).
    kind*: SubscriptionKind
    topics*: seq[string]
    resumeFrom*: string

  SubscriptionLimits* = object
    ## Batas ukuran pesan langganan: pertahanan terhadap klien yang mengirim daftar raksasa
    ## (spec §18.2 permukaan serangan). Nilainya **diberikan pemanggil** (transport/konfigurasi),
    ## bukan literal di lapisan application — sejalan dengan "tidak ada nilai bisnis di kode".
    maxTopics*: int
    maxTopicLen*: int

  RealtimeError* = object
    ## Kesalahan protokol realtime: kode mesin + kunci i18n (bukan kalimat siap pakai, spec §16.1).
    ## `detail` hanya untuk log/diagnostik.
    code*: string
    i18nKey*: string
    detail*: string

proc topicFor*(eventType: string): string =
  ## Topik = jenis peristiwa (mis. `param.changed`). Satu aturan sederhana yang dapat diaudit;
  ## topik turunan (mis. `account.<id>.balance`) ditambahkan saat modulnya lahir.
  eventType

proc matches*(patterns: openArray[string], topic: string): bool =
  for pattern in patterns:
    if pattern == WildcardTopic or pattern == topic:
      return true
  false

proc newHub*(): Hub =
  ## Tanpa antrean/kuota di dalam hub: transport (Mummy) yang mengantre keluar, dan kehilangan
  ## peristiwa ditutup lewat resume token — bukan lewat buffer yang tak punya sinyal "sudah
  ## terkirim". Beban satu klien lambat dicatat di docs/OPEN_ITEMS.md O-028.
  Hub(subscribers: @[])

proc findSubscriber(hub: Hub, id: string): int =
  for i, subscriber in hub.subscribers:
    if subscriber.id == id:
      return i
  -1

proc subscribe*(hub: var Hub, id: string, topics: seq[string];
                scope = EventScope()) =
  ## Idempoten: langganan yang sama di-*update* (klien reconnect memakai id yang sama).
  ## `scope` = hasil `TopicPolicy.eventScope`; default kosong menutup peristiwa ber-cabang.
  let index = hub.findSubscriber(id)
  var entry = Subscriber(id: id, topics: topics, scope: scope)
  if index >= 0:
    entry.lastSentId = hub.subscribers[index].lastSentId
    hub.subscribers[index] = entry
  else:
    hub.subscribers.add entry

proc unsubscribe*(hub: var Hub, id: string) =
  let index = hub.findSubscriber(id)
  if index >= 0:
    hub.subscribers.delete(index)

proc subscriberCount*(hub: Hub): int =
  hub.subscribers.len

proc lastSentId*(hub: Hub, id: string): string =
  let index = hub.findSubscriber(id)
  if index >= 0: hub.subscribers[index].lastSentId else: ""

proc outbound*(event: RealtimeEvent): OutboundMessage =
  OutboundMessage(
    eventId: event.eventId,
    topic: event.topic,
    eventType: event.eventType,
    occurredAt: event.occurredAt,
    payload: event.payload,
  )

proc scopeAllows*(scope: EventScope; event: RealtimeEvent): bool =
  ## Apakah peristiwa ini boleh sampai ke langganan dengan cakupan `scope` (O-070). Aturannya
  ## searah dengan otorisasi baca: peristiwa ber-scope `BRANCH` hanya untuk pemegang izin cabang
  ## itu (atau pemegang izin tanpa batas cabang); peristiwa lain lolos karena tidak spesifik.
  if event.topic != "param.changed" or event.payload.isNil or
      event.payload.kind != JObject:
    return true
  if event.payload{"scope_type"}.getStr("") != $pstBranch:
    return true
  if scope.institutionWide:
    return true
  let branchId = event.payload{"scope_id"}.getStr("")
  branchId.len > 0 and branchId in scope.branchIds

proc fanout*(hub: var Hub, events: seq[RealtimeEvent]): seq[Delivery] =
  ## Sebar peristiwa ke langganan yang topiknya cocok (urutan peristiwa dipertahankan).
  ## Hasilnya adalah *rencana kirim*: transport yang mengeksekusi, supaya hub tetap murni.
  for event in events:
    for i in 0 ..< hub.subscribers.len:
      if not matches(hub.subscribers[i].topics, event.topic):
        continue
      if not hub.subscribers[i].scope.scopeAllows(event):
        continue
      result.add Delivery(
        subscriberId: hub.subscribers[i].id,
        message: event.outbound(),
      )
      hub.subscribers[i].lastSentId = event.eventId

proc encodeEvent*(message: OutboundMessage): JsonNode =
  ## Amplop `type: "event"` (kontrak `realtime-envelope.v1`).
  result = %*{
    "type": "event",
    "id": message.eventId,
    "topic": message.topic,
    "eventType": message.eventType,
    "occurredAt": message.occurredAt,
  }
  if not message.payload.isNil:
    result["payload"] = message.payload

proc encodeSubscribed*(topics: seq[string], denied: seq[string], resumed: int,
                       replayLimit: int): JsonNode =
  ## `denied` sengaja eksplisit: klien yang topiknya ditolak harus tahu, bukan menunggu peristiwa
  ## yang tidak akan pernah datang. `replayLimit` = jumlah peristiwa maksimum per putaran resume.
  %*{
    "type": "subscribed",
    "topics": topics,
    "denied": denied,
    "resumed": resumed,
    "replayLimit": replayLimit,
  }

proc encodeResync*(reason: string): JsonNode =
  ## Klien harus langganan ulang dengan `resumeFrom` = id terakhir yang ia terima (spec §19.2).
  %*{"type": "resync", "reason": reason}

proc encodeError*(code, i18nKey: string): JsonNode =
  ## `i18nKey` diterjemahkan frontend (spec §16.1) — bukan kalimat siap pakai.
  %*{"type": "error", "code": code, "i18nKey": i18nKey}

proc protoErr(code, i18nKey, detail: string): RealtimeError =
  RealtimeError(code: code, i18nKey: i18nKey, detail: detail)

proc decodeSubscription*(raw: string,
                        limits: SubscriptionLimits): Result[Subscription, RealtimeError] =
  ## Membaca pesan kontrol klien. Ketat: bentuk tak dikenal = error, bukan diabaikan diam-diam
  ## (klien yang salah paham harus tahu, bukan menunggu peristiwa yang tak akan datang).
  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError:
    return err[Subscription, RealtimeError](
      protoErr("REALTIME_INVALID_JSON", "error_realtime_invalid_json", "bukan JSON yang valid"))
  if node.kind != JObject or not node.hasKey("type"):
    return err[Subscription, RealtimeError](protoErr(
      "REALTIME_INVALID_MESSAGE", "error_realtime_invalid_message",
      "pesan harus objek JSON dengan properti `type`"))
  let kind = node["type"].getStr("")
  case kind
  of "subscribe":
    if not node.hasKey("topics") or node["topics"].kind != JArray:
      return err[Subscription, RealtimeError](protoErr(
        "REALTIME_INVALID_MESSAGE", "error_realtime_invalid_message",
        "subscribe wajib menyertakan `topics` bertipe array"))
    if node["topics"].len == 0:
      return err[Subscription, RealtimeError](protoErr(
        "REALTIME_INVALID_MESSAGE", "error_realtime_invalid_message",
        "subscribe wajib punya minimal satu topik"))
    if node["topics"].len > limits.maxTopics:
      return err[Subscription, RealtimeError](protoErr(
        "REALTIME_TOO_MANY_TOPICS", "error_realtime_too_many_topics",
        "terlalu banyak topik (maks " & $limits.maxTopics & ")"))
    var topics: seq[string]
    for item in node["topics"]:
      if item.kind != JString:
        return err[Subscription, RealtimeError](protoErr(
          "REALTIME_INVALID_MESSAGE", "error_realtime_invalid_message", "topik harus string"))
      let topic = item.getStr()
      if topic.len == 0 or topic.len > limits.maxTopicLen:
        return err[Subscription, RealtimeError](protoErr(
          "REALTIME_INVALID_MESSAGE", "error_realtime_invalid_message",
          "panjang topik harus 1.." & $limits.maxTopicLen & " karakter"))
      topics.add topic
    var subscription = Subscription(kind: skSubscribe, topics: topics)
    if node.hasKey("resumeFrom"):
      if node["resumeFrom"].kind != JString:
        return err[Subscription, RealtimeError](protoErr(
          "REALTIME_INVALID_MESSAGE", "error_realtime_invalid_message",
          "`resumeFrom` harus string (id event)"))
      subscription.resumeFrom = node["resumeFrom"].getStr()
    ok[Subscription, RealtimeError](subscription)
  of "unsubscribe":
    ok[Subscription, RealtimeError](Subscription(kind: skUnsubscribe))
  else:
    err[Subscription, RealtimeError](protoErr(
      "REALTIME_UNKNOWN_TYPE", "error_realtime_unknown_type", "tipe pesan tidak dikenal: " & kind))

proc splitAllowed*(requested: seq[string], allowed: seq[string]):
    tuple[granted, denied: seq[string]] =
  ## Topik yang benar-benar diizinkan: irisan permintaan dengan hasil otorisasi.
  ## Wildcard dari klien tetap harus disebut eksplisit oleh otorisasi (tidak ada wildcard implisit).
  var allowedSet = initHashSet[string]()
  for topic in allowed:
    allowedSet.incl topic
  let everythingAllowed = allowedSet.contains(WildcardTopic)
  for topic in requested:
    if allowedSet.contains(topic) or everythingAllowed:
      result.granted.add topic
    else:
      result.denied.add topic
