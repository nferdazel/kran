## Handler REST detail party (T-078, spec §8/§13/§18.2). Composition root.
##
## Handler memegang `FieldCrypto` (kepemilikan kunci = urusan platform) dan menulis audit dalam
## transaksi yang sama. Nilai PII **tidak pernah** masuk audit, event, log, atau respons kecuali
## endpoint *unmask* yang punya izin + alasan + jejak audit. Baca biasa mengembalikan **bentuk
## tersamar** (kolom `_mask`, tanpa dekripsi) — pola D-069.
##
## **HUMAN-REVIEW-REQUIRED**: alur ini menyentuh kriptografi field-level/PII (ADR-017, D-069).

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import kernel/[ids, paramkey, result]
import kernel/generated/paramkeys
import "platform-lib/crypto/fieldcrypto"
import platform/domain/[audit, scope]
import platform/infrastructure/[audit_repo, auth_service]
import party/domain/[detail, kyc, party]
import party/infrastructure/[detail_repo, party_repo]

import ./access
import ./context
import ./db_bridge
import ./handlers_kyc # `permissionKycManage`, `permissionPiiRead`, `requireCrypto`, `listParam`
import ./handlers_party # `permissionPartyRead` — satu sumber kode izin
import ./http_util
import ./problem

const
  ## AAD field crypto = nama tabel (ADR-017/D-069): ciphertext tidak bisa dipindah antar tabel,
  ## dan blind index ber-domain terpisah untuk tabel yang sama.
  personTable = "party_person"
  orgTable = "party_org"
  addressTable = "address"

type
  ## Tiga turunan satu kolom sensitif (D-069). Dihitung composition root, bukan modul `party`.
  CryptoParts = tuple[enc, bidx, mask: string]

proc triple(fc: FieldCrypto, table, value: string): CryptoParts =
  ## Ciphertext + blind index + bentuk tersamar untuk satu nilai. `value` boleh "" (field
  ## opsional): enkripsi nilai kosong tetap sah dan bentuk tersamar ikut kosong.
  (enc: encryptField(fc, table, value),
   bidx: blindIndex(fc, table, value),
   mask: maskTail(value))

proc requiredDate(node: JsonNode, field: string): string =
  ## Tanggal wajib dari badan permintaan: bentuk salah → `ValueError` (400), bukan `DbError` (500).
  let raw = node.jsonField(field).strip
  if raw.len == 0:
    raise newException(ValueError, field & " wajib diisi")
  if not isIsoDate(raw):
    raise newException(ValueError, field & " harus tanggal YYYY-MM-DD yang sah")
  raw

proc personMaskedJson(p: PersonDetail): JsonNode =
  %*{
    "legalNameLast2": p.legalNameMask,
    "birthDateLast2": p.birthDateMask,
    "sexLast2": p.sexMask,
    "occupationLast2": p.occupationMask,
  }

proc orgMaskedJson(o: OrgDetail): JsonNode =
  %*{"legalNameLast2": o.legalNameMask}

proc addressMaskedJson(a: Address): JsonNode =
  %*{
    "lineLast2": a.lineMask,
    "cityLast2": a.cityMask,
    "postalCodeLast2": a.postalCodeMask,
  }

