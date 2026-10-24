## Handler REST vault kas cabang (T-107) + pengajuan top-up maker-checker (T-118).
##
## Composition root: izin ber-cabang, audit, jurnal, dan event outbox ditulis di sini dalam **satu**
## `withDbTx` per operasi. Modul `teller` tetap murni (domain + repo SQL).
##
## **HUMAN-REVIEW-REQUIRED**: mutasi saldo vault kas + jurnal GL (AGENTS.md §8).
##
## Alur top-up (memo T-118 §4, menutup O-098):
##  1. `POST /teller/vault/topups` = **pengajuan** (izin `teller.vault.submit`). Saldo vault belum
##     berubah; yang disimpan nominal, akun sumber, alasan, dan pengaju.
##  2. `POST /teller/vault/topups/{requestId}/approve` (izin `teller.vault.approve`) menulis saldo
##     vault + jurnal `D 101.1 KAS DI VAULT / K <source_account>` + audit + event dalam satu
##     transaksi. Pengaju tidak boleh menyetujui pengajuannya sendiri (CHECK DB + handler).
##  3. `.../reject` menutup pengajuan tanpa menyentuh saldo.
##
## Akun sumber dipilih **per pengajuan** dan wajib akun ASSET postable — memo menyerahkan sumber dana
## ke keputusan approver, bukan default di kode. Persetujuan yang menulis jurnal membuat O-097
## tertutup untuk jalur injeksi kas.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, money, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo, param_repo]
import ledger/domain/[coa, journal]
import ledger/infrastructure/[journal_repo, ledger_repo]
import teller/domain/session
import teller/infrastructure/[session_repo, vault_request_repo]

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./idempotency
import ./problem

const
  ## Izin lama (0026) dipertahankan di katalog untuk data historis, tetapi rute tidak lagi
  ## memakainya: top-up wajib lewat pengajuan + persetujuan.
  permissionTellerVaultTopupSubmit* = "teller.vault.submit"
  permissionTellerVaultTopupApprove* = "teller.vault.approve"
  permissionTellerVaultRead* = "teller.vault.read"
  operationIdVaultTopUpSubmit = "teller.vault.topup.submit"
  operationIdVaultTopUpApprove = "teller.vault.topup.approve"
  operationIdVaultTopUpReject = "teller.vault.topup.reject"
  maxTopUpListLimit = 100 # nomagic:ok batas teknis daftar pengajuan

type
  VaultConfigError* = object of CatchableError
    ## Parameter/COA yang dibutuhkan tidak terbaca atau tidak sah — 500, bukan 400: itu
    ## konfigurasi institusi, bukan kesalahan pemanggil.

proc vaultGlAccount(db: DbConn, asOf: string): string =
  ## Akun GL tempat vault dibukukan, dari parameter (bukan kode akun di kode program).
  dbCalls:
    let node =
      try:
        activeValueJson(db, keyString(P_teller_vault_cash_account), asOf,
          lookupFor(institutionScope()))
      except ValueError as e:
        raise newException(VaultConfigError, e.msg)
    if node.kind != JString or node.getStr().strip.len == 0:
      raise newException(VaultConfigError, "parameter teller.vault.cash_account bukan teks")
    let account = node.getStr().strip
    let coaOpt = coaByCode(db, account)
    if coaOpt.isNone or coaOpt.get().accountType != atAsset or
        not coaOpt.get().postable or coaOpt.get().status != asActive:
      raise newException(VaultConfigError,
        "akun vault pada parameter teller.vault.cash_account tidak sah: " & account)
    account

proc requestJson(r: VaultTopUpRequest): JsonNode =
  %*{
    "requestId": $r.requestId,
    "branchId": $r.branchId,
    "amount": r.amount.toDecimalString,
    "sourceAccount": r.sourceAccount,
    "note": r.note,
    "status": r.status,
    "requestedBy": r.requestedBy,
    "decidedBy": r.decidedBy,
    "decidedAt": r.decidedAt,
    "decisionNote": r.decisionNote,
    "journalId": r.journalId,
    "createdAt": r.createdAt,
  }

