## Logika `paramgen` (spec §10.2–§10.4).
##
## Sumber kebenaran definisi parameter = `modules/<m>/seeds/params.yaml` (bentuknya seperti
## contoh di spec §10.3). Tool ini menghasilkan tiga artefak:
##
##   1. `shared/kernel/generated/paramkeys.nim`      — key bertipe + metadata (Nim)
##   2. `packages/contracts/src/generated/params.ts` — katalog untuk UI Parameter Admin
##   3. `packs/<pack>/generated/param_seed.sql`      — SQL seed idempotent per pack
##
## Aturan: hasil generate **deterministik** (urut by key) dan `--check` dipakai `./task check`
## untuk mendeteksi drift antara kode dan definisi.

import std/[os, strutils, algorithm, json, tables, sets, sequtils]
import yaml/tojson

type
  ParamgenError* = object of ValueError

  ParamDef* = object
    key*: string
    module*: string
    valueType*: string
    scopes*: seq[string]
    schema*: JsonNode
    enumValues*: seq[string]
    sensitivity*: string
    requiresApproval*: bool
    regulatoryRefs*: seq[string]
    descriptionKey*: string
    sinceVersion*: string
    effectiveFrom*: string
    defaultPack*: OrderedTable[string, JsonNode]

  Output* = object
    path*: string
    content*: string

const
  allowedTypes* = ["integer", "decimal", "string", "bool", "json", "enum", "money", "rate",
                   "date"]
  allowedScopes* = ["GLOBAL", "INSTITUTION", "BRANCH", "PRODUCT", "SEGMENT", "ROLE"]
  ## Subset JSON Schema yang dipahami validator runtime (modules/platform/domain/param.nim).
  ## Kunci lain ditolak di sini supaya definisi tidak menjanjikan validasi yang tak ada.
  knownSchemaKeywords* = ["type", "minimum", "maximum", "minLength", "maxLength", "enum",
                          "description"]
  schemaTypeNames* = ["integer", "number", "string", "boolean", "object", "array"]
  nimGeneratedPath* = "shared/kernel/generated/paramkeys.nim"
  tsGeneratedPath* = "packages/contracts/src/generated/params.ts"
  ## UUID sistem untuk seed pack: pack berasal dari repo yang di-review pada commit, bukan
  ## perubahan runtime. Dua UUID berbeda supaya invarian 4-eyes (checker <> maker) tetap utuh.
  seedMakerUuid* = "00000000-0000-0000-0000-0000000000a1"
  seedCheckerUuid* = "00000000-0000-0000-0000-0000000000a2"
  banner* = "JANGAN EDIT — dihasilkan tools/paramgen dari modules/*/seeds/params.yaml"

proc fail(msg: string) {.noreturn.} =
  raise newException(ParamgenError, msg)

proc isValidKey*(key: string): bool =
  ## spec §27.A: `modul.kategori.nama` — huruf kecil, angka, underscore, dipisah titik,
  ## minimal dua segmen, tiap segmen tidak kosong dan tidak diawali angka.
  if key.len == 0 or key[0] notin {'a' .. 'z'}:
    return false
  var segments = 1
  var segStart = true
  for i, c in key:
    if c == '.':
      if segStart or i == key.len - 1:
        return false
      inc segments
      segStart = true
    elif segStart:
      if c notin {'a' .. 'z'}:
        return false
      segStart = false
    elif c in {'a' .. 'z', '0' .. '9', '_'}:
      discard
    else:
      return false
  segments >= 2 and not segStart

proc nimTypeOf(valueType: string): string =
  case valueType
  of "integer": "int64"
  of "decimal", "money": "Money"
  of "rate": "Rate"
  of "string", "enum": "string"
  of "bool": "bool"
  of "json": "JsonNode"
  of "date": "BusinessDate"
  else: fail("tipe tanpa padanan Nim: " & valueType)

proc nimConstName*(key: string): string =
  "P_" & key.replace('.', '_')

