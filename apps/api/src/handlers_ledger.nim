## Handler REST modul `ledger` (T-072, spec §8.1/§13).
##
## Composition root: audit/outbox ditulis di sini dalam transaksi yang sama. COA & periode milik
## **institusi**, jadi dijaga **dua gerbang**: `requirePermission` (izin dipegang di cabang mana pun)
## dan `authorizedAtBranch(db, principal, "", permission)` di dalam transaksi. Grant yang dibatasi
## cabang ditolak 403 `branch_not_allowed` (D-062/D-070).
##
## **HUMAN-REVIEW-REQUIRED**: fondasi jurnal double-entry (AGENTS.md §8).

import std/[json, options, re, strutils]

import mummy
import db_connector/db_postgres

import kernel/[ids, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo, param_repo]
import ledger/domain/[coa, period]
import ledger/infrastructure/ledger_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  permissionCoaRead* = "ledger.coa.read"
  permissionCoaManage* = "ledger.coa.manage"
  permissionPeriodRead* = "ledger.period.read"
  permissionPeriodManage* = "ledger.period.manage"

type
  ## Kesalahan konfigurasi (parameter pola kode hilang/rusak) — 500, bukan 400.
  LedgerConfigError = object of ValueError

proc respondInstitutionOnly(req: Request, permission: string) =
  ## Aksi COA/periode adalah **tingkat institusi** (`targetBranch = ""`). Menurut D-062 hanya
  ## grant **tanpa batas cabang** yang boleh; grant yang dibatasi ke satu cabang tidak boleh
  ## mengubah buku besar yang berlaku bagi semua cabang.
  req.respondProblem(newProblem(pkForbidden, "Forbidden",
    "aksi tingkat institusi " & permission & " hanya boleh dengan grant tanpa batas cabang",
    traceId = traceIdFrom(req),
    params = @[("reason", "branch_not_allowed"), ("permission", permission)]))

proc jsonOrNull(s: string): JsonNode =
  if s.len == 0: newJNull() else: %s

proc coaJson(a: CoaAccount): JsonNode =
  %*{
    "accountId": $a.accountId,
    "code": a.code,
    "name": a.name,
    "accountType": $a.accountType,
    "normalSide": $a.normalSide,
    "postable": a.postable,
    "status": $a.status,
    "createdAt": a.createdAt,
  }

proc periodJson(p: Period): JsonNode =
  %*{
    "periodId": $p.periodId,
    "startsOn": p.startsOn,
    "endsOn": p.endsOn,
    "status": $p.status,
    "closedAt": jsonOrNull(p.closedAt),
    "closedBy": jsonOrNull(p.closedBy),
    "createdAt": p.createdAt,
  }

proc codePattern(db: DbConn, asOf: string): Regex =
  ## Pola kode dari parameter; hilang/rusak = konfigurasi (bukan permintaan pemanggil).
  let node =
    try:
      activeValueJson(db, keyString(P_ledger_coa_code_pattern), asOf,
        lookupFor(institutionScope()))
    except ValueError:
      raise newException(LedgerConfigError, "parameter ledger.coa.code_pattern tidak terbaca")
  if node.kind != JString:
    raise newException(LedgerConfigError, "parameter ledger.coa.code_pattern bukan teks")
  try:
    compileCodePattern(node.getStr())
  except ValueError as e:
    raise newException(LedgerConfigError, e.msg)

