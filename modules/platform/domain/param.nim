## Aturan domain parameter (spec §10.2–§10.6) — murni, tanpa I/O.
##
## Tiga hal yang tinggal di sini:
##   1. **Urutan resolusi** scope (spesifik → umum) — satu tempat untuk semua modul.
##   2. **Validasi schema** (subset JSON Schema yang dipahami runtime; `tools/paramgen`
##      menolak kunci schema di luar subset ini saat build).
##   3. **Konversi nilai JSON → tipe Nim** (`int64`, `Money`, `Rate`, `BusinessDate`, …).
##
## Yang **tidak** di sini: akses DB, cache, maker-checker (itu `infrastructure/` +
## `application/`). Spesifikasi eksplisit: tidak ada fallback diam-diam (§10.6).

import std/[json, options, strutils]
import kernel/[paramkey, money, rate, businessdate, result]

type
  ParamErrorKind* = enum
    pekNotFound
    pekTypeMismatch
    pekSchemaViolation
    pekScopeNotAllowed
    pekPeriodConflict
    pekApprovalRequired
    pekNotPending
    pekDeprecated ## definisi parameter sengaja dipensiunkan (`param_definition.deprecated`); jalur
                  ## baca fail-closed (T-098) supaya key pensiun tidak pernah dipakai lagi.

  ParamError* = object
    kind*: ParamErrorKind
    key*: string
    detail*: string

  ParamStatus* = enum
    pvDraft = "DRAFT"
    pvPending = "PENDING"
    pvActive = "ACTIVE"
    pvSuperseded = "SUPERSEDED"
    pvRejected = "REJECTED"

  ParamCandidate* = object
    ## Satu nilai kandidat hasil query (ACTIVE pada `as_of`).
    paramValueId*: string
    scopeType*: ParamScopeType
    scopeId*: string ## "" = NULL (GLOBAL)
    value*: JsonNode
    effectiveFrom*: string
    effectiveTo*: string

  ScopeValueLookup* = proc(scopeType: ParamScopeType): Option[string] {.closure.}
    ## Id scope yang diminta pemanggil untuk tipe scope tertentu (O-012).
    ##   `some(id)` — tipe ini diminta dengan id tersebut. `some("")` **sah** dan berarti "id kosong",
    ##               yaitu institusi akar (nilai ber-`scope_id` NULL).
    ##   `none`     — tipe ini tidak diminta; tidak pernah cocok, jadi tidak ada fallback diam-diam
    ##               ke scope lain (diuji di `tparam`/`itparam`).

proc paramError*(kind: ParamErrorKind, key, detail: string): ParamError =
  ParamError(kind: kind, key: key, detail: detail)

proc `$`*(e: ParamError): string =
  ($e.kind) & " [" & e.key & "]: " & e.detail

proc resolutionRank*(s: ParamScopeType): int =
  ## 0 = paling spesifik. Urutan diambil dari kernel (`paramScopeResolutionOrder`) supaya
  ## hanya ada satu definisi (spec §10.2).
  for i, t in paramScopeResolutionOrder:
    if t == s:
      return i
  high(int)

proc resolveCandidate*(candidates: openArray[ParamCandidate],
                       lookup: ScopeValueLookup): Option[ParamCandidate] =
  ## Memilih kandidat paling spesifik yang cocok dengan scope pemanggil.
  ## `GLOBAL` selalu cocok; scope lain hanya bila pemanggil **meminta** tipe itu dengan id yang sama.
  ## Id kosong tetap "diminta" (`institutionScope()` → `some("")`), sehingga nilai institusi akar
  ## (`scope_id` NULL) terjangkau — sebelum O-012 kasus itu tidak bisa dibedakan dari "tidak diminta".
  var bestRank = high(int)
  for c in candidates:
    if c.scopeType != pstGlobal:
      let wanted = lookup(c.scopeType)
      if wanted.isNone or wanted.get() != c.scopeId:
        continue
    let rank = resolutionRank(c.scopeType)
    if rank < bestRank:
      bestRank = rank
      result = some(c)

const maxJsonNodeDepth* = 8 ## nomagic:ok batas teknis kedalaman nilai JSON parameter

