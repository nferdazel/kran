## Repository inbox: de-dup per konsumen (spec §12.4 — at-least-once → efektif sekali).
##
## Pola pakai di konsumen:
##   if claimInbox(db, "ledger-posting", ev.eventId):   # pertama kali
##     ... proses ...
##   else:                                              # sudah pernah
##     discard

import std/strutils
import db_connector/db_postgres

import kernel/ids

proc claimInbox*(db: DbConn, consumer: string, eventId: Id): bool =
  ## `true` = peristiwa ini pertama kali dilihat konsumen tersebut; `false` = duplikat.
  db.execAffectedRows(
    sql"""INSERT INTO platform.inbox (consumer, event_id)
          VALUES (?, ?)
          ON CONFLICT (consumer, event_id) DO NOTHING""", consumer, $eventId) == 1

proc inboxSeen*(db: DbConn, consumer: string, eventId: Id): bool =
  db.getValue(
    sql"SELECT count(*) FROM platform.inbox WHERE consumer = ? AND event_id = ?",
    consumer, $eventId) == "1"

proc countInbox*(db: DbConn, consumer: string): int64 =
  parseBiggestInt(db.getValue(
    sql"SELECT count(*) FROM platform.inbox WHERE consumer = ?", consumer))
