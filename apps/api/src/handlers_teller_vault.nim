## Handler REST vault kas cabang (T-107, spec §9.2/§13).
##
## Composition root: izin ber-cabang, audit, dan event outbox ditulis di sini dalam **satu**
## `withDbTx` per operasi. Modul `teller` tetap murni (domain + repo SQL).
##
## **HUMAN-REVIEW-REQUIRED**: mutasi saldo vault kas (AGENTS.md §8). Top-up **tidak** memposting
## jurnal GL: menambah kas operasional ke vault tanpa akun lawan yang sah adalah keputusan
## akuntansi yang belum diambil (O-097; lihat `docs/ACCEPTED-LIMITS.md` dan `modules/teller/MODULE.md`).
##
## `POST /teller/vault/topups` menaikkan saldo vault cabang lewat increment atomik
## (`UPDATE teller.vault SET balance = balance + ?`) — satu baris per cabang, tanpa celah
## read-then-write. `Idempotency-Key` **wajib** (operasi finansial, D-098): retry setelah timeout
## tidak boleh menambah vault dua kali. Replay = 200 + `Idempotent-Replayed`; isi beda = 409.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, money, result]
import platform/domain/[audit, event, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo]
import teller/domain/session
import teller/infrastructure/session_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./idempotency
import ./problem

const
  permissionTellerVaultTopup* = "teller.vault.topup"
  permissionTellerVaultRead* = "teller.vault.read"
  operationIdVaultTopUp = "teller.vault.topup"

proc handleTopUpTellerVault*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/vault/topups` — injeksi kas operasional ke vault satu cabang.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerVaultTopup):
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

  var note = ""
  try:
    note = validateSessionNote(node.jsonField("note"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let branchRaw = $branchId.value()
  let asOf = businessDateIso(app.clock)

  var status = 0
  var problem = ""
  var payload = newJObject()
  var outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdVaultTopUp, $node, asOf, app.clock.now(),
        proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            if not authorizedAtBranch(db, principal, branchRaw, permissionTellerVaultTopup):
              status = 403
              problem = "izin " & permissionTellerVaultTopup & " tidak dipegang di cabang ini"
              raise newException(ValueError, problem)

            # Vault harus sudah ada (seed/runbook, T-093): top-up tidak membuat baris vault baru
            # diam-diam. Baris hilang = 404, bukan 409 sesi-kas: di sini vault memang resource
            # yang dialamatkan permintaan.
            let balanceBefore = vaultBalanceOf(db, branchId.value())
            if balanceBefore.isNone:
              status = 404
              problem = "vault cabang belum dikonfigurasi"
              raise newException(ValueError, problem)

            # Increment atomik (satu baris per cabang): tabrakan dua top-up bersamaan dijumlahkan
            # di DB, bukan saling menimpa.
            let balanceAfter = creditVault(db, branchId.value(), amount)
            if balanceAfter.isNone:
              status = 404
              problem = "vault cabang belum dikonfigurasi"
              raise newException(ValueError, problem)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let ctx = auditContextFor(principal, req, app.clock, "top-up kas vault cabang",
              branchRaw)
            discard appendAudit(db, newAuditEntry(ctx, "teller.vault.topup", "teller_vault",
              branchRaw, app.clock, businessDate = businessDate,
              after = %*{
                "branchId": branchRaw,
                "amount": amount.toDecimalString,
                "balanceBefore": balanceBefore.get().toDecimalString,
                "balanceAfter": balanceAfter.get().toDecimalString,
                "note": note,
              }))

            # dedupKey butuh komponen unik per top-up: cabang bukan aggregate yang hanya sekali
            # disentuh (top-up berulang untuk cabang sama adalah hal normal).
            let eventId = newId(app.clock)
            discard appendEvent(db, newOutboxEvent(eventId, "TellerVaultTopedUp", "teller_vault",
              branchRaw, "TellerVaultTopedUp:" & $eventId,
              %*{"branchId": branchRaw, "amount": amount.toDecimalString,
                 "balanceAfter": balanceAfter.get().toDecimalString, "note": note,
                 "businessDate": businessDate}))

            status = 201
            payload = %*{"branchId": branchRaw, "balanceAfter": balanceAfter.get().toDecimalString}
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
    if status == 0:
      status = 500
    problem = "top-up vault gagal"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(newProblem(pkNotFound, "Not Found", problem,
      traceId = traceIdFrom(req), params = @[("reason", "vault_not_configured")]))
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
  if branchRaw.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "branchId wajib diisi")
    return
  let branchId = parseId(branchRaw)
  if branchId.isErr:
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
