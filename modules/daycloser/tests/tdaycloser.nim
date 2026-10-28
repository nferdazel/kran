## Unit test kerangka day-close (T-134): registry/DAG, state machine, rencana chunk, level.
##
## Murni (tanpa DB). Persistence + orkestrasi nyata diuji `itdaycloser`; jalur `ctl` di
## `itapi_roles` (kode keluar gate deploy).

import std/[json, sequtils, unittest]

import kernel/[dayclose, result]

import ../application/orchestrator
import ../domain/[registry, run, state, types]

proc noopRun(ctx: TaskContext, chunk: Chunk): TaskResult =
  ok[TaskOutcome, TaskError](okOutcome())

proc task(id: string; module = "platform"; levels: set[CloseLevel] = {clEOD};
          kind = tkProcess; deps: seq[string] = @[]; critical = true;
          partition = psSingle; countChunks: proc(ctx: TaskContext, chunkSize: int):
            Result[int, TaskError] {.closure.} = nil): DayCloseTask =
  DayCloseTask(id: id, module: module, levels: levels, kind: kind, dependsOn: deps,
    critical: critical, idempotency: imPerBusinessDate, partition: partition,
    requiredParams: @[], countChunks: countChunks, run: noopRun)

suite "daycloser: registry":
  test "registrasi sah menyimpan task secara berurutan":
    let r = newRegistry()
    r.register task("platform.a")
    r.register task("platform.b", deps = @["platform.a"])
    check r.len == 2
    check "platform.a" in r
    check r.all().mapIt(it.id) == @["platform.a", "platform.b"]

  test "id ganda / awalan modul salah / level kosong / run kosong ditolak":
    let r = newRegistry()
    r.register task("platform.a")
    expect DayCloserError:
      r.register task("platform.a")
    expect DayCloserError:
      r.register task("ledger.b", module = "platform")
    expect DayCloserError:
      r.register task("platform.empty", levels = {})
    var tanpaRun = task("platform.norun")
    tanpaRun.run = nil
    expect DayCloserError:
      r.register tanpaRun

  test "BY_CHUNK_COUNT tanpa countChunks ditolak":
    let r = newRegistry()
    expect DayCloserError:
      r.register task("platform.c", partition = psByChunkCount)

  test "dependensi tak terdaftar & dependensi diri ditolak":
    let r = newRegistry()
    expect DayCloserError:
      r.register task("platform.a", deps = @["platform.missing"])
    expect DayCloserError:
      r.register task("platform.a", deps = @["platform.a"])

  test "resolve menyaring level dan mengurutkan dependensi":
    let r = newRegistry()
    r.register task("platform.pre", levels = {clEOD, clEOM}, kind = tkPreCheck)
    r.register task("platform.body", levels = {clEOD}, deps = @["platform.pre"])
    r.register task("platform.month", levels = {clEOM}, deps = @["platform.body"])
    r.register task("platform.year", levels = {clEOY})

    check r.resolve({clEOD}).mapIt(it.id) == @["platform.pre", "platform.body"]
    check r.resolve({clEOD, clEOM}).mapIt(it.id) ==
      @["platform.pre", "platform.body", "platform.month"]
    check r.resolve({clEOD, clEOM, clEOY}).len == 4

  test "dependensi di luar level yang diminta ditolak, bukan ditarik diam-diam":
    let r = newRegistry()
    r.register task("platform.month", levels = {clEOM})
    r.register task("platform.body", levels = {clEOD}, deps = @["platform.month"])
    expect DayCloserError:
      discard r.resolve({clEOD})

  test "resolve tanpa level ditolak":
    let r = newRegistry()
    expect DayCloserError:
      discard r.resolve({})

  test "urutan deterministik walau dependensi bercabang":
    let r = newRegistry()
    r.register task("platform.root")
    for id in ["platform.z", "platform.a", "platform.m"]:
      r.register task(id, deps = @["platform.root"])
    # Kahn dengan antrean terurut: akar dulu, lalu anak-anak menurut id.
    check r.resolve({clEOD}).mapIt(it.id) ==
      @["platform.root", "platform.a", "platform.m", "platform.z"]