proc handleListCoa*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/ledger/coa` — daftar akun, urut kode.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionCoaRead):
    return

  let typeRaw = queryValue(req, "type").strip
  var accountType = ""
  if typeRaw.len > 0:
    let parsed = parseAccountType(typeRaw)
    if parsed.isNone:
      req.respondProblem(pkBadRequest, "Bad Request",
        "type harus salah satu ASSET/LIABILITY/EQUITY/REVENUE/EXPENSE")
      return
    accountType = $parsed.get()

  let postable = queryValue(req, "postable").strip.toLowerAscii
  if postable.len > 0 and postable notin ["true", "false"]:
    req.respondProblem(pkBadRequest, "Bad Request", "postable harus true atau false")
    return

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionCoaRead):
          status = 403
          return
        for account in coaAccounts(db, accountType, postable):
          items.add coaJson(account)
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondInstitutionOnly(permissionCoaRead)
  else: req.respondProblem(pkInternal, "Internal Server Error", "daftar COA gagal dibaca")

proc handleCreateCoa*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/ledger/coa` — buat akun COA.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionCoaManage):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let accountType = parseAccountType(node.jsonField("accountType"))
  if accountType.isNone:
    req.respondProblem(pkBadRequest, "Bad Request",
      "accountType harus ASSET/LIABILITY/EQUITY/REVENUE/EXPENSE")
    return
  var name = ""
  try:
    name = validateName(node.jsonField("name"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  # `postable` bertipe boolean di JSON: `jsonField` (khusus string) tidak boleh dipakai di sini.
  var postable = true
  if node.hasKey("postable"):
    if node["postable"].kind != JBool:
      req.respondProblem(pkBadRequest, "Bad Request", "postable harus boolean")
      return
    postable = node["postable"].getBool()

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionCoaManage):
          status = 403
          return
        let asOf = businessDateIso(app.clock)
        let rx = codePattern(db, asOf)
        var code = ""
        try:
          code = validateCode(node.jsonField("code"), rx)
        except ValueError as e:
          status = 400
          problem = e.msg
          raise newException(ValueError, problem)

        if coaByCode(db, code).isSome:
          status = 409
          problem = "kode akun sudah dipakai"
          raise newException(ValueError, problem)

        let account = CoaAccount(
          accountId: newId(app.clock),
          code: code,
          name: name,
          accountType: accountType.get(),
          normalSide: normalSideOf(accountType.get()),
          postable: postable,
          status: asActive,
          createdAt: "")
        let createdAt = insertCoa(db, account, parseId(principal.user.userId).value())

        let ctx = auditContextFor(principal, req, app.clock, "buat akun COA")
        discard appendAudit(db, newAuditEntry(ctx, "ledger.coa.create", "coa_account",
          $account.accountId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), asOf),
          after = %*{"accountId": $account.accountId, "code": code,
                     "accountType": $account.accountType,
                     "normalSide": $account.normalSide, "postable": postable}))

        status = 201
        payload = coaJson(CoaAccount(
          accountId: account.accountId, code: code, name: name,
          accountType: account.accountType, normalSide: account.normalSide,
          postable: postable, status: asActive, createdAt: createdAt)))
  except LedgerConfigError as e:
    status = 500
    problem = "konfigurasi parameter modul ledger tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError as e:
    if "coa_code_uq" in e.msg or "duplicate key" in e.msg:
      status = 409
      problem = "kode akun sudah dipakai"
    else:
      status = 500
      problem = "akun COA gagal disimpan"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondInstitutionOnly(permissionCoaManage)
  of 409: req.respondProblem(pkConflict, "Conflict", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleListPeriods*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/ledger/periods` — daftar periode, terbaru lebih dulu.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionPeriodRead):
    return

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionPeriodRead):
          status = 403
          return
        for p in periods(db):
          items.add periodJson(p)
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondInstitutionOnly(permissionPeriodRead)
  else: req.respondProblem(pkInternal, "Internal Server Error", "daftar periode gagal dibaca")

proc handleOpenPeriod*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/ledger/periods` — buka periode baru (rentang inklusif).
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionPeriodManage):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  var range: tuple[startsOn, endsOn: string]
  try:
    range = validateRange(node.jsonField("startsOn"), node.jsonField("endsOn"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionPeriodManage):
          status = 403
          return
        let asOf = businessDateIso(app.clock)
        let p = Period(
          periodId: newId(app.clock),
          startsOn: range.startsOn,
          endsOn: range.endsOn,
          status: psOpen,
          closedAt: "",
          closedBy: "",
          createdAt: "")
        let createdAt = insertPeriod(db, p, parseId(principal.user.userId).value())

        let ctx = auditContextFor(principal, req, app.clock, "buka periode akuntansi")
        discard appendAudit(db, newAuditEntry(ctx, "ledger.period.open", "period",
          $p.periodId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), asOf),
          after = %*{"periodId": $p.periodId, "startsOn": range.startsOn,
                     "endsOn": range.endsOn}))

        status = 201
        payload = periodJson(Period(
          periodId: p.periodId, startsOn: range.startsOn, endsOn: range.endsOn,
          status: psOpen, closedAt: "", closedBy: "", createdAt: createdAt)))
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError as e:
    if "period_no_overlap" in e.msg or "conflicting key" in e.msg:
      status = 409
      problem = "periode tumpang tindih dengan periode yang sudah ada"
    else:
      status = 500
      problem = "periode gagal dibuka"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondInstitutionOnly(permissionPeriodManage)
  of 409: req.respondProblem(pkConflict, "Conflict", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleClosePeriod*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/ledger/periods/{periodId}/close` — tutup periode; alasan wajib.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionPeriodManage):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  var reason = ""
  try:
    reason = validateCloseReason(node.jsonField("reason"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let periodId = parseId(pathParam(req, "periodId"))
  if periodId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "periode tidak ditemukan")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionPeriodManage):
          status = 403
          return
        let p = periodById(db, periodId.value())
        if p.isNone:
          status = 404
          problem = "periode tidak ditemukan"
          raise newException(ValueError, problem)
        if p.get().status == psClosed:
          status = 409
          problem = "periode sudah ditutup"
          raise newException(ValueError, problem)

        let userId = parseId(principal.user.userId).value()
        let closedAt = closePeriod(db, periodId.value(), userId)
        if closedAt.len == 0:
          # Balapan: transaksi lain menutup periode ini di antara SELECT dan UPDATE (UPDATE
          # mengenai 0 baris). Audit/event **tidak** ditulis; pemanggil mendapat 409 yang sama
          # dengan penutupan kedua secara berurutan.
          status = 409
          problem = "periode sudah ditutup"
          raise newException(ValueError, problem)

        let ctx = auditContextFor(principal, req, app.clock, reason)
        discard appendAudit(db, newAuditEntry(ctx, "ledger.period.close", "period",
          $periodId.value(), app.clock,
          businessDate = businessDateFor(db, institutionScope(), businessDateIso(app.clock)),
          after = %*{"periodId": $periodId.value(), "status": "CLOSED",
                     "startsOn": p.get().startsOn, "endsOn": p.get().endsOn}))
        discard appendEvent(db, newOutboxEvent(newId(app.clock), "period.closed", "period",
          $periodId.value(), "period.closed:" & $periodId.value(), %*{
            "periodId": $periodId.value(),
            "startsOn": p.get().startsOn,
            "endsOn": p.get().endsOn,
          }))

        status = 200
        payload = %*{
          "periodId": $periodId.value(),
          "startsOn": p.get().startsOn,
          "endsOn": p.get().endsOn,
          "status": "CLOSED",
          "closedAt": closedAt,
          "closedBy": principal.user.userId,
          "createdAt": p.get().createdAt,
        })
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    status = 500
    problem = "periode gagal ditutup"

  case status
  of 200: req.respondJson(200, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondInstitutionOnly(permissionPeriodManage)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 409: req.respondProblem(pkConflict, "Conflict", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
