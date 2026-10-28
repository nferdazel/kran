## Penyimpanan run day-close (lapisan infrastructure).
##
## Satu baris = satu fakta: run, task, chunk, checkpoint, registry. Tidak ada aturan urutan di
## sini — itu milik orkestrator; repositori hanya menolak baris yang tidak ada dan menerjemahkan
## teks DB kembali ke tipe domain dengan fail-fast bila isinya rusak.

import std/[json, options, strutils]

import db_connector/db_postgres

import nimcrypto/[sha2, utils]

import ../domain/[run, state, types]
import kernel/dayclose

type
  RegistryRow* = object
    taskId*: string
    module*: string
    levels*: string
    kind*: TaskKind
    critical*: bool
    idempotency*: IdempotencyMode
    partition*: PartitionStrategy
    requiredParams*: seq[string]

proc textArray*(s: string): string =
  ## `{EOD,EOM}` untuk parameter `text[]`. Isi level tidak memuat koma/kutip (enum tetap), jadi
  ## tidak perlu escaping penuh — dan tidak ada nilai bebas pengguna yang lewat di sini.
  "{" & s & "}"

proc parseTimestamp*(s: string): string =
  ## DB mengembalikan `+00`; domain memakai `Z`. Nilai kosong tetap kosong.
  if s.len == 0: "" else: s.replace("+00", "Z")

proc configHash*(config: Config): string =
  var ctx: sha256
  ctx.init()
  ctx.update($config.configJson)
  let digest = ctx.finish()
  result = utils.toHex(digest.data, lowercase = true)
  ctx.clear()

proc insertRun*(db: DbConn; runId: string; req: RunRequest; plan: seq[PlannedTask];
                at: string) =
  ## Menulis run + task + chunk dalam satu transaksi (pemanggil memakai `withTx`).
  db.exec(sql"""
    INSERT INTO daycloser.run
      (run_id, scope_type, scope_id, business_date, levels, mode, state, control,
       param_snapshot, param_snapshot_hash, started_at)
    VALUES (?::uuid, ?, NULLIF(?, ''), ?::date, ?::text[], ?, 'PLANNED', 'NONE',
            ?::jsonb, ?, ?::timestamptz)""",
    runId, req.scopeType, req.scopeId, req.businessDate,
    textArray(levelsCsv(req.levels)), $req.mode, $req.config.configJson,
    configHash(req.config), at)
  for t in plan:
    db.exec(sql"""
      INSERT INTO daycloser.task (run_id, task_id, kind, critical, state)
      VALUES (?::uuid, ?, ?, ?, 'PENDING')""",
      runId, t.taskId, $t.kind, t.critical)
    for ch in t.chunks:
      db.exec(sql"""
        INSERT INTO daycloser.chunk
          (run_id, task_id, chunk_no, range_start, range_end, state)
        VALUES (?::uuid, ?, ?, NULLIF(?, ''), NULLIF(?, ''), 'PENDING')""",
        runId, t.taskId, ch.chunkNo, ch.rangeStart, ch.rangeEnd)

proc snapshot*(db: DbConn; runId: string): RunSnapshot =
  let rows = db.getAllRows(sql"""
    SELECT run_id::text, scope_type, coalesce(scope_id, ''), business_date::text, levels, mode,
           state, control, param_snapshot,
           coalesce(to_char(started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''),
           coalesce(to_char(finished_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), ''),
           coalesce(summary_hash, ''), param_snapshot_hash
      FROM daycloser.run WHERE run_id = ?::uuid""", runId)
  if rows.len == 0:
    raise newException(DayCloserError, "run day-close tidak ditemukan: " & runId)
  let row = rows[0]
  result = RunSnapshot(
    runId: row[0],
    scopeType: row[1],
    scopeId: row[2],
    businessDate: row[3],
    levels: parseLevelsCsv(row[4].strip(chars = {'{', '}'})),
    mode: parseRunMode(row[5]),
    state: parseRunState(row[6]),
    control: parseRunControl(row[7]),
    config: parseConfig(parseJson(row[8])),
    startedAt: parseTimestamp(row[9]),
    finishedAt: parseTimestamp(row[10]),
    summaryHash: row[11],
    paramSnapshotHash: row[12])

  # Snapshot parameter adalah dasar perilaku resume; hash-nya dibandingkan setiap kali dibaca
  # supaya snapshot yang diubah di luar jalur aplikasi tidak diam-diam mengubah run.
  if configHash(result.config) != result.paramSnapshotHash:
    raise newException(DayCloserError,
      "snapshot parameter run " & runId & " tidak cocok dengan hash-nya")

  for trow in db.getAllRows(sql"""
      SELECT task_id, kind, critical, state, attempt, coalesce(error->>'code', '')
        FROM daycloser.task WHERE run_id = ?::uuid ORDER BY task_id""", runId):
    result.tasks.add TaskProgress(
      taskId: trow[0],
      kind: parseTaskKind(trow[1]),
      critical: trow[2] == "t",
      state: parseTaskState(trow[3]),
      attempt: parseInt(trow[4]),
      errorCode: trow[5])

  for crow in db.getAllRows(sql"""
      SELECT task_id, chunk_no, state, attempt, coalesce(error->>'code', '')
        FROM daycloser.chunk WHERE run_id = ?::uuid ORDER BY task_id, chunk_no""", runId):
    let taskId = crow[0]
    for i in 0 ..< result.tasks.len:
      if result.tasks[i].taskId == taskId:
        result.tasks[i].chunks.add ChunkProgress(
          chunkNo: parseInt(crow[1]), state: parseChunkState(crow[2]),
          attempt: parseInt(crow[3]), errorCode: crow[4])
        break