suite "daycloser: fase & state machine":
  test "kind memetakan ke fase run":
    check phaseOf(tkPreCheck) == rsPrecheck
    check phaseOf(tkProcess) == rsRunning
    check phaseOf(tkReport) == rsRunning
    check phaseOf(tkPostCheck) == rsPostcheck

  test "jalur run yang sah":
    check canTransition(rsPlanned, rsPrecheck)
    check canTransition(rsPrecheck, rsRunning)
    check canTransition(rsRunning, rsPostcheck)
    check canTransition(rsPostcheck, rsCompleted)
    check canTransition(rsRunning, rsPaused)
    check canTransition(rsPaused, rsPrecheck)
    check canTransition(rsFailed, rsPrecheck)
    check canTransition(rsBlocked, rsPrecheck)

  test "lompatan & terminal ditolak":
    check not canTransition(rsPlanned, rsRunning)
    check not canTransition(rsPrecheck, rsCompleted)
    check not canTransition(rsCompleted, rsPrecheck)
    check not canTransition(rsCanceled, rsPrecheck)
    check not canTransition(rsPaused, rsRunning)

  test "task & chunk":
    check canTransition(tsPending, tsReady)
    check canTransition(tsReady, tsRunning)
    check canTransition(tsRunning, tsSucceeded)
    check canTransition(tsRunning, tsFailed)
    check canTransition(tsFailed, tsReady)
    check canTransition(tsRunning, tsPending) # sisa proses yang mati
    check not canTransition(tsSucceeded, tsRunning)
    check canTransition(csPending, csRunning)
    check canTransition(csRunning, csFailed)
    check canTransition(csFailed, csRunning)
    check not canTransition(csSucceeded, csRunning)

  test "parse menolak nilai tak dikenal":
    check parseRunState("RUNNING") == rsRunning
    expect DayCloserError:
      discard parseRunState("running")
    check parseChunkState("FAILED") == csFailed
    expect DayCloserError:
      discard parseRunControl("STOP")

  test "kebijakan transaksi saat closing hanya nilai yang bisa ditegakkan":
    check parseTxnPolicy("REJECT") == tpcReject
    check parseTxnPolicy("ALLOW") == tpcAllow
    # Spec menyebut "antri"; antrean belum ada, jadi nilainya sengaja tidak sah.
    expect DayCloserError:
      discard parseTxnPolicy("QUEUE")

suite "daycloser: rencana chunk":
  let ctx = TaskContext(runId: "r", scopeType: "INSTITUTION", scopeId: "",
    businessDate: "2026-10-25", levels: {clEOD}, mode: rmReal, chunkSize: 10)

  test "SINGLE selalu satu chunk":
    let planned = planChunks(task("platform.a"), ctx, 10)
    check planned.isOk
    check planned.value().len == 1
    check planned.value()[0].chunkNo == 0

  test "BY_CHUNK_COUNT mengikuti jumlah dari task":
    let counter = proc(c: TaskContext, chunkSize: int): Result[int, TaskError] =
      ok[int, TaskError](3)
    let planned = planChunks(task("platform.b", partition = psByChunkCount,
      countChunks = counter), ctx, 10)
    check planned.isOk
    check planned.value().mapIt(it.chunkNo) == @[0, 1, 2]

  test "jumlah negatif & kegagalan hitung diteruskan sebagai error":
    let negative = proc(c: TaskContext, chunkSize: int): Result[int, TaskError] =
      ok[int, TaskError](-1)
    let planned = planChunks(task("platform.c", partition = psByChunkCount,
      countChunks = negative), ctx, 10)
    check planned.isErr
    check planned.error().code == "DAY-102"

    let failed = proc(c: TaskContext, chunkSize: int): Result[int, TaskError] =
      err[int, TaskError](taskError("DAY-999", "db mati"))
    let planned2 = planChunks(task("platform.d", partition = psByChunkCount,
      countChunks = failed), ctx, 10)
    check planned2.isErr
    check planned2.error().code == "DAY-999"

  test "chunk size < 1 adalah bug konfigurasi (raise)":
    expect DayCloserError:
      discard planChunks(task("platform.a"), ctx, 0)

