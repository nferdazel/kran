## Handler REST modul `product` (T-076).
##
## Composition root: validasi terhadap **definisi parameter** (tipenya milik platform), audit, dan
## outbox ditulis di sini dalam transaksi yang sama. Modul `product` tetap murni (domain saja).
##
## Aksi institusi (bukan cabang) → dua gerbang seperti T-072/T-073: izin dipegang di cabang mana pun
## (`requirePermission`) **dan** grant tanpa batas cabang (`authorizedAtBranch(..., "")`).

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[businessdate, clock, ids, money, paramkey, rate, result]
import platform/domain/[audit, event, param, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo, param_repo]
import product/domain/product
import product/infrastructure/product_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  permissionProductRead* = "product.catalog.read"
  permissionProductManage* = "product.catalog.manage"

proc respondInstitutionOnly(req: Request, permission: string) =
  req.respondProblem(newProblem(pkForbidden, "Forbidden",
    "aksi tingkat institusi " & permission & " hanya boleh dengan grant tanpa batas cabang",
    traceId = traceIdFrom(req),
    params = @[("reason", "branch_not_allowed"), ("permission", permission)]))

proc bindingJson(b: ParamBinding): JsonNode =
  %*{"paramKey": b.paramKey, "value": b.value}

proc versionJson(v: ProductVersion, bindings: seq[ParamBinding]): JsonNode =
  var items = newJArray()
  for b in bindings:
    items.add bindingJson(b)
  %*{
    "versionId": $v.versionId,
    "versionNo": v.versionNo,
    "effectiveFrom": v.effectiveFrom,
    "effectiveTo": if v.effectiveTo.len == 0: newJNull() else: %v.effectiveTo,
    "bindings": items,
  }

proc productJson(p: Product): JsonNode =
  %*{
    "productId": $p.productId,
    "code": p.code,
    "name": p.name,
    "productType": $p.productType,
    "createdAt": p.createdAt,
  }

proc parseBindings(body: JsonNode): seq[ParamBinding] =
  if body.kind != JObject or not body.hasKey("bindings") or body["bindings"].kind != JObject:
    raise newException(ValueError, "bindings wajib berupa objek {paramKey: value}")
  for key, value in body["bindings"]:
    result.add ParamBinding(paramKey: key, value: value)

const
  maxStringBindingLength = 200 # nomagic:ok batas teknis nilai parameter teks
  maxJsonBindingBytes = 16_384 # nomagic:ok batas teknis payload JSON binding
  rateScale = 6                # nomagic:ok Rate = 10^-6 (shared/kernel/rate)

proc pow10(n: int): int64 =
  result = 1
  for _ in 0 ..< n:
    result *= 10

proc boundUnits(bound: int64, scale: int): Option[int64] =
  ## `bound * 10^scale` dengan pemeriksaan overflow; `none` = di luar rentang int64.
  try:
    some(checkedMul(bound, pow10(scale)))
  except MoneyOverflowError:
    none(int64)

proc schemaBound(schema: JsonNode, key: string): tuple[value: Option[int64], error: string] =
  ## Batas schema hanya bisa dibandingkan tanpa float bila berupa bilangan bulat. Batas pecahan
  ## **ditolak** (fail-closed), bukan diabaikan diam-diam.
  if schema.isNil or schema.kind != JObject or not schema.hasKey(key):
    return (none(int64), "")
  if schema[key].kind != JInt:
    return (none(int64), "batas schema `" & key & "` harus bilangan bulat")
  (some(schema[key].getBiggestInt()), "")

