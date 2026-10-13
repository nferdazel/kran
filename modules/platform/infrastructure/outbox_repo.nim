## Repository outbox (spec §12.4, §19.1).
##
## Kontrak dispatcher:
##   - Klaim batch memakai `FOR UPDATE SKIP LOCKED` → beberapa dispatcher aman berjalan paralel.
##   - `PENDING` → `IN_FLIGHT` (attempts +1) → `DONE`, atau `PENDING` lagi dengan `available_at`
##     mundur (backoff), atau `DEAD` (dead-letter) setelah `maxAttempts`.
##   - `DEAD` bisa di-*re-drive* manual (`redrive`) — UI re-drive menyusul di task notifikasi.
##
## `backoffSeconds`/`maxAttempts` **dikirim pemanggil** (dari parameter DB), bukan literal di sini:
## aturan "tidak ada nilai bisnis di kode" (spec §10.4).

import std/[json, strutils]
import db_connector/db_postgres

import ../domain/event
import kernel/ids

proc appendEvent*(db: DbConn, ev: OutboxEvent): bool =
  ## Menulis peristiwa ke outbox. Mengembalikan `false` bila `dedup_key` sudah ada
  ## (retry publisher) — peristiwa ganda tidak dibuat.
  db.execAffectedRows(
    sql"""INSERT INTO platform.outbox
            (outbox_id, event_type, event_version, aggregate_type, aggregate_id,
             payload, headers, dedup_key)
          VALUES (?, ?, ?, ?, ?, ?::jsonb, ?::jsonb, ?)
          ON CONFLICT (dedup_key) DO NOTHING""",
    $ev.eventId, ev.eventType, $ev.eventVersion, ev.aggregateType, ev.aggregateId,
    (if ev.payload.isNil: "{}" else: $ev.payload),
    (if ev.headers.isNil: "{}" else: $ev.headers), ev.dedupKey) == 1

proc claimBatch*(db: DbConn, worker: string, limit: int): seq[OutboxEvent] =
  ## Mengambil dan mengunci satu batch (`PENDING` yang `available_at` sudah lewat).
  for row in db.getAllRows(
      sql"""WITH claimed AS (
              SELECT c.outbox_id
                FROM platform.outbox c
               WHERE c.status = 'PENDING' AND c.available_at <= now()
               ORDER BY c.seq
               FOR UPDATE SKIP LOCKED
               LIMIT ?
            )
            UPDATE platform.outbox o
               SET status = 'IN_FLIGHT', locked_by = ?, locked_at = now(),
                   attempts = o.attempts + 1
              FROM claimed
             WHERE o.outbox_id = claimed.outbox_id
            RETURNING o.outbox_id, o.event_type, o.event_version, o.aggregate_type,
                      o.aggregate_id, o.payload::text, o.headers::text, o.dedup_key,
                      to_char(o.occurred_at AT TIME ZONE 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                      o.status, o.attempts, coalesce(o.locked_by, ''),
                      coalesce(o.last_error, '')""",
      $limit, worker):
    result.add OutboxEvent(
      eventId: Id(row[0]),
      eventType: row[1],
      eventVersion: parseInt(row[2]),
      aggregateType: row[3],
      aggregateId: row[4],
      payload: parseJson(row[5]),
      headers: parseJson(row[6]),
      dedupKey: row[7],
      occurredAt: row[8],
      status: parseEventStatus(row[9]),
      attempts: parseInt(row[10]),
      lockedBy: row[11],
      lastError: row[12])

proc markDone*(db: DbConn, eventId: Id) =
  discard db.execAffectedRows(
    sql"""UPDATE platform.outbox
             SET status = 'DONE', locked_by = NULL, locked_at = NULL, last_error = NULL
           WHERE outbox_id = ?""", $eventId)

proc markFailed*(db: DbConn, eventId: Id, errorMessage: string,
                 backoffSeconds: int, maxAttempts: int) =
  ## Kegagalan konsumen: mundurkan `available_at`, atau matikan (DEAD) setelah batas percobaan.
  discard db.execAffectedRows(
    sql"""UPDATE platform.outbox
             SET status = CASE WHEN attempts >= ? THEN 'DEAD' ELSE 'PENDING' END,
                 available_at = now() + make_interval(secs => ?),
                 last_error = ?, locked_by = NULL, locked_at = NULL
           WHERE outbox_id = ?""",
    $maxAttempts, $backoffSeconds, errorMessage, $eventId)

proc redrive*(db: DbConn, eventId: Id): bool =
  ## Mengembalikan peristiwa DEAD/PENDING ke antrean (spec §19.1: UI re-drive).
  db.execAffectedRows(
    sql"""UPDATE platform.outbox
             SET status = 'PENDING', available_at = now(), attempts = 0, last_error = NULL,
                 locked_by = NULL, locked_at = NULL
           WHERE outbox_id = ? AND status IN ('DEAD', 'IN_FLIGHT')""", $eventId) == 1

proc statusOf*(db: DbConn, eventId: Id): string =
  db.getValue(sql"SELECT status FROM platform.outbox WHERE outbox_id = ?", $eventId)

proc attemptsOf*(db: DbConn, eventId: Id): int =
  parseInt(db.getValue(sql"SELECT attempts FROM platform.outbox WHERE outbox_id = ?",
    $eventId))

proc countByStatus*(db: DbConn, status: EventStatus): int64 =
  parseBiggestInt(db.getValue(
    sql"SELECT count(*) FROM platform.outbox WHERE status = ?", $status))
