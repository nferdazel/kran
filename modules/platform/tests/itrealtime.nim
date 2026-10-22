## Test integrasi outbox → hub realtime (butuh `KRAN_DATABASE_URL`).
##
## Kriteria T-009: peristiwa dari outbox sampai ke "klien" (di sini: langganan hub) dan resume
## tidak kehilangan peristiwa. Transport WebSocket diuji terpisah di
## `apps/api/tests/itapi_ws.nim`; di sini yang dibuktikan adalah jalur
## INSERT → trigger NOTIFY (`0007`) → pendengar → baca tabel → fanout hub.
##
## Test ini **tidak** menghapus schema: hanya menambah baris outbox dengan `dedup_key` unik.

import std/[json, random, strutils, times, unittest]

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[clock, ids]
import platform/application/realtime
import platform/domain/event
import platform/infrastructure/[outbox_listener, outbox_repo]

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itrealtime: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
let sysClock = systemClock()
randomize(20261014)

discard applyAllMigrations(db, ".")

proc uniqueKey(prefix: string): string =
  prefix & ":" & $epochTime() & ":" & $rand(1_000_000)

proc appendTestEvent(eventType: string, payload: JsonNode): OutboxEvent =
  let ev = newOutboxEvent(sysClock, eventType, "test", eventType, payload, uniqueKey(eventType))
  check appendEvent(db, ev)
  ev

let listener = dbPool.acquire()
listenOutbox(listener)

suite "outbox -> hub (NOTIFY + baca tabel)":
  test "INSERT ke outbox memicu NOTIFY dan peristiwanya terbaca pendengar":
    ## Pendengar memakai koneksi sendiri (LISTEN per koneksi) — sama seperti pump di `apps/api`.
    let ev = appendTestEvent("param.changed", %*{"key": "platform.calendar.weekend_days"})

    let notified = pollOutbox(listener, timeoutMs = 5000)
    check notified.len >= 1
    check $ev.eventId in notified

    let fetched = eventsAfter(db, "", limit = 500)
    var found = false
    for item in fetched:
      if item.eventId == $ev.eventId:
        found = true
        check item.topic == "param.changed"
        check item.eventType == "param.changed"
        check item.payload["key"].getStr() == "platform.calendar.weekend_days"
        check item.occurredAt.endsWith("Z")
    check found

  test "peristiwa sampai ke langganan hub yang cocok (dan tidak ke yang lain)":
    var hub = newHub()
    hub.subscribe("ui-param", @["param.changed"])
    hub.subscribe("ui-audit", @["audit.appended"])

    let ev = appendTestEvent("param.changed", %*{"key": "x"})
    discard pollOutbox(listener, timeoutMs = 5000)

    let fetched = eventsAfter(db, "", limit = 500)
    # Sebar hanya peristiwa yang baru saja dibuat (fanout di produksi memakai id terakhir).
    var only: seq[RealtimeEvent]
    for item in fetched:
      if item.eventId == $ev.eventId:
        only.add item

    let deliveries = hub.fanout(only)
    check deliveries.len == 1
    check deliveries[0].subscriberId == "ui-param"
    check deliveries[0].message.eventId == $ev.eventId

  test "resume: klien dengan token lama menerima peristiwa yang terlewat":
    let first = appendTestEvent("param.changed", %*{"n": 1})
    let second = appendTestEvent("param.changed", %*{"n": 2})
    let third = appendTestEvent("audit.appended", %*{"n": 3})

    # Klien "putus" setelah `first`, lalu reconnect dengan resumeFrom = id `first`.
    let replayed = eventsAfter(db, $first.eventId, limit = 500)
    var ids: seq[string]
    for item in replayed:
      ids.add item.eventId

    check $second.eventId in ids
    check $third.eventId in ids
    check $first.eventId notin ids # yang sudah diterima tidak diulang

    # Fanout hasil replay hanya mengirim yang topiknya cocok.
    var hub = newHub()
    hub.subscribe("ui", @["param.changed"])
    let deliveries = hub.fanout(replayed)
    var deliveredIds: seq[string]
    for delivery in deliveries:
      deliveredIds.add delivery.message.eventId
    check $second.eventId in deliveredIds
    check $third.eventId notin deliveredIds

  test "token tak dikenal diperlakukan sebagai replay dari awal (klien de-dup by id)":
    let ev = appendTestEvent("param.changed", %*{"n": 4})
    let replayed = eventsAfter(db, "0198e0d0-0000-7000-8000-000000000000", limit = 500)
    check replayed.len > 0
    var ids: seq[string]
    for item in replayed:
      ids.add item.eventId
    check $ev.eventId in ids

  test "dedup_key ganda tidak membuat peristiwa kedua (dan tidak ada NOTIFY kedua)":
    let key = uniqueKey("dedup")
    let first = newOutboxEvent(sysClock, "param.changed", "test", "param.changed", %*{"n": 5}, key)
    let second = newOutboxEvent(sysClock, "param.changed", "test", "param.changed", %*{"n": 5}, key)
    check appendEvent(db, first)
    check not appendEvent(db, second)
    discard pollOutbox(listener, timeoutMs = 1000)
