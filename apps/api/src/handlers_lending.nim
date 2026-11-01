## Handler REST modul `lending` (T-163): pengajuan dan persetujuan pinjaman.
##
## Composition root: validasi parameter, audit, dan outbox ditulis di sini dalam transaksi yang
## sama. Modul `lending` tetap murni (domain + SQL).
##
## Dua gerbang izin seperti `handlers_products`: `requirePermission` (izin dipegang di cabang mana
## pun) lalu `authorizedAtBranch` untuk cabang objeknya, begitu cabang pinjaman diketahui dari
## data — bukan dari badan permintaan.
##
## Empat mata ditegakkan tiga kali: domain (`assertDistinctActors`), handler (409 `self_approval`
## dengan alasan yang bisa dibaca operator), dan CHECK DB (`approved_by <> applied_by`). Yang di DB
## itu jaring terakhir, bukan satu-satunya.

import std/[json, options]

import mummy
import db_connector/db_postgres

import kernel/[ids, money, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo, param_repo]
import lending/domain/loan
import lending/infrastructure/loan_repo
import party/domain/party
import party/infrastructure/party_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  permissionLendingRead* = "lending.loan.read"
  permissionLendingSubmit* = "lending.loan.submit"
  permissionLendingApprove* = "lending.loan.approve"

proc respondLendingReason(req: Request, kind: ProblemKind, title, reason, detail: string) =
  req.respondProblem(newProblem(kind, title, detail,
    traceId = traceIdFrom(req), params = @[("reason", reason)]))

proc loanJson(loan: Loan): JsonNode =
  %*{
    "loanId": $loan.loanId,
    "partyId": $loan.partyId,
    "productVersionId": $loan.productVersionId,
    "branchId": $loan.branchId,
    "principal": toDecimalString(loan.principal),
    "status": $loan.status,
    "disbursedOn": (if loan.disbursedOn.len == 0: newJNull() else: %loan.disbursedOn),
  }

proc maxPrincipalOf(db: DbConn, asOf: string): Money =
  ## Plafon pengajuan dari parameter. Hilang atau rusak = galat konfigurasi, **bukan** plafon tak
  ## terbatas: pembatas yang gagal dibaca tidak boleh berubah menjadi "tanpa batas" (spec §10.6).
  let node = activeValueJson(db, keyString(P_lending_loan_max_principal), asOf,
    lookupFor(institutionScope()))
  if node.kind != JString:
    raise newException(ValueError,
      "parameter " & keyString(P_lending_loan_max_principal) & " bukan nominal desimal")
  let limit = moneyFromString(node.getStr())
  if not limit.isOk:
    raise newException(ValueError,
      "parameter " & keyString(P_lending_loan_max_principal) & " bukan nominal desimal")
  limit.val

