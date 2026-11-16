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
import kernel/[ids, result]

const
  ## Token resume "kosong": uuid yang dijamin tidak ada di tabel, sehingga anchor tidak ketemu
  ## dan replay dimulai dari awal.
  zeroUuid* = "00000000-0000-0000-0000-000000000000"

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

proc claimBatch*(db: DbConn, worker: string, limit: int,
                 leaseSeconds = 0): seq[OutboxEvent] =
  ## Mengambil dan mengunci satu batch (`PENDING` yang `available_at` sudah lewat).
  ##
  ## `leaseSeconds > 0` juga merebut kembali event `IN_FLIGHT` yang `locked_at`-nya lebih lama dari
  ## lease: worker yang mati setelah klaim tidak boleh memarkir event selamanya (review T-074).
  ## Lease 0 = perilaku lama (hanya `PENDING`).
  for row in db.getAllRows(
      sql"""WITH claimed AS (
              SELECT c.outbox_id
                FROM platform.outbox c
               WHERE c.available_at <= now()
                 AND (c.status = 'PENDING'
                      OR (c.status = 'IN_FLIGHT' AND ? > 0
                          AND c.locked_at < now() - make_interval(secs => ?)))
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
      $leaseSeconds, $leaseSeconds, $limit, worker):
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

proc latestEventId*(db: DbConn): string =
  ## Id peristiwa terakhir di outbox ("" bila kosong). Dipakai pump saat mulai: stream dimulai dari
  ## "sekarang", riwayat diambil klien lewat resume/HTTP — bukan disemprotkan ke setiap klien baru.
  let row = db.getRow(
    sql"SELECT outbox_id::text FROM platform.outbox ORDER BY seq DESC LIMIT 1")
  if row.len == 0: "" else: row[0]

proc fetchAfter*(db: DbConn, afterEventId: string, limit: int): seq[OutboxEvent] =
  ## Peristiwa yang urutannya setelah token, terurut `seq` (bukan waktu) supaya resume tidak
  ## kehilangan/duplikat peristiwa yang `occurred_at`-nya sama.
  ##
  ## Token tak dikenal (mis. sudah dipurge) diperlakukan sebagai "mulai dari awal": klien
  ## menerima replay penuh (dibatasi `limit`) dan melakukan de-dup berdasarkan `id` — lebih baik
  ## daripada klien diam-diam kehilangan peristiwa (spec §19.2).
  ## Token kosong/tidak valid (mis. rusak, atau sudah dipurge) diperlakukan sebagai
  ## "mulai dari awal": replay penuh (dibatasi `limit`) — klien de-dup berdasarkan `id`.
  let token =
    if afterEventId.len == 0:
      zeroUuid
    else:
      let parsed = parseId(afterEventId)
      if parsed.isOk: $parsed.value else: zeroUuid

  proc rowOf(row: Row): OutboxEvent =
    OutboxEvent(
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

  for row in db.getAllRows(
      sql"""WITH anchor AS (
              SELECT seq FROM platform.outbox WHERE outbox_id = ?::uuid
            )
            SELECT o.outbox_id, o.event_type, o.event_version, o.aggregate_type,
                   o.aggregate_id, o.payload::text, o.headers::text, o.dedup_key,
                   to_char(o.occurred_at AT TIME ZONE 'UTC',
                           'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
                   o.status, o.attempts, coalesce(o.locked_by, ''),
                   coalesce(o.last_error, '')
              FROM platform.outbox o
             WHERE o.seq > coalesce((SELECT seq FROM anchor), 0)
             ORDER BY o.seq
             LIMIT ?""",
      token, $limit):
    result.add rowOf(row)

proc markDone*(db: DbConn, eventId: Id) =
  ## `completed_at` adalah dasar purge retensi (D-206, T-282): jam 30 hari dihitung dari
  ## transisi terakhir ke `DONE`, bukan dari `occurred_at`.
  discard db.execAffectedRows(
    sql"""UPDATE platform.outbox
             SET status = 'DONE', completed_at = now(),
                 locked_by = NULL, locked_at = NULL, last_error = NULL
           WHERE outbox_id = ?""", $eventId)

proc markFailed*(db: DbConn, eventId: Id, errorMessage: string,
                 backoffSeconds: int, maxAttempts: int) =
  ## Kegagalan konsumen: mundurkan `available_at`, atau matikan (DEAD) setelah batas percobaan.
  ## `completed_at` hanya diisi saat baris benar-benar berhenti di `DEAD`; kegagalan yang masih
  ## akan dicoba ulang (`PENDING`) belum "selesai" dan tidak boleh mulai dihitung.
  discard db.execAffectedRows(
    sql"""UPDATE platform.outbox
             SET status = CASE WHEN attempts >= ? THEN 'DEAD' ELSE 'PENDING' END,
                 completed_at = CASE WHEN attempts >= ? THEN now() ELSE completed_at END,
                 available_at = now() + make_interval(secs => ?),
                 last_error = ?, locked_by = NULL, locked_at = NULL
           WHERE outbox_id = ?""",
    $maxAttempts, $maxAttempts, $backoffSeconds, errorMessage, $eventId)

proc redrive*(db: DbConn, eventId: Id): bool =
  ## Mengembalikan peristiwa DEAD/PENDING ke antrean (spec §19.1: UI re-drive).
  ##
  ## `completed_at` **sengaja tidak dikosongkan** (T-282): baris yang kembali ke `PENDING` keluar
  ## dari predikat purge karena statusnya, dan `markDone`/`markFailed` menimpa jamnya saat baris
  ## itu selesai lagi. Mengosongkannya justru membuat baris lama tampak "belum pernah selesai".
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

proc countsByStatus*(db: DbConn): seq[tuple[status: string, total: int64]] =
  ## Satu kueri untuk semua status (T-250). Dikembalikan sebagai teks, bukan `EventStatus`, supaya
  ## pemanggil di lapisan probe tidak perlu tahu tipe domainnya. Status yang tidak punya baris tidak
  ## muncul; pemanggil yang ingin seri nol menambahkannya sendiri.
  for row in db.getAllRows(sql"""
      SELECT status, count(*) FROM platform.outbox GROUP BY status ORDER BY status"""):
    result.add (status: row[0], total: parseBiggestInt(row[1]))

proc oldestUndeliveredSeconds*(db: DbConn, afterEventId: string): int64 =
  ## Usia (detik, dibulatkan ke bawah) peristiwa outbox **tertua yang belum diproses konsumen** —
  ## baris dengan `seq` setelah token — atau `0` bila tidak ada sisa.
  ##
  ## Dipakai readiness `/readyz` (O-019) untuk melihat konsumen (pump realtime) tertinggal. Memakai
  ## `seq` (bukan `occurred_at`) supaya konsisten dengan kursor pump yang berbasis `outbox_id`;
  ## token kosong/tak dikenal diperlakukan sebagai "mulai dari awal", sama seperti `fetchAfter`.
  let token =
    if afterEventId.len == 0:
      zeroUuid
    else:
      let parsed = parseId(afterEventId)
      if parsed.isOk: $parsed.value else: zeroUuid
  parseBiggestInt(db.getValue(sql"""SELECT coalesce(
      (extract(epoch FROM now() - min(o.occurred_at)))::bigint, 0)
      FROM platform.outbox o
     WHERE o.seq > coalesce((SELECT seq FROM platform.outbox WHERE outbox_id = ?::uuid), 0)""",
    token))

