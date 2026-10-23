## Tabel rute aplikasi — **satu tempat** untuk semua endpoint HTTP.
##
## Gate `apps/api/tests/tcontract.nim` membandingkan tabel ini dengan
## `packages/contracts/openapi/kran-api.yaml` (spec §13: kontrak = sumber kebenaran), jadi
## menambah rute tanpa memperbarui kontrak (atau sebaliknya) membuat CI merah.
##
## Rute tumbuh bertahap: T-008 hanya endpoint sistem; T-009 menambah realtime; T-012 auth,
## parameter, dan audit.

import mummy

import ./events
import ./handlers_audit
import ./handlers_auth
import ./handlers_deposit
import ./handlers_journals
import ./handlers_kyc
import ./handlers_ledger
import ./handlers_mfa
import ./handlers_products
import ./handlers_reports
import ./handlers_param
import ./handlers_party
import ./handlers_teller
import ./handlers_teller_sessions
import ./handlers_teller_vault
import ./handlers_users
import ./health
import ./problem

type
  HttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmPatch = "PATCH"
    hmDelete = "DELETE"

  RouteHandler* = proc(app: AppContext, req: Request) {.gcsafe.}

  RouteSpec* = object
    httpMethod*: HttpMethod
    path*: string ## pola kontrak, mis. `/api/v1/params/{key}`
    operationId*: string
    handler*: RouteHandler

proc key*(spec: RouteSpec): string =
  ## Kunci pembanding untuk contract test: `GET /healthz`.
  $spec.httpMethod & " " & spec.path

proc handleEventsStream*(app: AppContext, req: Request) {.gcsafe.} =
  ## Perekat rute → layanan. Handshake WebSocket ada di `events.openStream`; di sini hanya
  ## penerjemahan `AppContext` dan penanganan kasus "realtime belum dikonfigurasi".
  if app.events.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan realtime tidak dikonfigurasi (KRAN_DATABASE_URL kosong saat start)")
    return
  app.events.openStream(req)

proc eventRoutes*(): seq[RouteSpec] =
  ## Satu rute; Mummy mengarahkan permintaan ber-`Upgrade` ke `websocketHandler` (dipasang di
  ## `server.newApiServer`), sedangkan GET tanpa Upgrade tetap sampai ke handler ini dan dibalas 426.
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/events/stream", operationId: "streamEvents",
              handler: handleEventsStream),
  ]

proc systemRoutes*(): seq[RouteSpec] =
  @[
    RouteSpec(httpMethod: hmGet, path: "/healthz", operationId: "getHealth",
              handler: handleHealth),
    RouteSpec(httpMethod: hmGet, path: "/readyz", operationId: "getReadiness",
              handler: handleReadiness),
  ]

proc authRoutes*(): seq[RouteSpec] =
  ## Sesi: masuk, identitas, keluar (spec §13).
  @[
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/login", operationId: "login",
              handler: handleLogin),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/auth/session", operationId: "getSession",
              handler: handleSession),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/logout", operationId: "logout",
              handler: handleLogout),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/password", operationId: "changePassword",
              handler: handleChangePassword),
  ]

proc mfaRoutes*(): seq[RouteSpec] =
  ## MFA TOTP self-service (T-046, spec §13). Semua butuh sesi; saklar fitur
  ## `platform.security.mfa.enabled` (default mati) diputuskan di handler, bukan di tabel rute.
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/auth/mfa", operationId: "getMfaStatus",
              handler: handleMfaStatus),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/mfa/enrolment",
              operationId: "startMfaEnrolment", handler: handleMfaEnrolment),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/mfa/verify",
              operationId: "verifyMfaEnrolment", handler: handleMfaVerify),
  ]

proc paramRoutes*(): seq[RouteSpec] =
  ## Parameter: daftar, pengajuan (maker), persetujuan (checker) — spec §10.2/§10.7.
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/params", operationId: "listParams",
              handler: handleListParams),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/params/{key}/changes",
              operationId: "submitParamChange", handler: handleSubmitParamChange),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/params/changes/{paramValueId}/approve",
              operationId: "approveParamChange", handler: handleApproveParamChange),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/params/changes/{paramValueId}/reject",
              operationId: "rejectParamChange", handler: handleRejectParamChange),
  ]

proc auditRoutes*(): seq[RouteSpec] =
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/audit", operationId: "listAudit",
              handler: handleListAudit),
  ]

proc partyRoutes*(): seq[RouteSpec] =
  ## party: CIF + identitas dasar (T-070). Pencarian ringkas untuk pemilih pemilik rekening (T-115).
  @[
    RouteSpec(httpMethod: hmPost, path: "/api/v1/parties", operationId: "createParty",
              handler: handleCreateParty),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/parties", operationId: "searchParties",
              handler: handleSearchParties),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/parties/{partyId}",
              operationId: "getParty", handler: handleGetParty),
  ]

proc kycRoutes*(): seq[RouteSpec] =
  ## KYC & dokumen identitas (T-071). Nomor dokumen hanya keluar lewat *unmask* (izin + audit).
  @[
    RouteSpec(httpMethod: hmPost, path: "/api/v1/parties/{partyId}/identity-docs",
              operationId: "addIdentityDoc", handler: handleAddIdentityDoc),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/parties/{partyId}/kyc",
              operationId: "getPartyKyc", handler: handleGetKyc),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/parties/{partyId}/risk-rating",
              operationId: "ratePartyRisk", handler: handleRiskRating),
    RouteSpec(httpMethod: hmPost,
              path: "/api/v1/parties/{partyId}/identity-docs/{docId}/unmask",
              operationId: "unmaskIdentityDoc", handler: handleUnmask),
  ]

