## Handler REST **baca** day-close (T-139a, spec §11.7).
##
## Hanya membaca: status tanggal buku, riwayat run, dan detail task/chunk. Aksi
## (run/resume/pause/cancel) adalah commit terpisah dan memakai jalur `ctl` yang sama — berkas ini
## tidak memuat logika penutupan, hanya menerjemahkan `RunSnapshot` (repositori) ke bentuk kontrak.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[dayclose, ids, result]
import platform/domain/scope
import platform/infrastructure/calendar_repo
import daycloser/domain/[run, types]
import daycloser/infrastructure/run_repo

import ./access
import ./business_date_view
import ./context
import ./db_bridge
import ./daycloser_service
import ./http_util
import ./problem

const
  ## Izin dibaca dari katalog (migrasi `0061`/`0063`), bukan string bebas di handler.
  permissionDayCloseRead* = "dayclose.run.read"
  ## Menjalankan/menghentikan penutupan. Dipisah dari izin baca: memantau bukan mengoperasikan.
  permissionDayCloseManage* = "dayclose.run.manage"

  ## Batas jumlah run: nilai **teknis** (ukuran respons), bukan ambang bisnis.
  defaultDayCloseRunLimit* = 20 # nomagic:ok ukuran halaman default
  maxDayCloseRunLimit* = 100    # nomagic:ok batas atas ukuran respons

  ## Satu-satunya scope yang dikenal Fase 3 (spec §11.2, D-148); penutupan cabang belum ada.
  institutionScopeType = "INSTITUTION"

proc respondInstitutionOnly(req: Request, permission: string) =
  ## Day-close adalah data **tingkat institusi** (satu tanggal buku untuk semua cabang, spec §11.2):
  ## grant yang dibatasi satu cabang tidak membuka monitor ini (D-062).
  req.respondProblem(newProblem(pkForbidden, "Forbidden",
    "aksi tingkat institusi " & permission & " hanya boleh dengan grant tanpa batas cabang",
    traceId = traceIdFrom(req),
    params = @[("reason", "branch_not_allowed"), ("permission", permission)]))

proc jsonOrNull(s: string): JsonNode =
  if s.len == 0: newJNull() else: %s

proc levelsJson(snap: RunSnapshot): JsonNode =
  ## Urutan tetap (EOD..EOY) supaya respons stabil antar run.
  result = newJArray()
  for lvl in CloseLevel:
    if lvl in snap.levels:
      result.add %($lvl)

proc taskCountsJson(snap: RunSnapshot): JsonNode =
  var ok, failed, skipped = 0
  for t in snap.tasks:
    case t.state
    of tsSucceeded: inc ok
    of tsFailed: inc failed
    of tsSkipped: inc skipped
    else: discard
  %*{"ok": ok, "failed": failed, "skipped": skipped, "total": snap.tasks.len}

proc chunkJson(c: ChunkProgress): JsonNode =
  %*{
    "chunkNo": c.chunkNo,
    "state": $c.state,
    "attempt": c.attempt,
    "errorCode": jsonOrNull(c.errorCode),
  }

proc taskJson(t: TaskProgress): JsonNode =
  var chunks = newJArray()
  for c in t.chunks:
    chunks.add chunkJson(c)
  %*{
    "taskId": t.taskId,
    "kind": $t.kind,
    "critical": t.critical,
    "state": $t.state,
    "attempt": t.attempt,
    "errorCode": jsonOrNull(t.errorCode),
    "reason": jsonOrNull(t.reason),
    "chunks": chunks,
  }

proc runSummaryJson(snap: RunSnapshot): JsonNode =
  %*{
    "runId": snap.runId,
    "businessDate": snap.businessDate,
    "scopeType": snap.scopeType,
    "levels": levelsJson(snap),
    "state": $snap.state,
    "startedAt": snap.startedAt,
    "finishedAt": jsonOrNull(snap.finishedAt),
    "summaryHash": jsonOrNull(snap.summaryHash),
    "taskCounts": taskCountsJson(snap),
  }

proc runDetailJson(snap: RunSnapshot): JsonNode =
  ## Detail = ringkasan + daftar task beserta chunk-nya. Hitungan tetap di `taskCounts` supaya
  ## kunci yang sama tidak berarti dua hal berbeda di dua bentuk respons (ringkasan vs detail).
  result = runSummaryJson(snap)
  var tasks = newJArray()
  for t in snap.tasks:
    tasks.add taskJson(t)
  result["tasks"] = tasks

