## Handler REST parameter (T-012, spec §10.2/§10.4/§10.7).
##
## Pemetaan ke jalur yang sudah ada: daftar nilai → `param_repo.paramValueRows`, perubahan →
## `param_repo.submitChange`/`approveChange` (maker-checker, `checker <> maker` ditegakkan skema
## DB). Handler hanya menambahkan otorisasi (`access`), konteks audit dari permintaan HTTP, dan
## penerjemahan hasil/kesalahan ke HTTP.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import platform/domain/param
import platform/infrastructure/[auth_service, param_repo]

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  ## Batas ukuran daftar (permintaan & jawaban). Nilainya **teknis** — pertahanan terhadap UI
  ## yang meminta seluruh tabel; bukan ambang bisnis.
  listLimit* = 200 # nomagic:ok batas ukuran respons, bukan nilai bisnis
  defaultScopeType* = "GLOBAL"
  ## Alasan 409 ketika nilai yang akan diaktifkan melanggar aturan lintas-parameter
  ## (lihat `sessionPolicyCandidateProblem`). Kontrak menyebut nilai ini di deskripsi 409.
  reasonCombination* = "invalid_combination"

proc itemJson(row: ParamValueRow): JsonNode =
  ## Bentuk satu item daftar (kontrak `ParamValue`). Nama field = kontrak, bukan nama kolom.
  %*{
    "paramValueId": row.paramValueId,
    "key": row.key,
    "scopeType": row.scopeType,
    "scopeId": row.scopeId,
    "status": $row.status,
    "value": row.value,
    "effectiveFrom": row.effectiveFrom,
    "effectiveTo": row.effectiveTo,
    "maker": row.maker,
    "checker": row.checker,
    "reason": row.reason,
    "requiresApproval": row.requiresApproval}

