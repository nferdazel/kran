## Handler REST modul `deposit` (T-088a, spec §9.2/§13).
##
## Composition root: validasi lintas-modul (party/product) dan audit ditulis di sini dalam transaksi
## yang sama. Modul `deposit` tetap murni (domain + repo SQL).
##
## Rekening adalah objek **ber-cabang**: izin dipegang di cabang rekening (`authorizedAtBranch`),
## bukan tingkat institusi. Nomor rekening = kode cabang 3 digit + nomor urut 7 digit (D-135);
## cabang **wajib terdaftar** di master cabang (`platform.branch`) supaya prefiksnya nyata.

import std/[algorithm, json, options, strutils]

import mummy
import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[clock, ids, money, result]
import platform/domain/[audit, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_service, branch_repo]
import deposit/domain/account
import deposit/domain/transaction
import deposit/domain/transfer
import deposit/infrastructure/account_repo
import deposit/infrastructure/transaction_repo
import deposit/infrastructure/transfer_repo
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
  ## Batas jumlah baris daftar rekening (nilai **teknis**, ukuran respons — pola daftar audit/param,
  ## T-100). Bukan ambang bisnis.
  maxAccountListLimit* = 200 # nomagic:ok batas ukuran respons daftar
  ## Batas jumlah baris statement per respons (nilai **teknis**, ukuran respons). Rentang tanggal
  ## yang melewatinya ditolak dengan 400, bukan dipotong diam-diam (statement yang terpotong =
  ## dokumen menyesatkan). T-094b.
  maxStatementRows* = 500 # nomagic:ok batas ukuran respons statement

type
  ## Data server rusak pada jalur rekening (nomor urut sequence melewati lebar, baris DB tidak bisa
  ## di-parse, rekening baru tidak terbaca kembali). Ini bukan kesalahan pemanggil: jawabannya 500,
  ## bukan 400 (T-099, pola `PartyConfigError`).
  DepositAccountConfigError* = object of ValueError

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
    "savingsKind": if a.savingsKind.len == 0: newJNull() else: %a.savingsKind,
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
  # Kunci yang **ada tetapi tidak sah** (kosong setelah trim, terlalu panjang, berisi karakter
  # kontrol) adalah permintaan salah, bukan kerusakan server. Tanpa pemeriksaan ini, `ValueError`
  # dari validator muncul di dalam transaksi dan handler menerjemahkannya jadi 500 (T-133/API-5).
  try:
    discard validateIdempotencyKey(req.headers[idempotencyHeader])
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
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

            # Nomor rekening memakai kode cabang (D-135), jadi cabang harus terdaftar dulu.
            let branchOpt = branchById(db, branchId.value())
            if branchOpt.isNone:
              status = 409
              reason = "branch_not_registered"
              problem = "cabang belum terdaftar di master cabang (kode 3 digit belum ada)"
              raise newException(ValueError, problem)
            let branchCode = branchOpt.get().code

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

            let account =
              try:
                newAccount(newId(app.clock), partyId.value(), prod.productId,
                  versionOpt.get().versionId, prod.code, branchId.value(), branchCode,
                  businessDate, nextAccountSeq(db))
              except ValueError:
                # Nomor urut tidak muat lebar / data tidak sah = kondisi operator, bukan 400.
                raise newException(DepositAccountConfigError,
                  "rekening tidak bisa dibentuk (nomor urut atau produk tidak sah)")
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

            let storedOpt =
              try:
                accountById(db, account.accountId)
              except ValueError:
                raise newException(DepositAccountConfigError,
                  "rekening baru tidak bisa dibaca kembali setelah disimpan")
            if storedOpt.isNone:
              raise newException(DepositAccountConfigError,
                "rekening baru tidak terbaca kembali setelah disimpan")
            payload = accountJson(storedOpt.get())
            status = 201
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problem = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problem = "idempotensi gagal diselesaikan"
  except DepositAccountConfigError:
    status = 500
    problem = "data rekening simpanan tidak bisa diproses"
  except ValueError as e:
    if status == 0:
      # Tidak ada validasi pemanggil di dalam transaksi (400 sudah dicek sebelum tx): `ValueError`
      # tanpa status = data server rusak, bukan permintaan salah (T-099).
      status = 500
      problem = "data rekening simpanan tidak bisa diproses"
    else:
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
  except ValueError:
    # Baris DB tidak bisa di-parse (mis. balance/status rusak) = kondisi server, bukan 404/400.
    status = 500
    problem = "data rekening tersimpan tidak bisa dibaca"

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

  ## Tepat satu: `partyId` atau `accountNo`. Tidak menebak prioritas bila keduanya diisi.
  let partyRaw = queryValue(req, "partyId").strip
  let accountNoRaw = queryValue(req, "accountNo").strip
  if (partyRaw.len == 0) == (accountNoRaw.len == 0):
    req.respondProblem(pkBadRequest, "Bad Request", "isi tepat satu: partyId atau accountNo")
    return

  var partyId = none(Id)
  if partyRaw.len > 0:
    let parsed = parseId(partyRaw)
    if parsed.isErr:
      req.respondProblem(pkBadRequest, "Bad Request", "partyId harus UUID yang sah")
      return
    partyId = some(parsed.value())
  elif accountNoRaw.len > maxAccountNoLength:
    # Batas teknis kolom (32), bukan format bisnis: bentuk nomor belum diputuskan (D-123).
    req.respondProblem(pkBadRequest, "Bad Request", "accountNo terlalu panjang")
    return

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        # Gerbang cabang per baris: rekening di cabang yang tidak dipegang izinnya tidak
        # dikembalikan (bukan 403 seluruh daftar — hasilnya disaring per baris, pola D-062).
        if partyId.isSome:
          # Satu kali muat grant untuk seluruh halaman (T-130/ARC-2): sebelumnya 2 query otorisasi
          # per baris, sampai 400 query tambahan untuk 200 rekening.
          let authz = loadBranchAuthz(db, principal)
          for account in accountsByParty(db, partyId.get(), maxAccountListLimit):
            # Batas respons (T-100): daftar party besar tidak mengembalikan ribuan baris sekaligus.
            if items.len >= maxAccountListLimit:
              break
            if authz.allowedAt($account.branchId, permissionDepositAccountRead):
              items.add accountJson(account)
        else:
          # Tidak ditemukan dan "tidak berizin" sengaja sama (items kosong), supaya nomor rekening
          # tidak bisa dipakai menebak keberadaan rekening di cabang lain.
          let accountOpt = accountByNo(db, accountNoRaw)
          if accountOpt.isSome and
              authorizedAtBranch(db, principal, $accountOpt.get().branchId,
                permissionDepositAccountRead):
            items.add accountJson(accountOpt.get())
        status = 200)
  except DbError:
    status = 500
  except ValueError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  else: req.respondProblem(pkInternal, "Internal Server Error", "rekening gagal dibaca")

