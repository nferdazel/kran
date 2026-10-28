## Layanan day-close untuk composition root (T-139a, spec §11.5/§11.7).
##
## Berkas ini memegang **keputusan** penutupan — kapan run boleh dimulai, dilanjutkan, dipause,
## atau dibatalkan, dan apa yang harus terjadi pada tanggal buku — bukan cara menyampaikannya.
## `daycloser_ctl.nim` menerjemahkan `ActionResult` ke kode keluar + teks operator, sedangkan
## `handlers_dayclose.nim` menerjemahkannya ke status HTTP. Satu implementasi aturan, dua saluran:
## tombol di layar monitor dan perintah di server tidak boleh punya perilaku berbeda.
##
## Tidak ada `echo`/`exit` di sini, dan tidak ada yang membaca argumen command line: pemanggil
## sudah memvalidasi bentuk masukannya.

import std/[json, options, os, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[auditcontext, businessdate, clock, dayclose, ids, paramkey, result]
import kernel/generated/paramkeys

import platform/domain/[audit, calendar, event, scope]
import platform/infrastructure/[audit_repo, calendar_repo, outbox_repo, param_repo]

import daycloser/application/orchestrator
import daycloser/domain/[registry, run, types]
import daycloser/infrastructure/run_repo

import ./daycloser_common
import ./daycloser_tasks

const
  ## Scope yang dikelola Fase 3 (spec §11.2, D-148). Penutupan per cabang belum ada; menambah
  ## scope tanpa pemanggil hanya menghasilkan jalur yang tidak teruji.
  dayCloseScopeType* = "INSTITUTION"

type
  ActionStatus* = enum
    asOk       ## aksi diterima dan (bila menjalankan) sudah selesai
    asInvalid  ## argumen pemanggil tidak sah — salah pakai, bukan salah keadaan
    asNotFound ## run yang dimaksud tidak ada
    asConflict ## keadaan sekarang menolak aksi ini
    asBusy     ## proses lain memegang lock scope ini

  ActionResult* = object
    status*: ActionStatus
    message*: string ## kalimat untuk operator (ctl mencetaknya apa adanya)
    code*: string    ## kode mesin stabil untuk HTTP/UI, mis. `already_finished`
    runId*: string
    snapshot*: RunSnapshot
    hasSnapshot*: bool

proc isoNow*(clock: Clock): string =
  format(clock.now().utc, "yyyy-MM-dd'T'HH:mm:ss'Z'")

proc assertInstitutionRun(snap: RunSnapshot; action: string) =
  if snap.scopeType != dayCloseScopeType or snap.scopeId.len > 0:
    raise newException(DayCloserError,
      action & " hanya mendukung penutupan institusi (run ini " & snap.scopeType &
      ":" & snap.scopeId & ")")

proc resultOf(status: ActionStatus; code, message: string): ActionResult =
  ActionResult(status: status, code: code, message: message)

proc resultOf(status: ActionStatus; code, message: string;
              snap: RunSnapshot): ActionResult =
  ActionResult(status: status, code: code, message: message, runId: snap.runId,
    snapshot: snap, hasSnapshot: true)

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
      # Baris tanggal buku dibuat oleh `run --bootstrap`, bukan di sini: freeze yang membuat
      # baris sendiri akan "membootstrap" lewat jalur mana pun (mis. resume) tanpa pernyataan
      # operator, dan tanggal yang salah akan menetap untuk selamanya.
      raise newException(DayCloserError,
        "belum ada baris business_date untuk dibekukan; jalankan daycloser-run " &
        "--bootstrap untuk tanggal buku pertama")
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
      snap.businessDate, "business_date.opened:" & dayCloseScopeType & ":" & nextIso,
      %*{"businessDate": nextIso, "closedDate": snap.businessDate,
         "scopeType": dayCloseScopeType, "scopeId": "", "runId": runId}))
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
  ## `cancel` saat tidak ada proses hidup.
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