proc handleListParams*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/params?status=` — daftar nilai parameter beserta statusnya.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  if not requirePermission(app, req, principal.get(), permissionParamRead):
    return

  let status = queryValue(req, "status").strip()
  if status.len > 0:
    try:
      discard parseStatus(status)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "status tidak dikenal: " & status)
      return

  var rows: seq[ParamValueRow]
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        rows = paramValueRows(db, status, listLimit))
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "daftar parameter gagal dibaca")
    return

  var items = newJArray()
  for row in rows:
    items.add itemJson(row)
  req.respondJson(200, %*{"items": items})

proc handleSubmitParamChange*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/params/{key}/changes` — pengajuan perubahan (maker) → status PENDING.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  if not requirePermission(app, req, principal.get(), permissionParamSubmit):
    return

  let key = pathParam(req, "key")
  if key.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "key parameter kosong")
    return

  let body = parseJsonBody(req)
  if body.isNone:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus JSON")
    return
  let node = body.get()
  if node.kind != JObject or not node.hasKey("value"):
    req.respondProblem(pkBadRequest, "Bad Request", "field value wajib ada")
    return

  var scopeType = node.jsonField("scopeType")
  if scopeType.len == 0:
    scopeType = defaultScopeType
  let scopeId = node.jsonField("scopeId")
  var effectiveFrom = node.jsonField("effectiveFrom")
  if effectiveFrom.len == 0:
    effectiveFrom = businessDateIso(app.clock)
  let effectiveTo = node.jsonField("effectiveTo")
  let reason = node.jsonField("reason")
  if reason.len == 0:
    # Alasan wajib: audit perubahan parameter harus bisa menjelaskan "mengapa" (spec §10.2, §11.7).
    req.respondProblem(pkBadRequest, "Bad Request", "field reason wajib diisi")
    return

  var status = 0
  var payload = newJObject()
  var problem = ""
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let ctx = auditContextFor(principal.get(), req, app.clock, reason)
        # Aturan lintas-parameter diperiksa lebih dulu: nilai yang sah sendiri bisa tetap ditolak
        # bila digabung nilai lain yang sudah aktif (lihat `sessionPolicyCandidateProblem`).
        let combinationProblem = sessionPolicyCandidateProblem(db, key, node["value"],
          effectiveFrom, effectiveTo, businessDateIso(app.clock))
        if combinationProblem.len > 0:
          raise newException(ValueError, combinationProblem)
        let outcome = submitChange(db, ctx, app.clock, key, scopeType, scopeId, node["value"],
          effectiveFrom, effectiveTo, reason)
        status = 201
        payload = %*{
          "paramValueId": outcome.paramValueId,
          "key": key,
          "status": $pvPending,
          "scopeType": scopeType,
          "scopeId": scopeId,
          "value": node["value"],
          "effectiveFrom": effectiveFrom,
          "effectiveTo": effectiveTo,
          "reason": reason})
  except ValueError as e:
    # Validasi definisi/scope/schema/tipe nilai — semuanya kesalahan permintaan, bukan kesalahan
    # server (spec §10.4: pesannya menyebut aturan yang dilanggar).
    status = 400
    problem = e.msg
  except DbError:
    status = 500
    problem = "perubahan parameter gagal disimpan"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleApproveParamChange*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/params/changes/{paramValueId}/approve` — persetujuan (checker) → ACTIVE.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  if not requirePermission(app, req, principal.get(), permissionParamApprove):
    return

  let paramValueId = pathParam(req, "paramValueId")
  if paramValueId.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "paramValueId kosong")
    return

  var status = 0
  var payload = newJObject()
  var problem = ""
  var reasonParam = ""
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let current = statusOf(db, paramValueId)
        if current.isNone:
          status = 404
          problem = "nilai parameter tidak ditemukan"
        elif current.get() != pvPending:
          # Balapan yang wajar (dua checker, atau sudah ditolak): bukan kesalahan pemanggil.
          status = 409
          reasonParam = "not_pending"
          problem = "nilai tidak berstatus PENDING (sekarang " & $current.get() & ")"
        else:
          # Persetujuan adalah pintu terakhir: dua pengajuan yang masing-masing sah bisa
          # bertabrakan setelah salah satunya aktif, jadi kombinasi diperiksa lagi di sini.
          let pending = pendingValueOf(db, paramValueId)
          let combinationProblem =
            if pending.isSome:
              sessionPolicyCandidateProblem(db, pending.get().key, pending.get().value,
                pending.get().effectiveFrom, pending.get().effectiveTo,
                businessDateIso(app.clock))
            else:
              ""
          if combinationProblem.len > 0:
            status = 409
            reasonParam = reasonCombination
            problem = combinationProblem
          else:
            let ctx = auditContextFor(principal.get(), req, app.clock,
              "persetujuan perubahan parameter")
            let outcome = approveChange(db, ctx, app.clock, paramValueId)
            status = 200
            payload = %*{"paramValueId": outcome.paramValueId, "status": $pvActive})
  except ValueError as e:
    status = 409
    reasonParam = "not_pending"
    problem = e.msg
  except DbError as e:
    # Dua penolakan yang memang datang dari skema DB: `checker = maker` (constraint
    # `self_approval`) dan periode bertabrakan (EXCLUDE). Keduanya 409, dan kodenya disebut
    # supaya UI bisa menerjemahkan alasannya (nama constraint milik repo ini, bukan tebakan).
    if e.msg.contains("self_approval"):
      status = 409
      reasonParam = "self_approval"
      problem = "pengesahan sendiri ditolak: checker harus orang lain (spec §10.2)"
    elif e.msg.contains("exclusion") or e.msg.contains("conflict"):
      status = 409
      reasonParam = "period_conflict"
      problem = "periode nilai bertabrakan dengan nilai lain"
    else:
      status = 500
      problem = "persetujuan gagal disimpan"

  case status
  of 200: req.respondJson(200, payload)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 409: req.respondProblem(newProblem(pkConflict, "Conflict", problem,
           traceId = traceIdFrom(req), params = @[("reason", reasonParam)]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
