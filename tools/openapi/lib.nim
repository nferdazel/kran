## Pembaca & pemeriksa kontrak OpenAPI (spec §13: kontrak = sumber kebenaran; §20: contract test).
##
## Modul ini dipakai `apps/api/tests/tcontract.nim` (parity rute ↔ kontrak) dan
## `apps/api/tests/tapi.nim` (bentuk respons nyata vs skema kontrak). Yang diperiksa adalah
## **subset** JSON Schema 2020-12 yang benar-benar dipakai kontrak CBS (`type`, `required`,
## `properties`, `additionalProperties: false`, `enum`, `items`, `minimum`) — bukan validator
## penuh. Bila kontrak mulai memakai kata kunci lain, tambahkan di sini sekaligus test-nya;
## jangan diamkan (validator yang diam = gate palsu).

import std/[json, os, strutils, tables]

import yaml/tojson

const HttpMethods* = ["GET", "POST", "PUT", "PATCH", "DELETE"]

type
  Operation* = object
    path*: string
    httpMethod*: string ## huruf besar: "GET"
    operationId*: string

  DeclaredRoute* = object
    httpMethod*: string
    path*: string
    operationId*: string

  Contract* = object
    doc*: JsonNode
    operations*: seq[Operation]

proc key*(route: DeclaredRoute): string =
  route.httpMethod & " " & route.path

proc key*(op: Operation): string =
  op.httpMethod & " " & op.path

proc loadContract*(content, origin: string): Contract =
  var nodes: seq[JsonNode]
  try:
    nodes = loadToJson(content)
  except CatchableError as e:
    raise newException(ValueError, origin & ": YAML tidak valid: " & e.msg)
  if nodes.len == 0:
    raise newException(ValueError, origin & ": kontrak kosong")
  let doc = nodes[0]
  if not doc.hasKey("openapi"):
    raise newException(ValueError, origin & ": bukan dokumen OpenAPI (tidak ada `openapi`)")
  if not doc.hasKey("paths"):
    raise newException(ValueError, origin & ": tidak ada `paths`")
  result.doc = doc
  for path, item in doc["paths"]:
    for rawMethod, operation in item:
      let verb = rawMethod.toUpperAscii()
      if verb notin HttpMethods:
        continue
      result.operations.add Operation(
        path: path,
        httpMethod: verb,
        operationId: operation{"operationId"}.getStr(""),
      )

proc loadContractFile*(path: string): Contract =
  if not fileExists(path):
    raise newException(ValueError, path & ": kontrak tidak ditemukan")
  loadContract(readFile(path), path)

proc findings*(declared: seq[DeclaredRoute], contract: Contract): seq[string] =
  ## Bandingkan tabel rute implementasi dengan operasi di kontrak (dua arah).
  var byKey = initTable[string, Operation]()
  for op in contract.operations:
    byKey[op.key] = op

  var declaredKeys = initTable[string, DeclaredRoute]()
  for route in declared:
    let k = route.key
    if declaredKeys.hasKey(k):
      result.add "rute duplikat di tabel implementasi: " & k
    declaredKeys[k] = route

  for k, route in declaredKeys:
    if not byKey.hasKey(k):
      result.add "implementasi punya rute yang tidak ada di kontrak: " & k &
        " (operationId: " & route.operationId & ")"
    elif byKey[k].operationId != route.operationId:
      result.add "operationId tidak cocok untuk " & k & ": kontrak='" &
        byKey[k].operationId & "' implementasi='" & route.operationId & "'"

  for k, op in byKey:
    if not declaredKeys.hasKey(k):
      result.add "kontrak punya operasi yang tidak diimplementasikan: " & k &
        " (operationId: " & op.operationId & ")"

proc resolveRef*(contract: Contract, node: JsonNode): JsonNode =
  ## Ikuti `$ref` lokal (`#/components/...`); `$ref` eksternal dianggap error pemakaian.
  result = node
  var guard = 0
  while result.kind == JObject and result.hasKey("$ref"):
    inc guard
    if guard > 16:
      raise newException(ValueError, "rantai $ref terlalu panjang / melingkar")
    let target = result["$ref"].getStr("")
    if not target.startsWith("#/"):
      raise newException(ValueError, "$ref eksternal tidak didukung: " & target)
    var node = contract.doc
    for part in target[2 .. ^1].split('/'):
      if node.kind != JObject or not node.hasKey(part):
        raise newException(ValueError, "$ref tidak dapat diselesaikan: " & target)
      node = node[part]
    result = node