proc jsonString(n: JsonNode): string =
  if n.isNil: "null" else: $n

proc parseDefsFromJson*(module: string, node: JsonNode): seq[ParamDef] =
  ## `node` adalah isi `params.yaml` satu modul: sequence of mapping.
  if node.isNil or node.kind == JNull:
    return @[]
  if node.kind != JArray:
    fail(module & ": params.yaml harus berupa daftar (sequence) definisi")

  for entry in node.items:
    if entry.kind != JObject:
      fail(module & ": tiap definisi harus mapping")
    var d = ParamDef(
      module: module,
      sensitivity: "NORMAL",
      requiresApproval: true,
      sinceVersion: "0.1.0",
      effectiveFrom: "1970-01-01",
      scopes: @[],
      regulatoryRefs: @[],
      enumValues: @[],
      defaultPack: initOrderedTable[string, JsonNode](),
    )
    for k, v in entry.pairs:
      case k
      of "key": d.key = v.getStr("")
      of "type": d.valueType = v.getStr("")
      of "scopes":
        if v.kind == JArray:
          for s in v.items: d.scopes.add s.getStr("")
      of "schema": d.schema = v
      of "sensitivity": d.sensitivity = v.getStr("NORMAL")
      of "regulatory_refs":
        if v.kind == JArray:
          for s in v.items: d.regulatoryRefs.add s.getStr("")
      of "requires_approval": d.requiresApproval = v.getBool(true)
      of "description_key": d.descriptionKey = v.getStr("")
      of "since_version": d.sinceVersion = v.getStr("0.1.0")
      of "effective_from": d.effectiveFrom = v.getStr("1970-01-01")
      of "default_pack":
        if v.kind == JObject:
          for pack, pv in v.pairs: d.defaultPack[pack] = pv
      of "enum":
        if v.kind == JArray:
          for s in v.items: d.enumValues.add s.getStr("")
      else:
        fail(module & "." & d.key & ": kunci tidak dikenal di params.yaml: " & k)

    if d.key.len == 0:
      fail(module & ": definisi tanpa `key`")
    if not isValidKey(d.key):
      fail(d.key & ": key tidak sesuai pola `modul.kategori.nama` (huruf kecil, dipisah titik)")
    if d.key.split('.')[0] != module:
      fail(d.key & ": segmen pertama key harus sama dengan nama modul (" & module & ")")
    if d.valueType.len == 0:
      fail(d.key & ": `type` wajib")
    if d.valueType == "duration":
      fail(d.key & ": tipe `duration` belum didukung sampai tipe Duration ada di shared/kernel")
    if d.valueType notin allowedTypes:
      fail(d.key & ": tipe tidak dikenal: " & d.valueType)
    if d.scopes.len == 0:
      fail(d.key & ": `scopes` wajib dan tidak boleh kosong")
    for s in d.scopes:
      if s notin allowedScopes:
        fail(d.key & ": scope tidak dikenal: " & s)
    if d.sensitivity notin ["NORMAL", "CRITICAL"]:
      fail(d.key & ": sensitivity harus NORMAL atau CRITICAL, bukan " & d.sensitivity)
    for r in d.regulatoryRefs:
      if not (r.len == 7 and r.startsWith("REG-") and
              r[4] in {'0' .. '9'} and r[5] in {'0' .. '9'} and r[6] in {'0' .. '9'}):
        fail(d.key & ": regulatory_refs harus berbentuk REG-NNN, bukan " & r)
    if d.valueType == "enum" and d.enumValues.len == 0:
      fail(d.key & ": tipe enum wajib punya `enum`")
    if not d.schema.isNil and d.schema.kind == JObject:
      for k, _ in d.schema.pairs:
        if k notin knownSchemaKeywords:
          fail(d.key & ": schema." & k & " tidak didukung validator runtime (didukung: " &
            knownSchemaKeywords.join(", ") & ")")
      if d.schema.hasKey("type") and d.schema["type"].getStr("") notin schemaTypeNames:
        fail(d.key & ": schema.type tidak dikenal: " & d.schema["type"].getStr(""))
      if d.schema.hasKey("minimum") and d.schema.hasKey("maximum"):
        if d.schema["minimum"].getFloat() > d.schema["maximum"].getFloat():
          fail(d.key & ": schema.minimum > schema.maximum")
    if d.descriptionKey.len == 0:
      d.descriptionKey = "param." & d.key
    result.add d