proc setRunState*(db: DbConn; runId: string; st: RunState; at, summaryHash: string) =
  let affected = db.execAffectedRows(sql"""
    UPDATE daycloser.run
       SET state = ?,
           finished_at = CASE WHEN ? IN ('COMPLETED','FAILED','BLOCKED','CANCELED')
                              THEN ?::timestamptz ELSE NULL END,
           summary_hash = CASE WHEN ? = '' THEN summary_hash ELSE ? END
     WHERE run_id = ?::uuid""",
    $st, $st, at, summaryHash, summaryHash, runId)
  if affected != 1:
    raise newException(DayCloserError,
      "gagal memperbarui state run " & runId & " → " & $st)

proc setTaskState*(db: DbConn; runId: string; taskId: TaskId; st: TaskState; at: string;
                   err, metrics: JsonNode) =
  let affected = db.execAffectedRows(sql"""
    UPDATE daycloser.task
       SET state = ?,
           attempt = CASE WHEN ? = 'RUNNING' THEN attempt + 1 ELSE attempt END,
           started_at = CASE WHEN ? = 'RUNNING' AND started_at IS NULL
                             THEN ?::timestamptz ELSE started_at END,
           finished_at = CASE WHEN ? IN ('SUCCEEDED','FAILED','SKIPPED','CANCELED')
                              THEN ?::timestamptz ELSE NULL END,
           error = ?::jsonb,
           metrics = COALESCE(?::jsonb, metrics)
     WHERE run_id = ?::uuid AND task_id = ?""",
    $st, $st, $st, at, $st, at,
    (if err.isNil: "null" else: $err), (if metrics.isNil: "null" else: $metrics),
    runId, taskId)
  if affected != 1:
    raise newException(DayCloserError,
      "gagal memperbarui task " & taskId & " pada run " & runId)

proc setChunkState*(db: DbConn; runId: string; taskId: TaskId; chunkNo: int;
                    st: ChunkState; at: string; err: JsonNode) =
  let affected = db.execAffectedRows(sql"""
    UPDATE daycloser.chunk
       SET state = ?,
           attempt = CASE WHEN ? = 'RUNNING' THEN attempt + 1 ELSE attempt END,
           started_at = CASE WHEN ? = 'RUNNING' AND started_at IS NULL
                             THEN ?::timestamptz ELSE started_at END,
           finished_at = CASE WHEN ? IN ('SUCCEEDED','FAILED')
                              THEN ?::timestamptz ELSE NULL END,
           error = ?::jsonb
     WHERE run_id = ?::uuid AND task_id = ? AND chunk_no = ?""",
    $st, $st, $st, at, $st, at, (if err.isNil: "null" else: $err),
    runId, taskId, chunkNo)
  if affected != 1:
    raise newException(DayCloserError,
      "gagal memperbarui chunk " & $chunkNo & " task " & taskId & " run " & runId)

proc controlOf*(db: DbConn; runId: string): RunControl =
  for row in db.getAllRows(sql"""
      SELECT control FROM daycloser.run WHERE run_id = ?::uuid""", runId):
    return parseRunControl(row[0])
  raise newException(DayCloserError, "run day-close tidak ditemukan: " & runId)

proc setControl*(db: DbConn; runId: string; control: RunControl) =
  let affected = db.execAffectedRows(sql"""
    UPDATE daycloser.run SET control = ? WHERE run_id = ?::uuid""",
    $control, runId)
  if affected != 1:
    raise newException(DayCloserError, "run day-close tidak ditemukan: " & runId)

