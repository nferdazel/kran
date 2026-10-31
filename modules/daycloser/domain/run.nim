## Bentuk data satu run day-close (spec §11.5) — murni, tanpa I/O.
##
## Dipakai tiga lapisan sekaligus: orkestrator (application) menyusun rencana, repositori
## (infrastructure) menyimpannya, dan `ctl` membacanya untuk laporan. Karena itu tipe di sini
## tidak memuat koneksi, JSON teks, maupun detail SQL.

import std/json

import kernel/[dayclose, result]

import ./types

type
  Config* = object
    ## Nilai parameter `daycloser.*` yang **dibekukan saat run dibuat** dan dipakai ulang pada
    ## resume — mengubah parameter di tengah run tidak boleh mengubah perilaku run yang berjalan.
    chunkSize*: int
    maxAttempts*: int
    retryBackoffSeconds*: int

  RunRequest* = object
    scopeType*: string ## INSTITUTION | BRANCH (schema sudah siap; ctl Fase 3 = INSTITUTION)
    scopeId*: string   ## kosong untuk institusi
    businessDate*: string
    levels*: set[CloseLevel]
    mode*: RunMode
    config*: Config

  PlannedTask* = object
    taskId*: TaskId
    kind*: TaskKind
    critical*: bool
    chunks*: seq[Chunk]

  ChunkProgress* = object
    chunkNo*: int
    state*: ChunkState
    attempt*: int
    errorCode*: string

  TaskProgress* = object
    taskId*: TaskId
    kind*: TaskKind
    critical*: bool
    state*: TaskState
    attempt*: int
    errorCode*: string
    reason*: string
    chunks*: seq[ChunkProgress]

  RunSnapshot* = object
    runId*: string
    scopeType*: string
    scopeId*: string
    businessDate*: string
    levels*: set[CloseLevel]
    mode*: RunMode
    state*: RunState
    control*: RunControl
    config*: Config
    paramSnapshotHash*: string
    startedAt*: string
    finishedAt*: string
    summaryHash*: string
    tasks*: seq[TaskProgress]

  RunOutcome* = object
    state*: RunState
    summaryHash*: string
    succeeded*: int
    failed*: int
    skipped*: int

proc taskProgress*(snap: RunSnapshot, taskId: TaskId): TaskProgress =
  ## Raise `DayCloserError` bila task tidak ada di snapshot — registry dan baris DB harus
  ## sepakat; ketidaksepakatan itu bug, bukan kondisi yang bisa dilewati.
  for t in snap.tasks:
    if t.taskId == taskId:
      return t
  raise newException(DayCloserError,
    "task " & taskId & " tidak ada di run " & snap.runId)

proc configJson*(c: Config): JsonNode =
  %*{"chunkSize": c.chunkSize, "maxAttempts": c.maxAttempts,
     "retryBackoffSeconds": c.retryBackoffSeconds}

proc parseConfig*(n: JsonNode): Config =
  ## Raise `DayCloserError` bila snapshot rusak: run yang tidak bisa dibaca konfigurasinya
  ## tidak boleh dijalankan dengan tebakan.
  if n.isNil or n.kind != JObject:
    raise newException(DayCloserError, "snapshot parameter run bukan objek JSON")
  try:
    result = Config(
      chunkSize: n["chunkSize"].getInt.int,
      maxAttempts: n["maxAttempts"].getInt.int,
      retryBackoffSeconds: n["retryBackoffSeconds"].getInt.int)
  except KeyError, ValueError:
    raise newException(DayCloserError, "snapshot parameter run tidak lengkap: " & $n)
  if result.chunkSize < 1 or result.maxAttempts < 1 or result.retryBackoffSeconds < 0:
    raise newException(DayCloserError, "snapshot parameter run di luar batas: " & $n)

proc planChunks*(task: DayCloseTask, ctx: TaskContext,
                 chunkSize: int): Result[seq[Chunk], TaskError] =
  ## Rencana chunk **tidak berubah** setelah run dibuat: resume memakai baris chunk yang sudah
  ## tersimpan, bukan menghitung ulang (data bisa bertambah di antara dua percobaan).
  if chunkSize < 1:
    raise newException(DayCloserError, "chunk size harus >= 1, dapat " & $chunkSize)
  case task.partition
  of psSingle:
    result = ok[seq[Chunk], TaskError](@[Chunk(chunkNo: 0)])
  of psByChunkCount:
    let counted = task.countChunks(ctx, chunkSize)
    if counted.isErr:
      return err[seq[Chunk], TaskError](counted.error())
    let n = counted.value()
    if n < 0:
      return err[seq[Chunk], TaskError](
        taskError("DAY-102", "jumlah chunk negatif untuk " & task.id))
    var chunks: seq[Chunk]
    for i in 0 ..< n:
      chunks.add Chunk(chunkNo: i)
    result = ok[seq[Chunk], TaskError](chunks)
