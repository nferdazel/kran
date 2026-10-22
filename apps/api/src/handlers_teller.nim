## Handler REST transaksi tunai teller (T-088b, spec §9.2/§9.3/§13).
##
## Composition root: validasi lintas-modul (rekening, binding versi produk, periode), posting jurnal
## **sinkron**, dan audit ditulis di sini dalam **satu** `withDbTx`. Modul `deposit`/`ledger` tetap
## murni (domain + repo SQL).
##
## **HUMAN-REVIEW-REQUIRED**: jalur finansial — mutasi saldo + jurnal double-entry (AGENTS.md §8).
##
## Alur satu permintaan (semua di dalam satu transaksi DB):
##   kunci/ubah saldo (`UPDATE ... WHERE balance - ? >= min_balance`) → jurnal sinkron (posting rule)
##   → baris `deposit.transaction` → audit → event outbox non-akuntansi.
## 0 baris pada UPDATE = 409 `insufficient_funds`; periode tertutup = 409 `period_closed` (rollback:
## saldo & baris transaksi tidak berubah).

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, money, result]
import platform/domain/[audit, event, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo]
import deposit/domain/account
import deposit/domain/transaction
import deposit/infrastructure/account_repo
import deposit/infrastructure/transaction_repo
import ledger/infrastructure/journal_repo
import product/domain/product
import product/infrastructure/product_repo

import ./access
import ./context
import ./db_bridge
import ./deposit_posting
import ./http_util
import ./idempotency
import ./problem

const
  permissionTellerTransactionPost* = "teller.transaction.post"
  operationIdCashTransaction = "teller.cash_transaction.post"
  ## Binding saldo minimum milik versi produk (spec §10: nilai dari parameter, bukan kode).
  minBalanceParamKey = "product.savings.min_balance"

proc minBalanceFor(db: DbConn, versionId: Id): Money =
  ## Saldo minimum dari binding versi produk akun. Tidak ada binding → 0 (D-095: pack default 0).
  ## Binding ada tetapi bukan nominal sah = data produk rusak → `ValueError` (pemanggil → 500).
  for binding in bindingsOf(db, versionId):
    if binding.paramKey != minBalanceParamKey:
      continue
    if binding.value.isNil or binding.value.kind != JString:
      raise newException(ValueError,
        "binding " & minBalanceParamKey & " bukan string desimal")
    let parsed = moneyFromString(binding.value.getStr())
    if parsed.isErr:
      raise newException(ValueError, "binding " & minBalanceParamKey & " bukan nominal sah")
    return parsed.value()
  zero()

proc respondConflict(req: Request, reason, detail: string) =
  ## 409 dengan `reason` supaya klien bisa membedakan penyebab tanpa menebak dari `detail`.
  req.respondProblem(newProblem(pkConflict, "Conflict", detail, traceId = traceIdFrom(req),
    params = @[("reason", reason)]))

proc cashTransactionJson(tx: Transaction, direction: CashDirection, balanceAfter: Money): JsonNode =
  %*{
    "transactionId": $tx.transactionId,
    "journalId": $tx.journalId,
    "direction": $direction,
    "amount": tx.amount.toDecimalString,
    "balanceAfter": balanceAfter.toDecimalString,
    "businessDate": tx.businessDate,
  }