proc jsonFormProblem*(value: JsonNode; depth = 0): string =
  ## Bentuk JSON yang boleh disimpan sebagai nilai parameter `json` (O-087, keputusan 31 Okt 2026):
  ## objek/array/string/angka/boolean, **tanpa `null`**, dan kedalaman maksimum `maxJsonNodeDepth`.
  ##
  ## Ini batas bentuk, bukan schema bisnis: arti struktur tetap milik konsumennya. `null` ditolak
  ## karena ambigu (nilai kosong vs parameter tidak ada), dan kedalaman dibatasi supaya konsumen
  ## tidak perlu memanggil parser rekursif tanpa batas atas data yang mereka terima.
  if value.isNil:
    return "nilai JSON kosong"
  if depth > maxJsonNodeDepth:
    return "kedalaman JSON melebihi " & $maxJsonNodeDepth
  case value.kind
  of JNull:
    return "null tidak diterima di dalam nilai JSON"
  of JObject:
    for _, child in value:
      let problem = jsonFormProblem(child, depth + 1)
      if problem.len > 0:
        return problem
  of JArray:
    for child in value:
      let problem = jsonFormProblem(child, depth + 1)
      if problem.len > 0:
        return problem
  of JInt, JBool, JString: discard
  of JFloat:
    # `NaN`/`Inf` tidak bisa lahir dari parser JSON standar, tetapi bisa datang dari pemanggil
    # library; menolaknya lebih baik daripada menyimpannya sebagai token yang tidak sah di jsonb.
    let f = value.getFloat()
    if f != f:
      return "angka JSON bukan bilangan terhingga"
  ""

proc jsonTypeMatches*(want: string, value: JsonNode): bool =
  case want
  of "integer": value.kind == JInt
  of "number": value.kind in {JInt, JFloat}
  of "string": value.kind == JString
  of "boolean": value.kind == JBool
  of "object": value.kind == JObject
  of "array": value.kind == JArray
  else: false

proc isDecimalString*(s: string): bool =
  ## Bentuk angka desimal `-?digit+(.digit+)?` — bentuk nilai money/rate (spec §13: uang dan rate
  ## adalah **string** desimal, bukan angka JSON). Tanggal, enum, dan teks bebas tidak cocok, jadi
  ## pemeriksaan batas numerik di bawah tidak menyentuh tipe lain.
  var i = 0
  if s.len == 0:
    return false
  if s[0] == '-':
    i = 1
  if i >= s.len:
    return false
  var digits = 0
  var dots = 0
  while i < s.len:
    let c = s[i]
    if c in {'0' .. '9'}:
      inc digits
    elif c == '.':
      inc dots
    else:
      return false
    inc i
  digits > 0 and dots <= 1

proc validateAgainstSchema*(schema: JsonNode, value: JsonNode): string =
  ## Mengembalikan "" bila nilai memenuhi schema, atau pesan masalah.
  ## Subset yang dipahami: `type`, `minimum`, `maximum`, `minLength`, `maxLength`, `enum`.
  if schema.isNil or schema.kind != JObject:
    return ""
  if value.isNil or value.kind == JNull:
    return "nilai kosong (null) tidak diterima"
  if schema.hasKey("type"):
    let want = schema["type"].getStr("")
    if not jsonTypeMatches(want, value):
      return "tipe nilai tidak sesuai schema (diharapkan " & want & ")"
  if value.kind in {JInt, JFloat}:
    let v = value.getFloat()
    if schema.hasKey("minimum") and v < schema["minimum"].getFloat():
      return "nilai " & $v & " di bawah minimum " & $schema["minimum"].getFloat()
    if schema.hasKey("maximum") and v > schema["maximum"].getFloat():
      return "nilai " & $v & " di atas maximum " & $schema["maximum"].getFloat()
  if value.kind == JString and (schema.hasKey("minimum") or schema.hasKey("maximum")):
    # T-133/API-11: nilai money/rate adalah string desimal, sehingga cabang numerik di atas tidak
    # pernah menjangkaunya — akibatnya `limit_withdrawal` = "-1.00" lolos submit **dan** approve
    # walau schema-nya `{"minimum": 0}`. Perbandingan di sini hanya batas (bukan aritmetika uang),
    # dan hanya untuk string yang memang berbentuk desimal.
    let raw = value.getStr("")
    if isDecimalString(raw):
      let v = parseFloat(raw)
      if schema.hasKey("minimum") and v < schema["minimum"].getFloat():
        return "nilai " & raw & " di bawah minimum " & $schema["minimum"].getFloat()
      if schema.hasKey("maximum") and v > schema["maximum"].getFloat():
        return "nilai " & raw & " di atas maximum " & $schema["maximum"].getFloat()
  if value.getStr("").len > 0 or value.kind == JString:
    let s = value.getStr("")
    if schema.hasKey("minLength") and s.len < schema["minLength"].getInt():
      return "panjang nilai " & $s.len & " kurang dari minLength"
    if schema.hasKey("maxLength") and s.len > schema["maxLength"].getInt():
      return "panjang nilai " & $s.len & " melebihi maxLength"
    if schema.hasKey("enum"):
      var allowed = false
      for e in schema["enum"]:
        if e.getStr("") == s:
          allowed = true
      if not allowed:
        return "nilai \"" & s & "\" tidak ada di daftar enum"