proc handleDayCloseStatus*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/dayclose/status` — tanggal buku + run aktif + run terakhir.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDayCloseRead):
    return

  var status = 0
  var businessDate = newJNull()
  var activeRun = newJNull()
  var latestRun = newJNull()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionDayCloseRead):
          status = 403
          return
        let row = businessDateOf(db, institutionScope())
        if row.isSome:
          businessDate = businessDateJson(row.get())
        let active = db.activeRunFor(institutionScopeType, "")
        if active.isSome:
          activeRun = runSummaryJson(active.get())
        let last = db.latestRun(institutionScopeType, "")
        if last.isSome:
          latestRun = runSummaryJson(last.get())
        status = 200)
  except DbError:
    status = 500
  except DayCloserError:
    status = 500

  case status
  of 200:
    req.respondJson(200, %*{"businessDate": businessDate, "activeRun": activeRun,
                            "latestRun": latestRun})
  of 403:
    req.respondInstitutionOnly(permissionDayCloseRead)
  else:
    req.respondProblem(pkInternal, "Internal Server Error", "status day-close gagal dibaca")

proc handleListDayCloseRuns*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/dayclose/runs?limit=` — riwayat run, terbaru lebih dulu.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDayCloseRead):
    return

  var limit = defaultDayCloseRunLimit
  let limitParam = queryValue(req, "limit").strip()
  if limitParam.len > 0:
    try:
      limit = parseInt(limitParam)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus angka")
      return
    if limit < 1 or limit > maxDayCloseRunLimit:
      req.respondProblem(pkBadRequest, "Bad Request",
        "limit harus antara 1 dan " & $maxDayCloseRunLimit)
      return

  var status = 0
  var runs = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionDayCloseRead):
          status = 403
          return
        for snap in db.recentRuns(institutionScopeType, "", limit):
          runs.add runSummaryJson(snap)
        status = 200)
  except DbError:
    status = 500
  except DayCloserError:
    status = 500

  case status
  of 200:
    req.respondJson(200, %*{"runs": runs})
  of 403:
    req.respondInstitutionOnly(permissionDayCloseRead)
  else:
    req.respondProblem(pkInternal, "Internal Server Error", "riwayat day-close gagal dibaca")

proc handleGetDayCloseRun*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/dayclose/runs/{runId}` — detail task + chunk satu run.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDayCloseRead):
    return

  # Id yang tidak berbentuk uuid dijawab sama dengan id yang tidak ada: keduanya "run tidak
  # ditemukan". Membedakannya hanya memberi tahu bentuk id tanpa manfaat bagi pemanggil, dan pola
  # ini sama dengan penutupan periode di `handlers_ledger`.
  let runId = parseId(pathParam(req, "runId").strip())
  if runId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "run day-close tidak ditemukan")
    return

  var status = 0
  var payload = newJNull()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionDayCloseRead):
          status = 403
          return
        let snap = findSnapshot(db, $runId.value())
        if snap.isNone:
          status = 404
          return
        payload = runDetailJson(snap.get())
        status = 200)
  except DbError:
    status = 500
  except DayCloserError:
    status = 500

  case status
  of 200:
    req.respondJson(200, payload)
  of 403:
    req.respondInstitutionOnly(permissionDayCloseRead)
  of 404:
    req.respondProblem(pkNotFound, "Not Found", "run day-close tidak ditemukan")
  else:
    req.respondProblem(pkInternal, "Internal Server Error", "detail day-close gagal dibaca")

# ---------------------------------------------------------------------------------------------
# Aksi (T-139a/actions): jalankan, resume, pause, batalkan.
#
# Handler tidak memuat aturan penutupan: semuanya lewat `daycloser_service.nim`, jalur yang sama
# dengan `daycloser-*` di server. Yang dilakukan di sini hanya otorisasi, pemetaan hasil ke status
# HTTP, dan pembacaan nilai yang memang milik HTTP (query/path).
# ---------------------------------------------------------------------------------------------

proc institutionStatus(app: AppContext; principal: Principal; permission: string): int {.gcsafe.} =
  ## 200 = izin berlaku di tingkat institusi, 403 = grant terbatas cabang, 500 = basis data gagal.
  var status = 500
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        status = if authorizedAtBranch(db, principal, "", permission): 200 else: 403)
  except DbError:
    status = 500
  status

proc respondAction(req: Request; res: ActionResult) =
  ## Satu pemetaan untuk keempat aksi, supaya `run`/`resume`/`pause`/`cancel` tidak menjawab
  ## status berbeda untuk sebab yang sama.
  case res.status
  of asOk:
    if res.hasSnapshot:
      req.respondJson(200, runSummaryJson(res.snapshot))
    else:
      req.respondJson(200, newJObject())
  of asInvalid:
    req.respondProblem(newProblem(pkBadRequest, "Bad Request", res.message,
      traceId = traceIdFrom(req), params = @[("reason", res.code)]))
  of asNotFound:
    req.respondProblem(newProblem(pkNotFound, "Not Found", res.message,
      traceId = traceIdFrom(req), params = @[("reason", res.code)]))
  of asConflict, asBusy:
    req.respondProblem(newProblem(pkConflict, "Conflict", res.message,
      traceId = traceIdFrom(req), params = @[("reason", res.code)]))

proc currentBusinessDate(app: AppContext): string {.gcsafe.} =
  ## Tanggal buku berjalan, dibaca hanya bila pemanggil tidak menyebutkannya.
  var date = ""
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let row = businessDateOf(db, institutionScope())
        if row.isSome:
          date = row.get().currentDate)
  except DbError:
    date = ""
  date

proc handleStartDayClose*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/dayclose/run` — jalankan penutupan tanggal buku berjalan.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDayCloseManage):
    return
  case app.institutionStatus(principal, permissionDayCloseManage)
  of 403:
    req.respondInstitutionOnly(permissionDayCloseManage)
    return
  of 500:
    req.respondProblem(pkInternal, "Internal Server Error",
      "status day-close gagal dibaca")
    return
  else: discard

  var dateRaw = queryValue(req, "businessDate").strip()
  if dateRaw.len == 0:
    dateRaw = app.currentBusinessDate()
    if dateRaw.len == 0:
      req.respondProblem(newProblem(pkConflict, "Conflict",
        "belum ada baris business_date; tetapkan tanggal buku pertama lewat ctl",
        traceId = traceIdFrom(req), params = @[("reason", "bootstrap_required")]))
      return
  # Diminta eksplisit: endpoint ini tidak pernah "membuat" tanggal buku pertama.
  var res: ActionResult
  try:
    {.cast(gcsafe).}:
      res = startRunAction(app.pool, app.clock, dateRaw, bootstrap = false)
  except DayCloserError as e:
    req.respondProblem(newProblem(pkConflict, "Conflict", e.msg,
      traceId = traceIdFrom(req), params = @[("reason", "dayclose_error")]))
    return
  except IOError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "penutupan gagal dijalankan")
    return
  req.respondAction(res)

