## Utilitas respons HTTP (spec §13): JSON biasa & `application/problem+json`, plus pembacaan
## permintaan (badan JSON, parameter path/query) supaya handler tidak mengulang kode parsing.

import std/[json, options]

import mummy
import mummy/routers

const
  ContentTypeJson* = "application/json"
  ContentTypeProblem* = "application/problem+json"

proc headersWithType*(contentType: string): HttpHeaders =
  result = emptyHttpHeaders()
  result["Content-Type"] = contentType

proc respondJson*(req: Request, status: int, body: JsonNode) =
  ## Satu tempat menulis respons JSON supaya header konsisten.
  req.respond(status, headersWithType(ContentTypeJson), $body)

proc jsonField*(node: JsonNode, name: string): string =
  ## Nilai string sebuah field; "" bila tidak ada atau bukan string. Field bertipe salah
  ## diperlakukan "tidak diisi" — handler yang memutuskan itu 400 (satu aturan validasi).
  if node.kind != JObject or not node.hasKey(name) or node[name].kind != JString:
    return ""
  node[name].getStr()

proc parseJsonBody*(req: Request): Option[JsonNode] =
  ## Badan permintaan sebagai JSON. `none` bila kosong atau bukan JSON yang sah.
  if req.body.len == 0:
    return none(JsonNode)
  try:
    some(parseJson(req.body))
  except JsonParsingError, ValueError:
    none(JsonNode)

proc pathParam*(req: Request, name: string): string =
  ## Parameter path gaya router Mummy (`@nama` pada pola rute, `{nama}` pada kontrak).
  for (key, value) in req.pathParams:
    if key == name:
      return value
  ""

proc queryValue*(req: Request, name: string): string =
  ## Nilai parameter query atau "" bila tidak ada.
  try:
    req.queryParams[name]
  except KeyError:
    ""
