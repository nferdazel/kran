## Handler REST administrasi pengguna & role (T-117, spec §13).
##
## Hanya `ctl` yang bisa mengelola akun operator sebelum ini; rute di sini membuka jalur HTTP untuk
## layar `/app/users` dengan **aturan yang sama**. Aturan siklus hidup (scope role, SoD, penjagaan
## admin terakhir, transisi status) tinggal di `auth_service` (`grantUserRole`, `revokeUserRole`,
## `disableUserAccount`, `enableUserAccount`, `unlockUserAccount`) — handler hanya menerjemahkan
## permintaan HTTP dan hasilnya, tidak menyalin kebijakan (AGENTS.md §1.6).
##
## Aksi institusi (bukan cabang) → dua gerbang seperti T-072/T-073: izin dipegang di cabang mana pun
## (`requirePermission`) **dan** grant tanpa batas cabang (`authorizedAtBranch(..., "")`).

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[auditcontext, clock, ids, result]
import platform/domain/scope
import platform/infrastructure/[auth_repo, auth_service]

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  permissionUserManage* = "platform.user.manage"
  ## Batas baris daftar pengguna: nilai **teknis** (ukuran respons), bukan ambang bisnis.
  defaultUsersLimit* = 20 # nomagic:ok ukuran halaman default
  maxUsersLimit* = 200    # nomagic:ok batas atas ukuran respons

proc respondInstitutionOnly(req: Request, permission: string) =
  req.respondProblem(newProblem(pkForbidden, "Forbidden",
    "aksi tingkat institusi " & permission & " hanya boleh dengan grant tanpa batas cabang",
    traceId = traceIdFrom(req),
    params = @[("reason", "branch_not_allowed"), ("permission", permission)]))

proc roleGrantJson(g: RoleGrant): JsonNode =
  %*{
    "role": g.roleCode,
    "branchId": if g.branchId.len == 0: newJNull() else: %g.branchId,
  }

proc userJson(db: DbConn, u: UserRow): JsonNode =
  ## Bentuk pengguna untuk layar administrasi: **tanpa** password hash dan tanpa sesi/secret.
  var roles = newJArray()
  for g in roleGrantsOfUser(db, u.userId):
    roles.add roleGrantJson(g)
  %*{
    "userId": u.userId,
    "username": u.username,
    "fullName": u.fullName,
    "status": u.status,
    "mustChangePassword": u.mustChangePassword,
    "roles": roles,
  }

proc roleJson(r: RoleCatalogue): JsonNode =
  %*{"code": r.code, "scope": r.scope, "isSystem": r.isSystem}

proc parseLimit(req: Request): tuple[value: int, error: string] =
  let raw = queryValue(req, "limit").strip()
  if raw.len == 0:
    return (defaultUsersLimit, "")
  try:
    let parsed = parseInt(raw)
    if parsed < 1 or parsed > maxUsersLimit:
      return (0, "limit harus antara 1 dan " & $maxUsersLimit)
    (parsed, "")
  except ValueError:
    (0, "limit harus angka")

proc rejectKind(reason: string): ProblemKind =
  ## `400` untuk kode role/branch yang salah bentuk (masukan pemanggil), `403` untuk penugasan yang
  ## melebihi wewenang pemberi izin, `409` untuk konflik keadaan (sudah dipegang, admin terakhir,
  ## status salah).
  if reason in ["role_not_found", "role_scope"]: pkBadRequest
  elif reason == "grant_exceeds_actor": pkForbidden
  else: pkConflict

proc respondUserProblem(req: Request, kind: ProblemKind, reason, detail: string) =
  req.respondProblem(newProblem(kind, $kind, detail, traceId = traceIdFrom(req),
    params = @[("reason", reason)]))

proc respondNotFoundUser(req: Request) =
  respondUserProblem(req, pkNotFound, "user_not_found", "pengguna tidak ditemukan")