proc submitTopUp(principal: Principal, app: AppContext, req: Request, db: DbConn,
                 branchId: Id, branchRaw: string, amount: Money, sourceAccount,
                 note: string): tuple[status: int, payload: JsonNode, problem,
                     reason: string] {.gcsafe.} =
  ## Inti pengajuan, dijalankan di dalam transaksi + idempotensi pemanggil.
  if not authorizedAtBranch(db, principal, branchRaw, permissionTellerVaultTopupSubmit):
    return (403, newJObject(), "izin " & permissionTellerVaultTopupSubmit &
      " tidak dipegang di cabang ini", "branch_not_allowed")

  # Vault harus sudah ada (seed/runbook, T-093): pengajuan tidak membuat konfigurasi diam-diam.
  if vaultBalanceOf(db, branchId).isNone:
    return (404, newJObject(), "vault cabang belum dikonfigurasi", "vault_not_configured")

  let coaOpt = coaByCode(db, sourceAccount)
  if coaOpt.isNone:
    return (400, newJObject(), "akun sumber tidak ada di COA", "source_account_invalid")
  let coa = coaOpt.get()
  if coa.accountType != atAsset or not coa.postable or coa.status != asActive:
    return (400, newJObject(),
      "akun sumber harus akun ASSET aktif yang postable", "source_account_invalid")
  let businessDate = businessDateFor(db, institutionScope(), businessDateIso(app.clock))
  # Sumber = akun vault sendiri akan memposting D/K akun yang sama: saldo vault naik sementara
  # jurnal netto nol — saldo dan buku besar tidak lagi mengikat. Tolak di sini, bukan dibiarkan.
  if sourceAccount == vaultGlAccount(db, businessDate):
    return (400, newJObject(),
      "akun sumber tidak boleh akun vault itu sendiri", "source_account_invalid")

  let requestedBy = parseId(principal.user.userId).value()
  let requestId = newId(app.clock)
  if not insertTopUpRequest(db, NewVaultTopUpRequest(
      requestId: requestId, branchId: branchId, amount: amount,
      sourceAccount: sourceAccount, note: note, requestedBy: requestedBy)):
    return (409, newJObject(), "pengajuan bentrok; ulangi", "topup_request_conflict")

  let ctx = auditContextFor(principal, req, app.clock, "ajukan top-up kas vault cabang", branchRaw)
  discard appendAudit(db, newAuditEntry(ctx, "teller.vault.topup.submit",
    "teller_vault_topup_request", $requestId, app.clock, businessDate = businessDate,
    after = %*{
      "requestId": $requestId,
      "branchId": branchRaw,
      "amount": amount.toDecimalString,
      "sourceAccount": sourceAccount,
      "note": note,
    }))

  discard appendEvent(db, newOutboxEvent(newId(app.clock), "TellerVaultTopUpRequested",
    "teller_vault_topup_request", $requestId, "TellerVaultTopUpRequested:" & $requestId,
    %*{"requestId": $requestId, "branchId": branchRaw, "amount": amount.toDecimalString,
       "sourceAccount": sourceAccount, "businessDate": businessDate}))

  let stored = topUpRequestById(db, requestId)
  if stored.isNone:
    return (500, newJObject(), "pengajuan tidak bisa dibaca kembali", "")
  (201, requestJson(stored.get()), "", "")

