## Composition root perintah `ctl` day-close (spec §11.5, §12.5).
##
## Di sinilah tiga hal bertemu dan **hanya** di sini: registry task nyata, port `Store` yang
## memakai pool Postgres, dan keluaran operator. Modul `daycloser` sendiri tidak tahu DB.
##
## Perintah (sengaja terpisah dari `runCtl` umum karena memegang pool sendiri):
##   daycloser-status                     status untuk operator & gate deploy (kode keluar)
##   daycloser-run --business-date=...    rencanakan + jalankan penutupan satu hari
##   daycloser-resume --run=<uuid>        lanjutkan run PAUSED/FAILED/BLOCKED
##   daycloser-pause  --run=<uuid>        hentikan di batas chunk (langsung bila tak ada proses)
##   daycloser-cancel --run=<uuid>        batalkan; tanggal buku yang dibekukan dibuka kembali
##
## Siklus tanggal buku (spec §11.2/§11.5): `OPEN → CLOSING` saat gate pra-tutup lulus,
## `CLOSING → CLOSED` + rollover ke hari kerja berikutnya saat run disegel, dan `CLOSING → OPEN`
## bila percobaan penutupan dibatalkan (belum tersegel — bukan reopen EOD).

import std/[json, options, os, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"

import kernel/[auditcontext, businessdate, clock, dayclose, ids, paramkey, result]
import kernel/generated/paramkeys

import platform/domain/[audit, calendar, event, scope]
import platform/infrastructure/[audit_repo, calendar_repo, outbox_repo, param_repo]

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

  ## Scope yang dikelola `ctl` Fase 3. Penutupan per cabang menyusul bersama UI (T-139); menambah
  ## scope tanpa pemanggil hanya akan menjadi kode yang tidak teruji.
  ctlScopeType = "INSTITUTION"

  ## Task pertama yang terdaftar: menyapu klaim idempotensi kedaluwarsa (T-089, D-098).
  idempotencySweepTaskId = "platform.idempotency_sweep"

proc isoNow(clock: Clock): string =
  format(clock.now().utc, "yyyy-MM-dd'T'HH:mm:ss'Z'")

proc ctlAuditContext(clock: Clock; reason: string): AuditContext =
  ## `ctl` tidak punya pengguna: pelakunya tercatat lewat `device`, bukan user id palsu.
  newAuditContext(Id(""), device = "kran-api ctl", reason = reason, startedAt = clock.now())

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

proc assertInstitutionRun(snap: RunSnapshot; action: string) =
  if snap.scopeType != ctlScopeType or snap.scopeId.len > 0:
    raise newException(DayCloserError,
      action & " hanya mendukung penutupan institusi (run ini " & snap.scopeType &
      ":" & snap.scopeId & ")")

proc freezeBusinessDate*(pool: DbPool; clock: Clock; runId: string) =
  ## `OPEN → CLOSING` untuk tanggal run (spec §11.5 #3).
  ##
  ## Idempoten bila tanggal itu sudah `CLOSING`: resume setelah crash di antara freeze dan task
  ## pertama tidak boleh gagal hanya karena tanggalnya sudah dibekukan. Tanggal yang berbeda atau
  ## sudah `CLOSED` ditolak keras — membekukan tanggal lain berarti menutup buku yang salah.
  let actx = ctlAuditContext(clock, "day-close freeze")
  discard pool.withTx(proc(d: DbConn): int =
    let snap = d.snapshot(runId)
    assertInstitutionRun(snap, "freeze")
    let scope = institutionScope()
    let existing = businessDateOf(d, scope)
    if existing.isNone:
      # Baris tanggal buku dibuat oleh `runCmd --bootstrap`, bukan di sini: freeze yang membuat
      # baris sendiri akan "membootstrap" lewat jalur mana pun (mis. resume) tanpa pernyataan
      # operator, dan tanggal yang salah akan menetap untuk selamanya.
      raise newException(DayCloserError,
        "belum ada baris business_date untuk dibekukan; jalankan " & dayCloserRunCmd &
        " --bootstrap untuk tanggal buku pertama")
    let row = existing.get
    if row.currentDate != snap.businessDate:
      raise newException(DayCloserError,
        "tanggal buku " & row.currentDate & " bukan " & snap.businessDate &
        "; jalankan penutupan untuk tanggal buku yang berjalan")
    case row.state
    of bdsOpen:
      if not transitionBusinessDate(d, scope, bdsOpen, bdsClosing, Id("")):
        raise newException(DayCloserError,
          "tanggal buku " & snap.businessDate &
          " berubah saat dibekukan (proses lain menutupnya lebih dulu)")
      discard appendAudit(d, newAuditEntry(actx, "daycloser.date.freeze", "business_date",
        snap.businessDate, clock, businessDate = snap.businessDate,
        before = %*{"state": "OPEN"}, after = %*{"state": "CLOSING", "runId": runId}))
    of bdsClosing:
      discard # idempoten: freeze sudah terjadi pada percobaan sebelumnya
    of bdsClosed:
      raise newException(DayCloserError,
        "tanggal buku " & snap.businessDate & " sudah CLOSED; tidak bisa dibekukan lagi")
    1)

proc sealAndRollover*(pool: DbPool; clock: Clock; runId, at, summaryHash: string) =
  ## Transisi terakhir + segel tanggal dalam **satu transaksi**: `COMPLETED`, audit
  ## `run.finish`, `CLOSING → CLOSED`, rollover ke hari kerja berikutnya, event
  ## `BusinessDateOpened`. Run yang tersegel tidak boleh ada tanpa tanggal yang ikut maju, dan
  ## sebaliknya — keduanya satu fakta.
  let actx = ctlAuditContext(clock, "day-close selesai")
  discard pool.withTx(proc(d: DbConn): int =
    let snap = d.snapshot(runId)
    assertInstitutionRun(snap, "seal")

    d.setRunState(runId, rsCompleted, at, summaryHash)
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

    let scope = institutionScope()
    let bd = businessDateOf(d, scope)
    if bd.isNone or bd.get.currentDate != snap.businessDate:
      raise newException(DayCloserError,
        "tanggal buku bukan " & snap.businessDate & " saat menyegel; tidak menutup tanggal lain")
    if not transitionBusinessDate(d, scope, bdsClosing, bdsClosed, Id("")):
      raise newException(DayCloserError,
        "tanggal buku " & snap.businessDate & " tidak sedang CLOSING saat menyegel")

    let parsed = parseBusinessDate(snap.businessDate)
    if parsed.isErr:
      raise newException(DayCloserError,
        "tanggal buku run tidak sah: " & snap.businessDate)
    let nextIso = nextWorkingDay(parsed.value(),
      calendarShape(d, scope, snap.businessDate)).toIso
    if not rollOverBusinessDate(d, scope, nextIso, Id("")):
      raise newException(DayCloserError,
        "rollover tanggal buku gagal (state bukan CLOSED)")
    # Event ditulis di transaksi yang sama: tanggal buku baru tidak pernah "terbuka" tanpa
    # pemberitahuan, dan pemberitahuan tidak pernah mendahului faktanya.
    discard appendEvent(d, newOutboxEvent(newId(clock), "BusinessDateOpened", "business_date",
      snap.businessDate, "business_date.opened:" & ctlScopeType & ":" & nextIso,
      %*{"businessDate": nextIso, "closedDate": snap.businessDate,
         "scopeType": ctlScopeType, "scopeId": "", "runId": runId}))
    discard appendAudit(d, newAuditEntry(actx, "daycloser.date.rollover", "business_date",
      nextIso, clock, businessDate = nextIso,
      before = %*{"businessDate": snap.businessDate, "state": "CLOSED"},
      after = %*{"businessDate": nextIso, "state": "OPEN", "runId": runId}))
    1)

proc scopeOfRun(snap: RunSnapshot): ScopeRef =
  ## Scope milik run, dibaca dari snapshot. Dipakai jalur pemulihan (abort) yang harus bekerja
  ## untuk scope apa pun; penutupan sendiri tetap dibatasi `assertInstitutionRun`.
  if snap.scopeType == "INSTITUTION":
    institutionScope()
  elif snap.scopeType == "BRANCH" and snap.scopeId.len > 0:
    branchScope(snap.scopeId)
  else:
    raise newException(DayCloserError,
      "scope run tidak dikenal: " & snap.scopeType & ":" & snap.scopeId)

proc reopenDateIn(d: DbConn; actx: AuditContext; clock: Clock;
                  snap: RunSnapshot): bool =
  ## `CLOSING → OPEN` bila tanggal buku **milik run ini** masih `CLOSING`. No-op selain itu:
  ## `CLOSED` tidak pernah dibuka (spec §11.7), dan tanggal yang sudah maju bukan urusan run lama.
  let scope = scopeOfRun(snap)
  let bd = businessDateOf(d, scope)
  if bd.isNone or bd.get.currentDate != snap.businessDate or
      not canAbortClose(bd.get.state):
    return false
  if not abortClose(d, scope, Id("")):
    return false
  discard appendAudit(d, newAuditEntry(actx, "daycloser.date.reopen", "business_date",
    snap.businessDate, clock, businessDate = snap.businessDate,
    before = %*{"state": "CLOSING"},
    after = %*{"state": "OPEN", "runId": snap.runId}))
  true

proc cancelAndReopen*(pool: DbPool; clock: Clock; runId, at: string): bool =
  ## Pembatalan yang benar-benar diterapkan, **satu transaksi**: sisa task `CANCELED`, run
  ## `CANCELED`, tanggal buku dibuka kembali. Dipakai orkestrator (batas fase/chunk) dan
  ## `daycloser-cancel` saat tidak ada proses hidup.
  ##
  ## Satu transaksi bukan kerapian: urutan terpisah yang terputus meninggalkan `CANCELED` +
  ## `CLOSING`, dan keadaan itu menolak semua tulisan HTTP tanpa satu pun perintah pemulih.
  let actx = ctlAuditContext(clock, "day-close dibatalkan")
  pool.withTx(proc(d: DbConn): bool =
    let snap = d.snapshot(runId)
    d.cancelRemaining(runId, at)
    d.setRunState(runId, rsCanceled, at, "")
    reopenDateIn(d, actx, clock, snap))

proc reopenBusinessDate*(pool: DbPool; clock: Clock; runId: string): bool =
  ## Pemulihan idempoten untuk keadaan yang sudah terlanjur `CANCELED` + `CLOSING` (mis. run yang
  ## dibatalkan versi sebelumnya, atau tulisan DB langsung): membuka tanggal tanpa menyentuh run.
  let actx = ctlAuditContext(clock, "day-close dibatalkan")
  pool.withTx(proc(d: DbConn): bool =
    reopenDateIn(d, actx, clock, d.snapshot(runId)))

proc cancelRunNow*(pool: DbPool; clock: Clock; runId, at: string): bool =
  cancelAndReopen(pool, clock, runId, at)

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

  proc cancelRun(runId: string; at: string) =
    discard cancelAndReopen(pool, clock, runId, at)

  Store(createRun: createRun, snapshot: snapshot, setRunState: setRunState,
        freezeDate: proc(runId: string) = freezeBusinessDate(pool, clock, runId),
        sealRun: proc(runId: string; at, summaryHash: string) =
    sealAndRollover(pool, clock, runId, at, summaryHash),
        cancelRun: cancelRun,
        setTaskState: setTaskState, setChunkState: setChunkState,
        controlOf: controlOf, setControl: setControl, resetInFlight: resetInFlight)

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
  let ctx = ctlAuditContext(clock, "day-close " & action)
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
  ## `COMPLETED` sudah diaudit di dalam transaksi `sealAndRollover`; state lain ditulis di sini.
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
    last = db.latestRun(ctlScopeType, "")
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

proc runCmd(pool: DbPool; clock: Clock; businessDateRaw: string; bootstrap: bool): int =
  let dateRaw = businessDateRaw.strip
  if dateRaw.len == 0:
    stderr.writeLine "kran-api: " & dayCloserRunCmd & " butuh --business-date=<YYYY-MM-DD>"
    return 2
  let parsedDate = parseBusinessDate(dateRaw)
  if parsedDate.isErr:
    stderr.writeLine "kran-api: tanggal tidak sah: " & dateRaw
    return 2

  # Lock **sebelum** pemeriksaan keadaan: dua operator yang menjalankan tanggal yang sama tidak
  # boleh sama-sama lolos pemeriksaan lalu bertabrakan di index unik.
  let lockConn = pool.acquire()
  try:
    if not lockScope(lockConn, ctlScopeType, ""):
      stderr.writeLine "kran-api: run day-close lain sedang berjalan untuk scope institusi"
      return 3

    var info: WorkingDayInfo
    var bd: Option[BusinessDateRow]
    var existing: Option[RunSnapshot]
    discard pool.withConn(proc(db: DbConn): int =
      info = workingDayInfo(db, institutionScope(), dateRaw)
      bd = businessDateOf(db, institutionScope())
      existing = db.runForDate(ctlScopeType, "", dateRaw)
      1)

    if not info.isWorkingDay:
      stderr.writeLine "kran-api: " & dateRaw & " bukan hari kerja menurut kalender institusi"
      return 3
    if existing.isSome:
      # `CANCELED` = run yang sengaja dihentikan dan tanggalnya sudah dibuka kembali. Mengulang
      # tanggal itu adalah satu-satunya cara memajukan buku, jadi run baru diizinkan — index unik
      # DB (`run_one_per_date_uq`) memang mengecualikan state terminal. Keamanan ulang ini
      # bergantung pada idempotensi task (`imPerBusinessDate`), jadi task `NONE` tidak boleh
      # didaftarkan untuk penutupan (dicatat di ACCEPTED-LIMITS).
      if existing.get.state != rsCanceled:
        stderr.writeLine "kran-api: sudah ada run untuk " & dateRaw & " (" &
          $existing.get.state & ", " & existing.get.runId &
          "); gunakan daycloser-resume atau daycloser-cancel"
        return 3
      echo "mengulang penutupan " & dateRaw & ": run sebelumnya " &
        existing.get.runId & " " & $existing.get.state
    if bd.isNone and not bootstrap:
      stderr.writeLine "kran-api: belum ada baris business_date; tetapkan tanggal buku pertama " &
        "dengan --bootstrap (hanya sekali)"
      return 3
    if bd.isSome and bootstrap:
      stderr.writeLine "kran-api: tanggal buku sudah ada (" & bd.get.currentDate &
        " " & $bd.get.state & "); --bootstrap hanya untuk tanggal buku pertama"
      return 3
    if bd.isSome:
      if bd.get.currentDate != dateRaw:
        stderr.writeLine "kran-api: tanggal buku berjalan " & bd.get.currentDate &
          ", bukan " & dateRaw & "; tutup tanggal buku berjalan lebih dulu"
        return 3
      if bd.get.state == bdsClosing:
        stderr.writeLine "kran-api: tanggal buku " & dateRaw &
          " sedang CLOSING; lanjutkan run yang ada (daycloser-resume) atau batalkan " &
          "(daycloser-cancel) sebelum memulai run baru"
        return 3
      if bd.get.state != bdsOpen:
        stderr.writeLine "kran-api: tanggal buku " & dateRaw & " berstatus " &
          $bd.get.state & "; tidak ada penutupan yang bisa dimulai"
        return 3

    if bd.isNone:
      # `--bootstrap` sudah diperiksa di atas: membuat baris di sini berarti operator menyatakannya
      # secara eksplisit. Port `freezeBusinessDate` tidak pernah membuat baris diam-diam.
      discard pool.withTx(proc(db: DbConn): int =
        discard ensureBusinessDate(db, institutionScope(), dateRaw, Id(""))
        1)

    let reg = newRegistry()
    registerDayCloseTasks(reg, pool)
    syncRegistry(pool, reg)

    let config = pool.withConn(proc(db: DbConn): Config = readConfig(db, dateRaw))
    let req = RunRequest(
      scopeType: ctlScopeType, scopeId: "", businessDate: dateRaw,
      levels: info.closeLevels, mode: rmReal, config: config)
    let runId = $newId(clock)
    let store = makeStore(pool, clock)
    let planned = planRun(reg, store, runId, req)
    auditRun(pool, clock, runId, dateRaw, "daycloser.run.start",
      %*{"runId": runId, "businessDate": dateRaw, "levels": levelsCsv(info.closeLevels),
         "mode": "REAL", "config": config.configJson, "tasks": planned.tasks,
         "chunks": planned.chunks})
    echo "menjalankan day-close " & dateRaw & " level " & levelsCsv(info.closeLevels) &
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
    unlockScope(lockConn, ctlScopeType, "")
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

proc controlCmd(pool: DbPool; clock: Clock; runIdRaw: string;
                control: RunControl): int =
  let runId = runIdRaw.strip
  if runId.len == 0:
    stderr.writeLine "kran-api: perintah ini butuh --run=<uuid>"
    return 2
  let at = isoNow(clock)
  let snap = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
  if snap.state == rsCanceled and control == rcCancel:
    # Pemulihan: pembatalan sudah tercatat, tetapi tanggal buku bisa tertinggal `CLOSING` (mis.
    # proses mati di antara dua tulisan pada versi lama). Membuka tanggalnya idempoten dan tidak
    # menyentuh run — ini satu-satunya keadaan yang bisa menahan semua tulisan tanpa jalan keluar.
    if not reopenBusinessDate(pool, clock, runId):
      stderr.writeLine "kran-api: run " & runId & " sudah dibatalkan dan tanggal bukunya " &
        "tidak sedang dibekukan; tidak ada yang perlu dipulihkan"
      return 3
    echo "tanggal buku " & snap.businessDate & " dibuka kembali (pemulihan pembatalan)"
    auditRun(pool, clock, runId, snap.businessDate, "daycloser.run.cancel",
      %*{"runId": runId, "businessDate": snap.businessDate, "from": "CANCELED",
         "recoveredReopen": true})
    return 0
  elif snap.state in {rsCompleted, rsCanceled}:
    stderr.writeLine "kran-api: run " & runId & " sudah berakhir (" & $snap.state & ")"
    return 3

  # Lock scope memberi tahu apakah ada proses yang benar-benar menjalankan run ini. Bila tidak
  # ada (run PRECHECK/FAILED/PAUSED tanpa proses), perintah diterapkan di sini — menulis niat
  # yang tidak pernah dibaca hanya akan membuat operator mengira run sudah berhenti.
  let lockConn = pool.acquire()
  try:
    let live = not lockScope(lockConn, snap.scopeType, snap.scopeId)
    if live:
      discard pool.withConn(proc(d: DbConn): int =
        d.setControl(runId, control)
        1)
      echo "permintaan " & $control & " dicatat untuk run " & runId &
           " (dibaca orkestrator di batas chunk berikutnya)"
      return 0

    case control
    of rcCancel:
      discard cancelRunNow(pool, clock, runId, at)
      auditRun(pool, clock, runId, snap.businessDate, "daycloser.run.cancel",
        %*{"runId": runId, "businessDate": snap.businessDate, "from": $snap.state})
      echo "run " & runId & " DIBATALKAN; tanggal buku yang dibekukan dibuka kembali"
    of rcPause:
      if snap.state in {rsPlanned, rsPrecheck, rsRunning, rsPostcheck}:
        discard pool.withConn(proc(d: DbConn): int =
          d.setRunState(runId, rsPaused, at, "")
          1)
        echo "run " & runId & " DIPAUSE (tidak ada proses yang memegang lock)"
      else:
        echo "run " & runId & " tidak sedang berjalan (" & $snap.state & "); tidak ada yang dipause"
    of rcNone:
      discard
    let after = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
    printRun(after)
    0
  finally:
    unlockScope(lockConn, snap.scopeType, snap.scopeId)
    pool.release(lockConn)

proc runDayCloserCtl*(command, businessDate, runId: string;
                      bootstrap = false): int =
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
    of dayCloserRunCmd: runCmd(pool, clock, businessDate, bootstrap)
    of dayCloserResumeCmd: resumeCmd(pool, clock, runId)
    of dayCloserPauseCmd: controlCmd(pool, clock, runId, rcPause)
    of dayCloserCancelCmd: controlCmd(pool, clock, runId, rcCancel)
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
