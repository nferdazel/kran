## Handler REST modul `party` (T-070, spec §13).
##
## Composition root: handler boleh menyentuh repo `party` **dan** repo platform (audit, outbox,
## parameter) karena transaksi harus atomik. Modul `party` sendiri tidak mengimpor internal
## `platform` (archcheck rule C); ia hanya menyediakan domain + repo SQL.

import std/[json, options, sets, strutils]

import mummy
import db_connector/db_postgres

import kernel/[clock, ids, paramkey, result]
import kernel/generated/paramkeys
import platform/domain/[audit, authz, event, idempotency, scope]
import platform/infrastructure/[audit_repo, auth_repo, auth_service, outbox_repo, param_repo]
import party/domain/[cif, jsonparam, kyc, party]
import party/infrastructure/[kyc_repo, party_repo]

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./idempotency
import ./problem

const
  permissionPartyCreate* = "party.party.create"
  permissionPartyRead* = "party.party.read"
  ## Pencarian party (T-115): ambang panjang query & batas jumlah baris — nilai **teknis** (ukuran
  ## respons/pencarian), bukan aturan bisnis.
  minPartySearchQueryLength* = 2 # nomagic:ok ambang teknis panjang pencarian
  defaultPartySearchLimit* = 20 # nomagic:ok ukuran halaman default
  maxPartySearchLimit* = 50 # nomagic:ok batas atas ukuran respons

type
  ## Kegagalan **konfigurasi/operasional** party (parameter CIF/KYC hilang atau salah bentuk,
  ## nomor urut tidak muat di lebar pola). Ini bukan kesalahan pemanggil: jawabannya 500 dengan
  ## pesan yang tidak membocorkan internal (spec §10.6, §13) — bukan 400.
  PartyConfigError = object of ValueError

proc partyJson(row: PartyRow): JsonNode =
  %*{
    "partyId": $row.partyId,
    "cif": row.cif,
    "kind": $row.kind,
    "displayName": row.displayName,
    "status": $row.status,
    "branchId": $row.branchId,
    "createdAt": row.createdAt,
  }

proc partySummaryJson(row: PartyRow): JsonNode =
  ## Bentuk **ringkas** untuk pencarian (T-115): hanya yang dibutuhkan pemilih pemilik rekening.
  ## Tanpa `createdAt`, tanpa identitas/KYC — data pribadi tidak ikut keluar jalur ini.
  %*{
    "partyId": $row.partyId,
    "cif": row.cif,
    "kind": $row.kind,
    "displayName": row.displayName,
    "status": $row.status,
    "branchId": $row.branchId,
  }

