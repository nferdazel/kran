## Tipe domain modul `platform`: peristiwa outbox (spec §12.4, §19.1).
##
## Murni: tanpa I/O. Penulisan ke tabel dilakukan di `infrastructure/outbox_repo`.

import std/json
import kernel/ids

type
  EventStatus* = enum
    Pending = "PENDING"
    InFlight = "IN_FLIGHT"
    Done = "DONE"
    Dead = "DEAD"

  OutboxEvent* = object
    eventId*: Id
    eventType*: string  ## mis. `param.changed`
    eventVersion*: int  ## versi skema peristiwa (spec §12.4)
    aggregateType*: string
    aggregateId*: string
    payload*: JsonNode
    headers*: JsonNode
    dedupKey*: string   ## kunci idempotensi; UNIQUE di DB
    occurredAt*: string ## ISO-8601 UTC dari DB
    status*: EventStatus
    attempts*: int
    lockedBy*: string
    lastError*: string

proc newOutboxEvent*(
    eventId: Id,
    eventType, aggregateType, aggregateId, dedupKey: string,
    payload: JsonNode,
    eventVersion = 1,
    headers: JsonNode = nil,
): OutboxEvent =
  OutboxEvent(
    eventId: eventId,
    eventType: eventType,
    eventVersion: eventVersion,
    aggregateType: aggregateType,
    aggregateId: aggregateId,
    payload: payload,
    headers: headers,
    dedupKey: dedupKey,
    status: Pending,
  )

proc parseEventStatus*(s: string): EventStatus =
  case s
  of "PENDING": Pending
  of "IN_FLIGHT": InFlight
  of "DONE": Done
  of "DEAD": Dead
  else: Pending