proc handleSubmitTellerVaultTopUp*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/vault/topups` — ajukan top-up (belum mengubah saldo).
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerVaultTopupSubmit):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let branchId = parseId(node.jsonField("branchId"))
  if branchId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "branchId harus UUID yang sah")
    return

  let amountParsed = moneyFromString(node.jsonField("amount"))
  if amountParsed.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "amount harus nominal desimal")
    return
  var amount: Money
  try:
    amount = validateTopUpAmount(amountParsed.value())
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let sourceAccount = node.jsonField("sourceAccount").strip
  if sourceAccount.len == 0 or sourceAccount.len > maxCodeLength:
    req.respondProblem(pkBadRequest, "Bad Request", "sourceAccount (kode COA) wajib diisi")
    return

  var note = ""
  try:
    note = validateSessionNote(node.jsonField("note"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return
  if note.len == 0:
    # Bukti sumber dana wajib: pengajuan tanpa alasan tidak bisa ditelaah approver.
    req.respondProblem(pkBadRequest, "Bad Request", "note (bukti sumber dana) wajib diisi")
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
        withIdempotency(db, principal, req, operationIdVaultTopUpSubmit, $node, asOf,
        app.clock.now(), proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let res = submitTopUp(principal, app, req, db, branchId.value(), branchRaw, amount,
              sourceAccount, note)
            status = res.status
            problem = res.problem
            reason = res.reason
            payload = res.payload
            if res.status != 201:
              raise newException(ValueError, res.problem)
            (res.status, res.payload)))
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
    if status == 0:
      status = 500
    problem = "pengajuan top-up gagal"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(newProblem(pkBadRequest, "Bad Request", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  of 404: req.respondProblem(newProblem(pkNotFound, "Not Found", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  of 409: req.respondProblem(newProblem(pkConflict, "Conflict", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleApproveTellerVaultTopUp*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/vault/topups/{requestId}/approve` — setujui pengajuan: saldo vault +
  ## jurnal `D 101.1 / K source` + audit + event, satu transaksi.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerVaultTopupApprove):
    return
  let requestId = parseId(pathParam(req, "requestId"))
  if requestId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "requestId harus UUID yang sah")
    return
  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let body = parseJsonBody(req)
  let node = if body.isNone or body.get().kind != JObject: newJObject() else: body.get()
  let asOf = businessDateIso(app.clock)

  var status = 0
  var problem = ""
  var reason = ""
  var payload = newJObject()
  var outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdVaultTopUpApprove, $node, asOf,
        app.clock.now(), proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let found = topUpRequestById(db, requestId.value(), forUpdate = true)
            if found.isNone:
              status = 404
              reason = "topup_request_not_found"
              problem = "pengajuan top-up tidak ada"
              raise newException(ValueError, problem)
            let request = found.get()
            let branchRaw = $request.branchId
            if not authorizedAtBranch(db, principal, branchRaw,
                permissionTellerVaultTopupApprove):
              status = 403
              reason = "branch_not_allowed"
              problem = "izin " & permissionTellerVaultTopupApprove &
                " tidak dipegang di cabang ini"
              raise newException(ValueError, problem)
            if request.status != "PENDING":
              status = 409
              reason = "topup_request_not_pending"
              problem = "pengajuan sudah diputuskan"
              raise newException(ValueError, problem)
            let actor = parseId(principal.user.userId).value()
            if request.requestedBy == $actor:
              status = 409
              reason = "self_approval"
              problem = "pengaju tidak boleh menyetujui pengajuannya sendiri"
              raise newException(ValueError, problem)

            let balanceBefore = vaultBalanceOf(db, request.branchId)
            if balanceBefore.isNone:
              status = 404
              reason = "vault_not_configured"
              problem = "vault cabang belum dikonfigurasi"
              raise newException(ValueError, problem)
            let balanceAfter = creditVault(db, request.branchId, request.amount)
            if balanceAfter.isNone:
              status = 404
              reason = "vault_not_configured"
              problem = "vault cabang belum dikonfigurasi"
              raise newException(ValueError, problem)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            # Jurnal ditulis eksplisit (bukan posting rule): akun sumber dipilih per pengajuan,
            # jadi tidak ada template tetap yang bisa dipakai. Kaki vault tetap dari parameter.
            let vaultAccount = vaultGlAccount(db, asOf)
            if request.sourceAccount == vaultAccount:
              status = 409
              reason = "source_account_invalid"
              problem = "akun sumber tidak boleh akun vault itu sendiri"
              raise newException(ValueError, problem)
            let journalId = newId(app.clock)
            let journal = Journal(
              journalId: journalId,
              businessDate: businessDate,
              valueDate: businessDate,
              sourceEvent: "TellerVaultTopUp",
              sourceRef: request.requestId,
              idempotencyKey: "teller-vault-topup:" & $request.requestId,
              reversalOf: "")
            discard insertJournal(db, journal, actor)
            insertJournalLine(db, journalId, JournalLine(
              lineNo: 1, glAccount: vaultAccount, branchId: request.branchId,
              debit: request.amount, credit: zero()))
            insertJournalLine(db, journalId, JournalLine(
              lineNo: 2, glAccount: request.sourceAccount, branchId: request.branchId,
              debit: zero(), credit: request.amount))

            if not decideTopUpRequest(db, request.requestId, "APPROVED", $actor, "", $journalId):
              status = 409
              reason = "topup_request_not_pending"
              problem = "pengajuan sudah diputuskan"
              raise newException(ValueError, problem)

            let ctx = auditContextFor(principal, req, app.clock,
              "setujui top-up kas vault cabang", branchRaw)
            discard appendAudit(db, newAuditEntry(ctx, "teller.vault.topup.approve",
              "teller_vault_topup_request", $request.requestId, app.clock,
              businessDate = businessDate,
              after = %*{
                "requestId": $request.requestId,
                "branchId": branchRaw,
                "amount": request.amount.toDecimalString,
                "sourceAccount": request.sourceAccount,
                "vaultAccount": vaultAccount,
                "journalId": $journalId,
                "balanceBefore": balanceBefore.get().toDecimalString,
                "balanceAfter": balanceAfter.get().toDecimalString,
              }))

            discard appendEvent(db, newOutboxEvent(newId(app.clock), "TellerVaultTopedUp",
              "teller_vault", branchRaw, "TellerVaultTopedUp:" & $request.requestId,
              %*{"requestId": $request.requestId, "branchId": branchRaw,
                 "amount": request.amount.toDecimalString, "journalId": $journalId,
                 "balanceAfter": balanceAfter.get().toDecimalString,
                 "businessDate": businessDate}))

            let stored = topUpRequestById(db, request.requestId)
            status = 200
            payload = %*{
              "request": requestJson(stored.get()),
              "balanceAfter": balanceAfter.get().toDecimalString,
            }
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problem = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problem = "idempotensi gagal diselesaikan"
  except VaultConfigError as e:
    status = 500
    problem = "konfigurasi akun vault tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    if status == 0:
      status = 500
    problem = "persetujuan top-up gagal"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  of 404: req.respondProblem(newProblem(pkNotFound, "Not Found", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  of 409: req.respondProblem(newProblem(pkConflict, "Conflict", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleRejectTellerVaultTopUp*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/vault/topups/{requestId}/reject` — tolak pengajuan; butuh alasan.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerVaultTopupApprove):
    return
  let requestId = parseId(pathParam(req, "requestId"))
  if requestId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "requestId harus UUID yang sah")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()
  var reasonText = ""
  try:
    reasonText = validateSessionNote(node.jsonField("reason"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return
  if reasonText.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "reason wajib diisi")
    return

  var status = 0
  var problem = ""
  var reason = ""
  var payload = newJObject()
  try:
    discard withDbTx(app.pool, proc(db: DbConn): int {.gcsafe.} =
      dbCalls:
        let found = topUpRequestById(db, requestId.value(), forUpdate = true)
        if found.isNone:
          status = 404
          reason = "topup_request_not_found"
          problem = "pengajuan top-up tidak ada"
          return 0
        let request = found.get()
        let branchRaw = $request.branchId
        if not authorizedAtBranch(db, principal, branchRaw, permissionTellerVaultTopupApprove):
          status = 403
          reason = "branch_not_allowed"
          problem = "izin " & permissionTellerVaultTopupApprove & " tidak dipegang di cabang ini"
          return 0
        if request.status != "PENDING":
          status = 409
          reason = "topup_request_not_pending"
          problem = "pengajuan sudah diputuskan"
          return 0
        let actor = parseId(principal.user.userId).value()
        if request.requestedBy == $actor:
          status = 409
          reason = "self_approval"
          problem = "pengaju tidak boleh memutuskan pengajuannya sendiri"
          return 0
        discard decideTopUpRequest(db, request.requestId, "REJECTED", $actor, reasonText, "")
        let businessDate = businessDateFor(db, institutionScope(), businessDateIso(app.clock))
        let ctx = auditContextFor(principal, req, app.clock,
          "tolak top-up kas vault cabang", branchRaw)
        discard appendAudit(db, newAuditEntry(ctx, "teller.vault.topup.reject",
          "teller_vault_topup_request", $request.requestId, app.clock,
          businessDate = businessDate,
          after = %*{"requestId": $request.requestId, "branchId": branchRaw,
                     "reason": reasonText}))
        status = 200
        payload = %*{"request": requestJson(topUpRequestById(db, request.requestId).get())}
        0)
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    if status == 0:
      status = 500
    problem = "penolakan top-up gagal"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  of 404: req.respondProblem(newProblem(pkNotFound, "Not Found", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  of 409: req.respondProblem(newProblem(pkConflict, "Conflict", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleListTellerVaultTopUps*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/teller/vault/topups?branchId=&status=` — daftar pengajuan satu cabang.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerVaultRead):
    return
  let branchRaw = queryValue(req, "branchId").strip
  let branchId = parseId(branchRaw)
  if branchRaw.len == 0 or branchId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "branchId harus UUID yang sah")
    return
  let statusFilter = queryValue(req, "status").strip.toUpperAscii()
  if statusFilter.len > 0 and statusFilter notin ["PENDING", "APPROVED", "REJECTED"]:
    req.respondProblem(pkBadRequest, "Bad Request", "status harus PENDING/APPROVED/REJECTED")
    return
  var limit = maxTopUpListLimit
  let limitRaw = queryValue(req, "limit").strip
  if limitRaw.len > 0:
    try:
      limit = parseInt(limitRaw)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus angka")
      return
    if limit < 1 or limit > maxTopUpListLimit:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus antara 1 dan 100")
      return

  var status = 0
  var problem = ""
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, branchRaw, permissionTellerVaultRead):
          status = 403
          problem = "izin " & permissionTellerVaultRead & " tidak dipegang di cabang ini"
          return
        for request in topUpRequests(db, branchId.value(), statusFilter, limit):
          items.add requestJson(request)
        status = 200)
  except DbError:
    status = 500
    problem = "daftar pengajuan gagal dibaca"

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleGetTellerVault*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/teller/vault?branchId=` — saldo vault satu cabang.
  ## **404** (`params.reason = vault_not_configured`) bila baris vault belum ada: absennya
  ## konfigurasi adalah "tidak ada", bukan 200 dengan saldo nol yang menyesatkan.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerVaultRead):
    return
  let branchRaw = queryValue(req, "branchId").strip
  let branchId = parseId(branchRaw)
  if branchRaw.len == 0 or branchId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "branchId harus UUID yang sah")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, branchRaw, permissionTellerVaultRead):
          status = 403
          problem = "izin " & permissionTellerVaultRead & " tidak dipegang di cabang ini"
          return
        let balance = vaultBalanceOf(db, branchId.value())
        if balance.isNone:
          status = 404
          problem = "vault cabang belum dikonfigurasi"
          return
        status = 200
        payload = %*{"branchId": branchRaw, "balance": balance.get().toDecimalString})
  except DbError:
    status = 500
    problem = "saldo vault gagal dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(newProblem(pkNotFound, "Not Found", problem,
      traceId = traceIdFrom(req), params = @[("reason", "vault_not_configured")]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