proc loadModuleDefs*(root, moduleDirName: string): seq[ParamDef] =
  let path = root / "modules" / moduleDirName / "seeds" / "params.yaml"
  if not fileExists(path):
    return @[]
  var content = ""
  try:
    content = readFile(path)
  except CatchableError as e:
    fail(path & ": tidak bisa dibaca: " & e.msg)
  var nodes: seq[JsonNode]
  try:
    nodes = loadToJson(content)
  except CatchableError as e:
    fail(path & ": YAML tidak valid: " & e.msg)
  if nodes.len == 0:
    return @[]
  result = parseDefsFromJson(moduleDirName, nodes[0])

proc loadAllDefs*(root: string): seq[ParamDef] =
  ## Semua modul, urut by key (deterministik).
  let modulesDir = root / "modules"
  if not dirExists(modulesDir):
    return @[]
  var modules: seq[string]
  for kind, path in walkDir(modulesDir):
    if kind == pcDir or kind == pcLinkToDir:
      modules.add extractFilename(path)
  sort(modules)
  var seen = initHashSet[string]()
  for m in modules:
    for d in loadModuleDefs(root, m):
      if d.key in seen:
        fail("key duplikat: " & d.key)
      seen.incl d.key
      result.add d
  result.sort(proc(a, b: ParamDef): int = cmp(a.key, b.key))

proc scopeLiteral(scope: string): string =
  case scope
  of "GLOBAL": "pstGlobal"
  of "INSTITUTION": "pstInstitution"
  of "BRANCH": "pstBranch"
  of "PRODUCT": "pstProduct"
  of "SEGMENT": "pstSegment"
  of "ROLE": "pstRole"
  else: fail("scope tidak dikenal: " & scope)

proc valueTypeLiteral(valueType: string): string =
  "pvt" & valueType[0].toUpperAscii() & valueType[1 .. ^1]

proc renderNim*(defs: seq[ParamDef]): string =
  var imports = initHashSet[string]()
  imports.incl("../paramkey")
  for d in defs:
    case d.valueType
    of "decimal", "money": imports.incl("../money")
    of "rate": imports.incl("../rate")
    of "date": imports.incl("../businessdate")
    of "json": imports.incl("std/json")
    else: discard
  var ordered: seq[string]
  for i in imports:
    ordered.add i
  ordered.sort()

  result = "## " & banner & "\n"
  result.add("##\n## Ubah definisi di `modules/<m>/seeds/params.yaml`, lalu jalankan `./task paramgen-gen`.\n\n")
  for i in ordered:
    result.add("import " & i & "\n")

  result.add("\nconst paramKeys*: seq[string] = @[\n")
  for d in defs:
    result.add("  \"" & d.key & "\",\n")
  result.add("]\n")

  for d in defs:
    result.add("\nconst " & nimConstName(d.key) & "* = ParamKey[" & nimTypeOf(d.valueType) &
      "](\"" & d.key & "\")\n")

  result.add("\nconst paramDefinitions*: seq[ParamDefinition] = @[\n")
  for d in defs:
    var scopes: seq[string]
    for s in d.scopes:
      scopes.add scopeLiteral(s)
    var refs: seq[string]
    for r in d.regulatoryRefs:
      refs.add "\"" & r & "\""
    result.add("  ParamDefinition(\n")
    result.add("    key: \"" & d.key & "\",\n")
    result.add("    module: \"" & d.module & "\",\n")
    result.add("    valueType: " & valueTypeLiteral(d.valueType) & ",\n")
    result.add("    scopes: {" & scopes.join(", ") & "},\n")
    result.add("    sensitivity: " & (if d.sensitivity == "CRITICAL": "psCritical"
      else: "psNormal") & ",\n")
    result.add("    requiresApproval: " & (if d.requiresApproval: "true" else: "false") & ",\n")
    result.add("    regulatoryRefs: @[" & refs.join(", ") & "],\n")
    result.add("    descriptionKey: \"" & d.descriptionKey & "\",\n")
    result.add("    sinceVersion: \"" & d.sinceVersion & "\",\n")
    result.add("  ),\n")
  result.add("]\n")

