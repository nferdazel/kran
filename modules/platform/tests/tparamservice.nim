## Test murni layanan parameter + guard drift (T-016). Tanpa DB: sumber nilai dipalsukan.

import std/[json, options, sequtils, strutils, tables, unittest]

import kernel/[money, paramkey, result]
import kernel/generated/paramkeys
import platform/application/[param_cache, param_drift, param_service]
import platform/domain/[param, scope]

type Sumber = object
  ## Sumber palsu: menghitung berapa kali nilai benar-benar diambil (untuk membuktikan cache).
  calls: int
  values: Table[string, JsonNode]
  schemas: Table[string, JsonNode]
  types: Table[string, ParamValueType]
  failWith: Option[ParamError]


proc sumberPalsu(): Sumber =
  Sumber(calls: 0, values: initTable[string, JsonNode](),
    schemas: initTable[string, JsonNode](), types: initTable[string, ParamValueType]())

proc tambah(s: var Sumber; key: string; value: JsonNode; valueType: ParamValueType;
            schema: JsonNode) =
  s.values[key] = value
  s.schemas[key] = schema
  s.types[key] = valueType

proc sourceOf(s: var Sumber): ParamSource =
  let ptrSumber = addr s
  result.fetch = proc(key, asOf: string; scope: ScopeRef): Result[ParamSnapshot, ParamError] =
    inc ptrSumber.calls
    if ptrSumber.failWith.isSome:
      return err[ParamSnapshot, ParamError](ptrSumber.failWith.get())
    if not ptrSumber.values.hasKey(key):
      return err[ParamSnapshot, ParamError](paramError(pekNotFound, key, "tidak ada"))
    ok[ParamSnapshot, ParamError](ParamSnapshot(value: ptrSumber.values[key],
      valueType: ptrSumber.types[key], schema: ptrSumber.schemas[key]))

const
  keyInt = P_platform_security_session_idle_minutes
  keyJson = P_platform_calendar_weekend_days
  asOf = "2026-10-13"

let instScope = institutionScope()

proc packSchema(key: string): JsonNode =
  ## Batas schema sebuah parameter dibaca dari artefak `paramgen`
  ## (`packs/base/generated/param_definitions.sql`) supaya test tidak menyalin angkanya
  ## (O-042). Test murni ini tidak menyentuh DB, jadi sumbernya berkas hasil generate.
  const path = "packs/base/generated/param_definitions.sql"
  for line in readFile(path).splitLines:
    if not line.startsWith("VALUES ('" & key & "'"):
      continue
    let jsonbPos = line.find("'::jsonb")
    if jsonbPos < 0:
      continue
    let start = line[0 ..< jsonbPos].rfind('\'')
    return parseJson(line[start + 1 ..< jsonbPos])
  raise newException(ValueError, "definisi parameter tidak ada di " & path & ": " & key)

suite "cache parameter":
  test "hit/miss terhitung; invalidasi per key & seluruhnya":
    var cache = newParamCache()
    let ck = cacheKey("a.b.c", instScope, asOf)
    check cache.get(ck).isNone
    check cache.misses == 1
    cache.put(ck, ParamSnapshot(value: %*1, valueType: pvtInteger, schema: %*{"type": "integer"}))
    check cache.get(ck).isSome
    check cache.hits == 1
    check cache.size == 1
    # kunci berbeda scope/tanggal = entri terpisah
    cache.put(cacheKey("a.b.c", branchScope("br-1"), asOf), ParamSnapshot(value: %*2))
    cache.put(cacheKey("a.b.c", instScope, "2026-10-14"), ParamSnapshot(value: %*3))
    check cache.size == 3
    check cache.invalidateKey("a.b.c") == 3
    check cache.size == 0
    cache.put(ck, ParamSnapshot(value: %*1))
    check cache.invalidateAll() == 1
    check cache.size == 0

