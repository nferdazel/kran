## Handler REST parameter (T-012, spec §10.2/§10.4/§10.7).
##
## Pemetaan ke jalur yang sudah ada: daftar nilai → `param_repo.paramValueRows`, perubahan →
## `param_repo.submitChange`/`approveChange` (maker-checker, `checker <> maker` ditegakkan skema
## DB). Handler hanya menambahkan otorisasi (`access`), konteks audit dari permintaan HTTP, dan
## penerjemahan hasil/kesalahan ke HTTP.

import std/[json, options, sets, strutils]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, paramkey, result]

import platform/domain/[audit, authz, param]
import platform/infrastructure/[audit_repo, auth_repo, auth_service, param_repo]

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
  ## Alasan 403 ketika cabang objek di luar wewenang pemanggil (T-058, D-062). `targetBranch = ""`
  ## berarti aksi **tingkat institusi**, dan itu punya kalimatnya sendiri: menuliskan "cabang  di luar
  ## wewenang" (cabang kosong) akan menyesatkan operator.
  reasonBranchNotAllowed* = "branch_not_allowed"
  ## Batas panjang alasan penolakan (kontrak OpenAPI; teks audit/reason tidak dipotong diam-diam).
  maxParamReasonLength* = 500 # nomagic:ok batas ukuran permintaan, bukan nilai bisnis

proc branchNotAllowedProblem(targetBranch, aksi: string): string =
  if targetBranch.len == 0:
    "aksi tingkat institusi butuh wewenang tanpa batas cabang (" & aksi & ")"
  else:
    "cabang " & targetBranch & " di luar wewenang " & aksi

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

proc auditCrossBranchReads(db: DbConn, principal: Principal, req: Request, clock: Clock,
                           rows: openArray[ParamValueRow], grants: seq[Grant]) =
  ## D-046 butir 6: pembacaan lintas-cabang dicatat audit. Satu entri **per cabang** yang dibaca
  ## di luar cabang tugas, bukan per baris maupun per permintaan: barisnya tetap kecil dan bisa
  ## ditelusuri per cabang, dan satu permintaan yang membaca cabang yang sama berulang tidak
  ## menggandakan entri.
  var branches: HashSet[string]
  for row in rows:
    if row.scopeType == $pstBranch and isCrossBranchRead(grants, permissionParamRead, row.scopeId):
      branches.incl row.scopeId
  for branch in branches:
    # Cabang entri ini = cabang yang **dibaca** (T-058, D-062), bukan cabang tugas pelaku: auditor
    # cabang itu yang berkepentingan tahu siapa membaca datanya — termasuk pembacaan dari pusat.
    discard appendAudit(db, newAuditEntry(
      auditContextFor(principal, req, clock, "cross_branch_read", branch),
      "param.read_cross_branch", "param_branch", branch, clock,
      businessDate = businessDateIso(clock)))

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
  var grants: seq[Grant]
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        grants = grantsOf(db, principal.get().user.userId)
        # Visibilitas per scope (D-046 butir 6, D-055): disaring **di query**, dari himpunan scope
        # yang boleh dibaca — bukan setelah `LIMIT`, supaya halaman tidak terisi baris yang tidak
        # boleh dilihat. Aturannya di `platform/domain/authz`; lihat `paramValueRows`.
        rows = paramValueRows(db, status, listLimit,
          readableScopeFilter(grants, permissionParamRead))
        auditCrossBranchReads(db, principal.get(), req, app.clock, rows, grants))
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "daftar parameter gagal dibaca")
    return

  var items = newJArray()
  for row in rows:
    items.add itemJson(row)
  req.respondJson(200, %*{"items": items})

