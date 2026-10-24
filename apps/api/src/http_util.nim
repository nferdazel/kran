## Utilitas respons HTTP (spec §13): JSON biasa & `application/problem+json`, plus pembacaan
## permintaan (badan JSON, parameter path/query) supaya handler tidak mengulang kode parsing.

import std/[json, options, strutils]

import mummy
import mummy/routers

import kernel/ids

const
  ContentTypeJson* = "application/json"
  ContentTypeProblem* = "application/problem+json"

var scopeStatus {.threadvar.}: int
var scopeTrace {.threadvar.}: string

proc beginRequestScope*(req: Request) =
  ## Awal satu permintaan (dipanggil pembungkus di `server.nim`): status direset dan trace id
  ## ditetapkan **sekali**, sehingga amplop problem, access log, dan audit memakai korelasi yang
  ## sama (T-130/API-6). Threadvar cukup karena Mummy memproses satu permintaan per worker thread
  ## pada satu waktu.
  scopeStatus = 0
  scopeTrace = req.headers["X-Request-Id"].strip()
  if scopeTrace.len == 0:
    scopeTrace = newCorrelationId()

proc requestScopeTrace*(): string =
  ## Trace id permintaan yang sedang dilayani; "" di luar siklus permintaan (test/CLI).
  scopeTrace

proc requestScopeStatus*(): int =
  ## Status respons terakhir yang dicatat helper di modul ini; 0 = handler tidak lewat helper.
  scopeStatus

proc recordStatus*(status: int) {.inline.} =
  scopeStatus = status

proc headersWithType*(contentType: string): HttpHeaders =
  ## Header dasar setiap respons API. `no-store` wajib: respons memuat data sesi/PII (unmask,
  ## slip, statement) dan browser terminal bersama tidak boleh menyimpannya (T-128/SEC-3).
  result = emptyHttpHeaders()
  result["Content-Type"] = contentType
  result["Cache-Control"] = "no-store"

proc sameOrigin*(origin, host: string): bool =
  ## True bila `Origin` menunjuk host yang sama dengan header `Host`.
  ##
  ## Dipakai gerbang WebSocket (T-128/SEC-4): cookie `SameSite=Strict` sudah menahan sebagian besar
  ## cross-site, tetapi handshake WS tidak selalu diperlakukan sama oleh browser. Origin tanpa skema
  ## yang dikenal, atau host berbeda, ditolak. `Origin` kosong (klien non-browser) diloloskan dan
  ## tetap harus punya cookie sesi yang sah.
  if origin.len == 0:
    return true
  var o = origin.toLowerAscii()
  var matched = false
  for prefix in ["https://", "http://"]:
    if o.startsWith(prefix):
      o = o[prefix.len .. ^1]
      matched = true
      break
  if not matched:
    return false
  let slash = o.find('/')
  if slash >= 0:
    o = o[0 ..< slash]
  o == host.toLowerAscii()

proc respondJson*(req: Request, status: int, body: JsonNode) =
  ## Satu tempat menulis respons JSON supaya header konsisten.
  recordStatus(status)
  req.respond(status, headersWithType(ContentTypeJson), $body)

proc respondRaw*(req: Request, status: int, headers: HttpHeaders, body: string) =
  ## Respons yang butuh header sendiri (mis. `Set-Cookie` sesi, 204 tanpa badan). Tetap mencatat
  ## status supaya access log tidak kehilangan baris (T-130/API-6).
  recordStatus(status)
  req.respond(status, headers, body)

proc respondJsonHeaders*(req: Request, status: int, body: JsonNode,
    extra: openArray[(string, string)]) =
  ## JSON + header tambahan (mis. `Idempotent-Replayed` pada replay, `Retry-After`).
  var headers = headersWithType(ContentTypeJson)
  for (key, value) in extra:
    headers[key] = value
  recordStatus(status)
  req.respond(status, headers, $body)

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

proc isIsoDate*(s: string): bool =
  ## Tanggal `YYYY-MM-DD` yang benar-benar ada (mis. `2026-02-31` ditolak, bukan diteruskan ke
  ## cast `?::date` yang akan melempar `DbError` — kesalahan pemanggil tidak boleh jadi 500).
  ## Rentang tahun dibatasi hanya pada yang ditulis 4 digit; tidak ada batas bisnis di sini.
  if s.len != 10 or s[4] != '-' or s[7] != '-':
    return false
  for i, c in s:
    if i == 4 or i == 7:
      continue
    if c notin {'0' .. '9'}:
      return false
  let year = parseInt(s[0 .. 3])
  let month = parseInt(s[5 .. 6])
  let day = parseInt(s[8 .. 9])
  if year < 1 or month < 1 or month > 12 or day < 1:
    return false
  var maxDay: int
  case month
  of 2:
    let leap = (year mod 4 == 0 and year mod 100 != 0) or year mod 400 == 0
    maxDay = if leap: 29 else: 28
  of 4, 6, 9, 11: maxDay = 30
  else: maxDay = 31
  day <= maxDay