proc makeStore*(pool: DbPool; clock: Clock): Store =
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
                    err, metrics: JsonNode; reason: string) =
    discard pool.withConn(proc(d: DbConn): int =
      d.setTaskState(runId, taskId, st, at, err, metrics, reason)
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

proc readConfig*(db: DbConn; asOf: string): Config =
  let lookup = lookupFor(institutionScope())
  Config(
    chunkSize: activeParamInt(db, keyString(P_daycloser_chunk_size), asOf, lookup),
    maxAttempts: activeParamInt(db, keyString(P_daycloser_max_attempts), asOf, lookup),
    retryBackoffSeconds:
    activeParamInt(db, keyString(P_daycloser_retry_backoff_seconds), asOf, lookup))

proc logLine*(line: string) =
  echo line

proc sleepMs*(ms: int) =
  if ms > 0:
    sleep(ms)

proc auditRun*(pool: DbPool; clock: Clock; runId, businessDate, action: string;
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

proc auditOutcome*(pool: DbPool; clock: Clock; runId, businessDate: string;
                   outcome: RunOutcome) =
  ## `COMPLETED` sudah diaudit di dalam transaksi `sealAndRollover`; state lain ditulis di sini.
  if outcome.state == rsCompleted:
    return
  auditRun(pool, clock, runId, businessDate, "daycloser.run.finish",
    %*{"runId": runId, "businessDate": businessDate, "state": $outcome.state,
       "succeeded": outcome.succeeded, "failed": outcome.failed,
       "skipped": outcome.skipped})

proc startRunAction*(pool: DbPool; clock: Clock; businessDateRaw: string;
                     bootstrap = false): ActionResult =
  ## Mulai penutupan untuk satu tanggal. Semua penolakan yang mungkin terjadi **sebelum** run
  ## dibuat dilaporkan sebagai `ActionResult`, bukan exception, supaya operator (dan klien HTTP)
  ## menerima sebab yang bisa dibaca.
  let dateRaw = businessDateRaw.strip
  if dateRaw.len == 0:
    return resultOf(asInvalid, "business_date_required",
      "perintah ini butuh tanggal buku (YYYY-MM-DD)")
  let parsedDate = parseBusinessDate(dateRaw)
  if parsedDate.isErr:
    return resultOf(asInvalid, "invalid_business_date", "tanggal tidak sah: " & dateRaw)

  # Lock **sebelum** pemeriksaan keadaan: dua operator yang menjalankan tanggal yang sama tidak
  # boleh sama-sama lolos pemeriksaan lalu bertabrakan di index unik.
  let lockConn = pool.acquire()
  try:
    if not lockScope(lockConn, dayCloseScopeType, ""):
      return resultOf(asBusy, "scope_locked",
        "run day-close lain sedang berjalan untuk scope institusi")

    var info: WorkingDayInfo
    var bd: Option[BusinessDateRow]
    var existing: Option[RunSnapshot]
    discard pool.withConn(proc(db: DbConn): int =
      info = workingDayInfo(db, institutionScope(), dateRaw)
      bd = businessDateOf(db, institutionScope())
      existing = db.runForDate(dayCloseScopeType, "", dateRaw)
      1)

    if not info.isWorkingDay:
      return resultOf(asConflict, "not_working_day",
        dateRaw & " bukan hari kerja menurut kalender institusi")
    if existing.isSome:
      # `CANCELED` = run yang sengaja dihentikan dan tanggalnya sudah dibuka kembali. Mengulang
      # tanggal itu adalah satu-satunya cara memajukan buku, jadi run baru diizinkan — index unik
      # DB (`run_one_per_date_uq`) memang mengecualikan state terminal. Keamanan ulang ini
      # bergantung pada idempotensi task (`imPerBusinessDate`), jadi task `NONE` tidak boleh
      # didaftarkan untuk penutupan (dicatat di ACCEPTED-LIMITS).
      if existing.get.state != rsCanceled:
        return resultOf(asConflict, "run_exists",
          "sudah ada run untuk " & dateRaw & " (" & $existing.get.state & ", " &
          existing.get.runId & "); gunakan resume atau cancel")
    if bd.isNone and not bootstrap:
      return resultOf(asConflict, "bootstrap_required",
        "belum ada baris business_date; tetapkan tanggal buku pertama dengan --bootstrap " &
        "(hanya sekali, lewat ctl)")
    if bd.isSome and bootstrap:
      return resultOf(asConflict, "bootstrap_not_allowed",
        "tanggal buku sudah ada (" & bd.get.currentDate & " " & $bd.get.state &
        "); bootstrap hanya untuk tanggal buku pertama")
    if bd.isSome:
      if bd.get.currentDate != dateRaw:
        return resultOf(asConflict, "business_date_mismatch",
          "tanggal buku berjalan " & bd.get.currentDate & ", bukan " & dateRaw &
          "; tutup tanggal buku berjalan lebih dulu")
      if bd.get.state == bdsClosing:
        return resultOf(asConflict, "business_date_closing",
          "tanggal buku " & dateRaw &
          " sedang CLOSING; lanjutkan run yang ada atau batalkan sebelum memulai run baru")
      if bd.get.state != bdsOpen:
        return resultOf(asConflict, "business_date_closed",
          "tanggal buku " & dateRaw & " berstatus " & $bd.get.state &
          "; tidak ada penutupan yang bisa dimulai")

    if bd.isNone:
      # `bootstrap` sudah diperiksa di atas: membuat baris di sini berarti operator menyatakannya
      # secara eksplisit. freeze tidak pernah membuat baris diam-diam.
      discard pool.withTx(proc(db: DbConn): int =
        discard ensureBusinessDate(db, institutionScope(), dateRaw, Id(""))
        1)

    let reg = newRegistry()
    registerDayCloseTasks(reg, pool)
    syncRegistry(pool, reg)

    let config = pool.withConn(proc(db: DbConn): Config = readConfig(db, dateRaw))
    let req = RunRequest(
      scopeType: dayCloseScopeType, scopeId: "", businessDate: dateRaw,
      levels: info.closeLevels, mode: rmReal, config: config)
    let runId = $newId(clock)
    let store = makeStore(pool, clock)
    let planned = planRun(reg, store, runId, req)
    auditRun(pool, clock, runId, dateRaw, "daycloser.run.start",
      %*{"runId": runId, "businessDate": dateRaw, "levels": levelsCsv(info.closeLevels),
         "mode": "REAL", "config": config.configJson, "tasks": planned.tasks,
         "chunks": planned.chunks})
    logLine("menjalankan day-close " & dateRaw & " level " & levelsCsv(info.closeLevels) &
      " (run " & runId & ", " & $planned.tasks & " task / " & $planned.chunks & " chunk)")

    let now = proc(): string = isoNow(clock)
    let outcome = executeRun(reg, store, runId, now, sleepMs, logLine)

    auditOutcome(pool, clock, runId, dateRaw, outcome)
    let snap = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
    if outcome.state == rsCompleted:
      return resultOf(asOk, "completed", "penutupan " & dateRaw & " selesai", snap)
    resultOf(asOk, "finished_" & ($outcome.state).toLowerAscii(),
      "penutupan " & dateRaw & " berakhir " & $outcome.state, snap)
  finally:
    unlockScope(lockConn, dayCloseScopeType, "")
    pool.release(lockConn)

proc startSimulationAction*(pool: DbPool; clock: Clock; businessDateRaw: string): ActionResult =
  ## Dry-run `SIMULATION` (spec §11.7): menyusun rencana task/chunk yang **sama** dengan run nyata,
  ## lalu berhenti. Tidak menulis baris run, tidak menjalankan chunk, tidak membekukan tanggal.
  ##
  ## Yang diperiksa sama dengan `startRunAction` (hari kerja, tanggal buku, run ganda) supaya
  ## pratinjau tidak menjanjikan run yang toh akan ditolak. Yang **tidak** dibuktikan: apakah task
  ## akan gagal saat menulis (mis. `DAY-331` konfigurasi produk). Dry-run tingkat rencana, bukan
  ## eksekusi di transaksi ter-rollback — batas ini dicatat di `docs/ACCEPTED-LIMITS.md`.
  let dateRaw = businessDateRaw.strip
  if dateRaw.len == 0:
    return resultOf(asInvalid, "business_date_required",
      "perintah ini butuh tanggal buku (YYYY-MM-DD)")
  let parsedDate = parseBusinessDate(dateRaw)
  if parsedDate.isErr:
    return resultOf(asInvalid, "invalid_business_date", "tanggal tidak sah: " & dateRaw)

  var info: WorkingDayInfo
  var bd: Option[BusinessDateRow]
  var existing: Option[RunSnapshot]
  discard pool.withConn(proc(db: DbConn): int =
    info = workingDayInfo(db, institutionScope(), dateRaw)
    bd = businessDateOf(db, institutionScope())
    existing = db.runForDate(dayCloseScopeType, "", dateRaw)
    1)

  if not info.isWorkingDay:
    return resultOf(asConflict, "not_working_day",
      dateRaw & " bukan hari kerja menurut kalender institusi")
  if existing.isSome and existing.get.state != rsCanceled:
    return resultOf(asConflict, "run_exists",
      "sudah ada run untuk " & dateRaw & " (" & $existing.get.state & ", " &
      existing.get.runId & "); dry-run tidak merencanakan run kedua")
  if bd.isNone:
    return resultOf(asConflict, "bootstrap_required",
      "belum ada baris business_date; dry-run butuh tanggal buku yang sudah ditetapkan")
  if bd.get.currentDate != dateRaw:
    return resultOf(asConflict, "business_date_mismatch",
      "tanggal buku berjalan " & bd.get.currentDate & ", bukan " & dateRaw)
  if bd.get.state != bdsOpen:
    return resultOf(asConflict, "business_date_closed",
      "tanggal buku " & dateRaw & " berstatus " & $bd.get.state &
      "; dry-run hanya untuk tanggal OPEN")

  let reg = newRegistry()
  registerDayCloseTasks(reg, pool)
  let config = pool.withConn(proc(db: DbConn): Config = readConfig(db, dateRaw))
  let req = RunRequest(scopeType: dayCloseScopeType, scopeId: "", businessDate: dateRaw,
    levels: info.closeLevels, mode: rmSimulation, config: config)
  # `runId` hanya dipakai sebagai konteks task; tidak ada baris run yang dibuat.
  let planned = planTasks(reg, $newId(clock), req)

  var tasks = newJArray()
  var totalChunks = 0
  for p in planned:
    totalChunks += p.chunks.len
    tasks.add %*{"id": p.taskId, "kind": $p.kind, "critical": p.critical,
      "chunks": p.chunks.len}
  let report = %*{
    "mode": $rmSimulation,
    "businessDate": dateRaw,
    "levels": levelsCsv(info.closeLevels),
    "chunkSize": config.chunkSize,
    "tasks": tasks,
    "totalChunks": totalChunks,
    "writes": false,
  }
  resultOf(asOk, "simulated", report.pretty)

proc resumeRunAction*(pool: DbPool; clock: Clock; runIdRaw: string): ActionResult =
  ## Lanjutkan run yang belum berakhir (`PAUSED`/`FAILED`/`BLOCKED`). Run yang sudah
  ## `COMPLETED`/`CANCELED` ditolak: mengulangnya akan menutup tanggal yang sudah maju.
  let runId = runIdRaw.strip
  if isErr(parseId(runId)):
    return resultOf(asNotFound, "run_not_found", "run day-close tidak ditemukan")
  let reg = newRegistry()
  registerDayCloseTasks(reg, pool)
  syncRegistry(pool, reg)
  var found: Option[RunSnapshot]
  discard pool.withConn(proc(db: DbConn): int =
    found = findSnapshot(db, runId)
    1)
  if found.isNone:
    return resultOf(asNotFound, "run_not_found", "run day-close tidak ditemukan")
  let snap = found.get()
  if snap.state in {rsCompleted, rsCanceled}:
    return resultOf(asConflict, "already_finished",
      "run " & runId & " sudah berakhir (" & $snap.state & ")", snap)

  let lockConn = pool.acquire()
  try:
    if not lockScope(lockConn, snap.scopeType, snap.scopeId):
      return resultOf(asBusy, "scope_locked",
        "run day-close lain sedang berjalan untuk scope ini", snap)
    let store = makeStore(pool, clock)
    let now = proc(): string = isoNow(clock)
    let outcome = resumeRun(reg, store, runId, now, sleepMs, logLine)
    auditRun(pool, clock, runId, snap.businessDate, "daycloser.run.resume",
      %*{"runId": runId, "businessDate": snap.businessDate, "from": $snap.state,
         "to": $outcome.state})
    auditOutcome(pool, clock, runId, snap.businessDate, outcome)
    let after = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
    if outcome.state == rsCompleted:
      return resultOf(asOk, "completed", "run " & runId & " selesai", after)
    resultOf(asOk, "finished_" & ($outcome.state).toLowerAscii(),
      "run " & runId & " berakhir " & $outcome.state, after)
  finally:
    unlockScope(lockConn, snap.scopeType, snap.scopeId)
    pool.release(lockConn)

proc controlRunAction*(pool: DbPool; clock: Clock; runIdRaw: string;
                       control: RunControl): ActionResult =
  ## Pause/cancel. Bila ada proses yang memegang lock scope, niatnya dicatat dan dibaca
  ## orkestrator di batas chunk; bila tidak ada (run `PRECHECK`/`FAILED`/`PAUSED` tanpa proses),
  ## aksi diterapkan langsung — menulis niat yang tidak pernah dibaca hanya membuat operator
  ## mengira run sudah berhenti.
  let runId = runIdRaw.strip
  if isErr(parseId(runId)):
    return resultOf(asNotFound, "run_not_found", "run day-close tidak ditemukan")
  let at = isoNow(clock)
  var found: Option[RunSnapshot]
  discard pool.withConn(proc(db: DbConn): int =
    found = findSnapshot(db, runId)
    1)
  if found.isNone:
    return resultOf(asNotFound, "run_not_found", "run day-close tidak ditemukan")
  let snap = found.get()

  if snap.state == rsCanceled and control == rcCancel:
    # Pemulihan: pembatalan sudah tercatat, tetapi tanggal buku bisa tertinggal `CLOSING` (mis.
    # proses mati di antara dua tulisan pada versi lama). Membuka tanggalnya idempoten dan tidak
    # menyentuh run — ini satu-satunya keadaan yang bisa menahan semua tulisan tanpa jalan keluar.
    if not reopenBusinessDate(pool, clock, runId):
      return resultOf(asConflict, "already_canceled",
        "run " & runId & " sudah dibatalkan dan tanggal bukunya tidak sedang dibekukan", snap)
    auditRun(pool, clock, runId, snap.businessDate, "daycloser.run.cancel",
      %*{"runId": runId, "businessDate": snap.businessDate, "from": "CANCELED",
         "recoveredReopen": true})
    return resultOf(asOk, "already_canceled",
      "tanggal buku " & snap.businessDate & " dibuka kembali (pemulihan pembatalan)", snap)
  elif snap.state in {rsCompleted, rsCanceled}:
    return resultOf(asConflict, "already_finished",
      "run " & runId & " sudah berakhir (" & $snap.state & ")", snap)

  let lockConn = pool.acquire()
  try:
    let live = not lockScope(lockConn, snap.scopeType, snap.scopeId)
    if live:
      discard pool.withConn(proc(d: DbConn): int =
        d.setControl(runId, control)
        1)
      return resultOf(asOk, "control_requested",
        "permintaan " & $control & " dicatat untuk run " & runId &
        " (dibaca orkestrator di batas chunk berikutnya)", snap)

    var code = "noop"
    var message = "run " & runId & " tidak sedang berjalan (" & $snap.state &
      "); tidak ada yang dipause"
    var rejected = false
    case control
    of rcCancel:
      discard cancelRunNow(pool, clock, runId, at)
      auditRun(pool, clock, runId, snap.businessDate, "daycloser.run.cancel",
        %*{"runId": runId, "businessDate": snap.businessDate, "from": $snap.state})
      code = "canceled"
      message = "run " & runId & " DIBATALKAN; tanggal buku yang dibekukan dibuka kembali"
    of rcPause:
      if snap.state in {rsPlanned, rsPrecheck, rsRunning, rsPostcheck}:
        discard pool.withConn(proc(d: DbConn): int =
          d.setRunState(runId, rsPaused, at, "")
          1)
        code = "paused"
        message = "run " & runId & " DIPAUSE (tidak ada proses yang memegang lock)"
      else:
        # Meminta pause pada run yang memang tidak berjalan bukan keberhasilan: menjawab 200
        # akan membuat operator mengira ada yang berubah.
        rejected = true
    of rcNone:
      discard
    let after = pool.withConn(proc(db: DbConn): RunSnapshot = db.snapshot(runId))
    if rejected:
      return resultOf(asConflict, "not_running", message, after)
    resultOf(asOk, code, message, after)
  finally:
    unlockScope(lockConn, snap.scopeType, snap.scopeId)
    pool.release(lockConn)