proc definitionError(db: DbConn, bindings: seq[ParamBinding]): string =
  ## Validasi binding terhadap definisi parameter: terdaftar, tidak deprecated, tipe cocok,
  ## enum dikenal, dan batas numerik dipatuhi. Parser uang/rate memakai kernel (checked, tanpa
  ## float), bukan duplikasi aturan desimal.
  for b in bindings:
    let defOpt = definitionOf(db, b.paramKey)
    if defOpt.isNone:
      return "parameter tidak terdaftar: " & b.paramKey
    let def = defOpt.get()
    if def.deprecated:
      return "parameter sudah deprecated: " & b.paramKey
    let minB = schemaBound(def.schema, "minimum")
    let maxB = schemaBound(def.schema, "maximum")
    if minB.error.len > 0:
      return b.paramKey & ": " & minB.error
    if maxB.error.len > 0:
      return b.paramKey & ": " & maxB.error

    case def.valueType
    of pvtInteger:
      if b.value.kind != JInt:
        return b.paramKey & " harus bilangan bulat"
      let v = b.value.getBiggestInt()
      if minB.value.isSome and v < minB.value.get():
        return b.paramKey & " di bawah minimum"
      if maxB.value.isSome and v > maxB.value.get():
        return b.paramKey & " di atas maximum"
    of pvtBool:
      if b.value.kind != JBool:
        return b.paramKey & " harus boolean"
    of pvtJson:
      if ($b.value).len > maxJsonBindingBytes:
        return b.paramKey & " melebihi batas ukuran JSON"
    of pvtString:
      if b.value.kind != JString:
        return b.paramKey & " harus teks"
      let text = b.value.getStr()
      if def.schema != nil and def.schema.kind == JObject:
        if def.schema.hasKey("minLength") and def.schema["minLength"].kind == JInt and
            text.len < def.schema["minLength"].getInt():
          return b.paramKey & " lebih pendek dari minLength"
        if def.schema.hasKey("maxLength") and def.schema["maxLength"].kind == JInt and
            text.len > def.schema["maxLength"].getInt():
          return b.paramKey & " lebih panjang dari maxLength"
      if text.len > maxStringBindingLength:
        return b.paramKey & " melebihi batas panjang teks"
    of pvtEnum:
      if b.value.kind != JString:
        return b.paramKey & " harus teks (enum)"
      if def.schema.isNil or def.schema.kind != JObject or not def.schema.hasKey("enum") or
          def.schema["enum"].len == 0:
        return b.paramKey & " tidak punya daftar enum"
      var known = false
      for item in def.schema["enum"]:
        if item.kind == JString and item.getStr() == b.value.getStr():
          known = true
      if not known:
        return b.paramKey & " tidak termasuk nilai yang diizinkan"
    of pvtMoney, pvtDecimal, pvtRate:
      if b.value.kind != JString:
        return b.paramKey & " harus teks desimal"
      var units: int64
      var scale: int
      if def.valueType == pvtRate:
        let parsed = rateFromPercentString(b.value.getStr())
        if parsed.isErr:
          return b.paramKey & " bukan rate persen yang sah"
        units = parsed.value().microUnits
        scale = rateScale
      else:
        let parsed = moneyFromString(b.value.getStr())
        if parsed.isErr:
          return b.paramKey & " bukan desimal 4 angka di belakang koma yang sah"
        units = parsed.value().minorUnits
        scale = moneyScale
      if minB.value.isSome:
        let lo = boundUnits(minB.value.get(), scale)
        if lo.isNone:
          return b.paramKey & ": batas minimum di luar rentang"
        if units < lo.get():
          return b.paramKey & " di bawah minimum"
      if maxB.value.isSome:
        let hi = boundUnits(maxB.value.get(), scale)
        if hi.isNone:
          return b.paramKey & ": batas maximum di luar rentang"
        if units > hi.get():
          return b.paramKey & " di atas maximum"
    of pvtDate:
      if b.value.kind != JString or parseBusinessDate(b.value.getStr()).isErr:
        return b.paramKey & " bukan tanggal ISO"

proc detailJson(db: DbConn, p: Product): JsonNode =
  var versions = newJArray()
  for v in versionsOf(db, p.productId):
    versions.add versionJson(v, bindingsOf(db, v.versionId))
  result = productJson(p)
  result["versions"] = versions