proc handleResumeDayClose*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/dayclose/runs/{runId}/resume`.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDayCloseManage):
    return
  case app.institutionStatus(principal, permissionDayCloseManage)
  of 403:
    req.respondInstitutionOnly(permissionDayCloseManage)
    return
  of 500:
    req.respondProblem(pkInternal, "Internal Server Error",
      "status day-close gagal dibaca")
    return
  else: discard

  var res: ActionResult
  try:
    {.cast(gcsafe).}:
      res = resumeRunAction(app.pool, app.clock, pathParam(req, "runId"))
  except DayCloserError as e:
    req.respondProblem(newProblem(pkConflict, "Conflict", e.msg,
      traceId = traceIdFrom(req), params = @[("reason", "dayclose_error")]))
    return
  except IOError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "run day-close gagal dilanjutkan")
    return
  req.respondAction(res)

proc handlePauseDayClose*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/dayclose/runs/{runId}/pause` — berhenti di batas chunk.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDayCloseManage):
    return
  case app.institutionStatus(principal, permissionDayCloseManage)
  of 403:
    req.respondInstitutionOnly(permissionDayCloseManage)
    return
  of 500:
    req.respondProblem(pkInternal, "Internal Server Error",
      "status day-close gagal dibaca")
    return
  else: discard

  var res: ActionResult
  try:
    {.cast(gcsafe).}:
      res = controlRunAction(app.pool, app.clock, pathParam(req, "runId"), rcPause)
  except DayCloserError as e:
    req.respondProblem(newProblem(pkConflict, "Conflict", e.msg,
      traceId = traceIdFrom(req), params = @[("reason", "dayclose_error")]))
    return
  except IOError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "run day-close gagal dipause")
    return
  req.respondAction(res)

proc handleCancelDayClose*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/dayclose/runs/{runId}/cancel` — batalkan dan buka kembali tanggal buku.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDayCloseManage):
    return
  case app.institutionStatus(principal, permissionDayCloseManage)
  of 403:
    req.respondInstitutionOnly(permissionDayCloseManage)
    return
  of 500:
    req.respondProblem(pkInternal, "Internal Server Error",
      "status day-close gagal dibaca")
    return
  else: discard

  var res: ActionResult
  try:
    {.cast(gcsafe).}:
      res = controlRunAction(app.pool, app.clock, pathParam(req, "runId"), rcCancel)
  except DayCloserError as e:
    req.respondProblem(newProblem(pkConflict, "Conflict", e.msg,
      traceId = traceIdFrom(req), params = @[("reason", "dayclose_error")]))
    return
  except IOError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "run day-close gagal dibatalkan")
    return
  req.respondAction(res)
