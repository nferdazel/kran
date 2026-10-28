## Handler REST **baca** day-close (T-139a, spec §11.7).
##
## Hanya membaca: status tanggal buku, riwayat run, dan detail task/chunk. Aksi
## (run/resume/pause/cancel) adalah commit terpisah dan memakai jalur `ctl` yang sama — berkas ini
## tidak memuat logika penutupan, hanya menerjemahkan `RunSnapshot` (repositori) ke bentuk kontrak.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[dayclose, ids, result]
import platform/domain/calendar
import platform/domain/scope
import platform/infrastructure/calendar_repo
import daycloser/domain/[run, types]
import daycloser/infrastructure/run_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  ## Izin dibaca dari katalog (migrasi `0061_platform_rbac_dayclose.sql`), bukan string bebas.
  permissionDayCloseRead* = "dayclose.run.read"

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
    # Alasannya belum disimpan di DB (hanya `error` jsonb yang tersimpan), jadi selalu `null`.
      # Kontrak membiarkannya nullable supaya commit berikutnya bisa mengisinya tanpa breaking.
    "reason": newJNull(),
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
    "tasks": taskCountsJson(snap),
  }

proc runDetailJson(snap: RunSnapshot): JsonNode =
  ## Detail = ringkasan + daftar task. Kunci `tasks` pada ringkasan memuat **hitungan**, sedangkan
  ## di detail kunci yang sama memuat daftar task beserta chunk-nya (kontrak T-139a); hitungannya
  ## tetap tersedia dari `GET /dayclose/runs` dan `GET /dayclose/status`.
  result = runSummaryJson(snap)
  var tasks = newJArray()
  for t in snap.tasks:
    tasks.add taskJson(t)
  result["tasks"] = tasks

proc businessDateJson(row: BusinessDateRow): JsonNode =
  ## `frozenAt` = waktu state terakhir berubah. Tanggal `OPEN` belum beku, jadi `null`.
  let frozenAt = if row.state == bdsOpen: newJNull() else: %row.updatedAt
  %*{"date": row.currentDate, "state": $row.state, "frozenAt": frozenAt}

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
