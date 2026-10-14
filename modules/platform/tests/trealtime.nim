import std/[json, sequtils, strutils, unittest]

import ../application/realtime
import kernel/result

## Test hub realtime murni (spec §19.1, §19.2). Tanpa socket/DB: yang diuji adalah aturan
## topik, backpressure/resync, resume token, dan bentuk pesan (amplop kontrak).

## Batas yang dipakai uji (nilainya milik pemanggil, bukan konstanta lapisan application).
const testLimits = SubscriptionLimits(maxTopics: 4, maxTopicLen: 32)

proc ev(id, topic: string, payload = "{}"): RealtimeEvent =
  RealtimeEvent(eventId: id, topic: topic, eventType: topic, occurredAt: "2026-10-14T00:00:00.000Z",
                payload: parseJson(payload))

suite "topicFor & matches":
  test "topik = jenis peristiwa":
    check topicFor("param.changed") == "param.changed"

  test "wildcard cocok dengan apa pun, topik persis cocok hanya dengan dirinya":
    check matches(@["*"], "param.changed")
    check matches(@["param.changed"], "param.changed")
    check not matches(@["param.changed"], "audit.appended")
    check not matches(@[], "param.changed")

suite "hub: langganan & fanout":
  test "hanya langganan yang cocok yang menerima":
    var hub = newHub()
    hub.subscribe("a", @["param.changed"])
    hub.subscribe("b", @["audit.appended"])
    let deliveries = hub.fanout(@[ev("e1", "param.changed")])
    check deliveries.len == 1
    check deliveries[0].subscriberId == "a"
    check deliveries[0].message.eventId == "e1"

  test "wildcard menerima semua topik":
    var hub = newHub()
    hub.subscribe("a", @["*"])
    let deliveries = hub.fanout(@[ev("e1", "param.changed"), ev("e2", "audit.appended")])
    check deliveries.len == 2

  test "urutan peristiwa dipertahankan":
    var hub = newHub()
    hub.subscribe("a", @["*"])
    let deliveries = hub.fanout(@[ev("e1", "t"), ev("e2", "t"), ev("e3", "t")])
    check deliveries.mapIt(it.message.eventId) == @["e1", "e2", "e3"]

  test "id langganan sama = update, bukan duplikat (klien reconnect)":
    var hub = newHub()
    hub.subscribe("a", @["param.changed"])
    hub.subscribe("a", @["audit.appended"])
    check hub.subscriberCount == 1
    let deliveries = hub.fanout(@[ev("e1", "param.changed"), ev("e2", "audit.appended")])
    check deliveries.len == 1
    check deliveries[0].message.topic == "audit.appended"

  test "unsubscribe menghentikan pengiriman":
    var hub = newHub()
    hub.subscribe("a", @["*"])
    hub.unsubscribe("a")
    check hub.subscriberCount == 0
    check hub.fanout(@[ev("e1", "t")]).len == 0

  test "langganan tanpa topik tidak menerima apa pun":
    var hub = newHub()
    hub.subscribe("a", @[])
    check hub.fanout(@[ev("e1", "t")]).len == 0

  test "lastSentId mengikuti peristiwa terakhir yang dikirim":
    var hub = newHub()
    hub.subscribe("a", @["*"])
    discard hub.fanout(@[ev("e1", "t"), ev("e2", "t")])
    check hub.lastSentId("a") == "e2"
    check hub.lastSentId("b") == ""