proc renderTs*(defs: seq[ParamDef]): string =
  result = "// " & banner & "\n\n"
  result.add("export type ParamValueType = " &
    allowedTypes.mapIt("\"" & it & "\"").join(" | ") & ";\n\n")
  result.add("export interface ParamDefinition {\n")
  result.add("  readonly key: string;\n  readonly module: string;\n")
  result.add("  readonly valueType: ParamValueType;\n")
  result.add("  readonly tsType: string;\n")
  result.add("  readonly scopes: readonly string[];\n")
  result.add("  readonly sensitivity: \"NORMAL\" | \"CRITICAL\";\n")
  result.add("  readonly requiresApproval: boolean;\n")
  result.add("  readonly regulatoryRefs: readonly string[];\n")
  result.add("  readonly descriptionKey: string;\n")
  result.add("  readonly jsonSchema: unknown;\n}\n\n")
  var arr = newJArray()
  for d in defs:
    var tsType = "string"
    case d.valueType
    of "bool": tsType = "boolean"
    of "json": tsType = "unknown"
    of "enum": tsType = d.enumValues.mapIt("\"" & it & "\"").join(" | ")
    else: tsType = "string" ## uang/rate/tanggal dikirim sebagai string (spec §13)
    var scopes = newJArray()
    for s in d.scopes: scopes.add(%s)
    var refs = newJArray()
    for r in d.regulatoryRefs: refs.add(%r)
    arr.add(%*{
      "key": d.key,
      "module": d.module,
      "valueType": d.valueType,
      "tsType": tsType,
      "scopes": scopes,
      "sensitivity": d.sensitivity,
      "requiresApproval": d.requiresApproval,
      "regulatoryRefs": refs,
      "descriptionKey": d.descriptionKey,
      "jsonSchema": (if d.schema.isNil: newJNull() else: d.schema),
    })
  result.add("export const paramDefinitions: readonly ParamDefinition[] = " &
    pretty(arr, 2) & " as const;\n")

proc packNames*(defs: seq[ParamDef]): seq[string] =
  var s = initHashSet[string]()
  for d in defs:
    for pack in d.defaultPack.keys: s.incl pack
  for p in s: result.add p
  result.sort()

proc seedScope*(d: ParamDef, pack: string): tuple[scopeType, scopeId: string] =
  ## Menentukan tempat nilai pack disemai. Aturannya sengaja ketat supaya tidak ada scope_id
  ## palsu:
  ##   1. bila parameter mengizinkan `SEGMENT` → (`SEGMENT`, nama pack);
  ##   2. selain itu bila mengizinkan `GLOBAL` → (`GLOBAL`, NULL);
  ##   3. selain itu → gagal: pack tidak punya tempat yang sah untuk nilai awal.
  ##      (Menambahkan `GLOBAL` ke `scopes` adalah keputusan pemilik parameter, bukan tebakan tool.)
  if "SEGMENT" in d.scopes:
    ("SEGMENT", pack)
  elif "GLOBAL" in d.scopes:
    ("GLOBAL", "")
  else:
    fail(d.key & ": pack `" & pack &
      "` tidak bisa disemai karena parameter tidak mengizinkan scope SEGMENT maupun GLOBAL")

proc definitionsPath*(): string =
  "packs/base/generated/param_definitions.sql"

proc valuesPath*(pack: string): string =
  "packs/" & pack & "/generated/param_values.sql"