proc handleListProducts*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/products?asOf=yyyy-MM-dd` — katalog + versi yang berlaku pada tanggal itu.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionProductRead):
    return

  let rawAsOf = queryValue(req, "asOf").strip
  if rawAsOf.len > 0 and parseBusinessDate(rawAsOf).isErr:
    req.respondProblem(pkBadRequest, "Bad Request", "asOf bukan tanggal ISO (yyyy-MM-dd)")
    return

  var status = 0
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionProductRead):
          status = 403
          return
        let asOf = if rawAsOf.len > 0: rawAsOf
                   else: businessDateFor(db, institutionScope(), businessDateIso(app.clock))
        for p in listProducts(db, asOf):
          var row = productJson(p)
          let current = currentVersion(db, p.productId, asOf)
          row["currentVersion"] =
            if current.isNone: newJNull()
            else: %*{"versionNo": current.get().versionNo,
                     "effectiveFrom": current.get().effectiveFrom}
          items.add row
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, %*{"items": items})
  of 403: req.respondInstitutionOnly(permissionProductRead)
  else: req.respondProblem(pkInternal, "Internal Server Error", "katalog produk gagal dibaca")

proc handleGetProduct*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/products/{code}` — detail + seluruh versi + binding.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionProductRead):
    return
  let code = pathParam(req, "code").strip.toUpperAscii()

  var status = 0
  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionProductRead):
          status = 403
          return
        let p = productByCode(db, code)
        if p.isNone:
          status = 404
          return
        payload = detailJson(db, p.get())
        status = 200)
  except DbError:
    status = 500

  case status
  of 200: req.respondJson(200, payload)
  of 403: req.respondInstitutionOnly(permissionProductRead)
  of 404: req.respondProblem(pkNotFound, "Not Found", "produk tidak ditemukan")
  else: req.respondProblem(pkInternal, "Internal Server Error", "produk gagal dibaca")

proc parseWindowFields(body: JsonNode): tuple[fromIso, toIso: string] =
  if body.kind != JObject or not body.hasKey("effectiveFrom") or
      body["effectiveFrom"].kind != JString:
    raise newException(ValueError, "effectiveFrom wajib berupa tanggal ISO")
  validateWindow(body["effectiveFrom"].getStr(), "")

