## Handler REST transaksi teller (T-088b tunai, T-088c pemindahbukuan; spec §9.2/§9.3/§13).
##
## **Gerbang sesi kas (T-093b):** transaksi tunai wajib punya sesi `OPEN` milik pemanggil di cabang
## rekening pada tanggal bisnis yang sama (`no_open_session` bila tidak) dan menulis satu baris
## `teller.cash_movement`. PB **tidak** digerbang sesi (tidak menggerakkan uang fisik).
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

import kernel/[clock, ids, money, rate, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo]
import deposit/domain/account
import deposit/domain/transaction
import deposit/domain/transfer
import deposit/infrastructure/account_repo
import deposit/infrastructure/transaction_repo
import deposit/infrastructure/transfer_repo
import ledger/infrastructure/journal_repo
import product/domain/product
import product/infrastructure/product_repo
import teller/domain/session
import teller/infrastructure/session_repo

import ./access
import ./cash_limit
import ./context
import ./db_bridge
import ./deposit_posting
import ./handlers_deposit
import ./http_util
import ./idempotency
import ./problem

type
  DepositConfigError* = object of ValueError
    ## Data server (binding/min_balance/saldo tersimpan) rusak: 500, bukan 400.

const
  permissionTellerTransactionPost* = "teller.transaction.post"
  operationIdCashTransaction = "teller.cash_transaction.post"
  operationIdTransfer = "teller.transfer.post"
  ## Binding saldo minimum milik versi produk (spec §10: nilai dari parameter, bukan kode).
  minBalanceParamKey = "product.savings.min_balance"
  ## Penalti pencairan dini (D-164): persen dari pokok, tanpa nilai seed.
  earlyWithdrawalPenaltyKey = "product.savings.early_withdrawal_penalty"

proc minBalanceFor(db: DbConn, versionId: Id): Money =
  ## Saldo minimum dari binding versi produk akun. Tidak ada binding → 0 (D-095: pack default 0).
  ## Binding ada tetapi bukan nominal sah = data produk rusak → `ValueError` (pemanggil → 500).
  for binding in bindingsOf(db, versionId):
    if binding.paramKey != minBalanceParamKey:
      continue
    if binding.value.isNil or binding.value.kind != JString:
      raise newException(DepositConfigError,
        "binding " & minBalanceParamKey & " bukan string desimal")
    let parsed = moneyFromString(binding.value.getStr())
    if parsed.isErr:
      raise newException(DepositConfigError,
        "binding " & minBalanceParamKey & " bukan nominal sah")
    if parsed.value() < zero():
      raise newException(DepositConfigError,
        "binding " & minBalanceParamKey & " negatif (konfigurasi produk rusak)")
    return parsed.value()
  zero()

type
  EarlyWithdrawal* = object
    ## Rincian pencairan dini deposito berjangka (D-164). `cashPaid = principal + interest − penalty`.
    principal*: Money
    interest*: Money
    penalty*: Money

proc penaltyRateFor(db: DbConn; versionId: Id): Option[Rate] =
  ## Rate penalti dari binding versi produk. `none` = produk belum mengikat atribut itu; pencairan
  ## dini ditolak (`early_withdrawal_penalty_missing`), bukan dianggap tanpa penalti.
  for binding in bindingsOf(db, versionId):
    if binding.paramKey != earlyWithdrawalPenaltyKey:
      continue
    if binding.value.isNil or binding.value.kind != JString:
      raise newException(DepositConfigError,
        "binding " & earlyWithdrawalPenaltyKey & " bukan string persen")
    let parsed = rateFromPercentString(binding.value.getStr())
    if parsed.isErr:
      raise newException(DepositConfigError,
        "binding " & earlyWithdrawalPenaltyKey & " bukan persen sah")
    return some(parsed.value())
  none(Rate)

proc cashPaid(early: EarlyWithdrawal): Money =
  early.principal + early.interest - early.penalty

proc earlyWithdrawalJson(early: EarlyWithdrawal; credited: Money): JsonNode =
  ## `cashPaid` = uang yang keluar di jalur tunai; `creditedAmount` = dana yang masuk di jalur PB.
  ## Keduanya rumus yang sama (`pokok + bunga − penalti`), tetapi namanya harus jujur per kanal.
  %*{
    "principal": early.principal.toDecimalString,
    "interest": early.interest.toDecimalString,
    "penalty": early.penalty.toDecimalString,
    "cashPaid": credited.toDecimalString,
  }