proc respondParamReason(req: Request, kind: ProblemKind, title, reason, detail: string) =
  ## 400/409 yang menyebut **alasan berkode stabil** di `params.reason`, sehingga UI bisa
  ## menerjemahkannya per-field (O-045). `detail` tetap untuk log/diagnostik (spec §16.1).
  req.respondProblem(newProblem(kind, title, detail, traceId = traceIdFrom(req),
    params = @[("reason", reason)]))

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
    req.respondParamReason(pkBadRequest, "Bad Request", "value_missing", "field value wajib ada")
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
    req.respondParamReason(pkBadRequest, "Bad Request", "reason_missing",
      "field reason wajib diisi")
    return

  # Validasi bentuk permintaan **sebelum** menyentuh DB: cast `?::date`/`?::uuid` dan CHECK skema
  # melempar `DbError` yang tidak bisa dibedakan dari gangguan server, jadi tanpa pemeriksaan ini
  # kesalahan pemanggil dijawab 500 (O-035). Semua di sini 400 menurut kontrak.
  if not isIsoDate(effectiveFrom):
    req.respondParamReason(pkBadRequest, "Bad Request", "effective_from_invalid",
      "effectiveFrom harus tanggal YYYY-MM-DD yang sah")
    return
  if effectiveTo.len > 0:
    if not isIsoDate(effectiveTo):
      req.respondParamReason(pkBadRequest, "Bad Request", "effective_to_invalid",
        "effectiveTo harus tanggal YYYY-MM-DD yang sah")
      return
    if effectiveTo <= effectiveFrom:
      # CHECK skema `param_value_period_chk`: periode harus punya lebar positif.
      req.respondParamReason(pkBadRequest, "Bad Request", "period_invalid",
        "effectiveTo harus setelah effectiveFrom")
      return

  var scope: ParamScopeType
  try:
    scope = parseScopeType(scopeType)
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return
  # CHECK skema `param_value_global_scope_chk`: GLOBAL ⇔ `scope_id` kosong (NULL).
  if scope == pstGlobal and scopeId.len > 0:
    req.respondParamReason(pkBadRequest, "Bad Request", "scope_id_forbidden",
      "scope GLOBAL tidak boleh punya scopeId")
    return
  if scope != pstGlobal and scopeId.len == 0:
    req.respondParamReason(pkBadRequest, "Bad Request", "scope_id_required",
      "scope " & scopeType & " wajib punya scopeId")
    return

  # Cabang target (T-058, D-062): nilai ber-scope `BRANCH` menyentuh **satu** cabang, jadi izin
  # pengaju harus menutupinya. Aksi tingkat institusi (`""`) — termasuk scope GLOBAL/INSTITUTION —
  # tetap menuntut grant tanpa batas cabang, sama seperti sebelum T-058.
  let targetBranch = if scope == pstBranch: scopeId else: ""

  var status = 0
  var payload = newJObject()
  var problem = ""
  var problemCode = ""
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        # D-047 (O-044): wewenang mengusulkan tidak boleh melebihi wewenang melihat — pengaju
        # hanya boleh mengajukan nilai untuk scope yang ia sendiri boleh baca.
        if not mayReadScope(grantsOf(db, principal.get().user.userId), permissionParamRead,
                            scope, scopeId):
          problemCode = "scope_not_readable"
          raise newException(ValueError,
            "scope " & scopeType & " di luar wewenang baca pengaju")
        if not authorizedAtBranch(db, principal.get(), targetBranch, permissionParamSubmit):
          problemCode = reasonBranchNotAllowed
          raise newException(ValueError, branchNotAllowedProblem(targetBranch, "pengaju"))
        let ctx = auditContextFor(principal.get(), req, app.clock, reason, targetBranch)
        # Aturan lintas-parameter diperiksa lebih dulu: nilai yang sah sendiri bisa tetap ditolak
        # bila digabung nilai lain yang sudah aktif (lihat `sessionPolicyCandidateProblem`).
        let combinationProblem = sessionPolicyCandidateProblem(db, key, node["value"],
          effectiveFrom, effectiveTo, businessDateIso(app.clock))
        if combinationProblem.len > 0:
          problemCode = "invalid_combination"
          raise newException(ValueError, combinationProblem)
        # O-043 (D-046 butir 8): `effectiveTo` hanya boleh bila ada penerus yang menutup tanggal
        # berakhirnya — diperiksa sebelum menulis apa pun, dan diperiksa lagi saat persetujuan.
        let gapProblem = effectiveToGapProblem(db, key, scopeType, scopeId, effectiveFrom,
          effectiveTo)
        if gapProblem.len > 0:
          problemCode = "effective_to_without_successor"
          raise newException(ValueError, gapProblem)
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
    # server (spec §10.4: pesannya menyebut aturan yang dilanggar). `problemCode` sudah diisi
    # untuk pelanggaran lintas-parameter; sisanya = nilai itu sendiri yang tidak sah.
    # Wewenang scope dan cabang berbeda: permintaannya berbentuk sah, yang kurang adalah izinnya →
    # 403 (T-058 menambahkan `branch_not_allowed` dengan alasan yang sama).
    status = if problemCode in ["scope_not_readable", reasonBranchNotAllowed]: 403 else: 400
    problem = e.msg
    if problemCode.len == 0:
      problemCode = "value_invalid"
  except DbError:
    status = 500
    problem = "perubahan parameter gagal disimpan"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondParamReason(pkBadRequest, "Bad Request", problemCode, problem)
  of 403: req.respondParamReason(pkForbidden, "Forbidden", problemCode, problem)
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
  if parseId(paramValueId).isErr:
    # Id bukan UUID: `?::uuid` akan melempar `DbError` → 500. Kontrak tidak menyediakan 400 di
    # operasi ini, dan id yang tak bisa ada memang "tidak ditemukan".
    req.respondProblem(pkNotFound, "Not Found", "paramValueId bukan UUID yang sah")
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
          # Cabang target (T-058, D-062): yang disentuh adalah cabang **baris yang diaktifkan**.
          # Diperiksa lebih dulu daripada alasan 409 lain supaya penolakan wewenang tidak bergantung
          # pada keadaan barisnya (dan tidak membocorkan masalah kombinasi/periodenya).
          let targetBranch =
            if pending.isSome and pending.get().scopeType == $pstBranch:
              pending.get().scopeId
            else:
              ""
          if not authorizedAtBranch(db, principal.get(), targetBranch,
                                    permissionParamApprove):
            status = 403
            reasonParam = reasonBranchNotAllowed
            problem = branchNotAllowedProblem(targetBranch, "penyetuju")
          else:
            let combinationProblem =
              if pending.isSome:
                sessionPolicyCandidateProblem(db, pending.get().key, pending.get().value,
                  pending.get().effectiveFrom, pending.get().effectiveTo,
                  businessDateIso(app.clock))
              else:
                ""
            # O-043: nilai ber-`effective_to` yang penerusnya hilang (mis. ditolak) tidak boleh
            # diaktifkan — kalau lolos, tanggal setelahnya tidak punya nilai berlaku.
            let gapProblem =
              if pending.isSome:
                effectiveToGapProblem(db, pending.get().key, pending.get().scopeType,
                  pending.get().scopeId, pending.get().effectiveFrom,
                  pending.get().effectiveTo)
              else:
                ""
            if gapProblem.len > 0:
              status = 409
              reasonParam = "effective_to_without_successor"
              problem = gapProblem
            elif combinationProblem.len > 0:
              status = 409
              reasonParam = reasonCombination
              problem = combinationProblem
            else:
              let ctx = auditContextFor(principal.get(), req, app.clock,
                "persetujuan perubahan parameter", targetBranch)
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
  of 403: req.respondParamReason(pkForbidden, "Forbidden", reasonParam, problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 409: req.respondProblem(newProblem(pkConflict, "Conflict", problem,
           traceId = traceIdFrom(req), params = @[("reason", reasonParam)]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleRejectParamChange*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/params/changes/{paramValueId}/reject` — penolakan (checker) → REJECTED.
  ##
  ## O-065: tanpa jalur ini pengajuan yang salah hanya bisa "dibiarkan" (menumpuk PENDING) atau
  ## diubah lewat SQL — keduanya melewati audit dan event. Penolakan menulis `param.reject` +
  ## `param.changed` dalam transaksi yang sama, dan **tidak** menyentuh nilai ACTIVE.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionParamApprove):
    return

  let paramValueId = pathParam(req, "paramValueId")
  if paramValueId.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "paramValueId kosong")
    return
  if parseId(paramValueId).isErr:
    req.respondProblem(pkNotFound, "Not Found", "paramValueId bukan UUID yang sah")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondParamReason(pkBadRequest, "Bad Request", "reason_missing",
      "badan permintaan harus objek JSON dengan field reason")
    return
  let reason = body.get().jsonField("reason").strip()
  if reason.len == 0:
    req.respondParamReason(pkBadRequest, "Bad Request", "reason_missing",
      "field reason wajib diisi")
    return
  if reason.len > maxParamReasonLength:
    req.respondParamReason(pkBadRequest, "Bad Request", "reason_too_long",
      "reason maksimum " & $maxParamReasonLength & " karakter")
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
          status = 409
          reasonParam = "not_pending"
          problem = "nilai tidak berstatus PENDING (sekarang " & $current.get() & ")"
        else:
          let pending = pendingValueOf(db, paramValueId)
          let targetBranch =
            if pending.isSome and pending.get().scopeType == $pstBranch:
              pending.get().scopeId
            else:
              ""
          if not authorizedAtBranch(db, principal, targetBranch, permissionParamApprove):
            status = 403
            reasonParam = reasonBranchNotAllowed
            problem = branchNotAllowedProblem(targetBranch, "penyetuju")
          else:
            let ctx = auditContextFor(principal, req, app.clock,
              "penolakan perubahan parameter: " & reason, targetBranch)
            let outcome = rejectChange(db, ctx, app.clock, paramValueId, reason)
            status = 200
            payload = %*{"paramValueId": outcome.paramValueId, "status": $pvRejected})
  except ValueError as e:
    status = 409
    reasonParam = "not_pending"
    problem = e.msg
  except DbError as e:
    status = 500
    problem = "penolakan gagal disimpan: " & e.msg

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondParamReason(pkForbidden, "Forbidden", reasonParam, problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 400: req.respondParamReason(pkBadRequest, "Bad Request", reasonParam, problem)
  of 409: req.respondProblem(newProblem(pkConflict, "Conflict", problem,
           traceId = traceIdFrom(req), params = @[("reason", reasonParam)]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