proc resetInFlight*(db: DbConn; runId: string) =
  ## Sisa proses yang mati: chunk/task `RUNNING` dikembalikan ke `PENDING` supaya resume
  ## mengulangnya. Chunk `FAILED` sengaja dibiarkan — itu jejak percobaan sebelumnya.
  ##
  ## **Gate yang sudah `SUCCEEDED` ikut diulang**, termasuk chunk-nya. Gate pra-tutup berjalan
  ## saat tanggal buku masih `OPEN`, jadi keadaan yang disertifikasinya bisa berubah selama run
  ## `BLOCKED`/`PAUSED` (sesi teller baru, selisih kas). Kalau task di-reset tetapi chunk-nya
  ## tidak, `runTask` akan melewati chunk `SUCCEEDED` dan menandai gate sukses **tanpa
  ## menjalankannya** — sertifikat basi dengan label baru.
  discard db.execAffectedRows(sql"""
    UPDATE daycloser.chunk c SET state = 'PENDING', error = NULL
     WHERE c.run_id = ?::uuid
       AND (c.state = 'RUNNING'
            OR (c.state = 'SUCCEEDED' AND c.task_id IN (
                  SELECT t.task_id FROM daycloser.task t
                   WHERE t.run_id = c.run_id AND t.kind IN ('PRECHECK', 'POSTCHECK'))))""",
    runId)
  discard db.execAffectedRows(sql"""
    UPDATE daycloser.task SET state = 'PENDING', finished_at = NULL, error = NULL
     WHERE run_id = ?::uuid
       AND (state = 'RUNNING' OR (state = 'SUCCEEDED' AND kind IN ('PRECHECK', 'POSTCHECK')))""",
    runId)

proc cancelRemaining*(db: DbConn; runId, at: string) =
  discard db.execAffectedRows(sql"""
    UPDATE daycloser.task
       SET state = 'CANCELED', finished_at = ?::timestamptz
     WHERE run_id = ?::uuid AND state IN ('PENDING','READY','FAILED')""", at, runId)

proc lockScope*(db: DbConn; scopeType, scopeId: string): bool =
  ## Advisory lock per scope (bukan per tanggal): catch-up beberapa hari harus berurutan, dan
  ## dua run berbeda tanggal pada saat yang sama tetap berarti dua penutupan bersamaan.
  ## Session-level: lepas otomatis saat koneksi ditutup/dipulangkan.
  db.getValue(sql"""
    SELECT pg_try_advisory_lock(hashtextextended(?, 0))""",
    "daycloser:" & scopeType & ":" & scopeId) == "t"

proc unlockScope*(db: DbConn; scopeType, scopeId: string) =
  discard db.getValue(sql"""
    SELECT pg_advisory_unlock(hashtextextended(?, 0))""",
    "daycloser:" & scopeType & ":" & scopeId)

proc activeRuns*(db: DbConn): seq[RunSnapshot] =
  for row in db.getAllRows(sql"""
      SELECT run_id::text FROM daycloser.run
       WHERE state IN ('PLANNED','PRECHECK','RUNNING','POSTCHECK','PAUSED')
       ORDER BY business_date, run_id"""):
    result.add db.snapshot(row[0])

proc runForDate*(db: DbConn; scopeType, scopeId, businessDate: string): Option[RunSnapshot] =
  ## Run apa pun untuk (scope, tanggal), termasuk yang sudah selesai. Dipakai `ctl` untuk
  ## menolak run kedua pada tanggal yang sama: `FAILED`/`BLOCKED` harus di-resume atau
  ## dibatalkan, bukan diulang dari nol.
  for row in db.getAllRows(sql"""
      SELECT run_id::text FROM daycloser.run
       WHERE scope_type = ? AND coalesce(scope_id, '') = ? AND business_date = ?::date
       ORDER BY started_at DESC NULLS LAST LIMIT 1""",
      scopeType, scopeId, businessDate):
    return some(db.snapshot(row[0]))
  none(RunSnapshot)

proc latestRun*(db: DbConn; scopeType, scopeId: string): Option[RunSnapshot] =
  for row in db.getAllRows(sql"""
      SELECT run_id::text FROM daycloser.run
       WHERE scope_type = ? AND coalesce(scope_id, '') = ?
       ORDER BY business_date DESC, started_at DESC NULLS LAST
       LIMIT 1""", scopeType, scopeId):
    return some(db.snapshot(row[0]))
  none(RunSnapshot)

