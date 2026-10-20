## Handler REST KYC modul `party` (T-071, spec §8/§13/§18.2).
##
## Composition root: handler memegang `FieldCrypto` (kepemilikan kunci = urusan platform) dan
## menulis audit/outbox dalam transaksi yang sama. Nomor dokumen **tidak pernah** masuk audit,
## event, log, maupun respons kecuali endpoint *unmask* yang punya izin + alasan + jejak audit.
##
## **HUMAN-REVIEW-REQUIRED**: alur ini menyentuh kriptografi field-level (ADR-017, D-048).

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[ids, paramkey, result]
import kernel/generated/paramkeys
import "platform-lib/crypto/fieldcrypto"
import platform/domain/[audit, event, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo, param_repo]
import party/domain/[identity, jsonparam, kyc]
import party/infrastructure/[kyc_repo, party_repo]

import ./access
import ./context
import ./db_bridge
import ./handlers_party # `permissionPartyRead` — satu sumber kode izin
import ./http_util
import ./problem

const
  permissionKycManage* = "party.kyc.manage"
  permissionPiiRead* = "party.identity_doc.read"
  ## AAD field crypto = nama tabel, bukan nama kolom (ADR-017): ciphertext tidak bisa dipindah
  ## antar tabel, dan blind index ber-domain terpisah untuk tabel yang sama.
  docTable = "identity_doc"

type
  ## Kesalahan konfigurasi/operasional (parameter hilang/salah bentuk). Dijawab 500 dengan pesan
  ## non-internal — permintaannya sah, server yang belum siap (spec §10.6, §13).
  KycConfigError = object of ValueError

proc jsonOrNull(s: string): JsonNode =
  ## Tanggal kosong dikirim `null` (kontrak: `["string","null"]`), bukan string kosong.
  if s.len == 0: newJNull() else: %s

proc docJson(doc: IdentityDoc): JsonNode =
  ## Bentuk dokumen untuk daftar/`GET` — selalu tanpa nomor (hanya bentuk tersamar).
  %*{
    "docId": $doc.docId,
    "docType": doc.docType,
    "numberLast2": doc.numberLast2,
    "issuedAt": jsonOrNull(doc.issuedAt),
    "expiresAt": jsonOrNull(doc.expiresAt),
    "createdAt": doc.createdAt,
  }

proc optionalDate(node: JsonNode, field: string): string =
  ## Tanggal opsional dari badan permintaan: absen/kosong → "", bentuk salah → `ValueError`.
  ## Divalidasi **sebelum** transaksi supaya kesalahan pemanggil tidak berubah jadi 500 dari cast
  ## `?::date` (pola yang sama dengan tanggal parameter, T-049/O-035).
  let raw = node.jsonField(field).strip
  if raw.len == 0:
    return ""
  if not isIsoDate(raw):
    raise newException(ValueError, field & " harus tanggal YYYY-MM-DD yang sah")
  raw

proc assessmentJson(a: RiskAssessment): JsonNode =
  %*{
    "ratingId": $a.ratingId,
    "level": a.level,
    "reason": a.reason,
    "assessedAt": a.assessedAt,
    "assessedBy": a.assessedBy,
  }

proc paramNode(db: DbConn, key, asOf: string): JsonNode =
  try:
    activeValueJson(db, key, asOf, lookupFor(institutionScope()))
  except ValueError:
    raise newException(KycConfigError, "parameter " & key & " tidak terbaca")

proc stringParam(db: DbConn, key, asOf: string): string =
  let node = paramNode(db, key, asOf)
  if node.kind != JString:
    raise newException(KycConfigError, "parameter " & key & " bukan teks")
  node.getStr()

proc intParam(db: DbConn, key, asOf: string): int =
  let node = paramNode(db, key, asOf)
  if node.kind != JInt:
    raise newException(KycConfigError, "parameter " & key & " bukan angka")
  int(node.getInt)

proc listParam(db: DbConn, key, asOf: string): seq[string] =
  try:
    stringList(paramNode(db, key, asOf), key)
  except KycConfigError:
    raise
  except ValueError as e:
    raise newException(KycConfigError, e.msg)