proc renderDefinitionSql*(defs: seq[ParamDef]): string =
  ## Semua **definisi** parameter (pack-independent). Dipisah dari nilai pack supaya
  ## `param_value` tidak pernah menunjuk definisi yang belum ada (FK).
  result = "-- " & banner & "\n"
  result.add("-- Definisi parameter (pack-independent). Jalankan lebih dulu daripada\n")
  result.add("-- packs/<pack>/generated/param_values.sql. Idempotent.\n")
  result.add("--\n")
  result.add("-- NEEDS-COMPLIANCE-REVIEW: referensi regulasi & nilai default di sini belum\n")
  result.add("-- diverifikasi compliance officer (spec §1.8, §4).\n\n")
  if defs.len == 0:
    result.add("-- (belum ada definisi parameter)\n")
    return
  for d in defs:
    var scopes: seq[string]
    for sc in d.scopes: scopes.add("'" & sc & "'")
    var refs: seq[string]
    for r in d.regulatoryRefs: refs.add("'" & r & "'")
    # ARRAY[] tanpa cast ditolak Postgres ("cannot determine type of empty array").
    let refsSql = if refs.len == 0: "ARRAY[]::text[]" else: "ARRAY[" & refs.join(", ") & "]"
    result.add("INSERT INTO platform.param_definition\n")
    result.add("  (key, module, value_type, json_schema, allowed_scopes, description_key,\n")
    result.add("   regulatory_refs, sensitivity, requires_approval, since_version)\n")
    result.add("VALUES ('" & d.key & "', '" & d.module & "', '" & d.valueType & "', '" &
      (if d.schema.isNil: "{}" else: jsonString(d.schema)) &
      "'::jsonb, ARRAY[" & scopes.join(", ") & "], '" & d.descriptionKey & "', " &
      refsSql & ", '" & d.sensitivity & "', " &
      (if d.requiresApproval: "true" else: "false") & ", '" & d.sinceVersion & "')\n")
    result.add("ON CONFLICT (key) DO UPDATE SET\n")
    result.add("  module = EXCLUDED.module, value_type = EXCLUDED.value_type,\n")
    result.add("  json_schema = EXCLUDED.json_schema, allowed_scopes = EXCLUDED.allowed_scopes,\n")
    result.add("  description_key = EXCLUDED.description_key, regulatory_refs = EXCLUDED.regulatory_refs,\n")
    result.add("  sensitivity = EXCLUDED.sensitivity, requires_approval = EXCLUDED.requires_approval,\n")
    result.add("  since_version = EXCLUDED.since_version;\n\n")

proc renderValuesSql*(pack: string, defs: seq[ParamDef]): string =
  ## Nilai awal untuk satu segment pack. **Bukan** fallback kode (spec §10.3): aplikasi
  ## tetap gagal-cepat (`ParamNotFound`) bila parameter aktif tidak ada.
  result = "-- " & banner & "\n"
  result.add("-- Seed segment pack: " & pack & "\n")
  result.add("--\n")
  result.add("-- Prasyarat: packs/base/generated/param_definitions.sql sudah dijalankan.\n")
  result.add("-- Nilai di bawah ini NILAI AWAL untuk segmen ini, BUKAN fallback kode (spec §10.3).\n")
  result.add("-- Disemai sebagai ACTIVE oleh dua UUID sistem (pack generator & pack reviewer):\n")
  result.add("-- pack berasal dari repo yang di-review, bukan perubahan runtime.\n")
  result.add("-- NEEDS-COMPLIANCE-REVIEW: nilai yang menyentuh rate/ambang/denda wajib\n")
  result.add("-- diverifikasi compliance officer sebelum dipakai produksi (spec §1.8).\n")
  result.add("-- Idempotent: aman dijalankan berulang.\n\n")

  var withPack: seq[ParamDef]
  for d in defs:
    if d.defaultPack.hasKey(pack):
      withPack.add d
  if withPack.len == 0:
    result.add("-- (tidak ada definisi parameter untuk pack ini)\n")
    return

  for d in withPack:
    let (scopeType, scopeId) = seedScope(d, pack)
    let value = d.defaultPack[pack]
    result.add("INSERT INTO platform.param_value\n")
    result.add("  (param_value_id, key, scope_type, scope_id, value, effective_from, status,\n")
    result.add("   maker, checker, reason)\n")
    result.add("VALUES\n  (md5('" & d.key & "|" & pack & "')::uuid, '" & d.key & "', '" &
      scopeType & "', " & (if scopeId.len == 0: "NULL" else: "'" & scopeId & "'") & ", '" &
      jsonString(value) & "'::jsonb, DATE '" & d.effectiveFrom &
      "', 'ACTIVE', '" & seedMakerUuid & "', '" & seedCheckerUuid & "', 'segment pack seed')\n")
    result.add("ON CONFLICT (param_value_id) DO NOTHING;\n\n")

