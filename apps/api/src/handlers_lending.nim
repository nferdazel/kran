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

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, money, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/[audit, event, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo, param_repo]
import deposit/domain/[account, transaction]
import deposit/infrastructure/[account_repo, transaction_repo]
import lending/domain/[collectibility, loan, payment, recovery, restructure, schedule, writeoff]
import lending/infrastructure/[loan_repo, recovery_repo, restructure_repo, writeoff_repo]
import product/infrastructure/product_repo
import party/domain/party
import party/infrastructure/party_repo

import ./access
import ./context
import ./db_bridge
import ./deposit_posting
import ./http_util
import ./idempotency
import ./problem

const
  permissionLendingRead* = "lending.loan.read"
  permissionLendingSubmit* = "lending.loan.submit"
  permissionLendingApprove* = "lending.loan.approve"
  permissionLendingDisburse* = "lending.loan.disburse"
  permissionLendingPay* = "lending.loan.pay"
  permissionLendingRestructure* = "lending.loan.restructure"
  ## Hapus buku **tidak** dipegang `lending_maker` (migrasi `platform/0096`): yang mencairkan
  ## pinjaman tidak boleh yang menghapusbukukannya.
  permissionLendingWriteOff* = "lending.loan.write_off"
  ## Pemulihan pasca hapus buku memakai izin sendiri (migrasi `platform/0099`): uang yang masuk
  ## setelah piutang dibebankan mengubah laba rugi, jadi tidak dipegang `lending_maker` juga.
  permissionLendingRecovery* = "lending.loan.recovery"
  ## Idempotensi lapis HTTP: operasi pencairan memindahkan uang, jadi replay kunci yang sama harus
  ## mengembalikan respons asli, bukan mencairkan dua kali.
  operationIdLoanDisburse = "lending.loan.disburse"
  operationIdLoanRestructure = "lending.loan.restructure"
  operationIdLoanWriteOff = "lending.loan.write_off"
  operationIdLoanRecovery = "lending.loan.recovery"

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