proc handleCreateProduct*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/products` — produk baru + versi 1 (terbuka).
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionProductManage):
    return

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  let node = body.get()
  var code, name: string
  var ptype: ProductType
  var window: tuple[fromIso, toIso: string]
  var bindings: seq[ParamBinding]
  try:
    for field in ["code", "name", "productType"]:
      if not node.hasKey(field) or node[field].kind != JString:
        raise newException(ValueError, field & " wajib berupa teks")
    code = validateCode(node["code"].getStr())
    name = validateName(node["name"].getStr())
    ptype = parseProductType(node["productType"].getStr())
    window = parseWindowFields(node)
    bindings = validateBindings(parseBindings(node))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  var status = 0
  var problemText = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionProductManage):
          status = 403
          return
        let defErr = definitionError(db, bindings)
        if defErr.len > 0:
          status = 400
          problemText = defErr
          raise newException(ValueError, defErr)
        if productByCode(db, code).isSome:
          status = 409
          problemText = "kode produk sudah dipakai"
          raise newException(ValueError, problemText)

        let p = Product(productId: newId(app.clock), code: code, name: name,
          productType: ptype)
        insertProduct(db, p, parseId(principal.user.userId).value())
        let v = ProductVersion(versionId: newId(app.clock), productId: p.productId,
          versionNo: 1, effectiveFrom: window.fromIso)
        insertVersion(db, v, parseId(principal.user.userId).value())
        for b in bindings:
          insertBinding(db, v.versionId, b)

        let ctx = auditContextFor(principal, req, app.clock, "")
        discard appendAudit(db, newAuditEntry(ctx, "product.publish", "product", $p.productId,
          app.clock,
          businessDate = businessDateFor(db, institutionScope(), businessDateIso(app.clock)),
          after = %*{"code": p.code, "productType": $p.productType,
                     "versionNo": 1, "effectiveFrom": window.fromIso}))
        discard appendEvent(db, newOutboxEvent(newId(app.clock), "ProductPublished", "product",
          $p.productId, "product.published:" & $v.versionId,
          %*{"productId": $p.productId, "code": p.code, "productType": $p.productType,
             "versionNo": 1, "effectiveFrom": window.fromIso}))

        payload = detailJson(db, p)
        status = 201)
  except ValueError as e:
    if status == 0:
      status = 400
    if problemText.len == 0:
      problemText = e.msg
  except DbError as e:
    if "product_code_key" in e.msg or "duplicate key" in e.msg:
      status = 409
      problemText = "kode produk sudah dipakai"
    elif "product_version_no_overlap" in e.msg or "conflicting key" in e.msg:
      status = 409
      problemText = "versi produk bertumpang tindih"
    elif "product_version_window_chk" in e.msg:
      status = 409
      problemText = "jendela versi tidak sah"
    else:
      status = 500
      problemText = "produk gagal disimpan"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problemText)
  of 403: req.respondInstitutionOnly(permissionProductManage)
  of 409: req.respondProblem(pkConflict, "Conflict", problemText)
  else: req.respondProblem(pkInternal, "Internal Server Error", problemText)

proc handleCreateVersion*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/products/{code}/versions` — versi baru; versi terbuka sebelumnya ditutup
  ## sehari sebelum tanggal mulai.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionProductManage):
    return
  let code = pathParam(req, "code").strip.toUpperAscii()

  let body = parseJsonBody(req)
  if body.isNone or body.get().kind != JObject:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus objek JSON")
    return
  var window: tuple[fromIso, toIso: string]
  var bindings: seq[ParamBinding]
  try:
    window = parseWindowFields(body.get())
    bindings = validateBindings(parseBindings(body.get()))
  except ValueError as e:
    req.respondProblem(pkBadRequest, "Bad Request", e.msg)
    return

  var status = 0
  var problemText = ""
  var payload = newJObject()
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        if not authorizedAtBranch(db, principal, "", permissionProductManage):
          status = 403
          return
        let p = productByCode(db, code)
        if p.isNone:
          status = 404
          problemText = "produk tidak ditemukan"
          raise newException(ValueError, problemText)
        let defErr = definitionError(db, bindings)
        if defErr.len > 0:
          status = 400
          problemText = defErr
          raise newException(ValueError, defErr)

        let open = openVersion(db, p.get().productId)
        if open.isSome:
          if window.fromIso <= open.get().effectiveFrom:
            status = 409
            problemText = "effectiveFrom harus setelah versi berjalan (" &
              open.get().effectiveFrom & ")"
            raise newException(ValueError, problemText)
          if not closeVersion(db, open.get().versionId, window.fromIso):
            status = 409
            problemText = "versi berjalan sudah ditutup permintaan lain"
            raise newException(ValueError, problemText)

        let versionNo = nextVersionNo(db, p.get().productId)
        let v = ProductVersion(versionId: newId(app.clock), productId: p.get().productId,
          versionNo: versionNo, effectiveFrom: window.fromIso)
        insertVersion(db, v, parseId(principal.user.userId).value())
        for b in bindings:
          insertBinding(db, v.versionId, b)

        let ctx = auditContextFor(principal, req, app.clock, "")
        discard appendAudit(db, newAuditEntry(ctx, "product.publish", "product",
          $p.get().productId, app.clock,
          businessDate = businessDateFor(db, institutionScope(), businessDateIso(app.clock)),
          after = %*{"code": p.get().code, "versionNo": versionNo,
                     "effectiveFrom": window.fromIso}))
        discard appendEvent(db, newOutboxEvent(newId(app.clock), "ProductPublished", "product",
          $p.get().productId, "product.published:" & $v.versionId,
          %*{"productId": $p.get().productId, "code": p.get().code,
             "productType": $p.get().productType, "versionNo": versionNo,
             "effectiveFrom": window.fromIso}))

        payload = detailJson(db, p.get())
        status = 201)
  except ValueError as e:
    if status == 0:
      status = 400
    if problemText.len == 0:
      problemText = e.msg
  except DbError as e:
    if "product_version_no_overlap" in e.msg or "conflicting key" in e.msg:
      status = 409
      problemText = "versi produk bertumpang tindih"
    elif "effective_to sudah pernah diisi" in e.msg:
      status = 409
      problemText = "versi berjalan sudah ditutup permintaan lain"
    elif "product_version_window_chk" in e.msg:
      status = 409
      problemText = "jendela versi tidak sah"
    else:
      status = 500
      problemText = "versi produk gagal disimpan"

  case status
  of 201: req.respondJson(201, payload)
  of 400: req.respondProblem(pkBadRequest, "Bad Request", problemText)
  of 403: req.respondInstitutionOnly(permissionProductManage)
  of 404: req.respondProblem(pkNotFound, "Not Found", problemText)
  of 409: req.respondProblem(pkConflict, "Conflict", problemText)
  else: req.respondProblem(pkInternal, "Internal Server Error", problemText)
