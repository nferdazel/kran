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