proc handleDisburseLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/lending/loans/{loanId}/disburse` — cairkan pinjaman `APPROVED` ke rekening
  ## simpanan anggota penerima.
  ##
  ## Satu transaksi DB: jadwal angsuran, jurnal `D 110 / K 201` (dari `ledger.posting_rule`),
  ## baris subledger `LOAN_DISBURSEMENT` + saldo rekening, status pinjaman `ACTIVE`, audit, dan
  ## event `LoanDisbursed`. Tidak ada langkah yang boleh terjadi sendiri-sendiri: saldo berubah
  ## tanpa jurnal atau jadwal tanpa akad sama-sama tidak bisa dipertanggungjawabkan.
  ##
  ## Uang tunai tidak keluar di sini (D-182): anggota menariknya lewat teller, sehingga invarian
  ## kas penutupan sesi tidak berubah.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingDisburse):
    return
  let loanId = parseId(pathParam(req, "loanId"))
  if loanId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return
  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let accountId = parseId(body.get().jsonField("accountId"))
  if accountId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "accountId harus UUID yang sah")
    return
  let asOf = businessDateIso(app.clock)

  var
    status = 0
    reason = ""
    problemText = ""
    payload = newJObject()
    outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdLoanDisburse, $body.get(), asOf,
            app.clock.now(), proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let found = loanById(db, loanId.val, forUpdate = true)
            if found.isNone:
              status = 404
              reason = "loan_not_found"
              problemText = "pinjaman tidak ditemukan"
              raise newException(ValueError, problemText)
            let loan = found.get()
            let branch = $loan.branchId
            if not authorizedAtBranch(db, principal, branch, permissionLendingDisburse):
              status = 403
              reason = "branch_not_allowed"
              problemText = "izin " & permissionLendingDisburse & " tidak dipegang di cabang ini"
              raise newException(ValueError, problemText)
            case loan.status
            of lsApplied:
              status = 409
              reason = "not_approved"
              problemText = "pinjaman belum disetujui"
              raise newException(ValueError, problemText)
            of lsApproved:
              discard
            else:
              status = 409
              reason = "already_disbursed"
              problemText = "pinjaman sudah dicairkan"
              raise newException(ValueError, problemText)

            let version = productVersionById(db, loan.productVersionId)
            if version.isNone:
              status = 409
              reason = "product_version_missing"
              problemText = "versi produk pinjaman tidak ditemukan"
              raise newException(ValueError, problemText)

            let account = accountById(db, accountId.val)
            if account.isNone:
              status = 404
              reason = "account_not_found"
              problemText = "rekening tujuan tidak ditemukan"
              raise newException(ValueError, problemText)
            if account.get().partyId != loan.partyId:
              # Pencairan ke rekening orang lain adalah cara paling mudah memindahkan uang
              # pinjaman; ditolak sebelum jurnal ditulis.
              status = 409
              reason = "account_party_mismatch"
              problemText = "rekening tujuan bukan milik anggota peminjam"
              raise newException(ValueError, problemText)
            if account.get().branchId != loan.branchId:
              status = 409
              reason = "account_branch_mismatch"
              problemText = "rekening tujuan bukan di cabang pinjaman"
              raise newException(ValueError, problemText)
            if account.get().status != asActive:
              status = 409
              reason = "account_not_active"
              problemText = "rekening tujuan tidak aktif"
              raise newException(ValueError, problemText)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let firstDue = addMonthsIso(businessDate, 1)
            if not firstDue.isOk:
              status = 500
              problemText = firstDue.error.details
              raise newException(ValueError, problemText)
            let rows = buildSchedule(loan.principal, version.get().annualRate,
              version.get().tenorMonths, version.get().scheduleMethod, firstDue.val)
            if not rows.isOk:
              status = 409
              reason = "schedule_invalid"
              problemText = rows.error.details
              raise newException(ValueError, problemText)
            let installments = rows.val
            let maturityOn = installments[^1].dueOn

            let actor = parseId(principal.user.userId).value()
            let branchId = loan.branchId
            let journalId = postRuleJournalSync(db, app.clock, "LoanDisbursed", loan.principal,
              branchId, loan.loanId, businessDate,
              "lending:disbursement:" & $loan.loanId, actor, %*{"loanId": $loan.loanId})
            for inst in installments:
              insertInstallment(db, Installment(
                loanId: loan.loanId, no: inst.no, dueOn: inst.dueOn,
                principalDue: inst.principalDue, interestDue: inst.interestDue,
                penaltyDue: inst.penaltyDue))
            # Versi 1 = jadwal pencairan. Tanpa baris ini, restrukturisasi pertama akan mencoba
            # memakai versi 1 lagi dan ditolak (`restructure_invalid`), dan riwayat versi dimulai
            # dari restrukturisasi — seolah pinjaman tidak pernah punya jadwal awal.
            insertScheduleVersion(db, loan.loanId, 1, businessDate, "jadwal pencairan", actor)
            insertBalance(db, loan.loanId, loan.principal)

            let credited = increaseBalance(db, account.get().accountId, loan.principal)
            if credited.isNone:
              status = 409
              reason = "account_without_balance"
              problemText = "rekening tujuan belum punya baris saldo"
              raise newException(ValueError, problemText)
            insertTransaction(db, Transaction(
              transactionId: newId(app.clock),
              txType: ttLoanDisbursement,
              accountId: account.get().accountId,
              amount: loan.principal,
              businessDate: businessDate,
              narration: "pencairan pinjaman",
              journalId: journalId), actor)

            if not markDisbursed(db, loan.loanId, businessDate, maturityOn):
              status = 409
              reason = "already_disbursed"
              problemText = "pinjaman sudah dicairkan permintaan lain"
              raise newException(ValueError, problemText)

            let ctx = auditContextFor(principal, req, app.clock, "", branch = branch)
            discard appendAudit(db, newAuditEntry(ctx, "lending.loan.disburse", "lending.loan",
              $loan.loanId, app.clock,
              businessDate = businessDate,
              before = %*{"status": "APPROVED"},
              after = %*{"status": "ACTIVE", "accountId": $account.get().accountId,
                         "journalId": $journalId, "maturityOn": maturityOn}))
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "LoanDisbursed",
              "lending.loan", $loan.loanId, "lending.loan.disbursed:" & $loan.loanId,
              %*{"loanId": $loan.loanId, "partyId": $loan.partyId, "branchId": $branch,
                 "principal": toDecimalString(loan.principal), "journalId": $journalId,
                 "accountId": $account.get().accountId, "maturityOn": maturityOn,
                 "installments": installments.len}))

            payload = %*{
              "loan": loanJson(Loan(
                loanId: loan.loanId, partyId: loan.partyId,
                productVersionId: loan.productVersionId, branchId: loan.branchId,
                principal: loan.principal, status: lsActive,
                disbursedOn: businessDate, maturityOn: maturityOn,
                appliedBy: loan.appliedBy, approvedBy: loan.approvedBy)),
              "journalId": $journalId,
              "accountId": $account.get().accountId,
              "maturityOn": maturityOn,
              "installmentCount": installments.len,
            }
            status = 200
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problemText = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problemText = "idempotensi gagal diselesaikan"
  except ValueError as e:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = e.msg
  except DbError:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = "pencairan pinjaman gagal (jurnal/periode ditolak database)"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 200:
    req.respondJson(200, payload)
  of 400:
    respondLendingReason(req, pkBadRequest, "Bad Request", reason, problemText)
  of 403:
    respondLendingReason(req, pkForbidden, "Forbidden", reason, problemText)
  of 404:
    respondLendingReason(req, pkNotFound, "Not Found", reason, problemText)
  of 409:
    respondLendingReason(req, pkConflict, "Conflict", reason, problemText)
  else:
    req.respondProblem(pkInternal, "Internal Server Error", problemText)

type
  LendingConfigError* = object of CatchableError
    ## Data produk (binding versi) atau cache saldo rusak: 500, bukan 400 — itu konfigurasi
    ## institusi, bukan kesalahan pemanggil.

const
  ## Binding saldo minimum versi produk akun, sama dengan jalur teller (`handlers_teller`). Nilainya
  ## dari produk, bukan kode: pembayaran angsuran tetap tidak boleh menembus saldo minimum yang
  ## disepakati saat rekening dibuka.
  minBalanceParamKey = "product.savings.min_balance"
  operationIdLoanPay = "lending.loan.pay"

proc minBalanceFor(db: DbConn, versionId: Id): Money =
  ## `0` bila produk tidak mengikat saldo minimum (D-095: pack default 0). Binding ada tetapi bukan
  ## nominal sah = data produk rusak.
  for binding in bindingsOf(db, versionId):
    if binding.paramKey != minBalanceParamKey:
      continue
    if binding.value.isNil or binding.value.kind != JString:
      raise newException(LendingConfigError,
        "binding " & minBalanceParamKey & " bukan string desimal")
    let parsed = moneyFromString(binding.value.getStr())
    if parsed.isErr:
      raise newException(LendingConfigError,
        "binding " & minBalanceParamKey & " bukan nominal sah")
    if parsed.value() < zero():
      raise newException(LendingConfigError,
        "binding " & minBalanceParamKey & " negatif (konfigurasi produk rusak)")
    return parsed.value()
  zero()

proc allocationOrder(db: DbConn; asOf: string): seq[AllocationComponent] =
  ## Urutan komponen pembayaran dari parameter `lending.allocation_order` (D-180 butir 4). Rusak =
  ## galat konfigurasi: alokasi tanpa urutan akan menebak komponen mana yang dibayar lebih dulu.
  let node =
    try:
      activeValueJson(db, keyString(P_lending_allocation_order), asOf,
        lookupFor(institutionScope()))
    except ValueError as e:
      raise newException(LendingConfigError, e.msg)
  if node.kind != JString:
    raise newException(LendingConfigError,
      "parameter " & keyString(P_lending_allocation_order) & " bukan daftar komponen")
  let parsed = parseAllocationOrder(node.getStr())
  if not parsed.isOk:
    raise newException(LendingConfigError, parsed.error.details)
  parsed.val

proc postComponentJournal(db: DbConn, clock: Clock, eventType: string, amount: Money,
    branchId: Id, paymentId: Id, businessDate, component: string, actor: Id): Id =
  ## Satu jurnal per komponen yang **tidak nol**. `posting_rule` memakai satu nominal per jurnal, jadi
  ## pokok, bunga, dan denda tidak bisa menumpang satu jurnal tanpa membuat laporan pendapatan salah.
  postRuleJournalSync(db, clock, eventType, amount, branchId, paymentId, businessDate,
    "lending:payment:" & $paymentId & ":" & component, actor,
    %*{"paymentId": $paymentId})

proc handlePayLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/lending/loans/{loanId}/payments` — terima angsuran dari rekening simpanan anggota.
  ##
  ## Satu transaksi DB: jadwal dibaca `FOR UPDATE`, alokasi menurut parameter, `paid_*` bertambah,
  ## saldo rekening berkurang (tidak menembus saldo minimum produk), satu jurnal per komponen yang
  ## tidak nol, satu baris subledger per komponen (masing-masing menunjuk jurnalnya sendiri — satu
  ## baris tidak bisa menunjuk tiga jurnal), cache saldo pinjaman turun, audit, dan event.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingPay):
    return
  let loanId = parseId(pathParam(req, "loanId"))
  if loanId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return
  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let accountId = parseId(body.get().jsonField("accountId"))
  if accountId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "accountId harus UUID yang sah")
    return
  let amount = moneyFromString(body.get().jsonField("amount"))
  if not amount.isOk or not amount.val.isPositive:
    req.respondProblem(pkBadRequest, "Bad Request",
      "amount harus nominal positif, mis. \"1500000.00\"")
    return
  let asOf = businessDateIso(app.clock)

  var
    status = 0
    reason = ""
    problemText = ""
    payload = newJObject()
    outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdLoanPay, $body.get(), asOf,
            app.clock.now(), proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let found = loanById(db, loanId.val, forUpdate = true)
            if found.isNone:
              status = 404
              reason = "loan_not_found"
              problemText = "pinjaman tidak ditemukan"
              raise newException(ValueError, problemText)
            let loan = found.get()
            let branch = $loan.branchId
            if not authorizedAtBranch(db, principal, branch, permissionLendingPay):
              status = 403
              reason = "branch_not_allowed"
              problemText = "izin " & permissionLendingPay & " tidak dipegang di cabang ini"
              raise newException(ValueError, problemText)
            case loan.status
            of lsActive:
              discard
            of lsApplied:
              status = 409
              reason = "not_approved"
              problemText = "pinjaman belum disetujui"
              raise newException(ValueError, problemText)
            of lsApproved:
              status = 409
              reason = "not_disbursed"
              problemText = "pinjaman belum dicairkan; tidak ada yang bisa diangsur"
              raise newException(ValueError, problemText)
            of lsClosed, lsWrittenOff:
              status = 409
              reason = "loan_inactive"
              problemText = "pinjaman sudah tidak berjalan"
              raise newException(ValueError, problemText)

            let account = accountById(db, accountId.val)
            if account.isNone:
              status = 404
              reason = "account_not_found"
              problemText = "rekening sumber tidak ditemukan"
              raise newException(ValueError, problemText)
            if account.get().partyId != loan.partyId:
              status = 409
              reason = "account_party_mismatch"
              problemText = "rekening sumber bukan milik anggota peminjam"
              raise newException(ValueError, problemText)
            if account.get().branchId != loan.branchId:
              status = 409
              reason = "account_branch_mismatch"
              problemText = "rekening sumber bukan di cabang pinjaman"
              raise newException(ValueError, problemText)
            if account.get().status != asActive:
              status = 409
              reason = "account_not_active"
              problemText = "rekening sumber tidak aktif"
              raise newException(ValueError, problemText)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let rows = installmentsForUpdate(db, loan.loanId)
            if rows.len == 0:
              status = 409
              reason = "schedule_missing"
              problemText = "pinjaman belum punya jadwal angsuran"
              raise newException(ValueError, problemText)

            let allocated = allocatePayment(rows, allocationOrder(db, asOf), amount.val)
            if not allocated.isOk:
              status = 409
              reason = "amount_exceeds_outstanding"
              problemText = allocated.error.details
              raise newException(ValueError, problemText)
            let plan = allocated.val

            let actor = parseId(principal.user.userId).value()
            let payment = Payment(
              paymentId: newId(app.clock),
              loanId: loan.loanId,
              accountId: account.get().accountId,
              amount: amount.val,
              principalPaid: plan.principal,
              interestPaid: plan.interest,
              penaltyPaid: plan.penalty,
              businessDate: businessDate,
            )

            # Saldo rekening lebih dulu: bila tidak cukup (atau menembus saldo minimum), tidak ada
            # jurnal yang sudah terlanjur ditulis.
            let minBalance = minBalanceFor(db, account.get().productVersionId)
            if decreaseBalance(db, account.get().accountId, amount.val, minBalance).isNone:
              status = 409
              reason = "insufficient_balance"
              problemText = "saldo rekening tidak cukup untuk pembayaran ini"
              raise newException(ValueError, problemText)

            var journalIds: seq[string] = @[]
            proc postFor(component: AllocationComponent, componentAmount: Money,
                eventType, label: string) =
              if not componentAmount.isPositive:
                return
              let journalId = postComponentJournal(db, app.clock, eventType, componentAmount,
                loan.branchId, payment.paymentId, businessDate, label, actor)
              journalIds.add($journalId)
              insertTransaction(db, Transaction(
                transactionId: newId(app.clock),
                txType: ttLoanPayment,
                accountId: account.get().accountId,
                amount: componentAmount,
                businessDate: businessDate,
                narration: "angsuran pinjaman (" & label & ")",
                journalId: journalId), actor)

            postFor(acPrincipal, plan.principal, "LoanPrincipalPaid", "principal")
            postFor(acInterest, plan.interest, "LoanInterestPaid", "interest")
            postFor(acPenalty, plan.penalty, "LoanPenaltyPaid", "penalty")

            for line in plan.lines:
              if not addInstallmentPayment(db, loan.loanId, line.installmentNo, line.component,
                  line.amount):
                status = 409
                reason = "allocation_conflict"
                problemText = "jadwal berubah saat pembayaran diproses; ulangi permintaan"
                raise newException(ValueError, problemText)
            markSettledRows(db, loan.loanId, businessDate)

            insertPayment(db, payment, actor)
            for line in plan.lines:
              insertPaymentAllocation(db, payment.paymentId, line)

            if not decreaseLoanBalance(db, loan.loanId, plan.principal, plan.interest,
                plan.penalty):
              status = 500
              problemText = "saldo pinjaman tidak sinkron dengan jadwal (cache hilang/negatif)"
              raise newException(ValueError, problemText)
            let outstanding = principalOutstanding(db, loan.loanId)

            let ctx = auditContextFor(principal, req, app.clock, "", branch = branch)
            discard appendAudit(db, newAuditEntry(ctx, "lending.loan.pay", "lending.loan",
              $loan.loanId, app.clock,
              businessDate = businessDate,
              after = %*{"paymentId": $payment.paymentId, "amount": toDecimalString(amount.val),
                         "accountId": $account.get().accountId,
                         "principalPaid": toDecimalString(plan.principal),
                         "interestPaid": toDecimalString(plan.interest),
                         "penaltyPaid": toDecimalString(plan.penalty),
                         "principalOutstanding": toDecimalString(outstanding)}))
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "LoanInstallmentPaid",
              "lending.loan", $loan.loanId, "lending.loan.payment:" & $payment.paymentId,
              %*{"loanId": $loan.loanId, "paymentId": $payment.paymentId,
                 "partyId": $loan.partyId, "branchId": $branch,
                 "amount": toDecimalString(amount.val),
                 "principalPaid": toDecimalString(plan.principal),
                 "interestPaid": toDecimalString(plan.interest),
                 "penaltyPaid": toDecimalString(plan.penalty),
                 "principalOutstanding": toDecimalString(outstanding),
                 "journals": journalIds}))

            payload = %*{
              "paymentId": $payment.paymentId,
              "loanId": $loan.loanId,
              "accountId": $account.get().accountId,
              "amount": toDecimalString(amount.val),
              "principalPaid": toDecimalString(plan.principal),
              "interestPaid": toDecimalString(plan.interest),
              "penaltyPaid": toDecimalString(plan.penalty),
              "businessDate": businessDate,
              "principalOutstanding": toDecimalString(outstanding),
              "journalIds": journalIds,
            }
            status = 200
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problemText = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problemText = "idempotensi gagal diselesaikan"
  except LendingConfigError as e:
    status = 500
    problemText = "konfigurasi pinjaman tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = e.msg
  except DbError:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = "pembayaran angsuran gagal (jurnal/periode ditolak database)"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 200:
    req.respondJson(200, payload)
  of 400:
    respondLendingReason(req, pkBadRequest, "Bad Request", reason, problemText)
  of 403:
    respondLendingReason(req, pkForbidden, "Forbidden", reason, problemText)
  of 404:
    respondLendingReason(req, pkNotFound, "Not Found", reason, problemText)
  of 409:
    respondLendingReason(req, pkConflict, "Conflict", reason, problemText)
  else:
    req.respondProblem(pkInternal, "Internal Server Error", problemText)