proc handleListUsers*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/users?limit=` — daftar akun + role efektifnya, urut username.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionUserManage):
    return

  let limit = parseLimit(req)
  if limit.error.len > 0:
    req.respondProblem(pkBadRequest, "Bad Request", limit.error)
    return

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionUserManage):
          status = 403
          return
        for u in listUsers(db, limit.value):
          items.add userJson(db, u)
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondInstitutionOnly(permissionUserManage)
  else: req.respondProblem(pkInternal, "Internal Server Error", "daftar pengguna gagal dibaca")

proc handleListRoles*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/roles` — katalog role (kode, scope, sistem) untuk memilih bentuk penugasan.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionUserManage):
    return

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionUserManage):
          status = 403
          return
        for r in listRoles(db):
          items.add roleJson(r)
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondInstitutionOnly(permissionUserManage)
  else: req.respondProblem(pkInternal, "Internal Server Error", "katalog role gagal dibaca")

proc handleAssignRole*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/users/{userId}/roles` — tugaskan role; audit `user.role_grant`.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionUserManage):
    return

  let userIdRaw = pathParam(req, "userId").strip
  if parseId(userIdRaw).isErr:
    respondNotFoundUser(req)
    return
  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    respondUserProblem(req, pkBadRequest, "body_invalid", "badan permintaan harus objek JSON")
    return
  let node = body.get()
  let roleCode = node.jsonField("role").strip
  if roleCode.len == 0:
    respondUserProblem(req, pkBadRequest, "role_missing", "field role wajib diisi")
    return
  var branchId = ""
  if node.hasKey("branchId") and node["branchId"].kind != JNull:
    if node["branchId"].kind != JString:
      respondUserProblem(req, pkBadRequest, "branch_invalid", "branchId harus teks atau null")
      return
    branchId = node["branchId"].getStr().strip

  var status = 0
  var reason = ""
  var detail = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionUserManage):
          status = 403
          return
        let userOpt = userById(db, userIdRaw)
        if userOpt.isNone:
          status = 404
          return
        # T-128/BLK-3: menugaskan ke diri sendiri membuka jalur eskalasi (ops_admin -> platform_admin)
        # tanpa approver, dan `platform_admin` memang tidak dipasangkan SoD. Dilarang di sini, bukan
        # hanya di UI.
        if userOpt.get().userId == principal.user.userId:
          status = -1
          reason = "self_grant"
          detail = "peran tidak boleh ditugaskan kepada akun yang melakukan permintaan"
          return
        # Pemberi izin tidak boleh memberikan peran yang memuat izin yang tidak ia pegang sendiri.
        # Tanpa ini, `platform.user.manage` setara `platform_admin` (T-128/BLK-3).
        for permission in rolePermissions(db, roleCode):
          if not userHasPermission(db, principal.user.userId, permission):
            status = -1
            reason = "grant_exceeds_actor"
            detail = "peran memuat izin '" & permission &
              "' yang tidak dipegang oleh pemberi izin"
            return
        let ctx = auditContextFor(principal, req, app.clock, "assign role", branchId)
        let res = grantUserRole(db, ctx, app.clock, institutionScope(), userOpt.get(),
          roleCode, branchId)
        case res.outcome
        of uaoOk:
          payload = %*{"userId": userOpt.get().userId, "role": roleCode,
                       "branchId": if branchId.len == 0: newJNull() else: %branchId}
          status = 201
        of uaoWriteFailed:
          status = 500
        of uaoRoleNotFound, uaoRejected:
          status = -1
          reason = res.reason
          detail = res.detail)
  except DbError:
    status = 500

  case status
  of 201: req.respondJson(201, payload)
  of 403: req.respondInstitutionOnly(permissionUserManage)
  of 404: respondNotFoundUser(req)
  of 500: req.respondProblem(pkInternal, "Internal Server Error", "penugasan role gagal disimpan")
  else: respondUserProblem(req, rejectKind(reason), reason, detail)

proc handleRevokeRole*(app: AppContext, req: Request) {.gcsafe.} =
  ## `DELETE /api/v1/users/{userId}/roles/{role}?branchId=` — cabut grant persis; audit
  ## `user.role_revoke`. `branchId` kosong = grant tingkat institusi.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionUserManage):
    return

  let userIdRaw = pathParam(req, "userId").strip
  if parseId(userIdRaw).isErr:
    respondNotFoundUser(req)
    return
  let roleCode = pathParam(req, "role").strip
  if roleCode.len == 0:
    respondUserProblem(req, pkBadRequest, "role_missing", "kode role wajib diisi")
    return
  let branchId = queryValue(req, "branchId").strip

  var status = 0
  var reason = ""
  var detail = ""
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionUserManage):
          status = 403
          return
        let userOpt = userById(db, userIdRaw)
        if userOpt.isNone:
          status = 404
          return
        let ctx = auditContextFor(principal, req, app.clock, "revoke role", branchId)
        let res = revokeUserRole(db, ctx, app.clock, institutionScope(), userOpt.get(),
          roleCode, branchId)
        case res.outcome
        of uaoOk: status = 204
        of uaoWriteFailed: status = 500
        of uaoRoleNotFound, uaoRejected:
          status = -1
          reason = res.reason
          detail = res.detail)
  except DbError:
    status = 500

  case status
  of 204: req.respond(204, emptyHttpHeaders())
  of 403: req.respondInstitutionOnly(permissionUserManage)
  of 404: respondNotFoundUser(req)
  of 500: req.respondProblem(pkInternal, "Internal Server Error", "pencabutan role gagal disimpan")
  else: respondUserProblem(req, rejectKind(reason), reason, detail)

type
  LifecycleAction = enum
    laDisable, laEnable, laUnlock

proc lifecycleReason(action: LifecycleAction): string =
  case action
  of laDisable: "disable user"
  of laEnable: "enable user"
  of laUnlock: "unlock user"

proc applyLifecycle(db: DbConn, ctx: AuditContext, clock: Clock,
                    action: LifecycleAction, user: UserRow): UserAdminResult =
  case action
  of laDisable: disableUserAccount(db, ctx, clock, institutionScope(), user)
  of laEnable: enableUserAccount(db, ctx, clock, institutionScope(), user)
  of laUnlock: unlockUserAccount(db, ctx, clock, institutionScope(), user)

proc handleLifecycle(app: AppContext, req: Request, action: LifecycleAction) {.gcsafe.} =
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionUserManage):
    return

  let userIdRaw = pathParam(req, "userId").strip
  if parseId(userIdRaw).isErr:
    respondNotFoundUser(req)
    return

  var status = 0
  var reason = ""
  var detail = ""
  var newStatus = ""
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionUserManage):
          status = 403
          return
        let userOpt = userById(db, userIdRaw)
        if userOpt.isNone:
          status = 404
          return
        let ctx = auditContextFor(principal, req, app.clock, lifecycleReason(action))
        let res = applyLifecycle(db, ctx, app.clock, action, userOpt.get())
        case res.outcome
        of uaoOk:
          newStatus = userById(db, userIdRaw).get().status
          status = 200
        of uaoWriteFailed:
          status = 500
        of uaoRoleNotFound, uaoRejected:
          status = -1
          reason = res.reason
          detail = res.detail)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"userId": userIdRaw, "status": newStatus})
  of 403: req.respondInstitutionOnly(permissionUserManage)
  of 404: respondNotFoundUser(req)
  of 500: req.respondProblem(pkInternal, "Internal Server Error", "perubahan status gagal disimpan")
  else: respondUserProblem(req, rejectKind(reason), reason, detail)

proc handleDisableUser*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/users/{userId}/disable` — nonaktifkan + cabut seluruh sesi; audit `user.disable`.
  handleLifecycle(app, req, laDisable)

proc handleEnableUser*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/users/{userId}/enable` — INACTIVE → ACTIVE saja; audit `user.enable`.
  handleLifecycle(app, req, laEnable)

proc handleUnlockUser*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/users/{userId}/unlock` — LOCKED → ACTIVE saja; audit `user.unlock`.
  handleLifecycle(app, req, laUnlock)