proc outputsOf*(root: string, defs: seq[ParamDef]): seq[Output] =
  result.add Output(path: nimGeneratedPath, content: renderNim(defs))
  result.add Output(path: tsGeneratedPath, content: renderTs(defs))
  result.add Output(path: definitionsPath(), content: renderDefinitionSql(defs))
  for pack in packNames(defs):
    result.add Output(path: valuesPath(pack), content: renderValuesSql(pack, defs))

proc runGen*(root: string): seq[Output] =
  ## Menulis semua artefak; mengembalikan daftar yang ditulis.
  let defs = loadAllDefs(root)
  result = outputsOf(root, defs)
  for o in result:
    let full = root / o.path
    createDir(parentDir(full))
    writeFile(full, o.content)

proc firstDiff(a, b: string): string =
  let la = a.splitLines()
  let lb = b.splitLines()
  let n = max(la.len, lb.len)
  for i in 0 ..< n:
    let x = if i < la.len: la[i] else: "<tidak ada>"
    let y = if i < lb.len: lb[i] else: "<tidak ada>"
    if x != y:
      return "baris " & $(i + 1) & ":\n      disk : " & x & "\n      baru : " & y
  ""

proc runCheck*(root: string, extraNote: var string): bool =
  ## Membandingkan hasil generate dengan berkas di disk. `extraNote` diisi ringkasan
  ## perbedaan bila ada (untuk pesan CLI).
  let defs = loadAllDefs(root)
  let expected = outputsOf(root, defs)
  result = true
  for o in expected:
    let full = root / o.path
    if not fileExists(full):
      result = false
      extraNote.add("\n  - " & o.path & ": belum ada (jalankan ./task paramgen-gen)")
    else:
      let disk = readFile(full)
      if disk != o.content:
        result = false
        extraNote.add("\n  - " & o.path & ": berbeda\n      " & firstDiff(disk, o.content))
  # berkas hasil generate yang tidak lagi punya definisi = yatim
  var expectedPaths: seq[string]
  for o in expected:
    expectedPaths.add o.path
  let packsDir = root / "packs"
  if dirExists(packsDir):
    for kind, dirPath in walkDir(packsDir):
      if kind != pcDir:
        continue
      let genDir = dirPath / "generated"
      if not dirExists(genDir):
        continue
      for genKind, f in walkDir(genDir):
        if genKind != pcFile or not f.endsWith(".sql"):
          continue
        let rel = relativePath(f, root).replace('\\', '/')
        if rel notin expectedPaths:
          result = false
          extraNote.add("\n  - " & rel & ": yatim (tidak ada definisi lagi) — hapus manual")

proc moduleSeedPaths*(root: string): seq[string] =
  let modulesDir = root / "modules"
  if not dirExists(modulesDir):
    return @[]
  for kind, path in walkDir(modulesDir):
    if kind == pcDir:
      let p = path / "seeds" / "params.yaml"
      if fileExists(p):
        result.add relativePath(p, root)
  result.sort()