proc handleRestructureLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/lending/loans/{loanId}/restructure` — susun jadwal versi baru dari sisa pokok.
  ##
  ## Keputusan pemilik 1 Nov 2026 (D-186): jadwal **versi baru**, jadwal lama diarsipkan (tidak
  ## diubah — trigger `0089` melarangnya); tunggakan bunga/denda jadwal lama **dilepas**; DPD kembali
  ## lancar karena jadwal aktif dimulai di masa depan. Tarif dan metode jadwal diambil dari versi
  ## produk: mengubah tarif adalah keputusan produk baru, bukan efek samping restrukturisasi.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingRestructure):
    return
  let loanId = parseId(pathParam(req, "loanId"))
  if loanId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return
  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  var tenorMonths = 0
  if body.get().hasKey("tenorMonths") and body.get()["tenorMonths"].kind == JInt:
    tenorMonths = int(body.get()["tenorMonths"].getInt())
  if tenorMonths < 1:
    req.respondProblem(pkBadRequest, "Bad Request", "tenorMonths harus bilangan bulat >= 1")
    return
  let reasonText = body.get().jsonField("reason").strip()
  if reasonText.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "reason wajib diisi")
    return

  let asOf = businessDateIso(app.clock)
  var
    status = 0
    reason = ""
    problemText = ""
    payload = newJObject()
    outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdLoanRestructure, $body.get(), asOf,
            app.clock.now(), proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let found = loanById(db, loanId.val, forUpdate = true)
            if found.isNone:
              status = 404
              reason = "loan_not_found"
              problemText = "pinjaman tidak ditemukan"
              raise newException(ValueError, problemText)
            let loan = found.get()
            let branch = $loan.branchId
            if not authorizedAtBranch(db, principal, branch, permissionLendingRestructure):
              status = 403
              reason = "branch_not_allowed"
              problemText = "izin " & permissionLendingRestructure & " tidak dipegang di cabang ini"
              raise newException(ValueError, problemText)
            case loan.status
            of lsActive:
              discard
            of lsApplied, lsApproved:
              status = 409
              reason = "not_disbursed"
              problemText = "pinjaman belum dicairkan; tidak ada jadwal yang bisa direstrukturisasi"
              raise newException(ValueError, problemText)
            of lsClosed, lsWrittenOff:
              status = 409
              reason = "loan_inactive"
              problemText = "pinjaman sudah tidak berjalan"
              raise newException(ValueError, problemText)

            let version = productVersionById(db, loan.productVersionId)
            if version.isNone:
              status = 409
              reason = "product_version_missing"
              problemText = "versi produk pinjaman tidak ditemukan"
              raise newException(ValueError, problemText)

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let firstDue = addMonthsIso(businessDate, 1)
            if not firstDue.isOk:
              status = 500
              problemText = firstDue.error.details
              raise newException(ValueError, problemText)

            let outstanding = principalOutstanding(db, loan.loanId)
            let plan = restructurePlan(outstanding, version.get().annualRate, tenorMonths,
              version.get().scheduleMethod, firstDue.val, nextInstallmentNo(db, loan.loanId),
              nextScheduleVersion(db, loan.loanId))
            if not plan.isOk:
              status = 409
              reason = "restructure_invalid"
              problemText = plan.error.details
              raise newException(ValueError, problemText)
            var restructured = plan.val
            # `buildSchedule` tidak tahu loanId (domain murni); baris jadwal butuh kolom itu saat
            # disimpan. Disamakan di sini, bukan ditambahkan sebagai parameter domain yang hanya
            # dipakai satu tempat.
            for inst in restructured.rows.mitems:
              inst.loanId = loan.loanId

            let actor = parseId(principal.user.userId).value()
            insertScheduleVersion(db, loan.loanId, restructured.versionNo, businessDate,
              reasonText, actor)
            # Arsipkan jadwal lama **sebelum** menulis yang baru: kalau urutannya dibalik, UPDATE
            # arsip akan ikut menandai baris baru dan tidak ada jadwal aktif yang tersisa.
            let superseded = supersedeActiveSchedule(db, loan.loanId, businessDate)
            for inst in restructured.rows:
              insertInstallment(db, inst, scheduleVersion = restructured.versionNo)
            if not updateMaturity(db, loan.loanId, restructured.maturityOn):
              status = 409
              reason = "loan_inactive"
              problemText = "pinjaman berubah status saat direstrukturisasi; ulangi permintaan"
              raise newException(ValueError, problemText)

            let ctx = auditContextFor(principal, req, app.clock, "", branch = branch)
            discard appendAudit(db, newAuditEntry(ctx, "lending.loan.restructure", "lending.loan",
              $loan.loanId, app.clock,
              businessDate = businessDate,
              before = %*{"maturityOn": loan.maturityOn},
              after = %*{"scheduleVersion": restructured.versionNo,
                         "principalRestructured": toDecimalString(outstanding),
                         "tenorMonths": tenorMonths, "maturityOn": restructured.maturityOn,
                         "supersededInstallments": superseded, "reason": reasonText}))
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "LoanRestructured",
              "lending.loan", $loan.loanId,
              "lending.loan.restructured:" & $loan.loanId & ":" & $restructured.versionNo,
              %*{"loanId": $loan.loanId, "partyId": $loan.partyId, "branchId": $branch,
                 "businessDate": businessDate, "scheduleVersion": restructured.versionNo,
                 "principalRestructured": toDecimalString(outstanding),
                 "tenorMonths": tenorMonths, "firstDueOn": firstDue.val,
                 "maturityOn": restructured.maturityOn,
                 "installments": restructured.rows.len}))

            payload = %*{
              "loanId": $loan.loanId,
              "scheduleVersion": restructured.versionNo,
              "principalRestructured": toDecimalString(outstanding),
              "tenorMonths": tenorMonths,
              "firstDueOn": firstDue.val,
              "maturityOn": restructured.maturityOn,
              "firstInstallmentNo": restructured.rows[0].no,
              "installmentCount": restructured.rows.len,
              "supersededInstallments": superseded,
              "businessDate": businessDate,
            }
            status = 200
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problemText = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problemText = "idempotensi gagal diselesaikan"
  except LendingConfigError as e:
    status = 500
    problemText = "konfigurasi pinjaman tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = e.msg
  except DbError:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = "restrukturisasi gagal disimpan"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

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

proc handleWriteOffLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/lending/loans/{loanId}/write-off` — hapusbukukan piutang yang sudah macet.
  ##
  ## Syarat (keputusan pemilik 1 Nov 2026, D-186): golongan **LOSS** dan pinjaman `ACTIVE`. Nilai
  ## yang dihapus = **seluruh sisa kewajiban** jadwal aktif. Penyisihan yang sudah dibentuk dipakai
  ## lebih dulu (`D 111`), kekurangannya menjadi beban (`D 504`); keduanya mengkredit `110`.
  ##
  ## Dua jurnal, bukan satu: template Fase 1 memaksa tepat satu debit dan satu kredit per jurnal.
  ## Bagian yang nol tidak dijurnal sama sekali.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingWriteOff):
    return
  let loanId = parseId(pathParam(req, "loanId"))
  if loanId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return
  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let reasonText = body.get().jsonField("reason").strip()
  if reasonText.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "reason wajib diisi")
    return

  let asOf = businessDateIso(app.clock)
  var
    status = 0
    reason = ""
    problemText = ""
    payload = newJObject()
    outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdLoanWriteOff, $body.get(), asOf,
            app.clock.now(), proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let found = loanById(db, loanId.val, forUpdate = true)
            if found.isNone:
              status = 404
              reason = "loan_not_found"
              problemText = "pinjaman tidak ditemukan"
              raise newException(ValueError, problemText)
            let loan = found.get()
            let branch = $loan.branchId
            if not authorizedAtBranch(db, principal, branch, permissionLendingWriteOff):
              status = 403
              reason = "branch_not_allowed"
              problemText = "izin " & permissionLendingWriteOff & " tidak dipegang di cabang ini"
              raise newException(ValueError, problemText)
            case loan.status
            of lsActive:
              discard
            of lsWrittenOff:
              status = 409
              reason = "already_written_off"
              problemText = "pinjaman sudah dihapusbukukan"
              raise newException(ValueError, problemText)
            of lsApplied, lsApproved:
              status = 409
              reason = "not_disbursed"
              problemText = "pinjaman belum dicairkan; tidak ada piutang untuk dihapusbukukan"
              raise newException(ValueError, problemText)
            of lsClosed:
              status = 409
              reason = "loan_inactive"
              problemText = "pinjaman sudah ditutup"
              raise newException(ValueError, problemText)

            let grade = collectibilityOf(db, loan.loanId)
            if grade != $colLoss:
              status = 409
              reason = "not_loss"
              problemText = "hapus buku hanya untuk golongan LOSS; golongan sekarang: " &
                (if grade.len == 0: "belum dinilai" else: grade)
              raise newException(ValueError, problemText)

            let outstanding = activeOutstanding(db, loan.loanId)
            let split = writeoffSplit(outstanding.principal, outstanding.interest,
              outstanding.penalty, latestAllowance(db, loan.loanId))
            if not split.isOk:
              status = 409
              reason = "nothing_to_write_off"
              problemText = split.error.details
              raise newException(ValueError, problemText)
            let plan = split.val

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let actor = parseId(principal.user.userId).value()
            var journalIds: seq[string] = @[]
            proc postPart(eventType, suffix: string, amount: Money) =
              if not amount.isPositive:
                return
              let journalId = postRuleJournalSync(db, app.clock, eventType, amount,
                loan.branchId, loan.loanId, businessDate,
                "lending:writeoff:" & $loan.loanId & ":" & suffix, actor,
                %*{"loanId": $loan.loanId})
              journalIds.add($journalId)
            postPart("LoanWriteOffProvisioned", "provisioned", plan.allowanceApplied)
            postPart("LoanWriteOffExpense", "expense", plan.expense)

            if not markWrittenOff(db, loan.loanId, businessDate, reasonText, actor):
              status = 409
              reason = "loan_inactive"
              problemText = "pinjaman berubah status saat dihapusbukukan; ulangi permintaan"
              raise newException(ValueError, problemText)
            insertWriteoff(db, loan.loanId, businessDate, plan, actor)
            zeroLoanBalance(db, loan.loanId)

            let ctx = auditContextFor(principal, req, app.clock, "", branch = branch)
            discard appendAudit(db, newAuditEntry(ctx, "lending.loan.write_off", "lending.loan",
              $loan.loanId, app.clock,
              businessDate = businessDate,
              before = %*{"status": "ACTIVE", "collectibility": grade},
              after = %*{"status": "WRITTEN_OFF",
                         "principal": toDecimalString(plan.principal),
                         "interest": toDecimalString(plan.interest),
                         "penalty": toDecimalString(plan.penalty),
                         "allowanceApplied": toDecimalString(plan.allowanceApplied),
                         "expense": toDecimalString(plan.expense),
                         "journalIds": journalIds, "reason": reasonText}))
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "LoanWrittenOff",
              "lending.loan", $loan.loanId, "lending.loan.written_off:" & $loan.loanId,
              %*{"loanId": $loan.loanId, "partyId": $loan.partyId, "branchId": $branch,
                 "businessDate": businessDate, "principal": toDecimalString(plan.principal),
                 "interest": toDecimalString(plan.interest),
                 "penalty": toDecimalString(plan.penalty),
                 "allowanceApplied": toDecimalString(plan.allowanceApplied),
                 "expense": toDecimalString(plan.expense), "journalIds": journalIds}))

            payload = %*{
              "loanId": $loan.loanId,
              "status": "WRITTEN_OFF",
              "principal": toDecimalString(plan.principal),
              "interest": toDecimalString(plan.interest),
              "penalty": toDecimalString(plan.penalty),
              "total": toDecimalString(plan.total),
              "allowanceApplied": toDecimalString(plan.allowanceApplied),
              "expense": toDecimalString(plan.expense),
              "journalIds": journalIds,
              "businessDate": businessDate,
              "reason": reasonText,
            }
            status = 200
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problemText = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problemText = "idempotensi gagal diselesaikan"
  except LendingConfigError as e:
    status = 500
    problemText = "konfigurasi pinjaman tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = e.msg
  except DbError:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = "hapus buku gagal (jurnal/periode ditolak database)"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

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