suite "decodeSubscription":
  test "subscribe valid":
    let parsed = decodeSubscription("""{"type":"subscribe","topics":["param.changed","*"]}""", testLimits)
    check parsed.isOk
    check parsed.value.kind == skSubscribe
    check parsed.value.topics == @["param.changed", "*"]
    check parsed.value.resumeFrom == ""

  test "subscribe dengan resumeFrom":
    let parsed = decodeSubscription(
      """{"type":"subscribe","topics":["*"],"resumeFrom":"0198e0d0-0000-7000-8000-000000000000"}""",
      testLimits)
    check parsed.isOk
    check parsed.value.resumeFrom == "0198e0d0-0000-7000-8000-000000000000"

  test "unsubscribe valid":
    check decodeSubscription("""{"type":"unsubscribe"}""", testLimits).value.kind == skUnsubscribe

  test "bukan JSON = error dengan kode mesin":
    let parsed = decodeSubscription("bukan json", testLimits)
    check parsed.isErr
    check parsed.error.code == "REALTIME_INVALID_JSON"
    check parsed.error.i18nKey == "error_realtime_invalid_json"

  test "tanpa type = error":
    check decodeSubscription("""{"topics":["*"]}""", testLimits).isErr

  test "tipe tidak dikenal = error":
    let parsed = decodeSubscription("""{"type":"halo"}""", testLimits)
    check parsed.isErr
    check parsed.error.code == "REALTIME_UNKNOWN_TYPE"

  test "subscribe tanpa topics = error":
    check decodeSubscription("""{"type":"subscribe"}""", testLimits).isErr

  test "subscribe dengan topics kosong = error":
    check decodeSubscription("""{"type":"subscribe","topics":[]}""", testLimits).isErr

  test "topik bukan string = error":
    check decodeSubscription("""{"type":"subscribe","topics":[1]}""", testLimits).isErr

  test "topik terlalu panjang = error":
    let panjang = "a".repeat(testLimits.maxTopicLen + 1)
    check decodeSubscription("""{"type":"subscribe","topics":["""" & panjang & """"]}""",
                             testLimits).isErr

  test "terlalu banyak topik = error terkode":
    var topics: seq[string]
    for i in 0 .. testLimits.maxTopics:
      topics.add "\"t" & $i & "\""
    let parsed = decodeSubscription("""{"type":"subscribe","topics":[""" & topics.join(",") & "]}",
                                    testLimits)
    check parsed.isErr
    check parsed.error.code == "REALTIME_TOO_MANY_TOPICS"

  test "resumeFrom bukan string = error":
    check decodeSubscription("""{"type":"subscribe","topics":["*"],"resumeFrom":5}""",
        testLimits).isErr

suite "splitAllowed (otorisasi topik)":
  test "hanya topik yang diizinkan yang lolos":
    let split = splitAllowed(@["param.changed", "audit.appended"], @["param.changed"])
    check split.granted == @["param.changed"]
    check split.denied == @["audit.appended"]

  test "wildcard tidak implisit: klien minta * tapi otorisasi tidak menyebutnya = ditolak":
    let split = splitAllowed(@["*"], @["param.changed"])
    check split.granted.len == 0
    check split.denied == @["*"]

  test "otorisasi menyebut * = semua permintaan lolos":
    let split = splitAllowed(@["param.changed", "audit.appended"], @["*"])
    check split.granted.len == 2

suite "bentuk pesan (amplop kontrak)":
  test "encodeEvent memuat kunci kontrak dan payload":
    let node = encodeEvent((outbound(ev("e1", "param.changed", """{"key":"x"}"""))))
    check node["type"].getStr() == "event"
    check node["id"].getStr() == "e1"
    check node["topic"].getStr() == "param.changed"
    check node["eventType"].getStr() == "param.changed"
    check node["occurredAt"].getStr().len == 24
    check node["payload"]["key"].getStr() == "x"

  test "encodeSubscribed menyebut topik, yang ditolak, dan jumlah resume":
    let node = encodeSubscribed(@["param.changed"], @["audit.appended"], resumed = 3,
                                replayLimit = 200)
    check node["type"].getStr() == "subscribed"
    check node["topics"][0].getStr() == "param.changed"
    check node["denied"][0].getStr() == "audit.appended"
    check node["resumed"].getInt() == 3
    check node["replayLimit"].getInt() == 200

  test "encodeResync & encodeError memuat alasan/kunci i18n":
    check encodeResync("buffer penuh")["type"].getStr() == "resync"
    let errorNode = encodeError("RATE_LIMITED", "error_rate_limited")
    check errorNode["type"].getStr() == "error"
    check errorNode["i18nKey"].getStr() == "error_rate_limited"