proc handleCreateParty*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/parties` — CIF baru + identitas dasar.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  if not requirePermission(app, req, principal.get(), permissionPartyCreate):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let kind = parsePartyKind(node.jsonField("kind"))
  if kind.isNone:
    req.respondProblem(pkBadRequest, "Bad Request", "kind harus PERSON atau ORG")
    return

  var displayName = ""
  try:
    displayName = validateName(node.jsonField("displayName"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let branchRaw = node.jsonField("branchId")
  let branchId = parseId(branchRaw)
  if branchId.isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "branchId harus UUID yang sah")
    return

  if not requireIdempotencyKey(req):
    req.respondProblem(pkBadRequest, "Bad Request", "Idempotency-Key wajib diisi")
    return

  let asOf = businessDateIso(app.clock)

  var status = 0
  var problem = ""
  var payload = newJObject()
  var outcome = IdempotentOutcome(decision: idemProceed)
  try:
    outcome = withDbTx(app.pool, proc(db: DbConn): IdempotentOutcome {.gcsafe.} =
      dbCalls:
        withIdempotency(db, principal.get(), req, "party.create", $node, asOf,
          app.clock.now(),
        proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
          dbCalls:
            if not authorizedAtBranch(db, principal.get(), branchRaw, permissionPartyCreate):
              status = 403
              problem = "izin " & permissionPartyCreate & " tidak dipegang di cabang ini"
              raise newException(ValueError, problem)

            let patternNode =
              try:
                activeValueJson(db, keyString(P_party_cif_format), asOf,
                  lookupFor(institutionScope()))
              except ValueError:
                raise newException(PartyConfigError, "parameter party.cif.format tidak terbaca")
            if patternNode.kind != JString:
              raise newException(PartyConfigError, "parameter party.cif.format bukan string")
            let pattern = patternNode.getStr()

            # Pola divalidasi **sebelum** nomor urut dipakai supaya salah konfigurasi tidak
            # meninggalkan lubang CIF yang tidak perlu.
            try:
              discard formatCif(pattern, 1)
            except ValueError:
              raise newException(PartyConfigError, "parameter party.cif.format tidak sah")

            # Nama sudah divalidasi sebelum transaksi, jadi `ValueError` dari sini hanya bisa datang
            # dari pola/lebar sequence (mis. nomor urut melewati `{seq:N}`) — kondisi operator.
            let party =
              try:
                newParty(newId(app.clock), kind.get(), displayName, branchId.value(),
                  pattern, nextCifSeq(db))
              except ValueError:
                raise newException(PartyConfigError,
                  "nomor CIF tidak bisa dibentuk dari pola parameter")
            let userId = parseId(principal.get().user.userId).value()
            let createdAt = insertParty(db, party, userId)

            # Profil KYC lahir bersama party (T-071): status PENDING, rating awal + jadwal re-KYC
            # dari parameter. Parameter rusak = kondisi operator (500), bukan permintaan salah.
            var riskLevel = ""
            var reviewMonths = 0
            try:
              let levelNode = activeValueJson(db, keyString(P_party_kyc_default_risk_level), asOf,
                lookupFor(institutionScope()))
              if levelNode.kind != JString:
                raise newException(PartyConfigError,
                  "parameter party.kyc.default_risk_level bukan teks")
              let levels = stringList(activeValueJson(db, keyString(P_party_kyc_risk_levels), asOf,
                lookupFor(institutionScope())), "party.kyc.risk_levels")
              # Tingkat awal **wajib** anggota daftar tingkat; kalau tidak, profil KYC akan memuat
              # nilai yang tidak dikenal validasi lain (salah konfigurasi, bukan permintaan salah).
              let canonical = parseRiskLevel(levelNode.getStr(), levels)
              if canonical.isNone:
                raise newException(PartyConfigError,
                  "party.kyc.default_risk_level tidak termasuk party.kyc.risk_levels")
              riskLevel = canonical.get()
              reviewMonths = reviewMonthsOf(activeValueJson(db, keyString(
                  P_party_kyc_review_months),
                asOf, lookupFor(institutionScope())), riskLevel)
            except PartyConfigError:
              raise
            except ValueError as e:
              raise newException(PartyConfigError, e.msg)
            discard insertKycProfile(db, party.partyId, riskLevel, reviewDueDate(asOf,
                reviewMonths),
              userId)
            let ctx = auditContextFor(principal.get(), req, app.clock, "buat party", branchRaw)
            discard appendAudit(db, newAuditEntry(
              ctx, "party.create", "party", $party.partyId, app.clock,
              businessDate = businessDateFor(db, institutionScope(), asOf),
              after = %*{
                "partyId": $party.partyId,
                "cif": party.cif,
                "kind": $party.kind,
                "branchId": $party.branchId,
                "status": $party.status,
              }))
            # Nama **tidak** ikut event: data pribadi tidak perlu meninggalkan modul ini.
            discard appendEvent(db, newOutboxEvent(newId(app.clock), "party.onboarded", "party",
              $party.partyId, "party.onboarded:" & $party.partyId, %*{
                "partyId": $party.partyId,
                "cif": party.cif,
                "kind": $party.kind,
                "branchId": $party.branchId,
              }))
            status = 201
            payload = %*{
              "partyId": $party.partyId,
              "cif": party.cif,
              "kind": $party.kind,
              "displayName": party.displayName,
              "status": $party.status,
              "branchId": $party.branchId,
              "createdAt": createdAt,
            }
            (status, payload)))
  except IdempotencyConfigError:
    status = 500
    problem = "konfigurasi idempotensi di server tidak sah"
  except IdempotencyStateError:
    status = 500
    problem = "idempotensi gagal diselesaikan"
  except PartyConfigError:
    status = 500
    # Pesan tidak memuat nilai parameter maupun data party; menyebut modulnya supaya operator tahu
    # ke mana harus melihat (detail teknis ada di jejak server saat start/gate).
    problem = "konfigurasi parameter modul party tidak sah (CIF/KYC) — hubungi administrator"
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    status = 500
    problem = "party gagal disimpan"

  if outcome.decision != idemProceed:
    discard req.respondIdempotent(outcome)
    return

  case status
  of 201: req.respondJson(201, payload)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleGetParty*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/parties/{partyId}` — baca satu party.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  if not requirePermission(app, req, principal.get(), permissionPartyRead):
    return

  let partyId = parseId(pathParam(req, "partyId"))
  if partyId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "party tidak ditemukan")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let row = partyById(db, partyId.value())
        if row.isNone:
          status = 404
          problem = "party tidak ditemukan"
          return
        if not authorizedAtBranch(db, principal.get(), $(row.get().branchId),
                                  permissionPartyRead):
          status = 403
          problem = "izin " & permissionPartyRead & " tidak dipegang di cabang party ini"
          return
        status = 200
        payload = partyJson(row.get()))
  except DbError:
    status = 500
    problem = "party gagal dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleSearchParties*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/parties?query=&branchId=&limit=` — cari party untuk pemilih pemilik rekening
  ## (T-115). Hasil **ringkas** (tanpa identitas/KYC).
  ##
  ## Cabang: bila `branchId` diberikan, izin `party.party.read` harus dipegang di cabang itu
  ## (kalau tidak → 403 `branch_not_allowed`); bila tidak, hasil dibatasi cabang yang boleh dibaca
  ## pemanggil (`readableScopeFilter`) supaya cabang lain tidak bocor. Pemanggil tanpa grant
  ## berbatas cabang melihat semua cabang.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  if not requirePermission(app, req, principal.get(), permissionPartyRead):
    return

  let query = queryValue(req, "query").strip
  if query.len < minPartySearchQueryLength:
    req.respondProblem(pkBadRequest, "Bad Request",
      "query minimal " & $minPartySearchQueryLength & " karakter")
    return

  var limit = defaultPartySearchLimit
  let limitRaw = queryValue(req, "limit").strip
  if limitRaw.len > 0:
    try:
      limit = parseInt(limitRaw)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus angka")
      return
    if limit < 1 or limit > maxPartySearchLimit:
      req.respondProblem(pkBadRequest, "Bad Request",
        "limit harus antara 1 dan " & $maxPartySearchLimit)
      return

  let branchRaw = queryValue(req, "branchId").strip
  if branchRaw.len > 0 and parseId(branchRaw).isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "branchId harus UUID yang sah")
    return

  var status = 0
  var problem = ""
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        var allBranches = false
        var branches: seq[string]
        if branchRaw.len > 0:
          if not authorizedAtBranch(db, principal.get(), branchRaw, permissionPartyRead):
            status = 403
            problem = "izin " & permissionPartyRead & " tidak dipegang di cabang ini"
            return
          branches = @[branchRaw]
        else:
          let scope = readableScopeFilter(grantsOf(db, principal.get().user.userId),
            permissionPartyRead)
          allBranches = scope.allBranches
          for b in scope.branches:
            branches.add b
        for row in searchParties(db, query, allBranches, branches, limit):
          items.add partySummaryJson(row)
        status = 200)
  except DbError:
    status = 500
    problem = "pencarian party gagal"

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondProblem(newProblem(pkForbidden, "Forbidden", problem,
      traceId = traceIdFrom(req), params = @[("reason", "branch_not_allowed")]))
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