proc handleRecoverLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/lending/loans/{loanId}/recovery` — catat uang yang masuk setelah hapus buku.
  ##
  ## Pinjaman `WRITTEN_OFF` tidak punya piutang di neraca, jadi pemulihan **bukan** pelunasan:
  ## saldo rekening anggota berkurang (`D 201`) dan lawannya pendapatan — pokok `409`, bunga `401`,
  ## denda `403` (D-191, `NEEDS-COMPLIANCE-REVIEW`). Batas kumulatif per komponen dijaga domain
  ## (`planRecovery`): total pemulihan tidak boleh melebihi nilai yang dihapusbukukan.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingRecovery):
    return
  let loanId = parseId(pathParam(req, "loanId"))
  if loanId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return
  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let bodyNode = body.get()
  let accountId = parseId(bodyNode.jsonField("accountId"))
  if accountId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "accountId harus UUID yang sah")
    return
  var
    principalReq = zero()
    interestReq = zero()
    penaltyReq = zero()
  block parseComponents:
    let fields = [("principal", "principal"), ("interest", "interest"), ("penalty", "penalty")]
    for (name, target) in fields:
      let raw = bodyNode.jsonField(name)
      if raw.len == 0:
        continue
      let parsed = moneyFromString(raw)
      if not parsed.isOk or parsed.val.isNegative:
        req.respondProblem(pkBadRequest, "Bad Request",
          name & " harus nominal tidak negatif, mis. \"1500000.00\"")
        return
      case target
      of "principal": principalReq = parsed.val
      of "interest": interestReq = parsed.val
      else: penaltyReq = parsed.val
  let request = components(principalReq, interestReq, penaltyReq)
  if not request.totalOf().isPositive:
    req.respondProblem(pkBadRequest, "Bad Request",
      "isi minimal satu komponen pemulihan (principal/interest/penalty) dengan nominal positif")
    return
  let reasonText = bodyNode.jsonField("reason").strip()
  if reasonText.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "reason wajib diisi")
    return
  let asOf = businessDateIso(app.clock)

  var
    status = 0
    reason = ""
    problemText = ""
    payload = newJObject()
    outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal, req, operationIdLoanRecovery, $bodyNode, asOf,
            app.clock.now(), proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            let found = loanById(db, loanId.val, forUpdate = true)
            if found.isNone:
              status = 404
              reason = "loan_not_found"
              problemText = "pinjaman tidak ditemukan"
              raise newException(ValueError, problemText)
            let loan = found.get()
            let branch = $loan.branchId
            if not authorizedAtBranch(db, principal, branch, permissionLendingRecovery):
              status = 403
              reason = "branch_not_allowed"
              problemText = "izin " & permissionLendingRecovery & " tidak dipegang di cabang ini"
              raise newException(ValueError, problemText)
            if loan.status != lsWrittenOff:
              status = 409
              reason = "not_written_off"
              problemText = "pemulihan hanya untuk pinjaman yang sudah dihapusbukukan"
              raise newException(ValueError, problemText)

            let account = accountById(db, accountId.val)
            if account.isNone:
              status = 404
              reason = "account_not_found"
              problemText = "rekening sumber tidak ditemukan"
              raise newException(ValueError, problemText)
            if account.get().partyId != loan.partyId:
              status = 409
              reason = "account_party_mismatch"
              problemText = "rekening sumber bukan milik anggota peminjam"
              raise newException(ValueError, problemText)
            if account.get().branchId != loan.branchId:
              status = 409
              reason = "account_branch_mismatch"
              problemText = "rekening sumber bukan di cabang pinjaman"
              raise newException(ValueError, problemText)
            if account.get().status != asActive:
              status = 409
              reason = "account_not_active"
              problemText = "rekening sumber tidak aktif"
              raise newException(ValueError, problemText)

            let planned = planRecovery(request, writtenOffComponents(db, loan.loanId),
              recoveredComponents(db, loan.loanId))
            if not planned.isOk:
              status = 409
              reason = "recovery_exceeds_written_off"
              problemText = planned.error.details
              raise newException(ValueError, problemText)
            let plan = planned.val

            let businessDate = businessDateFor(db, institutionScope(), asOf)
            let actor = parseId(principal.user.userId).value()
            let recoveryId = newId(app.clock)

            let minBalance = minBalanceFor(db, account.get().productVersionId)
            if decreaseBalance(db, account.get().accountId, plan.total, minBalance).isNone:
              status = 409
              reason = "insufficient_balance"
              problemText = "saldo rekening tidak cukup untuk pemulihan ini"
              raise newException(ValueError, problemText)

            var journalIds: seq[string] = @[]
            proc postPart(eventType, suffix, label: string, amount: Money) =
              if not amount.isPositive:
                return
              let journalId = postRuleJournalSync(db, app.clock, eventType, amount,
                loan.branchId, recoveryId, businessDate,
                "lending:recovery:" & $loan.loanId & ":" & suffix, actor,
                %*{"loanId": $loan.loanId})
              journalIds.add($journalId)
              insertTransaction(db, Transaction(
                transactionId: newId(app.clock),
                txType: ttLoanRecovery,
                accountId: account.get().accountId,
                amount: amount,
                businessDate: businessDate,
                narration: "pemulihan hapus buku (" & label & ")",
                journalId: journalId), actor)
            postPart("LoanRecoveryPrincipal", "principal", "pokok", plan.request.principal)
            postPart("LoanRecoveryInterest", "interest", "bunga", plan.request.interest)
            postPart("LoanRecoveryPenalty", "penalty", "denda", plan.request.penalty)

            insertRecovery(db, recoveryId, loan.loanId, businessDate, account.get().accountId,
              plan, reasonText, actor)

            let ctx = auditContextFor(principal, req, app.clock, "", branch = branch)
            discard appendAudit(db, newAuditEntry(ctx, "lending.loan.recovery", "lending.loan",
              $loan.loanId, app.clock,
              businessDate = businessDate,
              before = %*{"status": "WRITTEN_OFF"},
              after = %*{"recoveryId": $recoveryId,
                         "principal": toDecimalString(plan.request.principal),
                         "interest": toDecimalString(plan.request.interest),
                         "penalty": toDecimalString(plan.request.penalty),
                         "total": toDecimalString(plan.total),
                         "journalIds": journalIds, "reason": reasonText}))
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "LoanRecovered",
              "lending.loan", $loan.loanId, "lending.loan.recovered:" & $recoveryId,
              %*{"loanId": $loan.loanId, "partyId": $loan.partyId, "branchId": $branch,
                 "businessDate": businessDate, "recoveryId": $recoveryId,
                 "principal": toDecimalString(plan.request.principal),
                 "interest": toDecimalString(plan.request.interest),
                 "penalty": toDecimalString(plan.request.penalty),
                 "total": toDecimalString(plan.total), "journalIds": journalIds}))

            payload = %*{
              "loanId": $loan.loanId,
              "status": "WRITTEN_OFF",
              "recoveryId": $recoveryId,
              "principal": toDecimalString(plan.request.principal),
              "interest": toDecimalString(plan.request.interest),
              "penalty": toDecimalString(plan.request.penalty),
              "total": toDecimalString(plan.total),
              "journalIds": journalIds,
              "businessDate": businessDate,
              "reason": reasonText,
            }
            status = 200
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problemText = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problemText = "idempotensi gagal diselesaikan"
  except LendingConfigError as e:
    status = 500
    problemText = "konfigurasi pinjaman tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = e.msg
  except DbError:
    if status == 0:
      status = 500
    if problemText.len == 0:
      problemText = "pemulihan gagal (jurnal/periode ditolak database)"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

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

const maxLoanListLimit* = 200 # nomagic:ok batas ukuran respons daftar

proc maybeStr(s: string): JsonNode {.inline.} =
  ## `null` untuk "belum ada" (tanggal cair, golongan). String kosong di JSON akan terbaca sebagai
  ## nilai sah oleh klien.
  if s.len == 0: newJNull() else: %s

proc handleListLoans*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/lending/loans?partyId=&status=&limit=` — daftar pinjaman, disaring **per baris**
  ## menurut cabang yang izin bacanya dipegang (pola D-062/`handleListDepositAccounts`), bukan 403
  ## seluruh daftar: operator cabang lain tidak perlu tahu akad itu ada.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingRead):
    return

  let partyRaw = queryValue(req, "partyId").strip
  var partyId = none(Id)
  if partyRaw.len > 0:
    let parsed = parseId(partyRaw)
    if parsed.isErr:
      req.respondProblem(pkBadRequest, "Bad Request", "partyId harus UUID yang sah")
      return
    partyId = some(parsed.value())

  let statusRaw = queryValue(req, "status").strip
  if statusRaw.len > 0 and statusRaw notin
      ["APPLIED", "APPROVED", "ACTIVE", "CLOSED", "WRITTEN_OFF"]:
    # Nilai tak dikenal ditolak, bukan diabaikan: daftar yang "kosong karena status salah ketik"
    # terlihat seperti "tidak ada pinjaman".
    req.respondProblem(pkBadRequest, "Bad Request", "status tidak dikenal: " & statusRaw)
    return

  var limit = 50
  let limitRaw = queryValue(req, "limit").strip
  if limitRaw.len > 0:
    var parsed = 0
    try:
      parsed = parseInt(limitRaw)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus bilangan bulat")
      return
    if parsed < 1:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus >= 1")
      return
    limit = min(parsed, maxLoanListLimit)

  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let authz = loadBranchAuthz(db, principal)
        for loan in loansPage(db, partyId, statusRaw, limit):
          if items.len >= limit:
            break
          if authz.allowedAt($loan.branchId, permissionLendingRead):
            items.add loanJson(loan))
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "pinjaman gagal dibaca")
    return
  req.respondJson(200, %*{"items": items})

