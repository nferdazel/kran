## Handler REST modul `deposit` (T-088a, spec §9.2/§13).
##
## Composition root: validasi lintas-modul (party/product) dan audit ditulis di sini dalam transaksi
## yang sama. Modul `deposit` tetap murni (domain + repo SQL).
##
## Rekening adalah objek **ber-cabang**: izin dipegang di cabang rekening (`authorizedAtBranch`),
## bukan tingkat institusi. Nomor rekening provisoris (10 digit dari sequence) — lihat
## `deposit/domain/account.nim` (**NEEDS-COMPLIANCE-REVIEW**).

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[clock, ids, money, result]
import platform/domain/[audit, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service]
import deposit/domain/account
import deposit/infrastructure/account_repo
import party/domain/party
import party/infrastructure/party_repo
import product/domain/product
import product/infrastructure/product_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./idempotency
import ./problem

const
  permissionDepositAccountManage* = "deposit.account.manage"
  permissionDepositAccountRead* = "deposit.account.read"

proc accountJson(a: Account): JsonNode =
  %*{
    "accountId": $a.accountId,
    "accountNo": a.accountNo,
    "partyId": $a.partyId,
    "productId": $a.productId,
    "productCode": a.productCode,
    "productVersionId": $a.productVersionId,
    "branchId": $a.branchId,
    "accountType": $a.accountType,
    "status": $a.status,
    "balance": a.balance.toDecimalString(),
    "openedOn": a.openedOn,
    "createdAt": a.createdAt,
  }

proc respondConflict(req: Request, reason, detail: string) =
  ## 409 dengan `reason` supaya klien bisa membedakan penyebab tanpa menebak dari `detail`.
  req.respondProblem(newProblem(pkConflict, "Conflict", detail, traceId = traceIdFrom(req),
    params = @[("reason", reason)]))

proc handleOpenDepositAccount*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/deposit/accounts` — buka rekening simpanan dari produk `SAVINGS` versi ACTIVE.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDepositAccountManage):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let productCode = node.jsonField("productCode").strip.toUpperAscii()
  if productCode.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "productCode wajib diisi")
    return
  let partyId = parseId(node.jsonField("partyId"))
  if partyId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "partyId harus UUID yang sah")
    return
  let branchId = parseId(node.jsonField("branchId"))
  if branchId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "branchId harus UUID yang sah")
    return
  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let branchRaw = $branchId.value()
  let asOf = businessDateIso(app.clock)

  var status = 0
  var problem = ""
  var reason = ""
  var payload = newJObject()
  var outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, "deposit.account.open", $node, asOf, app.clock.now(),
        proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            if not authorizedAtBranch(db, principal, branchRaw, permissionDepositAccountManage):
              status = 403
              problem = "izin " & permissionDepositAccountManage & " tidak dipegang di cabang ini"
              raise newException(ValueError, problem)

            let partyOpt = partyById(db, partyId.value())
            if partyOpt.isNone or partyOpt.get().status != psActive:
              status = 409
              reason = "party_not_active"
              problem = "party tidak ada atau tidak berstatus ACTIVE"
              raise newException(ValueError, problem)
            let party = partyOpt.get()
            if $party.branchId != branchRaw:
              status = 409
              reason = "branch_mismatch"
              problem = "cabang rekening harus sama dengan cabang party"
              raise newException(ValueError, problem)

            let productOpt = productByCode(db, productCode)
            if productOpt.isNone or productOpt.get().productType != ptSavings:
              status = 409
              reason = "product_not_active"
              problem = "produk tidak ada atau bukan jenis SAVINGS"
              raise newException(ValueError, problem)
            let prod = productOpt.get()

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let versionOpt = currentVersion(db, prod.productId, businessDate)
            if versionOpt.isNone:
              status = 409
              reason = "product_not_active"
              problem = "produk tidak punya versi ACTIVE yang berlaku pada tanggal bisnis"
              raise newException(ValueError, problem)

            let account = newAccount(newId(app.clock), partyId.value(), prod.productId,
              versionOpt.get().versionId, prod.code, branchId.value(), businessDate,
              nextAccountSeq(db))
            let actor = parseId(principal.user.userId).value()
            insertAccount(db, account, actor)

            let ctx = auditContextFor(principal, req, app.clock, "buka rekening simpanan",
              branchRaw)
            discard appendAudit(db, newAuditEntry(ctx, "deposit.account.open", "deposit_account",
              $account.accountId, app.clock, businessDate = businessDate,
              after = %*{
                "accountId": $account.accountId,
                "accountNo": account.accountNo,
                "partyId": $account.partyId,
                "productId": $account.productId,
                "productCode": account.productCode,
                "productVersionId": $account.productVersionId,
                "branchId": $account.branchId,
                "status": $account.status,
              }))

            status = 201
            payload = accountJson(accountById(db, account.accountId).get())
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problem = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problem = "idempotensi gagal diselesaikan"
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    status = 500
    problem = "rekening simpanan gagal disimpan"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 409: req.respondConflict(reason, problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleGetDepositAccount*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/deposit/accounts/{accountId}` — baca satu rekening + saldonya.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDepositAccountRead):
    return

  let accountId = parseId(pathParam(req, "accountId"))
  if accountId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "rekening tidak ditemukan")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let accountOpt = accountById(db, accountId.value())
        if accountOpt.isNone:
          status = 404
          problem = "rekening tidak ditemukan"
          return
        let account = accountOpt.get()
        if not authorizedAtBranch(db, principal, $account.branchId, permissionDepositAccountRead):
          status = 403
          problem = "izin " & permissionDepositAccountRead & " tidak dipegang di cabang rekening ini"
          return
        status = 200
        payload = accountJson(account))
  except DbError:
    status = 500
    problem = "rekening gagal dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleListDepositAccounts*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/deposit/accounts?partyId=` — rekening milik satu party, disaring per cabang.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDepositAccountRead):
    return

  let partyRaw = queryValue(req, "partyId").strip
  if partyRaw.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "partyId wajib diisi")
    return
  let partyId = parseId(partyRaw)
  if partyId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "partyId harus UUID yang sah")
    return

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        # Gerbang cabang per baris: rekening di cabang yang tidak dipegang izinnya tidak
        # dikembalikan (bukan 403 seluruh daftar — hasilnya disaring per baris, pola D-062).
        for account in accountsByParty(db, partyId.value()):
          if authorizedAtBranch(db, principal, $account.branchId, permissionDepositAccountRead):
            items.add accountJson(account)
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  else: req.respondProblem(pkInternal, "Internal Server Error", "rekening gagal dibaca")
