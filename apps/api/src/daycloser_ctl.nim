## Composition root perintah `ctl` day-close (spec §11.5, §12.5).
##
## Di sinilah tiga hal bertemu dan **hanya** di sini: registry task nyata, port `Store` yang
## memakai pool Postgres, dan keluaran operator. Modul `daycloser` sendiri tidak tahu DB.
##
## Perintah (sengaja terpisah dari `runCtl` umum karena memegang pool sendiri):
##   daycloser-status                     status untuk operator & gate deploy (kode keluar)
##   daycloser-run --business-date=...    rencanakan + jalankan penutupan satu hari
##   daycloser-resume --run=<uuid>        lanjutkan run PAUSED/FAILED/BLOCKED
##   daycloser-pause  --run=<uuid>        minta berhenti di batas chunk berikutnya
##   daycloser-cancel --run=<uuid>        minta berhenti & tandai sisa task CANCELED

import std/[json, options, os, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"

import kernel/[auditcontext, businessdate, clock, dayclose, ids, paramkey, result]
import kernel/generated/paramkeys

import platform/domain/[audit, calendar, scope]
import platform/infrastructure/[audit_repo, calendar_repo, param_repo]

import daycloser/application/orchestrator
import daycloser/domain/[registry, run, types]
import daycloser/infrastructure/run_repo

const
  dayCloserStatusCmd* = "daycloser-status"
  dayCloserRunCmd* = "daycloser-run"
  dayCloserResumeCmd* = "daycloser-resume"
  dayCloserPauseCmd* = "daycloser-pause"
  dayCloserCancelCmd* = "daycloser-cancel"

  dayCloserCommands* = [dayCloserStatusCmd, dayCloserRunCmd, dayCloserResumeCmd,
                        dayCloserPauseCmd, dayCloserCancelCmd]

  ## Task pertama yang terdaftar: menyapu klaim idempotensi kedaluwarsa (T-089, D-098).
  idempotencySweepTaskId = "platform.idempotency_sweep"

proc isoNow(clock: Clock): string =
  format(clock.now().utc, "yyyy-MM-dd'T'HH:mm:ss'Z'")

proc registerDayCloseTasks*(reg: Registry; pool: DbPool) =
  ## Registry nyata saat boot `ctl`. Task baru dari modul lain ditambahkan di sini pada fase
  ## berikutnya (ledger T-137, deposit T-138) — bukan dengan membuat batch sendiri.
  reg.register DayCloseTask(
    id: idempotencySweepTaskId,
    module: "platform",
    levels: {clEOD},
    kind: tkProcess,
    dependsOn: @[],
    critical: false,
    idempotency: imPerBusinessDate,
    partition: psSingle,
    requiredParams: @["platform.idempotency.ttl_hours"],
    run: proc(ctx: TaskContext; chunk: Chunk): TaskResult =
    ## Hapus bertahap: satu perintah menghapus paling banyak `chunkSize` baris, jadi tabel
    ## besar tidak menahan satu transaksi panjang. Baris kedaluwarsa tidak pernah dibaca lagi
    ## (klaim hanya melihat `expires_at > now()`), sehingga menghapusnya tidak mengubah replay
    ## yang sah.
    var total = 0
    let batch = max(1, ctx.chunkSize)
    try:
      while true:
        let deleted = pool.withConn(proc(db: DbConn): int =
          db.execAffectedRows(sql"""
              WITH doomed AS (
                SELECT principal_id, key
                  FROM platform.idempotency_key
                 WHERE expires_at <= now()
                 ORDER BY expires_at
                 LIMIT ?)
              DELETE FROM platform.idempotency_key k
               USING doomed d
               WHERE k.principal_id = d.principal_id AND k.key = d.key""", batch))
        total += deleted
        if deleted < batch:
          break
    except DbError as e:
      return err[TaskOutcome, TaskError](taskError(
        "DAY-201", "sapu idempotensi gagal: " & e.msg, retryable = true))
    ok[TaskOutcome, TaskError](okOutcome(%*{"deleted": total})))

proc syncRegistry(pool: DbPool; reg: Registry) =
  ## Registry in-process adalah sumber kebenaran eksekusi; tabel hanya salinan untuk UI/audit.
  ## Baris yang task-nya sudah tidak terdaftar **dihapus**: salinan yang menyebut task hantu lebih
  ## buruk daripada tidak ada salinan, karena UI akan menawarkan pekerjaan yang tidak bisa jalan.
  var ids, modules: seq[string]
  for task in reg.all():
    ids.add task.id
    if task.module notin modules:
      modules.add task.module
  discard pool.withTx(proc(db: DbConn): int =
    for task in reg.all():
      db.upsertRegistry(task)
    # Hanya modul yang didaftarkan proses ini yang dipangkas: composition root lain (worker,
    # ctl modul lain, test) boleh mendaftarkan subset dan tidak boleh menghapus baris modul lain.
    if ids.len > 0:
      discard db.execAffectedRows(sql"""
        DELETE FROM daycloser.task_registry
         WHERE module = ANY(?::text[]) AND task_id <> ALL(?::text[])""",
        textArray(modules.join(",")), textArray(ids.join(",")))
    1)

proc makeStore(pool: DbPool; clock: Clock): Store =
  ## Setiap operasi memakai blok `withConn` pendek sendiri: orkestrasi bisa berjalan berjam-jam,
  ## dan memegang satu koneksi sepanjang itu akan memicu batas waktu kueri milik pool
  ## (statement_timeout + margin), memutus koneksi di tengah run yang sehat.
  proc createRun(runId: string; req: RunRequest; plan: seq[PlannedTask]) =
    discard pool.withTx(proc(d: DbConn): int =
      d.insertRun(runId, req, plan, isoNow(clock))
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

  proc cancelRemaining(runId: string; at: string) =
    discard pool.withConn(proc(d: DbConn): int =
      d.cancelRemaining(runId, at)
      1)

  proc completeRun(runId: string; at, summaryHash: string) =
    ## Transisi COMPLETED dan audit `run.finish` di **satu transaksi**: run yang tersegel tidak
    ## boleh ada tanpa bukti audit hanya karena proses mati di antara dua perintah.
    let actx = newAuditContext(Id(""), device = "kran-api ctl",
      reason = "day-close selesai", startedAt = clock.now())
    discard pool.withTx(proc(d: DbConn): int =
      d.setRunState(runId, rsCompleted, at, summaryHash)
      let snap = d.snapshot(runId)
      var ok, failed, skipped: int
      for t in snap.tasks:
        case t.state
        of tsSucceeded: inc ok
        of tsFailed: inc failed
        of tsSkipped: inc skipped
        else: discard
      discard appendAudit(d, newAuditEntry(actx, "daycloser.run.finish", "daycloser_run", runId,
        clock, businessDate = snap.businessDate,
        after = %*{"runId": runId, "businessDate": snap.businessDate, "state": "COMPLETED",
                   "summaryHash": summaryHash, "succeeded": ok, "failed": failed,
                   "skipped": skipped}))
      1)

  Store(createRun: createRun, snapshot: snapshot, setRunState: setRunState,
        completeRun: completeRun,
        setTaskState: setTaskState, setChunkState: setChunkState,
        controlOf: controlOf, setControl: setControl, resetInFlight: resetInFlight,
        cancelRemaining: cancelRemaining)

proc readConfig(db: DbConn; asOf: string): Config =
  let lookup = lookupFor(institutionScope())
  Config(
    chunkSize: activeParamInt(db, keyString(P_daycloser_chunk_size), asOf, lookup),
    maxAttempts: activeParamInt(db, keyString(P_daycloser_max_attempts), asOf, lookup),
    retryBackoffSeconds:
    activeParamInt(db, keyString(P_daycloser_retry_backoff_seconds), asOf, lookup))

proc logLine(line: string) =
  echo line

proc sleepMs(ms: int) =
  if ms > 0:
    sleep(ms)

proc printRun(snap: RunSnapshot) =
  var ok, failed, skipped, done = 0
  for t in snap.tasks:
    case t.state
    of tsSucceeded: inc ok; inc done
    of tsFailed: inc failed
    of tsSkipped: inc skipped; inc done
    of tsCanceled: inc done
    else: discard
  echo "run " & snap.runId & ": tanggal=" & snap.businessDate & " level=" &
    levelsCsv(snap.levels) & " state=" & $snap.state & " task=" & $done & "/" &
    $snap.tasks.len & " (ok=" & $ok & ", gagal=" & $failed & ", lewati=" & $skipped & ")" &
    (if snap.summaryHash.len > 0: " segel=" & snap.summaryHash[0 ..< 12] else: "")

proc auditRun(pool: DbPool; clock: Clock; runId, businessDate, action: string;
              after: JsonNode) =
  ## Audit ditulis setelah fakta terjadi. Kegagalan audit **tidak** membatalkan run yang sudah
  ## berjalan (posting tidak bisa ditarik kembali), tetapi dilaporkan ke stderr supaya operator
  ## melihatnya — dan run tetap tercatat di tabel `daycloser.run` sebagai sumber kedua.
  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "day-close " & action, startedAt = clock.now())
  try:
    discard pool.withTx(proc(db: DbConn): int =
      discard appendAudit(db, newAuditEntry(ctx, action, "daycloser_run", runId, clock,
        businessDate = businessDate, after = after))
      1)
  except IOError as e:
    # DbError dan PoolError sama-sama IOError; kegagalan audit tidak boleh membatalkan penutupan
    # yang sudah menulis jurnal, tetapi harus terlihat operator.
    stderr.writeLine "kran-api: audit " & action & " gagal ditulis: " & e.msg

proc auditOutcome(pool: DbPool; clock: Clock; runId, businessDate: string;
                  outcome: RunOutcome) =
  ## `COMPLETED` sudah diaudit di dalam transaksi `completeRun`; state lain ditulis di sini.
  if outcome.state == rsCompleted:
    return
  auditRun(pool, clock, runId, businessDate, "daycloser.run.finish",
    %*{"runId": runId, "businessDate": businessDate, "state": $outcome.state,
       "succeeded": outcome.succeeded, "failed": outcome.failed,
       "skipped": outcome.skipped})

proc statusCmd(pool: DbPool; clock: Clock): int =
  var active: seq[RunSnapshot]
  var bd: Option[BusinessDateRow]
  var last: Option[RunSnapshot]
  discard pool.withConn(proc(db: DbConn): int =
    active = db.activeRuns()
    bd = businessDateOf(db, institutionScope())
    last = db.latestRun("INSTITUTION", "")
    1)

  var frozen = false
  if bd.isSome:
    echo "tanggal buku: " & bd.get.currentDate & " " & $bd.get.state
    if bd.get.state == bdsClosing:
      frozen = true
  else:
    echo "tanggal buku: (belum ada baris platform.business_date)"

  if active.len > 0:
    frozen = true
    for run in active:
      printRun(run)
  else:
    echo "run aktif: tidak ada"
    if last.isSome:
      printRun(last.get)

  echo (if frozen: "deploy: DITAHAN (ada penutupan belum selesai)" else: "deploy: boleh")
  if frozen:
    return 1
  0

proc runCmd(pool: DbPool; clock: Clock; businessDateRaw: string): int =
  let dateRaw = businessDateRaw.strip
  if dateRaw.len == 0:
    stderr.writeLine "kran-api: " & dayCloserRunCmd & " butuh --business-date=<YYYY-MM-DD>"
    return 2
  let parsed = parseBusinessDate(dateRaw)
  if parsed.isErr:
    stderr.writeLine "kran-api: tanggal tidak sah: " & dateRaw
    return 2

  var levels: set[CloseLevel]
  var working = false
  var currentDate = ""
  discard pool.withConn(proc(db: DbConn): int =
    let info = workingDayInfo(db, institutionScope(), dateRaw)
    levels = info.closeLevels
    working = info.isWorkingDay
    let bd = businessDateOf(db, institutionScope())
    if bd.isSome:
      currentDate = bd.get.currentDate
    1)
  if not working:
    stderr.writeLine "kran-api: " & dateRaw & " bukan hari kerja menurut kalender institusi"
    return 3
  if currentDate.len > 0 and dateRaw > currentDate:
    # Sebelum T-135 mengelola rollover, tanggal masa depan tidak punya arti: menutupnya akan
    # memposting akrual/snapshot untuk hari yang belum terjadi (review T-134 #11).
    stderr.writeLine "kran-api: " & dateRaw & " melewati tanggal buku " & currentDate &
      "; majukan tanggal buku lewat penutupan hari yang berjalan"
    return 3

  let existing = pool.withConn(proc(db: DbConn): Option[RunSnapshot] =
    db.runForDate("INSTITUTION", "", dateRaw))
  if existing.isSome:
    stderr.writeLine "kran-api: sudah ada run untuk " & dateRaw & " (" & $existing.get.state &
      ", " & existing.get.runId & "); gunakan daycloser-resume atau daycloser-cancel"
    return 3

  let reg = newRegistry()
  registerDayCloseTasks(reg, pool)
  syncRegistry(pool, reg)

  let lockConn = pool.acquire()
  try:
    if not lockScope(lockConn, "INSTITUTION", ""):
      stderr.writeLine "kran-api: run day-close lain sedang berjalan untuk scope institusi"
      return 3

    let config = pool.withConn(proc(db: DbConn): Config = readConfig(db, dateRaw))
    let req = RunRequest(
      scopeType: "INSTITUTION", scopeId: "", businessDate: dateRaw, levels: levels,
      mode: rmReal, config: config)
    let runId = $newId(clock)
    let store = makeStore(pool, clock)
    let planned = planRun(reg, store, runId, req)
    auditRun(pool, clock, runId, dateRaw, "daycloser.run.start",
      %*{"runId": runId, "businessDate": dateRaw, "levels": levelsCsv(levels),
         "mode": "REAL", "config": config.configJson, "tasks": planned.tasks,
         "chunks": planned.chunks})
    echo "menjalankan day-close " & dateRaw & " level " & levelsCsv(levels) &
         " (run " & runId & ", " & $planned.tasks & " task / " & $planned.chunks & " chunk)"

    let now = proc(): string = isoNow(clock)
    let outcome = executeRun(reg, store, runId, now, sleepMs, logLine)

    auditOutcome(pool, clock, runId, dateRaw, outcome)
    let snap = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
    printRun(snap)
    if outcome.state == rsCompleted:
      return 0
    return 1
  finally:
    unlockScope(lockConn, "INSTITUTION", "")
    pool.release(lockConn)

proc resumeCmd(pool: DbPool; clock: Clock; runIdRaw: string): int =
  let runId = runIdRaw.strip
  if runId.len == 0:
    stderr.writeLine "kran-api: " & dayCloserResumeCmd & " butuh --run=<uuid>"
    return 2
  let reg = newRegistry()
  registerDayCloseTasks(reg, pool)
  syncRegistry(pool, reg)
  let snap = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
  if snap.state in {rsCompleted, rsCanceled}:
    stderr.writeLine "kran-api: run " & runId & " sudah berakhir (" & $snap.state & ")"
    return 3

  let lockConn = pool.acquire()
  try:
    if not lockScope(lockConn, snap.scopeType, snap.scopeId):
      stderr.writeLine "kran-api: run day-close lain sedang berjalan untuk scope ini"
      return 3
    let store = makeStore(pool, clock)
    let now = proc(): string = isoNow(clock)
    let outcome = resumeRun(reg, store, runId, now, sleepMs, logLine)
    auditRun(pool, clock, runId, snap.businessDate, "daycloser.run.resume",
      %*{"runId": runId, "businessDate": snap.businessDate, "from": $snap.state,
         "to": $outcome.state})
    auditOutcome(pool, clock, runId, snap.businessDate, outcome)
    let after = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
    printRun(after)
    if outcome.state == rsCompleted: return 0
    return 1
  finally:
    unlockScope(lockConn, snap.scopeType, snap.scopeId)
    pool.release(lockConn)

proc controlCmd(pool: DbPool; runIdRaw: string; control: RunControl): int =
  let runId = runIdRaw.strip
  if runId.len == 0:
    stderr.writeLine "kran-api: perintah ini butuh --run=<uuid>"
    return 2
  var state: RunState
  discard pool.withConn(proc(db: DbConn): int =
    state = db.snapshot(runId).state
    1)
  if state in {rsCompleted, rsCanceled}:
    stderr.writeLine "kran-api: run " & runId & " sudah berakhir (" & $state & ")"
    return 3
  discard pool.withConn(proc(db: DbConn): int =
    db.setControl(runId, control)
    1)
  echo "permintaan " & $control & " dicatat untuk run " & runId &
       " (dibaca orkestrator di batas chunk berikutnya)"
  0

proc runDayCloserCtl*(command, businessDate, runId: string): int =
  ## Titik masuk dari `main`. Kode keluar: 0 sukses/idle, 1 gagal atau ada penutupan yang belum
  ## selesai (gate deploy membacanya sebagai "tahan"), 2 salah pakai/konfigurasi, 3 ditolak
  ## pada keadaan sekarang.
  if not databaseUrlSet(envTableFromProcess()):
    stderr.writeLine "kran-api: KRAN_DATABASE_URL kosong — perintah day-close butuh basis data"
    return 2
  let clock = systemClock()
  let pool = newDbPool(dbConfigFromProcessEnv())
  defer: pool.close()
  try:
    case command
    of dayCloserStatusCmd: statusCmd(pool, clock)
    of dayCloserRunCmd: runCmd(pool, clock, businessDate)
    of dayCloserResumeCmd: resumeCmd(pool, clock, runId)
    of dayCloserPauseCmd: controlCmd(pool, runId, rcPause)
    of dayCloserCancelCmd: controlCmd(pool, runId, rcCancel)
    else:
      stderr.writeLine "kran-api: perintah day-close tidak dikenal: " & command
      2
  except DayCloserError as e:
    stderr.writeLine "kran-api: day-close ditolak: " & e.msg
    3
  except IOError as e:
    # DbError dan PoolError (batas waktu pool/soket mati) sama-sama IOError.
    stderr.writeLine "kran-api: gagal terhadap basis data: " & e.msg
    1
  except ValueError as e:
    stderr.writeLine "kran-api: nilai tidak sah: " & e.msg
    2