proc earlyWithdrawalFor(db: DbConn; account: Account; amount: Money; businessDate: string):
    tuple[reason, problem: string, detail: EarlyWithdrawal] =
  ## Rincian pencairan dini (T-146/T-148). `reason == ""` berarti sah; selebihnya pemanggil
  ## memetakannya ke 409. Aturan yang sama dipakai jalur tunai dan PB: penuh, sebelum jatuh tempo,
  ## penalti dari binding produk (tanpa binding = ditolak, bukan nol), dan kas bersih harus positif.
  let maturity = maturityDateOf(db, account.accountId)
  if maturity.len == 0 or businessDate >= maturity:
    return ("time_deposit_locked",
      "penarikan deposito berjangka hanya untuk pencairan dini sebelum jatuh tempo",
      EarlyWithdrawal())
  if amount != account.balance:
    return ("time_deposit_partial_withdrawal",
      "pencairan dini deposito berjangka harus penuh sebesar saldo", EarlyWithdrawal())
  let rateOpt = penaltyRateFor(db, account.productVersionId)
  if rateOpt.isNone:
    return ("early_withdrawal_penalty_missing",
      "produk rekening belum mengikat " & earlyWithdrawalPenaltyKey &
        "; pencairan dini tidak bisa dihitung", EarlyWithdrawal())
  let detail = EarlyWithdrawal(principal: amount,
    interest: accruedUnpaidInterest(db, account.accountId),
    penalty: applyRate(amount, rateOpt.get()))
  if not cashPaid(detail).isPositive:
    # Penalti ≥ pokok + bunga: konfigurasi produk tidak masuk akal, dan tidak ada dana yang bisa
    # diserahkan/dikreditkan.
    return ("early_withdrawal_penalty_too_high",
      "penalti pencairan dini melebihi pokok + bunga yang dibayarkan", EarlyWithdrawal())
  ("", "", detail)

proc respondConflict(req: Request, reason, detail: string) =
  ## 409 dengan `reason` supaya klien bisa membedakan penyebab tanpa menebak dari `detail`.
  req.respondProblem(newProblem(pkConflict, "Conflict", detail, traceId = traceIdFrom(req),
    params = @[("reason", reason)]))

proc lockedSavingsKind(kind: string): bool =
  ## Tarik & PB **dari** simpanan pokok/wajib diblokir di Fase 2 (T-111, memo SME): alur keluar
  ## anggota belum ada. Nilai diambil dari enum produk (satu sumber), bukan literal kedua.
  kind == $skPokok or kind == $skWajib

proc cashTransactionJson(tx: Transaction, direction: CashDirection, balanceAfter: Money;
    early: Option[EarlyWithdrawal] = none(EarlyWithdrawal)): JsonNode =
  ## `earlyWithdrawal` hanya ada pada pencairan dini deposito (D-164); `amount` tetap pokok yang
  ## didebit dari rekening, sedangkan kas yang diserahkan bisa berbeda karena bunga dan penalti.
  result = %*{
    "transactionId": $tx.transactionId,
    "journalId": $tx.journalId,
    "direction": $direction,
    "amount": tx.amount.toDecimalString,
    "balanceAfter": balanceAfter.toDecimalString,
    "businessDate": tx.businessDate,
  }
  if early.isSome:
    result["earlyWithdrawal"] = earlyWithdrawalJson(early.get(), cashPaid(early.get()))

proc cashTransactionSlipJson(tx: Transaction, accountNo: string): JsonNode =
  ## Slip cetak ulang (T-094a). **Tanpa** `balanceAfter`: saldo per transaksi tidak disimpan, dan
  ## menghitung saldo berjalan dari subledger akan mengarang data (batas D-127). Pemanggil sudah
  ## memastikan barisnya benar-benar transaksi tunai (`isCashTransaction`).
  %*{
    "transactionId": $tx.transactionId,
    "journalId": $tx.journalId,
    "direction": $cashDirectionOf(tx.txType),
    "amount": tx.amount.toDecimalString,
    "businessDate": tx.businessDate,
    "accountNo": accountNo,
    "narration": tx.narration,
  }

