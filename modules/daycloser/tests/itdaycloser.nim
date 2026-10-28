## Test integrasi kerangka day-close (T-134) — butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan: persistence run/task/chunk, orkestrasi nyata (start, retry, resume, pause,
## cancel), segel hash, advisory lock, dan checkpoint yang hanya boleh maju. Task di sini fiktif
## dan hanya mencatat pemanggilan — tidak ada posting — supaya kegagalan yang diuji adalah
## kegagalan **kerangka**, bukan aturan bisnis modul lain.
##
## Test ini menghapus seluruh schema di DB dev (pola suite integrasi lain).

import std/[json, options, os, sets, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib

import kernel/[clock, dayclose, ids, result]

import ../application/orchestrator
import ../domain/[registry, run, types]
import ../infrastructure/run_repo

const
  repoRoot = "."
  fixedNow = "2026-10-25T00:00:00Z"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itdaycloser: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

type
  Recorder = ref object
    calls: seq[string]
    failOnce: HashSet[int] ## nomor chunk yang gagal sekali (percobaan pertama)

proc nowIso(): string = fixedNow

proc storeFor(pool: DbPool): Store =
  proc createRun(runId: string; req: RunRequest; plan: seq[PlannedTask]) =
    discard pool.withTx(proc(d: DbConn): int =
      d.insertRun(runId, req, plan, nowIso())
      1)
  proc snapshot(runId: string): RunSnapshot =
    pool.withConn(proc(d: DbConn): RunSnapshot = d.snapshot(runId))
  proc setRunState(runId: string; st: RunState; at: string; summaryHash: string) =
    discard pool.withConn(proc(d: DbConn): int =
      d.setRunState(runId, st, at, summaryHash)
      1)
  proc setTaskState(runId: string; taskId: TaskId; st: TaskState; at: string;
                    err, metrics: JsonNode) =
    discard pool.withConn(proc(d: DbConn): int =
      d.setTaskState(runId, taskId, st, at, err, metrics)
      1)
  proc setChunkState(runId: string; taskId: TaskId; chunkNo: int; st: ChunkState;
                     at: string; err: JsonNode) =
    discard pool.withConn(proc(d: DbConn): int =
      d.setChunkState(runId, taskId, chunkNo, st, at, err)
      1)
  proc controlOf(runId: string): RunControl =
    pool.withConn(proc(d: DbConn): RunControl = d.controlOf(runId))
  proc setControl(runId: string; control: RunControl) =
    discard pool.withConn(proc(d: DbConn): int =
      d.setControl(runId, control)
      1)
  proc resetInFlight(runId: string) =
    discard pool.withConn(proc(d: DbConn): int =
      d.resetInFlight(runId)
      1)
  proc completeRun(runId: string; at, summaryHash: string) =
    discard pool.withConn(proc(d: DbConn): int =
      d.setRunState(runId, rsCompleted, at, summaryHash)
      1)
  proc cancelRemaining(runId: string; at: string) =
    discard pool.withConn(proc(d: DbConn): int =
      d.cancelRemaining(runId, at)
      1)
  Store(createRun: createRun, snapshot: snapshot, setRunState: setRunState,
        completeRun: completeRun, setTaskState: setTaskState, setChunkState: setChunkState,
        controlOf: controlOf, setControl: setControl, resetInFlight: resetInFlight,
        cancelRemaining: cancelRemaining)

proc recordingTask(id: string; rec: Recorder; chunks = 1; critical = true;
                   deps: seq[string] = @[]; kind = tkProcess): DayCloseTask =
  let countChunks = proc(ctx: TaskContext; chunkSize: int): Result[int, TaskError] =
    ok[int, TaskError](chunks)
  DayCloseTask(
    id: id, module: "platform", levels: {clEOD}, kind: kind, dependsOn: deps,
    critical: critical, idempotency: imPerBusinessDate,
    partition: (if chunks == 1: psSingle else: psByChunkCount),
    requiredParams: @[],
    countChunks: (if chunks == 1: nil else: countChunks),
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    rec.calls.add id & ":" & $chunk.chunkNo
    if chunk.chunkNo in rec.failOnce:
      rec.failOnce.excl chunk.chunkNo
      return err[TaskOutcome, TaskError](
        taskError("DAY-900", "gagal sekali (uji)", retryable = false))
    ok[TaskOutcome, TaskError](okOutcome(%*{"chunk": chunk.chunkNo})))

proc syncRegistry(reg: Registry) =
  discard dbPool.withTx(proc(d: DbConn): int =
    for t in reg.all():
      d.upsertRegistry(t)
    1)

proc newRunId(): string = $newId(fakeClock(dateTime(2026, mOct, 25, 0, 0, 0)))

proc request(dateIso: string; cfg = Config(chunkSize: 10, maxAttempts: 1,
                                           retryBackoffSeconds: 0)): RunRequest =
  RunRequest(scopeType: "INSTITUTION", scopeId: "", businessDate: dateIso,
    levels: {clEOD}, mode: rmReal, config: cfg)

proc noSleep(ms: int) = discard
proc quiet(line: string) = discard

suite "daycloser: persistence & orkestrasi":
  test "run selesai, snapshot tersimpan, segel terisi":
    let rec = Recorder()
    let reg = newRegistry()
    let first = recordingTask("platform.first", rec, kind = tkPreCheck)
    let second = recordingTask("platform.second", rec, deps = @["platform.first"])
    reg.register first
    reg.register second
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let outcome = startRun(reg, store, runId,
      request("2026-10-01", Config(chunkSize: 10, maxAttempts: 1, retryBackoffSeconds: 0)),
      nowIso, noSleep, quiet)
    check outcome.state == rsCompleted
    check outcome.succeeded == 2
    check outcome.summaryHash.len == 64
    check rec.calls == @["platform.first:0", "platform.second:0"]

    let snap = db.snapshot(runId)
    check snap.state == rsCompleted
    check snap.levels == {clEOD}
    check snap.config.chunkSize == 10
    check snap.summaryHash == outcome.summaryHash
    check snap.startedAt.len > 0
    check snap.finishedAt.len > 0
    for t in snap.tasks:
      check t.state == tsSucceeded
      check t.chunks.len == 1
      check t.chunks[0].state == csSucceeded

  test "chunk gagal non-retryable → task FAILED; resume hanya mengulang chunk yang gagal":
    let rec = Recorder()
    rec.failOnce = toHashSet([1])
    let reg = newRegistry()
    reg.register recordingTask("platform.multi", rec, chunks = 2)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let cfg = Config(chunkSize: 1, maxAttempts: 1, retryBackoffSeconds: 0)
    let first = startRun(reg, store, runId, request("2026-10-02", cfg), nowIso, noSleep, quiet)
    check first.state == rsFailed
    check rec.calls == @["platform.multi:0", "platform.multi:1"]
    var snap = db.snapshot(runId)
    check snap.state == rsFailed
    check snap.tasks[0].state == tsFailed
    check snap.tasks[0].errorCode == "DAY-900"
    check snap.tasks[0].chunks[0].state == csSucceeded
    check snap.tasks[0].chunks[1].state == csFailed

    let second = resumeRun(reg, store, runId, nowIso, noSleep, quiet)
    check second.state == rsCompleted
    # Chunk 0 tidak dijalankan ulang; chunk 1 dicoba lagi satu kali.
    check rec.calls == @["platform.multi:0", "platform.multi:1", "platform.multi:1"]
    snap = db.snapshot(runId)
    check snap.tasks[0].attempt == 2

  test "chunk gagal retryable dicoba ulang sampai batas maxAttempts":
    let rec = Recorder()
    rec.failOnce = toHashSet([0])
    let reg = newRegistry()
    var attempts = 0
    let flaky = DayCloseTask(
      id: "platform.flaky", module: "platform", levels: {clEOD}, kind: tkProcess,
      dependsOn: @[], critical: true, idempotency: imPerBusinessDate, partition: psSingle,
      requiredParams: @[],
      run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
      inc attempts
      if attempts == 1:
        return err[TaskOutcome, TaskError](
          taskError("DAY-901", "sementara", retryable = true))
      ok[TaskOutcome, TaskError](okOutcome()))
    reg.register flaky
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let outcome = startRun(reg, store, runId,
      request("2026-10-03", Config(chunkSize: 10, maxAttempts: 2, retryBackoffSeconds: 0)),
      nowIso, noSleep, quiet)
    check outcome.state == rsCompleted
    check attempts == 2
    let snap = db.snapshot(runId)
    check snap.tasks[0].chunks[0].attempt == 2

  test "task non-kritis gagal tidak menggagalkan run":
    let rec = Recorder()
    rec.failOnce = toHashSet([0])
    let reg = newRegistry()
    reg.register recordingTask("platform.optional", rec, critical = false)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let outcome = startRun(reg, store, runId, request("2026-10-04"), nowIso, noSleep, quiet)
    check outcome.state == rsCompleted
    check outcome.failed == 1
    check db.snapshot(runId).tasks[0].state == tsFailed

  test "pause di batas fase, resume melanjutkan":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.pausable", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    # Run dibuat lalu dipause sebelum task pertama dieksekusi.
    let req = request("2026-10-05")
    store.createRun(runId, req, @[PlannedTask(taskId: "platform.pausable",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])
    db.setControl(runId, rcPause)
    let paused = executeRun(reg, store, runId, nowIso, noSleep, quiet)
    check paused.state == rsPaused
    check rec.calls.len == 0
    check db.snapshot(runId).state == rsPaused

    # Resume membersihkan permintaan PAUSE; tanpa itu run akan langsung dipause ulang.
    let finished = resumeRun(reg, store, runId, nowIso, noSleep, quiet)
    check finished.state == rsCompleted
    check db.controlOf(runId) == rcNone
    check rec.calls == @["platform.pausable:0"]

  test "pause dibaca di batas chunk, bukan menunggu task selesai":
    let rec = Recorder()
    let reg = newRegistry()
    let pausable = DayCloseTask(
      id: "platform.chunky", module: "platform", levels: {clEOD}, kind: tkProcess,
      dependsOn: @[], critical: true, idempotency: imPerBusinessDate,
      partition: psByChunkCount, requiredParams: @[],
      countChunks: proc(ctx: TaskContext; chunkSize: int): Result[int, TaskError] =
      ok[int, TaskError](2),
      run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
      rec.calls.add "chunky:" & $chunk.chunkNo
      if chunk.chunkNo == 0:
        # Meniru operator menekan pause saat chunk pertama selesai.
        db.setControl(ctx.runId, rcPause)
      ok[TaskOutcome, TaskError](okOutcome()))
    reg.register pausable
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let cfg = Config(chunkSize: 1, maxAttempts: 1, retryBackoffSeconds: 0)
    let paused = startRun(reg, store, runId, request("2026-10-08", cfg), nowIso, noSleep, quiet)
    check paused.state == rsPaused
    # Chunk 1 tidak pernah dijalankan: pause berlaku sebelum chunk berikutnya.
    check rec.calls == @["chunky:0"]
    var snap = db.snapshot(runId)
    check snap.state == rsPaused
    check snap.tasks[0].state == tsPending
    check snap.tasks[0].chunks[0].state == csSucceeded
    check snap.tasks[0].chunks[1].state == csPending

    let finished = resumeRun(reg, store, runId, nowIso, noSleep, quiet)
    check finished.state == rsCompleted
    check rec.calls == @["chunky:0", "chunky:1"]
    snap = db.snapshot(runId)
    check snap.tasks[0].state == tsSucceeded

  test "cancel menandai sisa task CANCELED":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.c", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let req = request("2026-10-06")
    store.createRun(runId, req, @[PlannedTask(taskId: "platform.c",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])
    db.setControl(runId, rcCancel)
    let outcome = executeRun(reg, store, runId, nowIso, noSleep, quiet)
    check outcome.state == rsCanceled
    check rec.calls.len == 0
    let snap = db.snapshot(runId)
    check snap.state == rsCanceled
    check snap.tasks[0].state == tsCanceled

  test "executeRun menolak state yang bukan awal (harus lewat resumeRun)":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.guard", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let req = request("2026-10-09")
    store.createRun(runId, req, @[PlannedTask(taskId: "platform.guard", kind: tkProcess,
      critical: true, chunks: @[Chunk(chunkNo: 0)])])
    db.setRunState(runId, rsPrecheck, nowIso(), "")
    db.setRunState(runId, rsRunning, nowIso(), "")
    expect DayCloserError:
      discard executeRun(reg, store, runId, nowIso, noSleep, quiet)
    check rec.calls.len == 0

  test "cancel pada run PAUSED diterapkan oleh resume, bukan dibuang":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.paused-cancel", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let req = request("2026-10-11")
    store.createRun(runId, req, @[PlannedTask(taskId: "platform.paused-cancel",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])
    db.setControl(runId, rcPause)
    check executeRun(reg, store, runId, nowIso, noSleep, quiet).state == rsPaused
    # Operator berubah pikiran: batalkan. Satu-satunya yang membaca control adalah resume.
    db.setControl(runId, rcCancel)
    let canceled = resumeRun(reg, store, runId, nowIso, noSleep, quiet)
    check canceled.state == rsCanceled
    check rec.calls.len == 0
    check db.snapshot(runId).state == rsCanceled

  test "task kritis yang meminta skip tidak pernah menjadi SUCCEEDED":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register DayCloseTask(
      id: "platform.refuses", module: "platform", levels: {clEOD}, kind: tkProcess,
      dependsOn: @[], critical: true, idempotency: imPerBusinessDate, partition: psSingle,
      requiredParams: @[],
      run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
      rec.calls.add "refuses"
      ok[TaskOutcome, TaskError](skipOutcome("tidak berlaku di segmen ini")))
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let first = startRun(reg, store, runId, request("2026-10-12"), nowIso, noSleep, quiet)
    check first.state == rsFailed
    var snap = db.snapshot(runId)
    check snap.tasks[0].state == tsFailed
    check snap.tasks[0].chunks[0].state == csPending # bukan SUCCEEDED
    # Resume mengulang penolakan yang sama; tidak boleh berubah menjadi sukses tanpa kerja.
    let second = resumeRun(reg, store, runId, nowIso, noSleep, quiet)
    check second.state == rsFailed
    check rec.calls.len == 2
    snap = db.snapshot(runId)
    check snap.tasks[0].state == tsFailed
    check snap.tasks[0].errorCode == "DAY-105"

  test "registry yang berubah sejak run dibuat ditolak sebelum state disentuh":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.only-old", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let req = request("2026-10-13")
    store.createRun(runId, req, @[PlannedTask(taskId: "platform.only-old",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])
    # Deploy baru menambah task; run lama tidak mengenalnya.
    let reg2 = newRegistry()
    reg2.register recordingTask("platform.only-old", rec)
    reg2.register recordingTask("platform.new-task", rec)
    syncRegistry(reg2)
    expect DayCloserError:
      discard resumeRun(reg2, store, runId, nowIso, noSleep, quiet)
    # Penolakan terjadi sebelum resetInFlight/setRunState: state tetap PLANNED.
    check db.snapshot(runId).state == rsPlanned
    check rec.calls.len == 0

  test "snapshot parameter yang diubah di luar aplikasi ditolak":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.tamper", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    store.createRun(runId, request("2026-10-14"), @[PlannedTask(taskId: "platform.tamper",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])
    execScript(db, """UPDATE daycloser.run
      SET param_snapshot = '{"chunkSize":1,"maxAttempts":9,"retryBackoffSeconds":0}'::jsonb
      WHERE run_id = '""" & runId & "'")
    expect DayCloserError:
      discard db.snapshot(runId)

  test "runForDate menemukan run pada tanggal yang sama":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.per-date", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    store.createRun(runId, request("2026-10-15"), @[PlannedTask(taskId: "platform.per-date",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])
    let found = db.runForDate("INSTITUTION", "", "2026-10-15")
    check found.isSome()
    check found.get().runId == runId
    check db.runForDate("INSTITUTION", "", "2026-10-16").isNone()

  test "satu run aktif per tanggal dijaga index, dan advisory lock menolak proses kedua":
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.lock", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    let req = request("2026-10-07")
    store.createRun(runId, req, @[PlannedTask(taskId: "platform.lock",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])

    # Run aktif kedua pada tanggal & scope yang sama ditolak basis data.
    var duplicateRejected = false
    try:
      discard dbPool.withTx(proc(d: DbConn): int =
        d.insertRun(newRunId(), req, @[PlannedTask(taskId: "platform.lock",
          kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])], nowIso())
        1)
    except DbError:
      duplicateRejected = true
    check duplicateRejected

    let second = newDbPool(dbConfigFromEnv(envT))
    defer: second.close()
    let other = second.acquire()
    defer: second.release(other)
    check lockScope(db, "INSTITUTION", "")
    check lockScope(other, "INSTITUTION", "") == false
    db.unlockScope("INSTITUTION", "")

  test "checkpoint hanya boleh maju":
    check db.checkpoint("INSTITUTION", "", "platform.cp", "acc-1") == ""
    db.setCheckpoint("INSTITUTION", "", "platform.cp", "acc-1", "2026-10-10")
    db.setCheckpoint("INSTITUTION", "", "platform.cp", "acc-1", "2026-10-08")
    check db.checkpoint("INSTITUTION", "", "platform.cp", "acc-1") == "2026-10-10"
    db.setCheckpoint("INSTITUTION", "", "platform.cp", "acc-1", "2026-10-12")
    check db.checkpoint("INSTITUTION", "", "platform.cp", "acc-1") == "2026-10-12"

  test "status membaca run aktif & run terakhir":
    execScript(db, "TRUNCATE daycloser.run CASCADE")
    let rec = Recorder()
    let reg = newRegistry()
    reg.register recordingTask("platform.status", rec)
    syncRegistry(reg)
    let store = storeFor(dbPool)
    let runId = newRunId()
    store.createRun(runId, request("2026-10-16"), @[PlannedTask(taskId: "platform.status",
      kind: tkProcess, critical: true, chunks: @[Chunk(chunkNo: 0)])])
    let active = db.activeRuns()
    check active.len == 1
    check active[0].runId == runId
    let latest = db.latestRun("INSTITUTION", "")
    check latest.isSome()
    check latest.get().runId == runId