proc handleCashTransaction*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/cash-transactions` — setor atau tarik tunai satu rekening.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerTransactionPost):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let accountId = parseId(node.jsonField("accountId"))
  if accountId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "accountId harus UUID yang sah")
    return

  var direction: CashDirection
  try:
    direction = parseCashDirection(node.jsonField("direction"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let amountParsed = moneyFromString(node.jsonField("amount"))
  if amountParsed.isErr or amountParsed.value() <= zero():
    req.respondProblem(pkBadRequest, "Bad Request", "amount harus nominal desimal positif")
    return
  let amount = amountParsed.value()

  var narration = ""
  try:
    narration = validateNarration(node.jsonField("narration"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  # Kunci jurnal (lapis kedua) dihitung sebelum transaksi supaya kunci terlalu panjang = 400 bersih,
  # tanpa menyentuh DB.
  var journalKey = ""
  try:
    journalKey = tellerJournalKey(principal.user.userId, req.headers[idempotencyHeader])
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let asOf = businessDateIso(app.clock)

  var status = 0
  var problem = ""
  var reason = ""
  var payload = newJObject()
  var outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdCashTransaction, $node, asOf,
        app.clock.now(),
        proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let accountOpt = accountById(db, accountId.value())
            if accountOpt.isNone:
              status = 404
              problem = "rekening tidak ditemukan"
              raise newException(ValueError, problem)
            let account = accountOpt.get()

            if not authorizedAtBranch(db, principal, $account.branchId,
                permissionTellerTransactionPost):
              status = 403
              problem = "izin " & permissionTellerTransactionPost &
                " tidak dipegang di cabang rekening ini"
              raise newException(ValueError, problem)

            if account.status != asActive:
              status = 409
              reason = "account_not_active"
              problem = "rekening tidak berstatus ACTIVE"
              raise newException(ValueError, problem)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            if not periodOpenFor(db, businessDate):
              status = 409
              reason = "period_closed"
              problem = "periode tanggal bisnis sudah ditutup"
              raise newException(ValueError, problem)

            var minBalance: Money
            try:
              minBalance = minBalanceFor(db, account.productVersionId)
            except ValueError as e:
              status = 500
              problem = e.msg
              raise newException(ValueError, problem)

            let txId = newId(app.clock)
            let actor = parseId(principal.user.userId).value()

            let balanceAfter =
              case direction
              of cdDeposit: increaseBalance(db, account.accountId, amount)
              of cdWithdrawal: decreaseBalance(db, account.accountId, amount, minBalance)
            if balanceAfter.isNone:
              if direction == cdWithdrawal:
                status = 409
                reason = "insufficient_funds"
                problem = "saldo tidak cukup untuk penarikan ini"
              else:
                status = 500
                problem = "baris saldo rekening tidak ditemukan"
              raise newException(ValueError, problem)

            # Posting jurnal sinkron (bukan outbox). Kegagalan periode dari trigger `ledger`
            # (balapan tutup periode, T-080) dipetakan ke 409; rollback membatalkan mutasi saldo.
            var journalId: Id
            try:
              journalId = postJournalSync(db, app.clock, sourceEventOf(direction), amount,
                account.branchId, txId, businessDate, journalKey, actor)
            except DbError as e:
              if "periode OPEN" in e.msg:
                status = 409
                reason = "period_closed"
                problem = "periode tanggal bisnis sudah ditutup"
              else:
                status = 500
                problem = "jurnal transaksi gagal disimpan"
              raise newException(ValueError, problem)
            except ValueError as e:
              status = 500
              problem = "posting rule transaksi tidak tersedia: " & e.msg
              raise newException(ValueError, problem)

            let tx = Transaction(
              transactionId: txId,
              txType: txTypeOf(direction),
              accountId: account.accountId,
              amount: amount,
              businessDate: businessDate,
              narration: narration,
              journalId: journalId)
            insertTransaction(db, tx, actor)

            let ctx = auditContextFor(principal, req, app.clock, "transaksi tunai " & $direction,
              $account.branchId)
            discard appendAudit(db, newAuditEntry(ctx, "deposit.transaction.post",
              "deposit_transaction", $txId, app.clock, businessDate = businessDate,
              after = %*{
                "transactionId": $txId,
                "accountId": $account.accountId,
                "direction": $direction,
                "amount": amount.toDecimalString,
                "journalId": $journalId,
              }))

            # Event non-akuntansi: TANPA header `accounting` supaya konsumen `ledger` tidak
            # memposting jurnal kedua (jurnal sudah ditulis sinkron di atas).
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "CashTransactionPosted",
              "deposit_transaction", $txId, "CashTransactionPosted:" & $txId,
              %*{"transactionId": $txId, "accountId": $account.accountId,
                 "direction": $direction, "amount": amount.toDecimalString,
                 "businessDate": businessDate, "branchId": $account.branchId}))
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "journal.posted", "journal",
              $journalId, "journal.posted:" & $journalId,
              %*{"journalId": $journalId, "businessDate": businessDate,
                 "sourceEvent": sourceEventOf(direction), "reversalOf": nil,
                 "totalDebit": amount.toDecimalString}))

            status = 201
            payload = cashTransactionJson(tx, direction, balanceAfter.get())
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
    problem = "transaksi tunai gagal disimpan"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 409:
    if reason.len > 0:
      req.respondConflict(reason, problem)
    else:
      req.respondProblem(pkConflict, "Conflict", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
