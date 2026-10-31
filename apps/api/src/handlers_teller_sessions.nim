## Handler REST sesi kas teller + vault (T-093, spec §9.2/§11.6/§13).
##
## Composition root: izin ber-cabang, tanggal bisnis institusi, audit, dan event outbox ditulis di
## sini dalam **satu** `withDbTx` per operasi. Modul `teller` tetap murni (domain + repo SQL).
##
## **HUMAN-REVIEW-REQUIRED**: mutasi vault + variance kas (AGENTS.md §8). T-093 **tidak** memposting
## jurnal GL (COA kas teller = keputusan akuntansi; lihat `docs/ACCEPTED-LIMITS.md`).
##
## Alur buka (satu transaksi DB): izin cabang → debit vault bersyarat (`balance >= ?`) → baris sesi
## `OPEN` (`ON CONFLICT ... WHERE status='OPEN'` menolak sesi ganda tanpa error DB) → audit → event.
## Alur tutup: kunci baris sesi (`FOR UPDATE`) → hitung `expected_cash` dari agregat `cash_movement`
## → `variance = counted − expected` → tandai `CLOSED` → tambah vault sebesar **counted**.
##
## `Idempotency-Key` **wajib** (operasi kas, D-098): retry setelah timeout tidak boleh mendebit vault
## dua kali atau menutup dua kali. Replay = 200 + `Idempotent-Replayed`; isi beda = 409.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, money, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo]
import ledger/infrastructure/journal_repo
import teller/domain/session
import teller/infrastructure/session_repo

import ./access
import ./cash_limit
import ./context
import ./db_bridge
import ./deposit_posting
import ./http_util
import ./idempotency
import ./problem

const
  permissionTellerSessionOpen* = "teller.session.open"
  permissionTellerSessionClose* = "teller.session.close"
  permissionTellerSessionRead* = "teller.session.read"
  operationIdSessionOpen = "teller.session.open"
  operationIdSessionClose = "teller.session.close"

proc respondConflict(req: Request, reason, detail: string) =
  ## 409 dengan `reason` supaya klien bisa membedakan penyebab tanpa menebak dari `detail`.
  req.respondProblem(newProblem(pkConflict, "Conflict", detail, traceId = traceIdFrom(req),
    params = @[("reason", reason)]))

proc sessionJson(s: TellerSession): JsonNode =
  %*{
    "sessionId": $s.sessionId,
    "tellerId": $s.tellerUserId,
    "branchId": $s.branchId,
    "businessDate": s.businessDate,
    "status": $s.status,
    "openingFloat": s.openingFloat.toDecimalString,
    "openedAt": s.openedAt,
    "note": s.note,
  }

proc closedSessionJson(s: TellerSession): JsonNode =
  ## Ringkasan tutup: kolom penutup wajib ada (ditegakkan CHECK tabel); `none` = data rusak.
  %*{
    "sessionId": $s.sessionId,
    "businessDate": s.businessDate,
    "status": $s.status,
    "openingFloat": s.openingFloat.toDecimalString,
    "countedCash": s.countedCash.get(zero()).toDecimalString,
    "expectedCash": s.expectedCash.get(zero()).toDecimalString,
    "variance": s.variance.get(zero()).toDecimalString,
    "closedAt": s.closedAt,
    "note": s.note,
  }