type
  StatementItem = object
    ## Baris statement + kunci urut internal (tanggal, waktu, jenis) supaya urutan deterministik
    ## saat menggabungkan dua sumber (transaksi tunai & PB).
    sortKey: string
    row: JsonNode

proc statementRowJson(kind, direction, amount, businessDate, journalId, narration: string,
    transactionId, transferId: string): JsonNode =
  ## Satu baris statement. `transactionId`/`transferId` selalu ada sebagai kunci; yang tidak
  ## berlaku bernilai `null` (kontrak menuntut keduanya, salah satu terisi).
  %*{
    "kind": kind,
    "direction": direction,
    "amount": amount,
    "businessDate": businessDate,
    "journalId": journalId,
    "narration": narration,
    "transactionId": if transactionId.len == 0: newJNull() else: %transactionId,
    "transferId": if transferId.len == 0: newJNull() else: %transferId,
  }

proc handleGetAccountStatement*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/deposit/accounts/{accountId}/statement?from&to` — subledger satu rekening
  ## (T-094b): baris transaksi tunai (masuk/keluar) dan PB (sumber/tujuan), urut tanggal.
  ## **Tanpa** saldo berjalan per baris dan **bukan** rekonsiliasi GL (jurnal tidak dirinci di
  ## sini). Izin `deposit.account.read` harus dipegang di cabang rekening.
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

  let fromDate = queryValue(req, "from").strip
  let toDate = queryValue(req, "to").strip
  if not isIsoDate(fromDate) or not isIsoDate(toDate):
    req.respondProblem(pkBadRequest, "Bad Request",
      "from dan to wajib tanggal YYYY-MM-DD yang sah")
    return
  if fromDate > toDate:
    req.respondProblem(pkBadRequest, "Bad Request", "from harus lebih awal atau sama dengan to")
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
          problem = "izin " & permissionDepositAccountRead &
            " tidak dipegang di cabang rekening ini"
          return

        # Ambil satu baris lebih dari batas supaya rentang yang terlalu lebar terdeteksi pasti
        # (bukan dipotong diam-diam).
        let probeLimit = maxStatementRows + 1
        var items: seq[StatementItem]
        for tx in transactionsForStatement(db, account.accountId, fromDate, toDate, probeLimit):
          # Arah saldo, bukan arah kas: baris jatuh tempo (MATURITY_*) bukan transaksi tunai
          # tetapi tetap menambah/mengurangi saldo rekening di rekening koran (T-138d).
          let direction = statementDirectionOf(tx.txType)
          # `kind` juga mengikuti sumbernya: baris jatuh tempo bukan "CASH" walau memakai
          # `transactionId` yang sama (alasan `0068` memperkenalkan jenis transaksi baru).
          let kind = if isCashTransaction(tx.txType): "CASH" else: "MATURITY"
          items.add StatementItem(
            sortKey: tx.businessDate & "/" & tx.createdAt & "/0",
            row: statementRowJson(kind, direction, tx.amount.toDecimalString,
              tx.businessDate, $tx.journalId, tx.narration, $tx.transactionId, ""))
        for tr in transfersForStatement(db, account.accountId, fromDate, toDate, probeLimit):
          let direction = if $tr.sourceAccountId == $account.accountId: "OUT" else: "IN"
          items.add StatementItem(
            sortKey: tr.businessDate & "/" & tr.createdAt & "/1",
            row: statementRowJson("TRANSFER", direction, tr.amount.toDecimalString,
              tr.businessDate, $tr.journalId, tr.narration, "", $tr.transferId))

        if items.len > maxStatementRows:
          status = 400
          problem = "rentang tanggal melebihi " & $maxStatementRows &
            " baris; persempit rentang"
          return

        items.sort(proc(a, b: StatementItem): int = cmp(a.sortKey, b.sortKey))
        var rows = newJArray()
        for item in items:
          rows.add item.row

        payload = %*{
          "accountNo": account.accountNo,
          "status": $account.status,
          "branchId": $account.branchId,
          "from": fromDate,
          "to": toDate,
          "rows": rows,
        }
        status = 200)
  except DbError:
    status = 500
    problem = "statement rekening gagal dibaca"
  except ValueError:
    status = 500
    problem = "data rekening atau transaksi tersimpan tidak bisa dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
