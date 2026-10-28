## Tipe inti kerangka day-close (spec §11.4) — murni, tanpa I/O.
##
## Nama state dan level disimpan sebagai **teks yang sama** dengan yang tertulis di spec, supaya
## baris DB, log, dan keluaran `ctl` bisa dibaca tanpa kamus tambahan.

import std/[json, strutils]

import kernel/[dayclose, result]

type
  DayCloserError* = object of ValueError
    ## Pelanggaran kontrak **saat registrasi/plan** (programmer error, bukan galat runtime):
    ## task ganda, dependensi tak dikenal, level kosong. Fail-fast saat boot.

  TaskId* = string

  TaskKind* = enum
    ## Urutan eksekusi: semua `PRECHECK` → `PROCESS`/`REPORT` → `POSTCHECK`.
    tkPreCheck = "PRECHECK"
    tkProcess = "PROCESS"
    tkPostCheck = "POSTCHECK"
    tkReport = "REPORT"

  IdempotencyMode* = enum
    ## `imPerBusinessDate`: task aman dijalankan ulang untuk tanggal yang sama (mis. hapus baris
    ## kedaluwarsa). `imPerEntity`: task wajib memakai checkpoint per entitas (tabel
    ## `daycloser.checkpoint`) supaya catch-up multi-hari tidak menggandakan posting.
    imPerBusinessDate = "PER_BUSINESS_DATE"
    imPerEntity = "PER_ENTITY"
    imNone = "NONE"

  PartitionStrategy* = enum
    ## `psSingle`: satu chunk (kerja kecil atau seluruh tabel).
    ## `psByChunkCount`: task melaporkan jumlah chunk lewat `countChunks`; tiap chunk memilih
    ## potongannya sendiri dari nomor chunk (mis. kunci rekening per rentang).
    psSingle = "SINGLE"
    psByChunkCount = "BY_CHUNK_COUNT"

  RunMode* = enum
    rmReal = "REAL"
    rmSimulation = "SIMULATION"

  RunState* = enum
    rsPlanned = "PLANNED"
    rsPrecheck = "PRECHECK"
    rsRunning = "RUNNING"
    rsPostcheck = "POSTCHECK"
    rsCompleted = "COMPLETED"
    rsFailed = "FAILED"
    rsBlocked = "BLOCKED"
    rsPaused = "PAUSED"
    rsCanceled = "CANCELED"

  TaskState* = enum
    tsPending = "PENDING"
    tsReady = "READY"
    tsRunning = "RUNNING"
    tsSucceeded = "SUCCEEDED"
    tsFailed = "FAILED"
    tsSkipped = "SKIPPED"
    tsCanceled = "CANCELED"

  ChunkState* = enum
    csPending = "PENDING"
    csRunning = "RUNNING"
    csSucceeded = "SUCCEEDED"
    csFailed = "FAILED"

  RunControl* = enum
    ## Permintaan operator yang dibaca orkestrator **di batas chunk** (spec §11.7).
    rcNone = "NONE"
    rcPause = "PAUSE"
    rcCancel = "CANCEL"

  TaskError* = object
    code*: string    ## kode stabil untuk log/UI (bukan kalimat untuk pengguna)
    message*: string ## diagnostik
    retryable*: bool ## boleh dicoba ulang pada chunk yang sama

  TaskOutcome* = object
    skipped*: bool     ## task tidak relevan untuk segmen/hari ini (spec §11.7 "skip by rule")
    reason*: string    ## wajib terisi bila `skipped`
    metrics*: JsonNode ## angka hasil kerja (jumlah baris, durasi, dsb.); boleh nil

  TaskResult* = Result[TaskOutcome, TaskError]

  Chunk* = object
    ## Potongan kerja. `rangeStart`/`rangeEnd` hanya metadata untuk UI/audit; task yang memakai
    ## `psByChunkCount` memilih datanya sendiri dari `chunkNo`.
    chunkNo*: int
    rangeStart*: string
    rangeEnd*: string

  TaskContext* = object
    ## Konteks satu run. Tidak memuat koneksi DB: task menutup dependensinya sendiri saat
    ## registrasi (composition root), sehingga lapisan domain tetap murni.
    runId*: string
    scopeType*: string
    scopeId*: string
    businessDate*: string
    levels*: set[CloseLevel]
    mode*: RunMode
    chunkSize*: int ## potongan kerja efektif (dibekukan saat run dibuat)

  DayCloseTask* = object
    id*: TaskId
    module*: string
    levels*: set[CloseLevel]
    kind*: TaskKind
    dependsOn*: seq[TaskId]
    critical*: bool
    idempotency*: IdempotencyMode
    partition*: PartitionStrategy
    requiredParams*: seq[string]
    ## Jumlah chunk untuk satu run. Wajib untuk `psByChunkCount`; diabaikan untuk `psSingle`.
    countChunks*: proc(ctx: TaskContext, chunkSize: int): Result[int, TaskError] {.closure.}
    ## Kerja satu chunk. Wajib.
    run*: proc(ctx: TaskContext, chunk: Chunk): TaskResult {.closure.}
    ## Pemeriksaan pasca-kondisi setelah semua chunk sukses (opsional). Kegagalan diperlakukan
    ## sama dengan kegagalan task.
    verify*: proc(ctx: TaskContext): TaskResult {.closure.}

proc taskError*(code, message: string, retryable = false): TaskError =
  TaskError(code: code, message: message, retryable: retryable)

proc okOutcome*(metrics: JsonNode = nil): TaskOutcome =
  TaskOutcome(metrics: metrics)

proc skipOutcome*(reason: string): TaskOutcome =
  ## `reason` wajib: skip tanpa alasan tidak bisa diaudit (spec §11.7).
  if reason.strip.len == 0:
    raise newException(DayCloserError, "skip outcome tanpa alasan")
  TaskOutcome(skipped: true, reason: reason)

proc isTerminal*(s: RunState): bool =
  ## Hanya dua state yang tidak bisa dilanjutkan. `FAILED`/`BLOCKED` sengaja bukan terminal:
  ## spec §11.7 memberi operator jalur "resume setelah resolusi".
  s in {rsCompleted, rsCanceled}

proc isActive*(s: RunState): bool =
  ## Run yang **sedang berjalan** (menahan deploy, spec §11.7/§21.4). `FAILED`/`BLOCKED` tidak
  ## termasuk: tidak ada proses yang bekerja, dan gate tetap menahan lewat state business date
  ## `CLOSING` (T-135).
  s in {rsPlanned, rsPrecheck, rsRunning, rsPostcheck, rsPaused}