proc handleUpsertPartyDetail*(app: AppContext, req: Request) {.gcsafe.} =
  ## `PUT /api/v1/parties/{partyId}/detail` — simpan detail sesuai jenis party + alamat opsional.
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

  let asOf = businessDateIso(app.clock)

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
        let kind = party.get().kind
        if not authorizedAtBranch(db, principal, $(party.get().branchId), permissionKycManage):
          status = 403
          problem = "izin " & permissionKycManage & " tidak dipegang di cabang party ini"
          raise newException(ValueError, problem)

        let hasPerson = node.hasKey("person") and node["person"].kind == JObject
        let hasOrg = node.hasKey("org") and node["org"].kind == JObject
        checkDetailKind(kind, hasPerson, hasOrg)

        let actor = parseId(principal.user.userId).value()
        var personJson = newJNull()
        var orgJson = newJNull()
        var updatedAt = ""

        if kind == pkPerson:
          let pnode = node["person"]
          let legalName = validateLegalName(pnode.jsonField("legalName"))
          let birthDate = requiredDate(pnode, "birthDate")
          # Tanggal lahir di masa depan bukan data yang sah; tanggal bisnis = batas atas.
          if birthDate > asOf:
            raise newException(ValueError, "birthDate tidak boleh melewati tanggal bisnis")
          let allowed = listParam(db, keyString(P_party_person_sex_values), asOf)
          let sex = parseSex(pnode.jsonField("sex"), allowed)
          if sex.isNone:
            raise newException(ValueError,
              "sex tidak termasuk daftar parameter party.person.sex_values")
          let occupation = validateOccupation(pnode.jsonField("occupation"))

          let ln = triple(app.fieldCrypto, personTable, legalName)
          let bd = triple(app.fieldCrypto, personTable, birthDate)
          let sx = triple(app.fieldCrypto, personTable, sex.get())
          let oc = triple(app.fieldCrypto, personTable, occupation)
          let p = PersonDetail(
            partyId: partyId.value(),
            legalNameEnc: ln.enc, legalNameBidx: ln.bidx, legalNameMask: ln.mask,
            birthDateEnc: bd.enc, birthDateBidx: bd.bidx, birthDateMask: bd.mask,
            sexEnc: sx.enc, sexBidx: sx.bidx, sexMask: sx.mask,
            occupationEnc: oc.enc, occupationBidx: oc.bidx, occupationMask: oc.mask)
          updatedAt = upsertPersonDetail(db, p, actor)
          personJson = %*{
            "legalNameLast2": ln.mask, "birthDateLast2": bd.mask,
            "sexLast2": sx.mask, "occupationLast2": oc.mask,
          }
        else:
          let onode = node["org"]
          let legalName = validateLegalName(onode.jsonField("legalName"))
          let ln = triple(app.fieldCrypto, orgTable, legalName)
          let o = OrgDetail(partyId: partyId.value(),
            legalNameEnc: ln.enc, legalNameBidx: ln.bidx, legalNameMask: ln.mask)
          updatedAt = upsertOrgDetail(db, o, actor)
          orgJson = %*{"legalNameLast2": ln.mask}

        # Alamat opsional: bila tidak dikirim, alamat yang ada dibiarkan (partial update).
        if node.hasKey("address") and node["address"].kind == JObject:
          let anode = node["address"]
          let line = validateAddressLine(anode.jsonField("line"))
          let city = validateCity(anode.jsonField("city"))
          let postal = validatePostalCode(anode.jsonField("postalCode"))
          let ln = triple(app.fieldCrypto, addressTable, line)
          let cy = triple(app.fieldCrypto, addressTable, city)
          let pc = triple(app.fieldCrypto, addressTable, postal)
          let a = Address(addressId: newId(app.clock), partyId: partyId.value(),
            lineEnc: ln.enc, lineBidx: ln.bidx, lineMask: ln.mask,
            cityEnc: cy.enc, cityBidx: cy.bidx, cityMask: cy.mask,
            postalCodeEnc: pc.enc, postalCodeBidx: pc.bidx, postalCodeMask: pc.mask)
          discard upsertAddress(db, a, actor)

        let addressRow = addressOf(db, partyId.value())
        let addrJson = if addressRow.isSome: addressMaskedJson(addressRow.get()) else: newJNull()

        let ctx = auditContextFor(principal, req, app.clock, "simpan detail party",
          $(party.get().branchId))
        # Audit tanpa PII: hanya id, jenis, dan apakah alamat ikut disimpan.
        discard appendAudit(db, newAuditEntry(ctx, "party.detail.upsert", "party_detail",
          $partyId.value(), app.clock,
          businessDate = businessDateFor(db, institutionScope(), asOf),
          after = %*{"partyId": $partyId.value(), "kind": $kind, "hasAddress": addressRow.isSome}))

        status = 200
        payload = %*{
          "partyId": $partyId.value(),
          "kind": $kind,
          "person": personJson,
          "org": orgJson,
          "address": addrJson,
          "updatedAt": updatedAt,
        })
  except KycConfigError as e:
    status = 500
    problem = "konfigurasi parameter party di server tidak sah: " & e.msg
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except FieldCryptoError:
    status = 500
    problem = "detail party tidak bisa disimpan (enkripsi gagal)"
  except DbError:
    status = 500
    problem = "detail party gagal disimpan"

  case status
  of 200: req.respondJson(200, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleGetPartyDetail*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/parties/{partyId}/detail` — detail dalam **bentuk tersamar** (tanpa dekripsi).
  ## Membuka nilai asli = *unmask* (izin baca PII + alasan + audit).
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

        var personJson = newJNull()
        var orgJson = newJNull()
        var updatedAt = ""
        case party.get().kind
        of pkPerson:
          let p = personDetailOf(db, partyId.value())
          if p.isNone:
            status = 404
            problem = "detail party belum ada"
            return
          personJson = personMaskedJson(p.get())
          updatedAt = p.get().updatedAt
        of pkOrg:
          let o = orgDetailOf(db, partyId.value())
          if o.isNone:
            status = 404
            problem = "detail party belum ada"
            return
          orgJson = orgMaskedJson(o.get())
          updatedAt = o.get().updatedAt

        let addressRow = addressOf(db, partyId.value())
        status = 200
        payload = %*{
          "partyId": $partyId.value(),
          "kind": $party.get().kind,
          "person": personJson,
          "org": orgJson,
          "address": (if addressRow.isSome: addressMaskedJson(addressRow.get()) else: newJNull()),
          "updatedAt": updatedAt,
        })
  except DbError:
    status = 500
    problem = "detail party gagal dibaca"

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)

proc handleUnmaskPartyDetail*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/parties/{partyId}/detail/unmask` — buka detail asli. Butuh izin
  ## `party.identity_doc.read` di cabang party **dan** alasan; setiap pembukaan diaudit
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
  if partyId.isErr:
    req.respondProblem(pkNotFound, "Not Found", "party tidak ditemukan")
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
        let kind = party.get().kind
        if not authorizedAtBranch(db, principal, $(party.get().branchId), permissionPiiRead):
          status = 403
          problem = "izin " & permissionPiiRead & " tidak dipegang di cabang party ini"
          raise newException(ValueError, problem)

        var personJson = newJNull()
        var orgJson = newJNull()
        try:
          if kind == pkPerson:
            let p = personDetailOf(db, partyId.value())
            if p.isNone:
              status = 404
              problem = "detail party belum ada"
              raise newException(ValueError, problem)
            personJson = %*{
              "legalName": decryptField(app.fieldCrypto, personTable, p.get().legalNameEnc),
              "birthDate": decryptField(app.fieldCrypto, personTable, p.get().birthDateEnc),
              "sex": decryptField(app.fieldCrypto, personTable, p.get().sexEnc),
              "occupation": decryptField(app.fieldCrypto, personTable, p.get().occupationEnc),
            }
          else:
            let o = orgDetailOf(db, partyId.value())
            if o.isNone:
              status = 404
              problem = "detail party belum ada"
              raise newException(ValueError, problem)
            orgJson = %*{
              "legalName": decryptField(app.fieldCrypto, orgTable, o.get().legalNameEnc),
            }
          let addressRow = addressOf(db, partyId.value())
          if addressRow.isSome:
            payload = %*{
              "partyId": $partyId.value(), "kind": $kind,
              "person": personJson, "org": orgJson,
              "address": %*{
                "line": decryptField(app.fieldCrypto, addressTable, addressRow.get().lineEnc),
                "city": decryptField(app.fieldCrypto, addressTable, addressRow.get().cityEnc),
                "postalCode": decryptField(app.fieldCrypto, addressTable,
                  addressRow.get().postalCodeEnc),
              },
            }
          else:
            payload = %*{
              "partyId": $partyId.value(), "kind": $kind,
              "person": personJson, "org": orgJson, "address": newJNull(),
            }
        except FieldCryptoError:
          status = 500
          problem = "detail party tidak bisa dibuka (data atau kunci tidak cocok)"
          raise newException(ValueError, problem)

        let ctx = auditContextFor(principal, req, app.clock, reason, $(party.get().branchId))
        # Jejak audit pembacaan PII: tanpa nilai asli, tanpa ciphertext.
        discard appendAudit(db, newAuditEntry(ctx, "party.detail.unmask", "party_detail",
          $partyId.value(), app.clock,
          businessDate = businessDateFor(db, institutionScope(), businessDateIso(app.clock)),
          after = %*{"partyId": $partyId.value(), "kind": $kind}))
        status = 200)
  except ValueError as e:
    if status == 0:
      status = 400
    problem = e.msg
  except DbError:
    status = 500
    problem = "detail party gagal dibuka"

  case status
  of 200: req.respondJson(200, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problem)
  of 403: req.respondProblem(pkForbidden, "Forbidden", problem)
  of 404: req.respondProblem(pkNotFound, "Not Found", problem)
  else: req.respondProblem(pkInternal, "Internal Server Error", problem)