proc handleOpenTellerSession*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/sessions` — buka sesi kas untuk pemanggil di satu cabang.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerSessionOpen):
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

  let floatParsed = moneyFromString(node.jsonField("openingFloat"))
  if floatParsed.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "openingFloat harus nominal desimal")
    return
  var openingFloat: Money
  try:
    openingFloat = validateOpeningFloat(floatParsed.value())
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
  var reason = ""
  var payload = newJObject()
  var outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdSessionOpen, $node, asOf, app.clock.now(),
        proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            if not authorizedAtBranch(db, principal, branchRaw, permissionTellerSessionOpen):
              status = 403
              problem = "izin " & permissionTellerSessionOpen & " tidak dipegang di cabang ini"
              raise newException(ValueError, problem)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let teller = parseId(principal.user.userId).value()

            # Plafon float per sesi (K-5/O-099) dari parameter; dicek sebelum vault disentuh.
            let floatLimit = cashLimit(db, P_teller_cash_limit_opening_float, businessDate)
            if exceedsLimit(openingFloat, floatLimit):
              status = 409
              reason = "cash_limit_exceeded"
              problem = "opening float melebihi plafon " & floatLimit.toDecimalString
              raise newException(ValueError, problem)

            # Periksa lebih dulu supaya vault tidak tersentuh; balapan tetap ditangani index di bawah.
            if openSessionFor(db, branchId.value(), teller).isSome:
              status = 409
              reason = "session_already_open"
              problem = "teller sudah punya sesi kas OPEN di cabang ini"
              raise newException(ValueError, problem)

            if debitVault(db, branchId.value(), openingFloat).isNone:
              status = 409
              if vaultBalanceOf(db, branchId.value()).isNone:
                reason = "vault_not_configured"
                problem = "vault cabang belum dikonfigurasi"
              else:
                reason = "insufficient_vault"
                problem = "saldo vault tidak cukup untuk opening float ini"
              raise newException(ValueError, problem)

            let session = newOpenSession(newId(app.clock), branchId.value(), teller, businessDate,
              openingFloat, teller, note)
            if not insertOpenSession(db, session):
              # Balapan dua buka: sesi sudah ada; transaksi dibatalkan sehingga debit vault batal.
              status = 409
              reason = "session_already_open"
              problem = "teller sudah punya sesi kas OPEN di cabang ini"
              raise newException(ValueError, problem)

            # Kas pindah dari vault ke laci: jurnal **sinkron** di transaksi yang sama supaya
            # tidak pernah ada float tanpa jejak buku besar (T-118, O-097 opsi A).
            # Float nol = tidak ada kas berpindah, jadi tidak ada jurnal (jurnal bernominal nol
            # ditolak domain).
            if openingFloat.isPositive:
              discard postRuleJournalSync(db, app.clock, "TellerSessionOpened", openingFloat,
                branchId.value(), session.sessionId, businessDate,
                "teller-session-opened:" & $session.sessionId, teller, newJObject())

            let ctx = auditContextFor(principal, req, app.clock, "buka sesi kas teller", branchRaw)
            discard appendAudit(db, newAuditEntry(ctx, "teller.session.open", "teller_session",
              $session.sessionId, app.clock, businessDate = businessDate,
              after = %*{
                "sessionId": $session.sessionId,
                "branchId": branchRaw,
                "tellerId": $teller,
                "openingFloat": openingFloat.toDecimalString,
                "businessDate": businessDate,
              }))

            discard appendEvent(db, newOutboxEvent(newId(app.clock), "TellerSessionOpened",
              "teller_session", $session.sessionId, "TellerSessionOpened:" & $session.sessionId,
              %*{"sessionId": $session.sessionId, "branchId": branchRaw, "tellerId": $teller,
                 "openingFloat": openingFloat.toDecimalString, "businessDate": businessDate}))

            status = 201
            payload = sessionJson(sessionById(db, session.sessionId).get())
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problem = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problem = "idempotensi gagal diselesaikan"
  except CashLimitConfigError as e:
    status = 500
    problem = "konfigurasi plafon kas tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    if status == 0:
      status = 500
    problem = "sesi kas gagal dibuka"

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

proc handleCloseTellerSession*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/sessions/{sessionId}/close` — tutup sesi kas + catat variance.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerSessionClose):
    return

  let sessionId = parseId(pathParam(req, "sessionId"))
  if sessionId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "sesi kas tidak ditemukan")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let countedParsed = moneyFromString(node.jsonField("countedCash"))
  if countedParsed.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "countedCash harus nominal desimal")
    return
  var countedCash: Money
  try:
    countedCash = validateCountedCash(countedParsed.value())
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

  let asOf = businessDateIso(app.clock)

  var status = 0
  var problem = ""
  var reason = ""
  var payload = newJObject()
  var outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdSessionClose, $node, asOf, app.clock.now(),
        proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            # Kunci baris lebih dulu: dua tutup bersamaan terserialisasi di sini (yang kedua melihat
            # status CLOSED dan ditolak) — vault tidak bertambah dua kali.
            let sessionOpt = sessionByIdForUpdate(db, sessionId.value())
            if sessionOpt.isNone:
              status = 404
              problem = "sesi kas tidak ditemukan"
              raise newException(ValueError, problem)
            let session = sessionOpt.get()

            if not authorizedAtBranch(db, principal, $session.branchId,
                permissionTellerSessionClose):
              status = 403
              problem = "izin " & permissionTellerSessionClose &
                " tidak dipegang di cabang sesi ini"
              raise newException(ValueError, problem)

            if $session.tellerUserId != principal.user.userId:
              status = 409
              reason = "session_not_owned"
              problem = "sesi kas ini bukan milik pemanggil"
              raise newException(ValueError, problem)

            if session.status != tssOpen:
              status = 409
              reason = "session_not_open"
              problem = "sesi kas sudah ditutup"
              raise newException(ValueError, problem)

            # LED-1/T-129: penutupan sesi memposting jurnal bertanggal `business_date` sesi.
            # Tanpa periode OPEN untuk tanggal itu, trigger menolak jurnal, transaksi rollback, dan
            # sesi tetap OPEN padahal kas sudah dihitung — layar teller hanya melihat 500. Karena
            # itu diperiksa lebih dulu dan dijawab 409 yang bisa ditindaklanjuti.
            if not periodOpenFor(db, session.businessDate):
              status = 409
              reason = "period_closed"
              problem = "tidak ada periode akuntansi OPEN untuk " & session.businessDate &
                "; buka periode itu lebih dulu"
              raise newException(ValueError, problem)

            let totals = movementTotalsOf(db, session.sessionId)
            let expectedCash = expectedCashOf(session.openingFloat, totals.cashIn, totals.cashOut)
            let variance = varianceOf(countedCash, expectedCash)
            let actor = parseId(principal.user.userId).value()

            if not closeSession(db, session.sessionId, expectedCash, countedCash, variance, note,
                actor):
              status = 409
              reason = "session_not_open"
              problem = "sesi kas sudah ditutup"
              raise newException(ValueError, problem)

            # Vault bertambah sebesar kas fisik yang benar-benar masuk (counted), bukan expected.
            if creditVault(db, session.branchId, countedCash).isNone:
              status = 500
              problem = "vault cabang hilang saat penutupan sesi"
              raise newException(ValueError, problem)

            # Kas fisik kembali ke vault, lalu selisih menutup saldo laci. Kaki selisih memakai
            # akun laci (`101.2`), bukan vault: setelah kas kembali, saldo laci = -variance, jadi
            # hanya laci yang bisa dinolkan oleh jurnal selisih (lihat migrasi `ledger/0034`).
            if countedCash.isPositive:
              discard postRuleJournalSync(db, app.clock, "TellerSessionClosed", countedCash,
                session.branchId, session.sessionId, session.businessDate,
                "teller-session-closed:" & $session.sessionId, actor, newJObject())
            if variance.isPositive:
              discard postRuleJournalSync(db, app.clock, "TellerCashOverage", variance,
                session.branchId, session.sessionId, session.businessDate,
                "teller-session-overage:" & $session.sessionId, actor, newJObject())
            elif variance.isNegative:
              discard postRuleJournalSync(db, app.clock, "TellerCashShortage", abs(variance),
                session.branchId, session.sessionId, session.businessDate,
                "teller-session-shortage:" & $session.sessionId, actor, newJObject())

            let ctx = auditContextFor(principal, req, app.clock, "tutup sesi kas teller",
              $session.branchId)
            discard appendAudit(db, newAuditEntry(ctx, "teller.session.close", "teller_session",
              $session.sessionId, app.clock, businessDate = session.businessDate,
              after = %*{
                "sessionId": $session.sessionId,
                "openingFloat": session.openingFloat.toDecimalString,
                "expectedCash": expectedCash.toDecimalString,
                "countedCash": countedCash.toDecimalString,
                "variance": variance.toDecimalString,
                "note": note,
              }))

            discard appendEvent(db, newOutboxEvent(newId(app.clock), "TellerSessionClosed",
              "teller_session", $session.sessionId, "TellerSessionClosed:" & $session.sessionId,
              %*{"sessionId": $session.sessionId, "branchId": $session.branchId,
                 "tellerId": $session.tellerUserId, "expectedCash": expectedCash.toDecimalString,
                 "countedCash": countedCash.toDecimalString, "variance": variance.toDecimalString}))

            status = 200
            payload = closedSessionJson(sessionById(db, session.sessionId).get())
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
    problem = "sesi kas gagal ditutup"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 200: req.respondJson(200, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 409: req.respondConflict(reason, problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleGetCurrentTellerSession*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/teller/sessions/current?branchId=` — sesi `OPEN` pemanggil di cabang itu.
  ## **404** (bukan 200 `{session:null}`) bila tidak ada: `params.reason = session_not_open`.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerSessionRead):
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
        if not authorizedAtBranch(db, principal, branchRaw, permissionTellerSessionRead):
          status = 403
          problem = "izin " & permissionTellerSessionRead & " tidak dipegang di cabang ini"
          return
        let teller = parseId(principal.user.userId).value()
        let sessionOpt = openSessionFor(db, branchId.value(), teller)
        if sessionOpt.isNone:
          status = 404
          problem = "tidak ada sesi kas OPEN di cabang ini"
          return
        status = 200
        payload = sessionJson(sessionOpt.get()))
  except DbError:
    status = 500
    problem = "sesi kas gagal dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(newProblem(pkNotFound, "Not Found", problem,
      traceId = traceIdFrom(req), params = @[("reason", "session_not_open")]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

const
  defaultSessionTransactionsLimit = 50 # nomagic:ok batas teknis paginasi, bukan nilai bisnis
  maxSessionTransactionsLimit = 100    # nomagic:ok batas teknis paginasi, bukan nilai bisnis

proc sessionTransactionJson(tx: SessionTransaction): JsonNode =
  ## `direction` relatif laci: `IN` = uang masuk (CASH_IN), `OUT` = uang keluar (CASH_OUT).
  %*{
    "transactionId": $tx.transactionId,
    "journalId": $tx.journalId,
    "accountId": $tx.accountId,
    "accountNo": tx.accountNo,
    "direction": (if tx.direction == cmCashIn: "IN" else: "OUT"),
    "amount": tx.amount.toDecimalString,
    "occurredAt": tx.occurredAt,
    "narration": tx.narration,
  }

proc handleListSessionTransactions*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/teller/sessions/{sessionId}/transactions` — arus kas satu sesi (T-147).
  ##
  ## Layar kas butuh daftar transaksi sesi tanpa berpindah halaman (DESIGN §11), dan tidak ada
  ## jalur lain yang bisa membacanya: statement per rekening tidak tahu sesi mana yang menulis baris
  ## itu. Sumbernya `teller.cash_movement` karena nominal di sana adalah **kas yang diserahkan**,
  ## bukan nominal rekening (pencairan dini membayar pokok + bunga − penalti, D-164).
  ##
  ## Izin `teller.session.read` di cabang sesi — sama dengan `GET current`, supaya layar tidak butuh
  ## izin tambahan hanya untuk menampilkan isi sesinya sendiri.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionTellerSessionRead):
    return

  let sessionId = parseId(pathParam(req, "sessionId"))
  if sessionId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "sessionId harus UUID yang sah")
    return

  var limit = defaultSessionTransactionsLimit
  let limitRaw = queryValue(req, "limit").strip
  if limitRaw.len > 0:
    try:
      limit = parseInt(limitRaw)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus angka")
      return
    if limit < 1 or limit > maxSessionTransactionsLimit:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus antara 1 dan 100")
      return

  var offset = 0
  let offsetRaw = queryValue(req, "offset").strip
  if offsetRaw.len > 0:
    try:
      offset = parseInt(offsetRaw)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "offset harus angka")
      return
    if offset < 0:
      req.respondProblem(pkBadRequest, "Bad Request", "offset tidak boleh negatif")
      return

  var status = 0
  var reason = ""
  var problem = ""
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let sessionOpt = sessionById(db, sessionId.value())
        if sessionOpt.isNone:
          status = 404
          reason = "session_not_found"
          problem = "sesi kas tidak dikenal"
          return
        let session = sessionOpt.get()
        if not authorizedAtBranch(db, principal, $session.branchId, permissionTellerSessionRead):
          status = 403
          problem = "izin " & permissionTellerSessionRead & " tidak dipegang di cabang sesi ini"
          return
        let items = sessionTransactions(db, session.sessionId, limit, offset)
        status = 200
        payload = %*{
          "sessionId": $session.sessionId,
          "businessDate": session.businessDate,
          "total": sessionTransactionCount(db, session.sessionId),
          "items": (block:
          var arr = newJArray()
          for item in items:
            arr.add sessionTransactionJson(item)
          arr),
        })
  except DbError:
    status = 500
    problem = "arus kas sesi gagal dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(newProblem(pkNotFound, "Not Found", problem,
      traceId = traceIdFrom(req), params = @[("reason", reason)]))
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