proc handleGetCashTransactionSlip*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/teller/cash-transactions/{transactionId}` — baca ulang satu transaksi tunai
  ## untuk cetak slip tanpa mengulang transaksi (T-094a, D-127). Izin `deposit.account.read`
  ## harus dipegang di cabang rekening; tidak ada (atau id PB) → 404.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionDepositAccountRead):
    return

  let transactionId = parseId(pathParam(req, "transactionId"))
  if transactionId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "transaksi tunai tidak ditemukan")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let txOpt = transactionById(db, transactionId.value())
        if txOpt.isNone:
          # Id PB atau id acak sama-sama "tidak ada di sini": transaksi tunai saja.
          status = 404
          problem = "transaksi tunai tidak ditemukan"
          return
        let tx = txOpt.get()
        # Baris perpindahan jatuh tempo (`MATURITY_*`/`INTEREST_CREDIT`) tidak punya arah kas dan
        # bukan slip tunai: 404, sama seperti id PB — bukan 500 "data tersimpan tidak bisa dibaca".
        if not isCashTransaction(tx.txType):
          status = 404
          problem = "transaksi tunai tidak ditemukan"
          return
        let accountOpt = accountById(db, tx.accountId)
        if accountOpt.isNone:
          status = 500
          problem = "data rekening transaksi tidak bisa dibaca"
          return
        let account = accountOpt.get()
        if not authorizedAtBranch(db, principal, $account.branchId, permissionDepositAccountRead):
          status = 403
          problem = "izin " & permissionDepositAccountRead &
            " tidak dipegang di cabang rekening ini"
          return
        status = 200
        payload = cashTransactionSlipJson(tx, account.accountNo))
  except DbError:
    status = 500
    problem = "transaksi tunai gagal dibaca"
  except ValueError:
    status = 500
    problem = "data transaksi tersimpan tidak bisa dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

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
  if amountParsed.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "amount harus nominal desimal positif")
    return
  # Positivitas dari domain (`validateAmount`) — satu tempat aturan, bukan cek inline terpisah.
  var amount: Money
  try:
    amount = validateAmount(amountParsed.value())
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

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
            var accountOpt: Option[Account]
            try:
              # Kunci baris rekening **sebelum** status/saldo dibaca (O-112): task
              # `deposit.maturity_aro` mengunci baris yang sama sebelum memutuskan, jadi setoran
              # dan penutupan jatuh tempo terserialisasi di satu baris ini. Tanpa itu setoran yang
              # sudah lolos cek status bisa commit setelah deposito ditutup (rekening `CLOSED`
              # bersaldo). Kunci diambil lebih dulu dari kunci lain jalur ini (sesi kas, baris
              # saldo) supaya urutan kunci sama dengan jalur jatuh tempo (rekening → saldo).
              lockAccountForUpdate(db, accountId.value())
              accountOpt = accountById(db, accountId.value())
            except ValueError:
              status = 500
              problem = "data rekening tersimpan tidak bisa dibaca"
              raise newException(DepositConfigError, problem)
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

            # DORMANT masih boleh menerima setoran (D-152 butir 4): tanpa itu reaktivasi otomatis
            # task `deposit.dormant` tidak pernah bisa terjadi. Penarikan dari rekening dormant
            # belum didukung — aturan penolakan transaksi dormant adalah keputusan lanjutan.
            if account.status == asClosed or
                (account.status == asDormant and direction == cdWithdrawal):
              status = 409
              reason = "account_not_active"
              problem = "rekening tidak aktif untuk transaksi ini"
              raise newException(ValueError, problem)

            let businessDate = businessDateFor(db, institutionScope(), asOf)

            # Pencairan dini deposito berjangka (D-164): hanya **penuh** dan hanya **sebelum**
            # jatuh tempo. Sebelum jatuh tempo, sisi jatuh tempo task bisa memindahkan pokok yang
            # sama; keduanya mengunci baris rekening yang sama (D-161), jadi salah satu menang dan
            # yang lain melihat status `CLOSED`.
            #
            # Sebagian tidak didukung: akrual dihitung dari saldo saat ini, jadi pokok yang
            # berkurang di tengah tenor membuat `DAY-335` menahan penutupan tanpa jalan keluar.
            var early: Option[EarlyWithdrawal] = none(EarlyWithdrawal)
            if direction == cdWithdrawal and account.accountType == atTimeDeposit:
              let (denyReason, denyProblem, detail) =
                earlyWithdrawalFor(db, account, amount, businessDate)
              if denyReason.len > 0:
                status = 409
                reason = denyReason
                problem = denyProblem
                raise newException(ValueError, problem)
              early = some(detail)

            # Tarik dari POKOK/WAJIB diblokir (setor tetap boleh): keluar anggota belum ada (T-111).
            if direction == cdWithdrawal and lockedSavingsKind(account.savingsKind):
              status = 409
              reason = "savings_kind_locked"
              problem = "penarikan dari simpanan pokok/wajib belum didukung"
              raise newException(ValueError, problem)

            # Plafon per transaksi (K-5/O-099) dari parameter; dicek sebelum saldo/jurnal disentuh.
            let valueLimit = cashLimit(db,
              if direction == cdDeposit: P_teller_cash_limit_deposit
              else: P_teller_cash_limit_withdrawal, businessDate)
            if exceedsLimit(amount, valueLimit):
              status = 409
              reason = "cash_limit_exceeded"
              problem = "nominal melebihi plafon " & valueLimit.toDecimalString
              raise newException(ValueError, problem)

            if not periodOpenFor(db, businessDate):
              status = 409
              reason = "period_closed"
              problem = "periode tanggal bisnis sudah ditutup"
              raise newException(ValueError, problem)

            # Gerbang sesi kas (T-093b): transaksi tunai **wajib** punya sesi OPEN hari ini milik
            # pemanggil di cabang rekening. Diletakkan **di dalam** blok idempotensi (bukan sebelum):
            # replay yang sah setelah sesi ditutup harus mengembalikan respons tersimpan, bukan
            # 409 palsu. `FOR KEY SHARE` membuat penutupan menunggu transaksi in-flight sehingga
            # movement ini tidak hilang dari `expected_cash`.
            let cashSessionOpt = lockOpenSession(db, account.branchId,
              parseId(principal.user.userId).value(), businessDate)
            if cashSessionOpt.isNone:
              status = 409
              # Sesi OPEN milik tanggal bisnis lain harus ditutup dulu; pesan "tidak ada sesi" akan
              # menyesatkan karena `GET /sessions/current` memang menampilkannya.
              if openSessionFor(db, account.branchId,
                  parseId(principal.user.userId).value()).isSome:
                reason = "session_business_date_mismatch"
                problem = "sesi kas OPEN milik tanggal bisnis lain; tutup sesi itu dulu"
              else:
                reason = "no_open_session"
                problem = "tidak ada sesi kas OPEN untuk teller ini di cabang rekening"
              raise newException(ValueError, problem)
            let cashSession = cashSessionOpt.get()

            var minBalance: Money
            try:
              minBalance = minBalanceFor(db, account.productVersionId)
            except ValueError as e:
              status = 500
              problem = e.msg
              raise newException(DepositConfigError, problem)

            let txId = newId(app.clock)
            let actor = parseId(principal.user.userId).value()

            var balanceAfter: Option[Money]
            try:
              balanceAfter =
                case direction
                of cdDeposit: increaseBalance(db, account.accountId, amount)
                of cdWithdrawal:
                  # Pencairan dini menutup rekening: saldo berakhir nol, jadi `min_balance` produk
                  # tidak berlaku (rekening yang ditutup tidak punya saldo minimum).
                  if early.isSome:
                    decreaseBalanceToZero(db, account.accountId, amount)
                  else:
                    decreaseBalance(db, account.accountId, amount, minBalance)
            except ValueError:
              status = 500
              problem = "data saldo rekening tidak bisa dibaca"
              raise newException(DepositConfigError, problem)
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
                account.branchId, txId, businessDate, journalKey, actor, account.productCode,
                $account.accountType, account.savingsKind)
            except DbError as e:
              if "periode OPEN" in e.msg:
                status = 409
                reason = "period_closed"
                problem = "periode tanggal bisnis sudah ditutup"
              elif "journal_idempotency_uq" in e.msg:
                # Klaim idempotensi platform kedaluwarsa (TTL) lalu permintaan diulang: kunci jurnal
                # unik selamanya menolak jurnal kedua. Perilaku terdefinisi = 409 dengan reason,
                # bukan 500 (T-102). Rollback membatalkan mutasi saldo.
                status = 409
                reason = "idempotency_replay_expired"
                problem = "Idempotency-Key ini sudah pernah diproses; respons replay sudah " &
                  "kedaluwarsa"
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

            # Pencairan dini: dua jurnal tambahan dan rekening ditutup. Kas yang diserahkan adalah
            # `pokok + bunga − penalti`; pokok sendiri sudah dijurnal `DepositWithdrawn` di atas.
            if early.isSome:
              let detail = early.get()
              try:
                if detail.interest.isPositive:
                  discard postJournalSync(db, app.clock, "InterestPaidEarly", detail.interest,
                    account.branchId, txId, businessDate, "early.interest:" & $txId, actor,
                    account.productCode, $account.accountType, account.savingsKind)
                if detail.penalty.isPositive:
                  discard postJournalSync(db, app.clock, "EarlyWithdrawalPenalty", detail.penalty,
                    account.branchId, txId, businessDate, "early.penalty:" & $txId, actor,
                    account.productCode, $account.accountType, account.savingsKind)
              except DbError as e:
                if "periode OPEN" in e.msg:
                  status = 409
                  reason = "period_closed"
                  problem = "periode tanggal bisnis sudah ditutup"
                elif "journal_idempotency_uq" in e.msg:
                  status = 409
                  reason = "idempotency_replay_expired"
                  problem = "Idempotency-Key ini sudah pernah diproses; respons replay sudah " &
                    "kedaluwarsa"
                else:
                  status = 500
                  problem = "jurnal pencairan dini gagal disimpan"
                raise newException(ValueError, problem)
              except ValueError as e:
                status = 500
                problem = "posting rule pencairan dini tidak tersedia: " & e.msg
                raise newException(ValueError, problem)
              closeAccount(db, account.accountId, actor)

            # Arus kas laci: setor = uang masuk laci (CASH_IN), tarik = keluar (CASH_OUT). Satu
            # baris per transaksi tunai (UNIQUE `transaction_id`), ditulis di transaksi DB yang sama
            # supaya `expected_cash` saat tutup tidak pernah kehilangan transaksi ini. Pencairan dini
            # menyerahkan kas bersih (pokok + bunga − penalti), bukan pokok saja.
            let movementType = if direction == cdDeposit: cmCashIn else: cmCashOut
            let cashAmount = if early.isSome: cashPaid(early.get()) else: amount
            insertMovement(db, newCashMovement(newId(app.clock), cashSession.sessionId,
              movementType, cashAmount, txId, businessDate, $actor))

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
                "earlyWithdrawal": (if early.isSome:
              earlyWithdrawalJson(early.get(), cashPaid(early.get()))
            else: newJNull()),
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
            payload = cashTransactionJson(tx, direction, balanceAfter.get(), early)
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problem = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problem = "idempotensi gagal diselesaikan"
  except DepositConfigError:
    if status == 0:
      status = 500
  except CashLimitConfigError as e:
    if status == 0:
      status = 500
    problem = "konfigurasi plafon kas tidak sah: " & e.msg
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

proc transferJson(t: Transfer, balances: TransferBalances;
    early: Option[EarlyWithdrawal] = none(EarlyWithdrawal)): JsonNode =
  ## `earlyWithdrawal` (T-148) menjelaskan mengapa saldo tujuan ≠ `amount`: bunga dibayar dan
  ## penalti dipotong. `creditedAmount` = `pokok + bunga − penalti`.
  result = %*{
    "transferId": $t.transferId,
    "journalId": $t.journalId,
    "sourceAccountId": $t.sourceAccountId,
    "destinationAccountId": $t.destinationAccountId,
    "amount": t.amount.toDecimalString,
    "sourceBalanceAfter": balances.sourceBalanceAfter.toDecimalString,
    "destinationBalanceAfter": balances.destinationBalanceAfter.toDecimalString,
    "businessDate": t.businessDate,
  }
  if early.isSome:
    let detail = early.get()
    result["earlyWithdrawal"] = %*{
      "principal": detail.principal.toDecimalString,
      "interest": detail.interest.toDecimalString,
      "penalty": detail.penalty.toDecimalString,
      "creditedAmount": cashPaid(detail).toDecimalString,
    }

proc handleTransfer*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/teller/transfers` — pemindahbukuan antar dua rekening simpanan (T-088c).
  ##
  ## Satu transaksi DB: kurangi saldo sumber (bersyarat), tambah saldo tujuan, jurnal sinkron,
  ## baris `deposit.transfer`, audit, event non-akuntansi. Izin `teller.transaction.post` harus
  ## dipegang di **kedua** cabang rekening. Periode tertutup = 409 dengan rollback penuh.
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

  let sourceParsed = parseId(node.jsonField("sourceAccountId"))
  if sourceParsed.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "sourceAccountId harus UUID yang sah")
    return
  let destinationParsed = parseId(node.jsonField("destinationAccountId"))
  if destinationParsed.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "destinationAccountId harus UUID yang sah")
    return
  let sourceId = sourceParsed.value()
  let destinationId = destinationParsed.value()

  let amountParsed = moneyFromString(node.jsonField("amount"))
  if amountParsed.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "amount harus nominal desimal positif")
    return
  let amount = amountParsed.value()

  # Akun sama / nominal tidak positif = permintaan tidak sah (400), bukan konflik: tidak ada mutasi
  # yang mungkin. Dicek sebelum menyentuh DB (positivitas termasuk `validateTransfer`).
  try:
    validateTransfer(sourceId, destinationId, amount)
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  var narration = ""
  try:
    narration = validateNarration(node.jsonField("narration"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  # Kunci jurnal (lapis kedua) dihitung sebelum transaksi supaya kunci terlalu panjang = 400 bersih.
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
        withIdempotency(db, principal, req, operationIdTransfer, $node, asOf,
        app.clock.now(),
        proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            var sourceOpt, destinationOpt: Option[Account]
            try:
              # Kunci rekening **sebelum** membaca dan sebelum baris saldo dikunci
              # (`applyTransferBalances`). Urutan rekening → saldo sama dengan jalur tunai dan task
              # jatuh tempo; tanpa ini PB memegang saldo lalu menunggu KEY SHARE rekening (FK
              # `deposit_transfer`) sementara setoran tunai memegang rekening dan menunggu saldo
              # → `40P01` (O-112/D-161). Status dibaca sesudah kunci, jadi tidak basi.
              lockTransferAccounts(db, sourceId, destinationId)
              sourceOpt = accountById(db, sourceId)
              destinationOpt = accountById(db, destinationId)
            except ValueError:
              status = 500
              problem = "data rekening tersimpan tidak bisa dibaca"
              raise newException(DepositConfigError, problem)
            if sourceOpt.isNone or destinationOpt.isNone:
              status = 404
              problem = "rekening tidak ditemukan"
              raise newException(ValueError, problem)
            let source = sourceOpt.get()
            let destination = destinationOpt.get()

            # Izin harus dipegang di **kedua** cabang rekening yang disentuh.
            if not authorizedAtBranch(db, principal, $source.branchId,
                permissionTellerTransactionPost):
              status = 403
              problem = "izin " & permissionTellerTransactionPost &
                " tidak dipegang di cabang rekening sumber"
              raise newException(ValueError, problem)
            if not authorizedAtBranch(db, principal, $destination.branchId,
                permissionTellerTransactionPost):
              status = 403
              problem = "izin " & permissionTellerTransactionPost &
                " tidak dipegang di cabang rekening tujuan"
              raise newException(ValueError, problem)

            if source.status != asActive or destination.status != asActive:
              status = 409
              reason = "account_not_active"
              problem = "rekening sumber atau tujuan tidak berstatus ACTIVE"
              raise newException(ValueError, problem)

            # Deposito berjangka sebagai **tujuan** tetap diblokir: aturan `DepositTransferred`
            # (0013) memakai `201` di kedua kaki, jadi pokok berjangka yang masuk lewat PB tidak
            # pernah dipisah ke `202` (D-152) dan saat jatuh tempo `D 202` mendebit akun yang tidak
            # pernah dikredit. Sebagai **sumber**, deposito boleh dicairkan dini (T-148/D-164) —
            # jalurnya memakai rule tersendiri di `ledger/0074`, bukan `DepositTransferred`.
            if destination.accountType == atTimeDeposit:
              status = 409
              reason = "time_deposit_locked"
              problem = "pemindahbukuan ke rekening deposito berjangka belum didukung"
              raise newException(ValueError, problem)

            # PB yang menyentuh POKOK/WAJIB (sumber **atau** tujuan) diblokir: template satu D/K
            # tidak bisa memindahkan liabilitas ke ekuitas (T-111). PB lintas jenis juga diblokir,
            # tetapi NULL (produk lama, belum terklasifikasi) diperlakukan sebagai simpanan generik
            # sehingga NULL <-> SUKARELA/TABUNGAN tetap boleh (D-128/ACCEPTED-LIMITS §4a).
            if lockedSavingsKind(source.savingsKind) or lockedSavingsKind(destination.savingsKind):
              status = 409
              reason = "savings_kind_locked"
              problem = "pemindahbukuan yang menyentuh simpanan pokok/wajib belum didukung"
              raise newException(ValueError, problem)
            if source.savingsKind != "" and destination.savingsKind != "" and
                source.savingsKind != destination.savingsKind:
              status = 409
              reason = "transfer_kind_mismatch"
              problem = "jenis simpanan rekening sumber dan tujuan berbeda"
              raise newException(ValueError, problem)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            if not periodOpenFor(db, businessDate):
              status = 409
              reason = "period_closed"
              problem = "periode tanggal bisnis sudah ditutup"
              raise newException(ValueError, problem)

            # Pencairan dini lewat PB (T-148): aturan sama dengan jalur tunai (penuh, sebelum jatuh
            # tempo, penalti dari binding produk), tetapi dana masuk ke rekening tujuan, bukan laci.
            var early: Option[EarlyWithdrawal] = none(EarlyWithdrawal)
            if source.accountType == atTimeDeposit:
              let (denyReason, denyProblem, detail) =
                earlyWithdrawalFor(db, source, amount, businessDate)
              if denyReason.len > 0:
                status = 409
                reason = denyReason
                problem = denyProblem
                raise newException(ValueError, problem)
              early = some(detail)

            # Saldo minimum dari versi produk **sumber** (rekening yang didebit).
            var minBalance: Money
            try:
              minBalance = minBalanceFor(db, source.productVersionId)
            except ValueError as e:
              status = 500
              problem = e.msg
              raise newException(DepositConfigError, problem)

            let transferId = newId(app.clock)
            let actor = parseId(principal.user.userId).value()

            var balances: Option[TransferBalances]
            try:
              if early.isSome:
                # Rekening sumber ditutup (saldo → 0) dan tujuan menerima pokok + bunga − penalti.
                let detail = early.get()
                balances = applyEarlyWithdrawalTransferBalances(db, source.accountId,
                  destination.accountId, detail.principal, detail.interest, detail.penalty)
              else:
                balances = applyTransferBalances(db, source.accountId, destination.accountId,
                  amount, minBalance)
            except ValueError:
              status = 500
              problem = "data saldo rekening tidak bisa dibaca"
              raise newException(DepositConfigError, problem)
            if balances.isNone:
              status = 409
              reason = "insufficient_funds"
              problem = "saldo rekening sumber tidak cukup untuk PB ini"
              raise newException(ValueError, problem)

            # Posting jurnal sinkron. Kegagalan periode dari trigger `ledger` (balapan tutup
            # periode, T-080) dipetakan ke 409; rollback membatalkan mutasi kedua saldo.
            var journalId: Id
            var interestJournalId, penaltyJournalId: Id
            try:
              if early.isSome:
                # Tiga jurnal, masing-masing satu D/K (template `ledger/0003`). `source_event`
                # menyebut kanalnya supaya laporan tidak menyamakan PB dengan penarikan tunai.
                let detail = early.get()
                journalId = postJournalSync(db, app.clock, "DepositWithdrawnViaTransfer",
                  detail.principal, source.branchId, transferId, businessDate,
                  tellerJournalSubKey(journalKey, "principal"), actor, source.productCode,
                  $source.accountType, source.savingsKind)
                if detail.interest.isPositive:
                  interestJournalId = postJournalSync(db, app.clock,
                    "InterestPaidEarlyViaTransfer", detail.interest, source.branchId, transferId,
                    businessDate, tellerJournalSubKey(journalKey, "interest"), actor,
                    source.productCode, $source.accountType, source.savingsKind)
                if detail.penalty.isPositive:
                  penaltyJournalId = postJournalSync(db, app.clock,
                    "EarlyWithdrawalPenaltyViaTransfer", detail.penalty, source.branchId,
                    transferId, businessDate, tellerJournalSubKey(journalKey, "penalty"), actor,
                    source.productCode, $source.accountType, source.savingsKind)
              else:
                journalId = postJournalSync(db, app.clock, transferSourceEvent, amount,
                  source.branchId, transferId, businessDate, journalKey, actor,
                  source.productCode, $source.accountType, source.savingsKind)
            except DbError as e:
              if "periode OPEN" in e.msg:
                status = 409
                reason = "period_closed"
                problem = "periode tanggal bisnis sudah ditutup"
              elif "journal_idempotency_uq" in e.msg:
                # Sama seperti transaksi tunai (T-102): replay setelah TTL → 409 terdefinisi.
                status = 409
                reason = "idempotency_replay_expired"
                problem = "Idempotency-Key ini sudah pernah diproses; respons replay sudah " &
                  "kedaluwarsa"
              else:
                status = 500
                problem = "jurnal pemindahbukuan gagal disimpan"
              raise newException(ValueError, problem)
            except ValueError as e:
              status = 500
              problem = "posting rule pemindahbukuan tidak tersedia: " & e.msg
              raise newException(ValueError, problem)

            let transfer = Transfer(
              transferId: transferId,
              sourceAccountId: source.accountId,
              destinationAccountId: destination.accountId,
              amount: amount,
              businessDate: businessDate,
              narration: narration,
              journalId: journalId)
            insertTransfer(db, transfer, actor)

            # Baris subledger sisi tujuan (T-148): bunga menambah, penalti mengurangi. Pokok sudah
            # diwakili `deposit.transfer`; sumber tidak mendapat baris sendiri.
            if early.isSome:
              let detail = early.get()
              if detail.interest.isPositive:
                insertTransaction(db, Transaction(transactionId: newId(app.clock),
                  txType: ttInterestPaidEarly, accountId: destination.accountId,
                  amount: detail.interest, businessDate: businessDate, narration: narration,
                  journalId: interestJournalId), actor)
              if detail.penalty.isPositive:
                insertTransaction(db, Transaction(transactionId: newId(app.clock),
                  txType: ttPenaltyCharge, accountId: destination.accountId,
                  amount: detail.penalty, businessDate: businessDate, narration: narration,
                  journalId: penaltyJournalId), actor)
              closeAccount(db, source.accountId, actor)

            let ctx = auditContextFor(principal, req, app.clock, "pemindahbukuan simpanan",
              $source.branchId)
            discard appendAudit(db, newAuditEntry(ctx, "deposit.transfer.post",
              "deposit_transfer", $transferId, app.clock, businessDate = businessDate,
              after = %*{
                "transferId": $transferId,
                "sourceAccountId": $source.accountId,
                "destinationAccountId": $destination.accountId,
                "amount": amount.toDecimalString,
                "journalId": $journalId,
                "earlyWithdrawal": (if early.isSome:
              %*{"principal": early.get().principal.toDecimalString,
                 "interest": early.get().interest.toDecimalString,
                 "penalty": early.get().penalty.toDecimalString,
                 "creditedAmount": cashPaid(early.get()).toDecimalString,
                 "interestJournalId": (if string(interestJournalId).len == 0: ""
                else: $interestJournalId),
                 "penaltyJournalId": (if string(penaltyJournalId).len == 0: ""
                else: $penaltyJournalId)}
            else: newJNull()),
              }))

            # Event non-akuntansi: TANPA header `accounting` supaya konsumen `ledger` tidak
            # memposting jurnal kedua (jurnal sudah ditulis sinkron di atas).
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "TransferPosted",
              "deposit_transfer", $transferId, "TransferPosted:" & $transferId,
              %*{"transferId": $transferId, "sourceAccountId": $source.accountId,
                 "destinationAccountId": $destination.accountId,
                 "amount": amount.toDecimalString, "businessDate": businessDate,
                 "branchId": $source.branchId}))
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "journal.posted", "journal",
              $journalId, "journal.posted:" & $journalId,
              %*{"journalId": $journalId, "businessDate": businessDate,
                 "sourceEvent": transferSourceEvent, "reversalOf": nil,
                 "totalDebit": amount.toDecimalString}))

            status = 201
            payload = transferJson(transfer, balances.get(), early)
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problem = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problem = "idempotensi gagal diselesaikan"
  except DepositConfigError:
    if status == 0:
      status = 500
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    if status == 0:
      status = 500
    problem = "pemindahbukuan gagal disimpan"

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