proc responseSchema*(contract: Contract, path, verb, status: string,
                     contentType = "application/json"): JsonNode =
  ## Skema isi respons (`application/json`) untuk satu operasi + status.
  var found = false
  for op in contract.operations:
    if op.path == path and op.httpMethod == verb.toUpperAscii():
      found = true
  if not found:
    raise newException(ValueError, "operasi tidak ada di kontrak: " & verb & " " & path)
  let paths = contract.doc["paths"][path][verb.toLowerAscii()]
  if not paths.hasKey("responses") or not paths["responses"].hasKey(status):
    raise newException(ValueError, "kontrak tidak mendefinisikan respons " & status &
      " untuk " & verb & " " & path)
  let response = contract.resolveRef(paths["responses"][status])
  if not response.hasKey("content") or not response["content"].hasKey(contentType):
    raise newException(ValueError, "respons " & status & " pada " & verb & " " & path &
      " tidak punya isi " & contentType)
  contract.resolveRef(response["content"][contentType]["schema"])

proc jsonTypeOf*(value: JsonNode): string =
  case value.kind
  of JObject: "object"
  of JArray: "array"
  of JString: "string"
  of JInt: "integer"
  of JFloat: "number"
  of JBool: "boolean"
  of JNull: "null"

proc typeMatches(expected, actual: string): bool =
  if expected == actual:
    return true
  # JSON Schema: integer memenuhi number; number tidak memenuhi integer.
  if expected == "number" and actual == "integer":
    return true
  false

proc validateValue*(contract: Contract, rawSchema: JsonNode, value: JsonNode,
                    location: string): seq[string] =
  ## Pemeriksaan bentuk (subset) satu nilai terhadap skema kontrak.
  let schema = contract.resolveRef(rawSchema)
  if schema.kind != JObject:
    return @[]

  if schema.hasKey("type"):
    let declared = schema["type"]
    var candidates: seq[string]
    if declared.kind == JString:
      candidates = @[declared.getStr()]
    elif declared.kind == JArray:
      for item in declared:
        candidates.add item.getStr("")
    let actual = jsonTypeOf(value)
    var ok = false
    for candidate in candidates:
      if typeMatches(candidate, actual):
        ok = true
    if not ok:
      result.add location & ": tipe '" & actual & "' tidak sesuai kontrak (" &
        candidates.join("|") & ")"

  if schema.hasKey("enum"):
    var ok = false
    for allowed in schema["enum"]:
      if allowed == value:
        ok = true
    if not ok:
      result.add location & ": nilai '" & $value & "' tidak ada di enum kontrak"

  if schema.hasKey("minimum") and value.kind in {JInt, JFloat}:
    if value.getFloat() < schema["minimum"].getFloat():
      result.add location & ": " & $value & " < minimum " & $schema["minimum"]

  case value.kind
  of JObject:
    if schema.hasKey("required"):
      for required in schema["required"]:
        let name = required.getStr("")
        if not value.hasKey(name):
          result.add location & ": properti wajib '" & name & "' tidak ada"
    var properties = newJObject()
    if schema.hasKey("properties"):
      properties = schema["properties"]
    if schema{"additionalProperties"}.kind == JBool and
        not schema["additionalProperties"].getBool():
      for name, _ in value:
        if not properties.hasKey(name):
          result.add location & ": properti '" & name & "' tidak didefinisikan kontrak"
    for name, child in value:
      if properties.hasKey(name):
        result.add contract.validateValue(properties[name], child, location & "." & name)
  of JArray:
    if schema.hasKey("items"):
      var index = 0
      for item in value:
        result.add contract.validateValue(schema["items"], item,
                                          location & "[" & $index & "]")
        inc index
  else:
    discard
