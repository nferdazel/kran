import std/[json, os, tables, unittest]

import openapi/lib

import ../src/routes

## Contract test parity (spec §13, §20): tabel rute implementasi harus **persis** sama dengan
## operasi di `packages/contracts/openapi/kran-api.yaml` (method, path, operationId).
##
## Test ini murni (tidak menyalakan server/DB) sehingga ikut jalan di CI mana pun; bentuk respons
## nyata diperiksa `tapi.nim`.

const ContractPath* = "packages/contracts/openapi/kran-api.yaml"

proc declaredRoutes(): seq[DeclaredRoute] =
  for spec in allRoutes():
    result.add DeclaredRoute(httpMethod: $spec.httpMethod, path: spec.path,
                             operationId: spec.operationId)

suite "kontrak OpenAPI == tabel rute implementasi":
  test "kontrak ada di repo (path relatif dari root repo)":
    check fileExists(ContractPath)

  test "tidak ada rute yang hanya ada di satu sisi":
    let contract = loadContractFile(ContractPath)
    let findings = findings(declaredRoutes(), contract)
    check findings.len == 0
    if findings.len > 0:
      for finding in findings:
        checkpoint finding

  test "kontrak mendefinisikan operasi (bukan dokumen kosong)":
    let contract = loadContractFile(ContractPath)
    check contract.operations.len == allRoutes().len
    check contract.operations.len > 0

  test "setiap operasi punya operationId unik":
    let contract = loadContractFile(ContractPath)
    var seen = initTable[string, bool]()
    for op in contract.operations:
      check op.operationId.len > 0
      check not seen.getOrDefault(op.operationId, false)
      seen[op.operationId] = true

proc operationJson(doc: JsonNode, operationId: string): JsonNode =
  for _, item in doc["paths"]:
    for _, op in item:
      if op{"operationId"}.getStr("") == operationId:
        return op
  nil

suite "tiga endpoint pembuat objek memakai idempotensi":
  test "header wajib, 409 terdeklarasi, replay 200, 201 tanpa header replay":
    let doc = loadContractFile(ContractPath).doc
    let header = doc["components"]["parameters"]["IdempotencyKey"]
    check header["name"].getStr() == "Idempotency-Key"
    check header["in"].getStr() == "header"
    check header["required"].getBool() == true

    for operationId in ["createParty", "ratePartyRisk", "submitParamChange"]:
      let op = operationJson(doc, operationId)
      check op != nil
      var memakaiHeader = false
      for parameter in op["parameters"]:
        if parameter{"$ref"}.getStr("") == "#/components/parameters/IdempotencyKey":
          memakaiHeader = true
      check memakaiHeader
      check op["responses"].hasKey("409")
      check op["responses"].hasKey("200")
      check op["responses"]["200"]["headers"].hasKey("Idempotent-Replayed")
      check not op["responses"]["201"].hasKey("headers")
