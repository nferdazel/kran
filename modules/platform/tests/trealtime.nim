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

suite "hub: penyaringan per cabang (O-070)":
  test "peristiwa param.changed ber-scope BRANCH hanya untuk cabang itu":
    let event = ev("e1", "param.changed",
      """{"key":"a.b","scope_type":"BRANCH","scope_id":"br-1"}""")
    check EventScope(institutionWide: true).scopeAllows(event)
    check EventScope(branchIds: @["br-1"]).scopeAllows(event)
    check not EventScope(branchIds: @["br-2"]).scopeAllows(event)
    # Default kosong = gagal-tertutup, bukan mengirim ke semua.
    check not EventScope().scopeAllows(event)

  test "peristiwa tanpa dimensi scope tidak melewati aturan baca":
    # GLOBAL pun butuh minimal satu grant baca (`mayReadScope`): langganan tanpa cakupan tidak
    # menerima nilai parameter apa pun, sama seperti `GET /api/v1/params` yang kosong untuknya.
    let global = ev("e1", "param.changed",
      """{"key":"a.b","scope_type":"GLOBAL","scope_id":""}""")
    check EventScope(branchIds: @["br-1"]).scopeAllows(global)
    check EventScope(institutionWide: true).scopeAllows(global)
    check not EventScope().scopeAllows(global)
    # Topik lain tidak punya dimensi scope: tetap sampai.
    check EventScope().scopeAllows(ev("e2", "audit.appended", """{"scope_type":"BRANCH"}"""))

  test "fanout tidak mengirim peristiwa cabang lain ke langganan":
    var hub = newHub()
    hub.subscribe("a", @["param.changed"], EventScope(branchIds: @["br-1"]))
    hub.subscribe("b", @["param.changed"], EventScope(branchIds: @["br-2"]))
    hub.subscribe("c", @["param.changed"], EventScope(institutionWide: true))
    let deliveries = hub.fanout(@[ev("e1", "param.changed",
      """{"scope_type":"BRANCH","scope_id":"br-1"}""")])
    check deliveries.mapIt(it.subscriberId) == @["a", "c"]

suite "hub: penyaringan mengikuti mayReadScope (C-01)":
  ## Temuan pentest ronde 2 (C-01): jalur realtime dulu hanya mengenal `BRANCH`, sehingga teller
  ## ber-scope cabang menerima `INSTITUTION` (termasuk nilai PENDING) yang `GET /api/v1/params`
  ## tolak untuk akun yang sama. Uji ini menahan perilaku itu kembali.

  test "INSTITUTION hanya untuk pemegang izin tanpa batas cabang":
    let event = ev("e1", "param.changed",
      """{"key":"a.b","scope_type":"INSTITUTION","scope_id":"","status":"PENDING"}""")
    check EventScope(institutionWide: true).scopeAllows(event)
    check not EventScope(branchIds: @["br-1", "br-2"]).scopeAllows(event)
    check not EventScope().scopeAllows(event)

  test "PRODUCT, SEGMENT, dan ROLE gagal-tertutup":
    for scopeType in ["PRODUCT", "SEGMENT", "ROLE"]:
      let event = ev("e1", "param.changed",
        """{"key":"a.b","scope_type":"JENIS","scope_id":"x"}""".replace("JENIS", scopeType))
      check not EventScope(institutionWide: true).scopeAllows(event)
      check not EventScope(branchIds: @["br-1"]).scopeAllows(event)

  test "scope_type tak dikenal atau tidak ada = ditutup, bukan diloloskan":
    check not EventScope(institutionWide: true).scopeAllows(
      ev("e1", "param.changed", """{"key":"a.b","scope_type":"WILAYAH"}"""))
    check not EventScope(institutionWide: true).scopeAllows(
      ev("e2", "param.changed", """{"key":"a.b"}"""))

  test "fanout menahan peristiwa INSTITUTION dari langganan cabang":
    var hub = newHub()
    hub.subscribe("branch", @["param.changed"], EventScope(branchIds: @["br-1"]))
    hub.subscribe("pusat", @["param.changed"], EventScope(institutionWide: true))
    let deliveries = hub.fanout(@[ev("e1", "param.changed",
      """{"scope_type":"INSTITUTION","scope_id":"","status":"PENDING","key":"a.b"}""")])
    check deliveries.mapIt(it.subscriberId) == @["pusat"]

suite "hub: langganan & fanout":
  test "hanya langganan yang cocok yang menerima":
    # Topik netral (`audit.appended`): uji ini soal pencocokan topik, bukan aturan scope parameter.
    var hub = newHub()
    hub.subscribe("a", @["audit.appended"])
    hub.subscribe("b", @["param.changed"])
    let deliveries = hub.fanout(@[ev("e1", "audit.appended")])
    check deliveries.len == 1
    check deliveries[0].subscriberId == "a"
    check deliveries[0].message.eventId == "e1"

  test "wildcard menerima semua topik":
    var hub = newHub()
    hub.subscribe("a", @["*"])
    let deliveries = hub.fanout(@[ev("e1", "audit.appended"), ev("e2", "t")])
    check deliveries.len == 2

  test "urutan peristiwa dipertahankan":
    var hub = newHub()
    hub.subscribe("a", @["*"])
    let deliveries = hub.fanout(@[ev("e1", "t"), ev("e2", "t"), ev("e3", "t")])
    check deliveries.mapIt(it.message.eventId) == @["e1", "e2", "e3"]

  test "id langganan sama = update, bukan duplikat (klien reconnect)":
    var hub = newHub()
    hub.subscribe("a", @["t"])
    hub.subscribe("a", @["audit.appended"])
    check hub.subscriberCount == 1
    let deliveries = hub.fanout(@[ev("e1", "t"), ev("e2", "audit.appended")])
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