proc ledgerRoutes*(): seq[RouteSpec] =
  ## `ledger`: COA + periode (T-072).
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/ledger/coa", operationId: "listCoa",
              handler: handleListCoa),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/ledger/coa", operationId: "createCoa",
              handler: handleCreateCoa),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/ledger/periods", operationId: "listPeriods",
              handler: handleListPeriods),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/ledger/periods", operationId: "openPeriod",
              handler: handleOpenPeriod),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/ledger/periods/{periodId}/close",
              operationId: "closePeriod", handler: handleClosePeriod),
  ]

proc journalRoutes*(): seq[RouteSpec] =
  ## `ledger` jurnal: baca + pembalik (T-073). Tidak ada endpoint buat/edit/hapus.
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/ledger/journals",
              operationId: "listJournals", handler: handleListJournals),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/ledger/journals/{journalId}",
              operationId: "getJournal", handler: handleGetJournal),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/ledger/journals/{journalId}/reversal",
              operationId: "reverseJournal", handler: handleReverseJournal),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/ledger/trial-balance",
              operationId: "getTrialBalance", handler: handleTrialBalance),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/ledger/balances",
              operationId: "getLedgerBalances", handler: handleLedgerBalances),
  ]

proc productRoutes*(): seq[RouteSpec] =
  ## Katalog produk parametrik (T-076).
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/products",
              operationId: "listProducts", handler: handleListProducts),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/products/{code}",
              operationId: "getProduct", handler: handleGetProduct),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/products",
              operationId: "createProduct", handler: handleCreateProduct),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/products/{code}/versions",
              operationId: "createProductVersion", handler: handleCreateVersion),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/products/{code}/versions/{versionId}/approve",
              operationId: "approveProductVersion", handler: handleApproveProductVersion),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/products/{code}/versions/{versionId}/reject",
              operationId: "rejectProductVersion", handler: handleRejectProductVersion),
  ]

proc depositRoutes*(): seq[RouteSpec] =
  ## Rekening simpanan (T-088a): buka + baca. Objek ber-cabang → gerbang `authorizedAtBranch`.
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/deposit/accounts",
              operationId: "listDepositAccounts", handler: handleListDepositAccounts),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/deposit/accounts",
              operationId: "openDepositAccount", handler: handleOpenDepositAccount),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/deposit/accounts/{accountId}",
              operationId: "getDepositAccount", handler: handleGetDepositAccount),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/deposit/accounts/{accountId}/statement",
              operationId: "getAccountStatement", handler: handleGetAccountStatement),
  ]

proc tellerRoutes*(): seq[RouteSpec] =
  ## Teller: transaksi tunai (T-088b) + pemindahbukuan (T-088c) + slip cetak ulang (T-094a).
  ## Objek ber-cabang → gerbang `authorizedAtBranch` di handler (PB: di kedua cabang rekening).
  @[
    RouteSpec(httpMethod: hmPost, path: "/api/v1/teller/cash-transactions",
              operationId: "postCashTransaction", handler: handleCashTransaction),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/teller/cash-transactions/{transactionId}",
              operationId: "getCashTransactionSlip", handler: handleGetCashTransactionSlip),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/teller/transfers",
              operationId: "postTransfer", handler: handleTransfer),
  ]

proc tellerSessionRoutes*(): seq[RouteSpec] =
  ## Sesi kas teller + vault (T-093): buka/tutup + baca sesi berjalan. Izin `teller.session.*`
  ## harus dipegang di cabang sesi (`authorizedAtBranch`).
  @[
    RouteSpec(httpMethod: hmPost, path: "/api/v1/teller/sessions",
              operationId: "openTellerSession", handler: handleOpenTellerSession),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/teller/sessions/current",
              operationId: "getCurrentTellerSession", handler: handleGetCurrentTellerSession),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/teller/sessions/{sessionId}/close",
              operationId: "closeTellerSession", handler: handleCloseTellerSession),
  ]

proc tellerVaultRoutes*(): seq[RouteSpec] =
  ## Vault kas cabang (T-107): top-up kas operasional + baca saldo. Izin `teller.vault.*` harus
  ## dipegang di cabang target (`authorizedAtBranch`). **Tanpa jurnal GL** (O-097).
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/teller/vault",
              operationId: "getTellerVault", handler: handleGetTellerVault),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/teller/vault/topups",
              operationId: "topUpTellerVault", handler: handleTopUpTellerVault),
  ]

proc userRoutes*(): seq[RouteSpec] =
  ## Administrasi pengguna & role (T-117): daftar akun, katalog role, dan siklus hidup akun.
  ## Institusi (bukan cabang) → izin `platform.user.manage` **dan** grant tanpa batas cabang di
  ## handler (`authorizedAtBranch(..., "")`).
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/users", operationId: "listUsers",
              handler: handleListUsers),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/roles", operationId: "listRoles",
              handler: handleListRoles),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/users/{userId}/roles",
              operationId: "assignUserRole", handler: handleAssignRole),
    RouteSpec(httpMethod: hmDelete, path: "/api/v1/users/{userId}/roles/{role}",
              operationId: "revokeUserRole", handler: handleRevokeRole),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/users/{userId}/disable",
              operationId: "disableUser", handler: handleDisableUser),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/users/{userId}/enable",
              operationId: "enableUser", handler: handleEnableUser),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/users/{userId}/unlock",
              operationId: "unlockUser", handler: handleUnlockUser),
  ]

proc allRoutes*(): seq[RouteSpec] =
  systemRoutes() & authRoutes() & mfaRoutes() & paramRoutes() & auditRoutes() &
    partyRoutes() & kycRoutes() & ledgerRoutes() & journalRoutes() & productRoutes() &
    depositRoutes() & tellerRoutes() & tellerSessionRoutes() & tellerVaultRoutes() &
    userRoutes() & eventRoutes()