proc activeRunFor*(db: DbConn; scopeType, scopeId: string): Option[RunSnapshot] =
  ## Run yang masih berjalan untuk **satu** scope (spec §11.7 "UI monitor"). `activeRuns` sengaja
  ## tidak dipakai di sini supaya status satu scope tidak menampilkan penutupan scope lain.
  for row in db.getAllRows(sql"""
      SELECT run_id::text FROM daycloser.run
       WHERE scope_type = ? AND coalesce(scope_id, '') = ?
         AND state IN ('PLANNED','PRECHECK','RUNNING','POSTCHECK','PAUSED')
       ORDER BY business_date DESC, started_at DESC NULLS LAST
       LIMIT 1""", scopeType, scopeId):
    return some(db.snapshot(row[0]))
  none(RunSnapshot)

proc recentRuns*(db: DbConn; scopeType, scopeId: string; limit: int): seq[RunSnapshot] =
  ## Riwayat run untuk satu scope, tanggal bisnis (lalu waktu mulai) terbaru lebih dulu.
  for row in db.getAllRows(sql"""
      SELECT run_id::text FROM daycloser.run
       WHERE scope_type = ? AND coalesce(scope_id, '') = ?
       ORDER BY business_date DESC, started_at DESC NULLS LAST
       LIMIT ?::int""", scopeType, scopeId, $limit):
    result.add db.snapshot(row[0])

proc findSnapshot*(db: DbConn; runId: string): Option[RunSnapshot] =
  ## `snapshot` melempar galat untuk run yang tidak ada (bagi orkestrator itu bug). Endpoint baca
  ## memperlakukan "tidak ditemukan" sebagai jawaban biasa, jadi keberadaannya diperiksa dulu.
  for row in db.getAllRows(sql"""
      SELECT run_id::text FROM daycloser.run WHERE run_id = ?::uuid""", runId):
    return some(db.snapshot(row[0]))
  none(RunSnapshot)

proc upsertRegistry*(db: DbConn; task: DayCloseTask) =
  db.exec(sql"""
    INSERT INTO daycloser.task_registry
      (task_id, module, levels, kind, critical, idempotency, partition, required_params,
       updated_at)
    VALUES (?, ?, ?::text[], ?, ?, ?, ?, ?::text[], now())
    ON CONFLICT (task_id) DO UPDATE SET
      module = EXCLUDED.module, levels = EXCLUDED.levels, kind = EXCLUDED.kind,
      critical = EXCLUDED.critical, idempotency = EXCLUDED.idempotency,
      partition = EXCLUDED.partition, required_params = EXCLUDED.required_params,
      updated_at = now()""",
    task.id, task.module, textArray(levelsCsv(task.levels)), $task.kind, task.critical,
    $task.idempotency, $task.partition, textArray(task.requiredParams.join(",")))

proc registryRows*(db: DbConn): seq[RegistryRow] =
  for row in db.getAllRows(sql"""
      SELECT task_id, module, array_to_string(levels, ','), kind, critical, idempotency,
             partition, array_to_string(required_params, ',')
        FROM daycloser.task_registry ORDER BY task_id"""):
    result.add RegistryRow(
      taskId: row[0], module: row[1], levels: row[2], kind: parseTaskKind(row[3]),
      critical: row[4] == "t", idempotency: parseIdempotencyMode(row[5]),
      partition: parsePartitionStrategy(row[6]),
      requiredParams: (if row[7].len == 0: @[] else: row[7].split(',')))

proc checkpoint*(db: DbConn; scopeType, scopeId, taskId, entityKey: string): string =
  ## Tanggal buku terakhir yang sudah diproses untuk entitas ini; kosong bila belum pernah.
  for row in db.getAllRows(sql"""
      SELECT last_business_date::text FROM daycloser.checkpoint
       WHERE scope_type = ? AND scope_id = ? AND task_id = ? AND entity_key = ?""",
      scopeType, scopeId, taskId, entityKey):
    return row[0]
  ""

proc setCheckpoint*(db: DbConn; scopeType, scopeId, taskId, entityKey,
                    lastBusinessDate: string) =
  ## Hanya maju: checkpoint yang dimundurkan akan membuat task memproses ulang hari yang sudah
  ## diposting. `GREATEST` menjaga itu tanpa perlu percaya pemanggil.
  db.exec(sql"""
    INSERT INTO daycloser.checkpoint
      (scope_type, scope_id, task_id, entity_key, last_business_date, updated_at)
    VALUES (?, ?, ?, ?, ?::date, now())
    ON CONFLICT (scope_type, scope_id, task_id, entity_key) DO UPDATE SET
      last_business_date = GREATEST(daycloser.checkpoint.last_business_date,
                                    EXCLUDED.last_business_date),
      updated_at = now()""",
    scopeType, scopeId, taskId, entityKey, lastBusinessDate)