proc handleGetLoan*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/lending/loans/{loanId}` — akad + saldo + **jadwal aktif** + riwayat versi jadwal.
  ##
  ## Pinjaman di cabang yang izin bacanya tidak dipegang dijawab **404**, sama seperti id yang tidak
  ## ada: 403 akan memberitahu bahwa akad itu ada di cabang lain.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionLendingRead):
    return
  let loanId = parseId(pathParam(req, "loanId"))
  if loanId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return

  var payload = newJNull()
  var found = false
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let loanOpt = loanById(db, loanId.val)
        if loanOpt.isNone or
            not authorizedAtBranch(db, principal, $loanOpt.get().branchId, permissionLendingRead):
          return
        let loan = loanOpt.get()
        let balance = loanBalanceOf(db, loan.loanId)
        var installments = newJArray()
        for inst in activeInstallments(db, loan.loanId):
          installments.add %*{
            "no": inst.no,
            "dueOn": inst.dueOn,
            "principalDue": toDecimalString(inst.principalDue),
            "interestDue": toDecimalString(inst.interestDue),
            "penaltyDue": toDecimalString(inst.penaltyDue),
            "paidPrincipal": toDecimalString(inst.paidPrincipal),
            "paidInterest": toDecimalString(inst.paidInterest),
            "paidPenalty": toDecimalString(inst.paidPenalty),
            "paidOn": maybeStr(inst.paidOn),
          }
        var versions = newJArray()
        for version in scheduleVersionsOf(db, loan.loanId):
          versions.add %*{"versionNo": version.versionNo, "createdOn": version.createdOn,
                          "reason": version.reason}

        var detail = loanJson(loan)
        detail["maturityOn"] = maybeStr(loan.maturityOn)
        detail["collectibility"] = maybeStr(collectibilityOf(db, loan.loanId))
        detail["principalOutstanding"] = (if balance.isNone: newJNull()
          else: %balance.get().principalOutstanding)
        detail["interestOverdue"] = (if balance.isNone: newJNull()
          else: %balance.get().interestOverdue)
        detail["penaltyOutstanding"] = (if balance.isNone: newJNull()
          else: %balance.get().penaltyOutstanding)
        detail["installments"] = installments
        detail["scheduleVersions"] = versions
        payload = detail
        found = true)
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "pinjaman gagal dibaca")
    return

  if not found:
    req.respondProblem(pkNotFound, "Not Found", "pinjaman tidak ditemukan")
    return
  req.respondJson(200, payload)