proc mapParam(db: DbConn, key, asOf: string): JsonNode =
  let node = paramNode(db, key, asOf)
  if node.kind != JObject:
    raise newException(KycConfigError, "parameter " & key & " harus objek")
  node

proc mapInt(node: JsonNode, key, paramName: string): int =
  try:
    intByKey(node, key, paramName).get(0)
  except KycConfigError:
    raise
  except ValueError as e:
    raise newException(KycConfigError, e.msg)

proc requireCrypto(app: AppContext, req: Request): bool =
  ## Fail-closed tanpa KEK: jangan pernah menyimpan/membuka nomor tanpa kunci (pola MFA T-046).
  if app.fieldCrypto.isConfigured:
    return true
  req.respondProblem(pkNotImplemented, "Not Implemented",
    "enkripsi field belum dikonfigurasi (" & envVarKekFile & " kosong) — dokumen identitas " &
    "tidak bisa disimpan maupun dibuka")
  false

proc handleAddIdentityDoc*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/parties/{partyId}/identity-docs` — registrasi dokumen identitas.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionKycManage):
    return
  if not requireCrypto(app, req):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let partyId = parseId(pathParam(req, "partyId"))
  if partyId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "party tidak ditemukan")
    return

  let rawNumber = node.jsonField("number")
  if rawNumber.strip.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "number wajib diisi")
    return

  var issuedAt = ""
  var expiresAt = ""
  try:
    issuedAt = optionalDate(node, "issuedAt")
    expiresAt = optionalDate(node, "expiresAt")
    if issuedAt.len > 0 and expiresAt.len > 0 and expiresAt < issuedAt:
      raise newException(ValueError, "expiresAt tidak boleh lebih awal dari issuedAt")
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let party = partyById(db, partyId.value())
        if party.isNone:
          status = 404
          problem = "party tidak ditemukan"
          raise newException(ValueError, problem)
        if not authorizedAtBranch(db, principal, $(party.get().branchId), permissionKycManage):
          status = 403
          problem = "izin " & permissionKycManage & " tidak dipegang di cabang party ini"
          raise newException(ValueError, problem)

        let asOf = businessDateIso(app.clock)
        let allowed = listParam(db, keyString(P_party_identity_doc_types), asOf)
        let docType = parseDocType(node.jsonField("docType"), allowed)
        if docType.isNone:
          status = 400
          problem = "docType tidak termasuk daftar parameter party.identity.doc_types"
          raise newException(ValueError, problem)

        let normalized = normalizeNumber(rawNumber)
        let fixedLength = mapInt(mapParam(db, keyString(P_party_identity_doc_lengths), asOf),
          docType.get(), "party.identity.doc_lengths")
        let maxLength = intParam(db, keyString(P_party_identity_number_max_length), asOf)
        try:
          discard validateNumber(normalized, maxLength, fixedLength)
        except ValueError as e:
          status = 400
          problem = e.msg
          raise newException(ValueError, problem)

        let bidx = blindIndex(app.fieldCrypto, docTable, normalized)
        # Diperiksa lebih dulu supaya pesannya jelas; constraint unik tetap jadi jaring terakhir
        # untuk balapan dua permintaan bersamaan (diterjemahkan 409 di blok `except DbError`).
        if identityDocByNumber(db, docType.get(), bidx).isSome:
          status = 409
          problem = "nomor dokumen sudah terdaftar"
          raise newException(ValueError, problem)

        var doc = IdentityDoc(
          docId: newId(app.clock),
          partyId: party.get().partyId,
          docType: docType.get(),
          numberEnc: encryptField(app.fieldCrypto, docTable, normalized),
          numberBidx: bidx,
          numberLast2: maskNumber(normalized),
          issuedAt: issuedAt,
          expiresAt: expiresAt,
          createdAt: "")
        doc.createdAt = insertIdentityDoc(db, doc, parseId(principal.user.userId).value())

        let ctx = auditContextFor(principal, req, app.clock, "registrasi dokumen identitas",
          $(party.get().branchId))
        # Audit menyebut jenis + id saja: nomor, ciphertext, dan indeks tidak ikut ke jejak.
        discard appendAudit(db, newAuditEntry(ctx, "party.identity.add", "identity_doc",
          $doc.docId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), asOf),
          after = %*{"docId": $doc.docId, "docType": doc.docType,
                     "partyId": $party.get().partyId}))

        status = 201
        payload = docJson(doc))
  except KycConfigError as e:
    status = 500
    problem = "konfigurasi KYC/dokumen di server tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError as e:
    if "identity_doc_number_uq" in e.msg or "duplicate key" in e.msg:
      status = 409
      problem = "nomor dokumen sudah terdaftar"
    else:
      status = 500
      problem = "dokumen identitas gagal disimpan"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  of 409: req.respondProblem(pkConflict, "Conflict", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleGetKyc*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/parties/{partyId}/kyc` — profil KYC, rating berjalan, riwayat, daftar dokumen.
  ## Tidak ada nomor dokumen di respons ini (hanya bentuk tersamar) — membuka nomor = *unmask*.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionPartyRead):
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
        let party = partyById(db, partyId.value())
        if party.isNone:
          status = 404
          problem = "party tidak ditemukan"
          return
        if not authorizedAtBranch(db, principal, $(party.get().branchId), permissionPartyRead):
          status = 403
          problem = "izin " & permissionPartyRead & " tidak dipegang di cabang party ini"
          return

        let profile = kycProfileOf(db, party.get().partyId)
        if profile.isNone:
          status = 404
          problem = "profil KYC party belum ada"
          return

        var docs = newJArray()
        for doc in identityDocsOf(db, party.get().partyId):
          docs.add docJson(doc)
        var history = newJArray()
        for a in riskAssessmentsOf(db, party.get().partyId):
          history.add assessmentJson(a)

        status = 200
        payload = %*{
          "partyId": $party.get().partyId,
          "status": $profile.get().status,
          "riskLevel": profile.get().riskLevel,
          "riskAssessedAt": jsonOrNull(profile.get().riskAssessedAt),
          "nextReviewDue": jsonOrNull(profile.get().nextReviewDue),
          "documents": docs,
          "riskHistory": history,
        })
  except DbError:
    status = 500
    problem = "profil KYC gagal dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleRiskRating*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/parties/{partyId}/risk-rating` — penilaian risiko baru (riwayat bertambah).
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionKycManage):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  let partyId = parseId(pathParam(req, "partyId"))
  if partyId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "party tidak ditemukan")
    return

  var reason = ""
  try:
    reason = validateReason(node.jsonField("reason"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let party = partyById(db, partyId.value())
        if party.isNone:
          status = 404
          problem = "party tidak ditemukan"
          raise newException(ValueError, problem)
        if not authorizedAtBranch(db, principal, $(party.get().branchId), permissionKycManage):
          status = 403
          problem = "izin " & permissionKycManage & " tidak dipegang di cabang party ini"
          raise newException(ValueError, problem)

        let asOf = businessDateIso(app.clock)
        let allowed = listParam(db, keyString(P_party_kyc_risk_levels), asOf)
        let level = parseRiskLevel(node.jsonField("level"), allowed)
        if level.isNone:
          status = 400
          problem = "level tidak termasuk daftar parameter party.kyc.risk_levels"
          raise newException(ValueError, problem)

        var months = 0
        try:
          months = reviewMonthsOf(mapParam(db, keyString(P_party_kyc_review_months), asOf),
            level.get())
        except ValueError as e:
          raise newException(KycConfigError, e.msg)

        let due = reviewDueDate(asOf, months)
        let userId = parseId(principal.user.userId).value()
        var assessment = RiskAssessment(
          ratingId: newId(app.clock),
          partyId: party.get().partyId,
          level: level.get(),
          reason: reason,
          assessedAt: "",
          assessedBy: principal.user.userId)
        assessment.assessedAt = insertRiskAssessment(db, assessment)
        # Profil memakai cap waktu yang **sama** dengan baris riwayat, bukan `now()` kedua.
        applyRiskAssessment(db, party.get().partyId, level.get(), due, userId,
          assessment.assessedAt)

        let ctx = auditContextFor(principal, req, app.clock, reason,
          $(party.get().branchId))
        discard appendAudit(db, newAuditEntry(ctx, "party.risk.change", "risk_rating",
          $assessment.ratingId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), asOf),
          after = %*{"ratingId": $assessment.ratingId, "partyId": $party.get().partyId,
                     "level": level.get(), "nextReviewDue": due}))
        # Event tanpa PII: identitas party + tingkat risiko + jadwal re-KYC.
        discard appendEvent(db, newOutboxEvent(newId(app.clock), "party.risk_changed", "party",
          $party.get().partyId, "party.risk_changed:" & $assessment.ratingId, %*{
            "partyId": $party.get().partyId,
            "ratingId": $assessment.ratingId,
            "level": level.get(),
            "nextReviewDue": due,
          }))

        status = 201
        payload = %*{
          "ratingId": $assessment.ratingId,
          "partyId": $party.get().partyId,
          "level": level.get(),
          "reason": reason,
          "assessedAt": assessment.assessedAt,
          "nextReviewDue": due,
        })
  except KycConfigError as e:
    status = 500
    problem = "konfigurasi KYC di server tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    status = 500
    problem = "penilaian risiko gagal disimpan"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleUnmask*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/parties/{partyId}/identity-docs/{docId}/unmask` — membuka nomor dokumen.
  ## Butuh izin `party.identity_doc.read` di cabang party **dan** alasan; setiap pembukaan diaudit
  ## (spec §18.2: unmask = permission + alasan + audit).
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionPiiRead):
    return
  if not requireCrypto(app, req):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()

  var reason = ""
  try:
    reason = validateReason(node.jsonField("reason"))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  let partyId = parseId(pathParam(req, "partyId"))
  let docId = parseId(pathParam(req, "docId"))
  if partyId.isErr or docId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "dokumen tidak ditemukan")
    return

  var status = 0
  var problem = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let party = partyById(db, partyId.value())
        if party.isNone:
          status = 404
          problem = "party tidak ditemukan"
          raise newException(ValueError, problem)
        if not authorizedAtBranch(db, principal, $(party.get().branchId), permissionPiiRead):
          status = 403
          problem = "izin " & permissionPiiRead & " tidak dipegang di cabang party ini"
          raise newException(ValueError, problem)

        let doc = identityDocById(db, docId.value())
        # Dokumen milik party lain dijawab 404: id dokumen tidak boleh jadi jalan menghitung
        # keberadaan data party yang tidak boleh dibaca.
        if doc.isNone or doc.get().partyId != party.get().partyId:
          status = 404
          problem = "dokumen tidak ditemukan"
          raise newException(ValueError, problem)

        var plain = ""
        try:
          plain = decryptField(app.fieldCrypto, docTable, doc.get().numberEnc)
        except FieldCryptoError:
          status = 500
          problem = "nomor dokumen tidak bisa dibuka (data atau kunci tidak cocok)"
          raise newException(ValueError, problem)

        let ctx = auditContextFor(principal, req, app.clock, reason,
          $(party.get().branchId))
        # Jejak audit pembacaan PII: tanpa nomor, tanpa ciphertext — hanya siapa/kapan/apa.
        discard appendAudit(db, newAuditEntry(ctx, "party.identity.unmask", "identity_doc",
          $doc.get().docId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), businessDateIso(app.clock)),
          after = %*{"docId": $doc.get().docId, "docType": doc.get().docType,
                     "partyId": $party.get().partyId}))

        status = 200
        payload = %*{
          "docId": $doc.get().docId,
          "docType": doc.get().docType,
          "number": plain,
          "expiresAt": jsonOrNull(doc.get().expiresAt),
        })
  except KycConfigError as e:
    status = 500
    problem = e.msg
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    status = 500
    problem = "nomor dokumen gagal dibuka"

  case status
  of 200: req.respondJson(200, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