proc typeErr[T](key: string, value: JsonNode, want: string,
                extra = ""): Result[T, ParamError] =
  err[T, ParamError](paramError(pekTypeMismatch, key,
    "diharapkan " & want & ", dapat " & ($value.kind) & (if extra.len > 0: " — " &
        extra else: "")))

proc coerceTo*[T](key: string, value: JsonNode): Result[T, ParamError] =
  ## Konversi nilai JSON ke tipe Nim yang diminta `ParamKey[T]`.
  ##
  ## Aturan yang disengaja (spec §13): **money, rate, date adalah string**, bukan angka JSON —
  ## angka JSON adalah float di banyak bahasa dan menghilangkan presisi desimal.
  when T is int64:
    if value.kind == JInt:
      ok[T, ParamError](int64(value.getBiggestInt()))
    else:
      typeErr[T](key, value, "integer (angka JSON)")
  elif T is bool:
    if value.kind == JBool:
      ok[T, ParamError](value.getBool())
    else:
      typeErr[T](key, value, "boolean")
  elif T is string:
    if value.kind == JString:
      ok[T, ParamError](value.getStr())
    else:
      typeErr[T](key, value, "string")
  elif T is Money:
    if value.kind != JString:
      typeErr[T](key, value, "string desimal (money)")
    else:
      let parsed = moneyFromString(value.getStr())
      if parsed.isErr:
        typeErr[T](key, value, "string desimal (money)", $parsed.error())
      else:
        ok[T, ParamError](parsed.value())
  elif T is Rate:
    if value.kind != JString:
      typeErr[T](key, value, "string persen (rate)")
    else:
      let parsed = rateFromPercentString(value.getStr())
      if parsed.isErr:
        typeErr[T](key, value, "string persen (rate)", $parsed.error())
      else:
        ok[T, ParamError](parsed.value())
  elif T is BusinessDate:
    if value.kind != JString:
      typeErr[T](key, value, "string tanggal ISO (YYYY-MM-DD)")
    else:
      let parsed = parseBusinessDate(value.getStr())
      if parsed.isErr:
        typeErr[T](key, value, "string tanggal ISO (YYYY-MM-DD)", $parsed.error())
      else:
        ok[T, ParamError](parsed.value())
  elif T is JsonNode:
    ok[T, ParamError](value)
  else:
    {.error: "coerceTo: tipe tidak didukung — tambahkan cabang eksplisit di domain/param.nim".}

proc checkedValue*[T](key: string, value: JsonNode, schema: JsonNode): Result[T, ParamError] =
  ## Validasi schema **lalu** konversi (urutan ini penting supaya pesan errornya jelas).
  let masalah = validateAgainstSchema(schema, value)
  if masalah.len > 0:
    return err[T, ParamError](paramError(pekSchemaViolation, key, masalah))
  coerceTo[T](key, value)

proc valueMatchesType*(valueType: ParamValueType, value: JsonNode): bool =
  ## Pemeriksaan bentuk JSON per tipe parameter (spec §10.2 value_type).
  ## money/rate/date/decimal = **string** (spec §13: uang & rate sebagai string desimal/persen).
  case valueType
  of pvtInteger: value.kind == JInt
  of pvtBool: value.kind == JBool
  of pvtString, pvtEnum: value.kind == JString
  of pvtMoney, pvtRate, pvtDecimal, pvtDate: value.kind == JString
  of pvtJson: true

proc typeShapeMessage*(valueType: ParamValueType): string =
  case valueType
  of pvtInteger: "integer (angka JSON)"
  of pvtBool: "boolean"
  of pvtString, pvtEnum: "string"
  of pvtMoney, pvtDecimal: "string desimal"
  of pvtRate: "string persen"
  of pvtDate: "string tanggal ISO (YYYY-MM-DD)"
  of pvtJson: "JSON apa saja"

type
  ParamSnapshot* = object
    ## Nilai aktif + definisi minimum yang diperlukan untuk konversi bertipe (spec §10.4).
    ## Dipakai bersama cache in-proc supaya aturan validasi tetap satu tempat.
    value*: JsonNode
    valueType*: ParamValueType
    schema*: JsonNode

proc checkedSnapshot*[T](key: string, snapshot: ParamSnapshot): Result[T, ParamError] =
  ## Validasi bentuk tipe **dan** schema, lalu konversi (urutan ini supaya pesan errornya jelas).
  if not valueMatchesType(snapshot.valueType, snapshot.value):
    return err[T, ParamError](paramError(pekTypeMismatch, key,
      "nilai tidak sesuai tipe " & valueTypeName(snapshot.valueType) & ": " & $snapshot.value))
  checkedValue[T](key, snapshot.value, snapshot.schema)