suite "daycloser: nilai kernel":
  test "levelsCsv deterministik & parse bolak-balik":
    check levelsCsv({clEOM, clEOD}) == "EOD,EOM"
    check parseLevelsCsv("EOM,EOD") == {clEOD, clEOM}
    check parseLevelsCsv("") == {}
    expect ValueError:
      discard parseCloseLevel("eod")

  test "config JSON bolak-balik":
    let c = Config(chunkSize: 500, maxAttempts: 2, retryBackoffSeconds: 7)
    check parseConfig(c.configJson) == c
    expect DayCloserError:
      discard parseConfig(%*{"chunkSize": 0, "maxAttempts": 1, "retryBackoffSeconds": 0})

# --- orkestrasi dengan Store palsu ---------------------------------------------------------------
#
# Port `Store` sengaja palsu di sini: yang diuji adalah **urutan** fase (freeze sebelum task proses,
# seal terakhir, tidak ada seal saat gagal/batal) — bukan SQL. Siklus business date yang sebenarnya
# diuji lewat perintah `ctl` di `apps/api/tests/itdaycloser_lifecycle.nim`.

type
  FakeRun = ref object
    snap: RunSnapshot
    calls: seq[string]
    control: RunControl
    sealFails: bool

proc pos(calls: seq[string]; needle: string): int =
  for i, c in calls:
    if c == needle:
      return i
  -1

proc fakeStore(f: FakeRun): Store =
  proc createRun(runId: string; req: RunRequest; plan: seq[PlannedTask]) =
    f.snap = RunSnapshot(runId: runId, scopeType: req.scopeType, scopeId: req.scopeId,
      businessDate: req.businessDate, levels: req.levels, mode: req.mode,
      state: rsPlanned, control: rcNone, config: req.config, paramSnapshotHash: "hash",
      tasks: plan.mapIt(TaskProgress(taskId: it.taskId, kind: it.kind,
        critical: it.critical, state: tsPending,
        chunks: it.chunks.mapIt(ChunkProgress(chunkNo: it.chunkNo, state: csPending)))))
    f.calls.add "createRun"

  proc findTask(taskId: string): int =
    for i, t in f.snap.tasks:
      if t.taskId == taskId:
        return i
    -1

  proc snapshot(runId: string): RunSnapshot =
    f.snap

  proc setRunState(runId: string; st: RunState; at: string; summaryHash: string) =
    f.snap.state = st
    f.calls.add "run:" & $st

  proc freezeDate(runId: string) =
    f.calls.add "freeze"

  proc sealRun(runId: string; at, summaryHash: string) =
    if f.sealFails:
      raise newException(DayCloserError, "segel gagal")
    f.snap.state = rsCompleted
    f.calls.add "seal"


  proc setTaskState(runId: string; taskId: TaskId; st: TaskState; at: string;
                    err, metrics: JsonNode) =
    let i = findTask(taskId)
    if i >= 0:
      f.snap.tasks[i].state = st
    f.calls.add "task:" & taskId & ":" & $st

  proc setChunkState(runId: string; taskId: TaskId; chunkNo: int; st: ChunkState;
                     at: string; err: JsonNode) =
    let i = findTask(taskId)
    if i >= 0:
      for j, ch in f.snap.tasks[i].chunks:
        if ch.chunkNo == chunkNo:
          f.snap.tasks[i].chunks[j].state = st
    f.calls.add "chunk:" & taskId & ":" & $st

  proc controlOf(runId: string): RunControl =
    f.control

  proc setControl(runId: string; control: RunControl) =
    f.control = control

  proc resetInFlight(runId: string) =
    f.calls.add "resetInFlight"

  proc cancelRun(runId: string; at: string) =
    # Port atomik: task + run + tanggal dalam satu panggilan. Fake mencatatnya sebagai satu
    # langkah supaya test urutan tidak bisa "lulus" karena tiga tulisan terpisah.
    for i in 0 ..< f.snap.tasks.len:
      if f.snap.tasks[i].state in {tsPending, tsReady, tsFailed}:
        f.snap.tasks[i].state = tsCanceled
    f.snap.state = rsCanceled
    f.calls.add "cancel"

  Store(createRun: createRun, snapshot: snapshot, setRunState: setRunState,
    freezeDate: freezeDate, sealRun: sealRun, cancelRun: cancelRun,
    setTaskState: setTaskState, setChunkState: setChunkState, controlOf: controlOf,
    setControl: setControl, resetInFlight: resetInFlight)