suite "layanan parameter: akses bertipe + cache":
  test "nilai diambil sekali lalu dilayani cache":
    var sumber = sumberPalsu()
    sumber.tambah(keyString(keyInt), %*30, pvtInteger, %*{"type": "integer", "minimum": 1})
    let service = newParamService(sourceOf(sumber))
    let pertama = service.get(keyInt, asOf, instScope)
    check pertama.isOk
    check pertama.value() == 30
    let kedua = service.get(keyInt, asOf, instScope)
    check kedua.value() == 30
    check sumber.calls == 1 # yang kedua dari cache
    check service.cache.hits == 1

  test "tanggal/scope berbeda = entri cache berbeda (nilai efektif-dated aman)":
    var sumber = sumberPalsu()
    sumber.tambah(keyString(keyInt), %*30, pvtInteger, %*{"type": "integer"})
    let service = newParamService(sourceOf(sumber))
    discard service.get(keyInt, asOf, instScope)
    discard service.get(keyInt, "2026-10-14", instScope)
    discard service.get(keyInt, asOf, branchScope("br-1"))
    check sumber.calls == 3

  test "invalidasi memaksa pengambilan ulang (jalur NOTIFY)":
    var sumber = sumberPalsu()
    sumber.tambah(keyString(keyInt), %*30, pvtInteger, %*{"type": "integer"})
    let service = newParamService(sourceOf(sumber))
    check service.get(keyInt, asOf, instScope).value() == 30
    sumber.tambah(keyString(keyInt), %*45, pvtInteger, %*{"type": "integer"})
    check service.get(keyInt, asOf, instScope).value() == 30 # masih cache
    check service.invalidate(keyString(keyInt)) == 1
    check service.get(keyInt, asOf, instScope).value() == 45
    check sumber.calls == 2

  test "key tak terdaftar → not found (tidak ada fallback)":
    var sumber = sumberPalsu()
    let service = newParamService(sourceOf(sumber))
    let hasil = service.get(keyInt, asOf, instScope)
    check hasil.isErr
    check hasil.error().kind == pekNotFound
    check service.cache.misses == 1 and service.cache.hits == 0

  test "nilai melanggar schema → error schema, bukan nilai diam-diam":
    var sumber = sumberPalsu()
    # Schema diambil dari definisi pack (bukan disalin) supaya test mengikuti seed (O-042).
    sumber.tambah(keyString(keyInt), %*0, pvtInteger, packSchema(keyString(keyInt)))
    let service = newParamService(sourceOf(sumber))
    let hasil = service.get(keyInt, asOf, instScope)
    check hasil.isErr
    check hasil.error().kind == pekSchemaViolation

  test "tipe nilai tidak cocok definisi → error tipe":
    var sumber = sumberPalsu()
    sumber.tambah(keyString(keyInt), %*"30", pvtInteger, %*{"type": "integer"})
    let service = newParamService(sourceOf(sumber))
    let hasil = service.get(keyInt, asOf, instScope)
    check hasil.isErr
    check hasil.error().kind == pekTypeMismatch

  test "nilai JSON (array) tetap bisa diambil lewat cache":
    var sumber = sumberPalsu()
    sumber.tambah(keyString(keyJson), parseJson("[6,7]"), pvtJson, %*{"type": "array"})
    let service = newParamService(sourceOf(sumber))
    let hasil = service.get(keyJson, asOf, instScope)
    check hasil.isOk
    check hasil.value() == parseJson("[6,7]")

suite "guard drift kode vs DB":
  proc def(key: string; valueType = pvtInteger; module = "platform";
           scopes: set[ParamScopeType] = {pstGlobal}; sensitivity = psNormal;
           requiresApproval = true): ParamDefinition =
    ParamDefinition(key: key, module: module, valueType: valueType, scopes: scopes,
      sensitivity: sensitivity, requiresApproval: requiresApproval,
      descriptionKey: "param." & key, regulatoryRefs: @[], sinceVersion: "0.1.0")

  test "sama → tanpa temuan":
    check compareDefinitions([def("a.b.c")], [def("a.b.c")]).len == 0

  test "ada di kode belum di DB / sebaliknya":
    let temuan = compareDefinitions([def("a.b.c"), def("a.b.d")], [def("a.b.c"), def("a.b.e")])
    check temuan.len == 2
    check temuan[0].kind == dkMissingInDb
    check temuan[0].key == "a.b.d"
    check temuan[1].kind == dkMissingInCode
    check temuan[1].key == "a.b.e"
    check driftKeys(temuan) == @["a.b.d", "a.b.e"]

  test "tipe/module/scope/sensitivitas/approval yang berbeda terdeteksi":
    let temuan = compareDefinitions(
      [def("a.b.c")],
      [def("a.b.c", valueType = pvtString, module = "lending", scopes = {pstGlobal, pstBranch},
        sensitivity = psCritical, requiresApproval = false)])
    let kinds = temuan.mapIt(it.kind)
    check dkTypeMismatch in kinds
    check dkModuleMismatch in kinds
    check dkScopeMismatch in kinds
    check dkSensitivityMismatch in kinds
    check dkApprovalMismatch in kinds

  test "scope dibandingkan sebagai himpunan (urutan tidak penting)":
    check compareDefinitions([def("a.b.c", scopes = {pstBranch, pstGlobal})],
      [def("a.b.c", scopes = {pstGlobal, pstBranch})]).len == 0

  test "daftar kosong di kedua sisi → tanpa temuan":
    check compareDefinitions([], []).len == 0