proc handleSubmitLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/lending/loans` — ajukan pinjaman sebagai `APPLIED`. Tidak ada uang yang
  ## bergerak di sini: pencairan (beserta `Idempotency-Key`-nya) adalah T-164.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingSubmit):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let partyId = parseId(body.get().jsonField("partyId"))
  if partyId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "partyId harus UUID yang sah")
    return
  let versionId = parseId(body.get().jsonField("productVersionId"))
  if versionId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "productVersionId harus UUID yang sah")
    return
  let amount = moneyFromString(body.get().jsonField("principal"))
  if not amount.isOk or minorUnits(amount.val) <= 0:
    req.respondProblem(pkBadRequest, "Bad Request", "principal harus nominal positif, mis. \"5000000.00\"")
    return
  let asOf = businessDateIso(app.clock)

  var
    status = 0
    reason = ""
    problemText = ""
    payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let partyRow = partyById(db, partyId.val)
        if partyRow.isNone:
          status = 404
          reason = "party_not_found"
          problemText = "anggota tidak ditemukan"
          raise newException(ValueError, problemText)
        let branch = $partyRow.get().branchId
        if not authorizedAtBranch(db, principal, branch, permissionLendingSubmit):
          status = 403
          reason = "branch_not_allowed"
          problemText = "izin " & permissionLendingSubmit & " tidak dipegang di cabang anggota"
          raise newException(ValueError, problemText)
        if partyRow.get().status != psActive:
          status = 409
          reason = "party_not_active"
          problemText = "anggota tidak aktif; pinjaman baru ditolak"
          raise newException(ValueError, problemText)

        let version = productVersionById(db, versionId.val)
        if version.isNone:
          status = 404
          reason = "product_version_not_found"
          problemText = "versi produk pinjaman tidak ditemukan"
          raise newException(ValueError, problemText)
        if version.get().status != pvsActive:
          # Syarat pinjaman dibekukan saat akad; versi DRAFT masih bisa berubah, jadi tidak boleh
          # dipakai untuk akad yang sudah mengikat anggota.
          status = 409
          reason = "product_version_not_active"
          problemText = "versi produk belum disetujui"
          raise newException(ValueError, problemText)

        let limit = maxPrincipalOf(db, asOf)
        if minorUnits(amount.val) > minorUnits(limit):
          status = 409
          reason = "limit_exceeded"
          problemText = "pokok melebihi plafon pengajuan " & toDecimalString(limit)
          raise newException(ValueError, problemText)

        let loan = Loan(
          loanId: newId(app.clock),
          partyId: partyRow.get().partyId,
          productVersionId: version.get().versionId,
          branchId: partyRow.get().branchId,
          principal: amount.val,
          status: lsApplied,
          appliedBy: parseId(principal.user.userId).value(),
        )
        insertLoan(db, loan)

        let ctx = auditContextFor(principal, req, app.clock, "", branch = branch)
        discard appendAudit(db, newAuditEntry(ctx, "lending.loan.submit", "lending.loan",
          $loan.loanId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), asOf),
          after = %*{"partyId": $loan.partyId, "principal": toDecimalString(loan.principal),
                     "productVersionId": $loan.productVersionId, "status": "APPLIED"}))
        discard appendEvent(db, newOutboxEvent(newId(app.clock), "LoanSubmitted", "lending.loan",
          $loan.loanId, "lending.loan.submitted:" & $loan.loanId,
          %*{"loanId": $loan.loanId, "partyId": $loan.partyId, "branchId": $loan.branchId,
             "principal": toDecimalString(loan.principal),
             "productVersionId": $loan.productVersionId}))

        payload = loanJson(loan)
        status = 201)
  except ValueError as e:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = e.msg

  case status
  of 201:
    req.respondJson(201, payload)
  of 403:
    respondLendingReason(req, pkForbidden, "Forbidden", reason, problemText)
  of 404:
    respondLendingReason(req, pkNotFound, "Not Found", reason, problemText)
  of 409:
    respondLendingReason(req, pkConflict, "Conflict", reason, problemText)
  else:
    req.respondProblem(pkInternal, "Internal Server Error", problemText)

proc handleApproveLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/lending/loans/{loanId}/approve` — setujui pengajuan. Pencairan tetap terpisah
  ## (T-164), jadi persetujuan tidak memindahkan uang dan tidak membuat jadwal.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingApprove):
    return
  let loanId = parseId(pathParam(req, "loanId"))
  if loanId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return
  let asOf = businessDateIso(app.clock)

  var
    status = 0
    reason = ""
    problemText = ""
    payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let found = loanById(db, loanId.val, forUpdate = true)
        if found.isNone:
          status = 404
          reason = "loan_not_found"
          problemText = "pinjaman tidak ditemukan"
          raise newException(ValueError, problemText)
        let loan = found.get()
        let branch = $loan.branchId
        if not authorizedAtBranch(db, principal, branch, permissionLendingApprove):
          status = 403
          reason = "branch_not_allowed"
          problemText = "izin " & permissionLendingApprove & " tidak dipegang di cabang ini"
          raise newException(ValueError, problemText)
        if not canApprove(loan.status):
          status = 409
          reason = "not_applied"
          problemText = "pinjaman sudah diputuskan"
          raise newException(ValueError, problemText)

        let actor = parseId(principal.user.userId).value()
        try:
          assertDistinctActors(loan.appliedBy, actor)
        except ValueError as e:
          status = 409
          reason = "self_approval"
          problemText = e.msg
          raise newException(ValueError, problemText)

        if not approveLoan(db, loan.loanId, actor):
          status = 409
          reason = "not_applied"
          problemText = "pinjaman sudah diputuskan permintaan lain"
          raise newException(ValueError, problemText)

        let ctx = auditContextFor(principal, req, app.clock, "", branch = branch)
        discard appendAudit(db, newAuditEntry(ctx, "lending.loan.approve", "lending.loan",
          $loan.loanId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), asOf),
          before = %*{"status": "APPLIED"}, after = %*{"status": "APPROVED"}))
        discard appendEvent(db, newOutboxEvent(newId(app.clock), "LoanApproved", "lending.loan",
          $loan.loanId, "lending.loan.approved:" & $loan.loanId,
          %*{"loanId": $loan.loanId, "partyId": $loan.partyId, "branchId": $loan.branchId,
             "principal": toDecimalString(loan.principal)}))

        payload = loanJson(Loan(
          loanId: loan.loanId,
          partyId: loan.partyId,
          productVersionId: loan.productVersionId,
          branchId: loan.branchId,
          principal: loan.principal,
          status: lsApproved,
          disbursedOn: loan.disbursedOn,
          appliedBy: loan.appliedBy,
          approvedBy: actor,
        ))
        status = 200)
  except ValueError as e:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = e.msg

  case status
  of 200:
    req.respondJson(200, payload)
  of 403:
    respondLendingReason(req, pkForbidden, "Forbidden", reason, problemText)
  of 404:
    respondLendingReason(req, pkNotFound, "Not Found", reason, problemText)
  of 409:
    respondLendingReason(req, pkConflict, "Conflict", reason, problemText)
  else:
    req.respondProblem(pkInternal, "Internal Server Error", problemText)