proc phaseTask(id: string; kind: TaskKind; f: FakeRun; critical = true;
               failWith = ""): DayCloseTask =
  DayCloseTask(id: id, module: "platform", levels: {clEOD}, kind: kind, dependsOn: @[],
    critical: critical, idempotency: imPerBusinessDate, partition: psSingle,
    requiredParams: @[],
    run: proc(ctx: TaskContext, chunk: Chunk): TaskResult =
    f.calls.add "ran:" & id
    if failWith.len > 0:
      return err[TaskOutcome, TaskError](taskError(failWith, "gagal (uji)"))
    ok[TaskOutcome, TaskError](okOutcome()))

proc fakeRequest(): RunRequest =
  RunRequest(scopeType: "INSTITUTION", scopeId: "", businessDate: "2026-10-26",
    levels: {clEOD}, mode: rmReal,
    config: Config(chunkSize: 10, maxAttempts: 1, retryBackoffSeconds: 0))

proc quiet(line: string) = discard
proc fixedNow(): string = "2026-10-26T00:00:00Z"
proc noSleep(ms: int) = discard

suite "daycloser: urutan fase business date":
  test "freeze terjadi setelah precheck dan sebelum task proses; seal terakhir":
    let f = FakeRun()
    let reg = newRegistry()
    reg.register phaseTask("platform.pre", tkPreCheck, f)
    reg.register phaseTask("platform.body", tkProcess, f)
    reg.register phaseTask("platform.report", tkReport, f)
    reg.register phaseTask("platform.post", tkPostCheck, f)
    let outcome = startRun(reg, f.fakeStore(), "run-ok", fakeRequest(),
      fixedNow, noSleep, quiet)
    check outcome.state == rsCompleted
    check pos(f.calls, "freeze") >= 0
    check pos(f.calls, "freeze") < pos(f.calls, "run:RUNNING")
    check pos(f.calls, "freeze") > pos(f.calls, "task:platform.pre:SUCCEEDED")
    check pos(f.calls, "seal") == f.calls.len - 1
    # Laporan berjalan di fase yang sama dengan proses, setelah freeze.
    check pos(f.calls, "ran:platform.report") > pos(f.calls, "freeze")
    check pos(f.calls, "ran:platform.post") > pos(f.calls, "ran:platform.body")

  test "precheck kritis gagal: tidak ada freeze, tidak ada seal, run FAILED":
    let f = FakeRun()
    let reg = newRegistry()
    reg.register phaseTask("platform.pre", tkPreCheck, f, failWith = "DAY-300")
    reg.register phaseTask("platform.body", tkProcess, f)
    let outcome = startRun(reg, f.fakeStore(), "run-fail", fakeRequest(),
      fixedNow, noSleep, quiet)
    check outcome.state == rsFailed
    check pos(f.calls, "freeze") == -1
    check pos(f.calls, "seal") == -1
    check pos(f.calls, "ran:platform.body") == -1

  test "segel gagal tidak meninggalkan run COMPLETED":
    let f = FakeRun()
    f.sealFails = true
    let reg = newRegistry()
    reg.register phaseTask("platform.body", tkProcess, f)
    expect DayCloserError:
      discard startRun(reg, f.fakeStore(), "run-seal", fakeRequest(),
        fixedNow, noSleep, quiet)
    check f.snap.state == rsPostcheck
    check pos(f.calls, "seal") == -1

  test "cancel membatalkan sisa task dan membuka kembali tanggal buku":
    let f = FakeRun()
    f.control = rcCancel
    let reg = newRegistry()
    reg.register phaseTask("platform.body", tkProcess, f)
    let outcome = startRun(reg, f.fakeStore(), "run-cancel", fakeRequest(),
      fixedNow, noSleep, quiet)
    check outcome.state == rsCanceled
    check pos(f.calls, "cancel") >= 0
    check pos(f.calls, "seal") == -1
    check pos(f.calls, "ran:platform.body") == -1

  test "pause tidak membuka tanggal buku dan tidak menyegel":
    let f = FakeRun()
    f.control = rcPause
    let reg = newRegistry()
    reg.register phaseTask("platform.body", tkProcess, f)
    let outcome = startRun(reg, f.fakeStore(), "run-pause", fakeRequest(),
      fixedNow, noSleep, quiet)
    check outcome.state == rsPaused
    check pos(f.calls, "seal") == -1
    check pos(f.calls, "cancel") == -1
    check pos(f.calls, "ran:platform.body") == -1
