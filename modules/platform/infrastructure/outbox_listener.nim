## Pendengar outbox: `LISTEN` kanal `kran_outbox` + baca peristiwa baru dari tabel (spec §12.4, §19.1).
##
## Peran file ini adalah **I/O**: menunggu sinyal dan mengambil data. Logika topik/resume ada di
## `application/realtime.nim` (murni) — pemisahan itu yang membuat keduanya dapat diuji terpisah.
##
## `db_connector` tidak membungkus `LISTEN/NOTIFY`, jadi bagian itu memakai libpq langsung dengan
## pola yang sama seperti `param_repo.nim` (satu tempat belajar, bukan dua gaya).

import std/[json, os, times]

import db_connector/db_postgres
import db_connector/postgres

import ../application/realtime
import ../domain/event
import ./outbox_repo
import kernel/[clock, ids]

const
  ## Kanal NOTIFY dari trigger `outbox_notify_insert` (migration 0007).
  outboxChannel* = "kran_outbox"

proc listenOutbox*(db: DbConn) =
  ## `LISTEN` sekali per koneksi pendengar (bukan per query).
  db.exec(sql("LISTEN " & outboxChannel))

proc pollOutbox*(db: DbConn, timeoutMs: int, pollIntervalMs = 20): seq[string] =
  ## Menunggu notifikasi kanal sampai `timeoutMs`. Mengembalikan payload (id event) yang masuk.
  ## Sekaligus sebagai "titik bangun" berkala supaya peristiwa yang lolos karena koneksi
  ## terputus tetap terambil (baca tabel berikutnya memakai id terakhir, bukan hanya NOTIFY).
  let deadline = epochTime() * 1000.0 + float(timeoutMs)
  while true:
    discard pqconsumeInput(db)
    var notif = pqnotifies(db)
    while not notif.isNil:
      let channel = $notif.relname
      let payload = $notif.extra
      pqfreemem(notif)
      if channel == outboxChannel and payload.len > 0:
        result.add payload
      notif = pqnotifies(db)
    if result.len > 0 or epochTime() * 1000.0 >= deadline:
      return
    sleep(pollIntervalMs)

proc toRealtimeEvent*(ev: OutboxEvent): RealtimeEvent =
  RealtimeEvent(
    eventId: $ev.eventId,
    topic: topicFor(ev.eventType),
    eventType: ev.eventType,
    occurredAt: ev.occurredAt,
    payload: ev.payload,
  )

proc eventsAfter*(db: DbConn, afterEventId: string, limit: int): seq[RealtimeEvent] =
  ## Peristiwa setelah token (untuk resume klien) — lihat `outbox_repo.fetchAfter`.
  for ev in fetchAfter(db, afterEventId, limit):
    result.add ev.toRealtimeEvent()

proc newOutboxEvent*(clockValue: Clock, eventType, aggregateType, aggregateId: string,
                     payload: JsonNode, dedupKey: string): OutboxEvent =
  ## Pembuat peristiwa outbox untuk pemanggil (use case) — dipakai uji integrasi dan T-012.
  newOutboxEvent(newId(clockValue), eventType, aggregateType, aggregateId, dedupKey, payload)
