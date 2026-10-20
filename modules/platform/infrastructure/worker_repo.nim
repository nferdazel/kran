## Denyut worker konsumen (O-081): satu baris per worker di `platform.worker_heartbeat`.
##
## Kenapa denyut, bukan hanya panjang backlog: backlog bisa kosong walau worker mati, dan bisa besar
## walau worker sehat (impor massal). Denyut menjawab pertanyaan yang tepat — "prosesnya masih
## hidup?" — tanpa menebak dari antrean. Ambang dan masa tenggang ada di `readiness.nim` (nilai
## teknis, bukan parameter bisnis).

import std/strutils

import db_connector/db_postgres

const
  ## Jarak minimum antar tulisan denyut. Worker memutar tiap `poll_interval_ms` (ratusan ms); tanpa
  ## ambang ini setiap putaran menjadi satu UPDATE.
  heartbeatWriteSeconds* = 15

proc touchWorkerHeartbeat*(db: DbConn, workerName: string,
                           staleSeconds = heartbeatWriteSeconds): bool =
  ## Menulis denyut hanya bila baris yang ada sudah lebih tua dari `staleSeconds`.
  ##
  ## Satu statement: `INSERT ... ON CONFLICT DO UPDATE ... WHERE last_seen_at < now() - interval`.
  ## Mengembalikan `true` bila baris ditulis (insert atau update).
  db.execAffectedRows(sql"""
    INSERT INTO platform.worker_heartbeat (worker_name, last_seen_at)
    VALUES (?, now())
    ON CONFLICT (worker_name) DO UPDATE SET last_seen_at = now()
     WHERE platform.worker_heartbeat.last_seen_at < now() - make_interval(secs => ?::double precision)""",
    workerName, staleSeconds) == 1

proc workerHeartbeatAgeSeconds*(db: DbConn, workerName: string): int64 =
  ## Usia denyut terakhir (detik, dibulatkan ke bawah); `-1` bila worker belum pernah melapor.
  ## Jam mundur/NTP bisa membuat `last_seen_at` di masa depan: usia negatif dijepit ke 0 supaya
  ## tidak salah dibaca sebagai "belum pernah melapor".
  parseBiggestInt(db.getValue(sql"""
    SELECT coalesce(max(greatest(0, floor(extract(epoch FROM now() - last_seen_at))))::bigint, -1)
      FROM platform.worker_heartbeat
     WHERE worker_name = ?""", workerName))

proc deadEventCount*(db: DbConn): int64 =
  ## Jumlah peristiwa outbox `DEAD` (perlu re-drive operator). Bukan kegagalan readiness: deploy
  ## ulang tidak menghidupkannya, dan gate yang gagal hanya berputar rollback.
  parseBiggestInt(db.getValue(
    sql"SELECT count(*) FROM platform.outbox WHERE status = 'DEAD'"))
