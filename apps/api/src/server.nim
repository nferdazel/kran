## Perakitan server HTTP (Mummy — ADR-002/D-019) dan pemilihan role proses (spec §12.5, §21.4).
##
## Handler dipanggil di **thread Mummy**, jadi boleh blocking — penting karena `db_connector`
## sinkron diwajibkan spec §12.1 (satu query sinkron tidak boleh membekukan seluruh API).

import std/[cpuinfo, strutils, times]

import mummy
import mummy/routers

import "platform-lib/db/pool"
import "platform-lib/log"

import ./context
import ./close_guard
import ./drain
import ./events
import ./health
import ./http_util
import ./problem
import ./routes

type
  Role* = enum
    roleApi = "api"
    roleWorker = "worker"
    roleCtl = "ctl"
    roleMigrate = "migrate"

proc parseRole*(value: string): Role =
  for role in Role:
    if $role == value:
      return role
  raise newException(ValueError,
    "role tidak dikenal: '" & value & "' (pilihan: api, worker, ctl, migrate)")

proc bindHandler*(handler: RouteHandler, app: AppContext): RequestHandler =
  ## Closure dibuat di proc terpisah supaya nilai yang ditangkap (`handler`, `app`) jelas
  ## per-rute. Menulis closure langsung di dalam loop `for` berisiko menangkap nilai iterasi
  ## terakhir — pernah kejadian di sini (`/healthz` melayani handler `/readyz`).
  result = proc(req: Request) {.gcsafe.} = handler(app, req)

proc mummyPattern*(path: string): string =
  ## Kontrak memakai `{nama}` (OpenAPI/URI template, spec §13); router Mummy memakai `@nama`.
  ## Konversi satu tempat di sini supaya `RouteSpec.path` tetap sama dengan kontrak (dibandingkan
  ## `apps/api/tests/tcontract.nim`) tanpa router perlu tahu dua gaya penulisan.
  var segments: seq[string]
  for segment in path.split('/'):
    if segment.len > 2 and segment[0] == '{' and segment[^1] == '}':
      segments.add("@" & segment[1 .. ^2])
    else:
      segments.add(segment)
  segments.join("/")

proc buildRouter*(app: AppContext): Router =
  for spec in allRoutes():
    let handleRequest = bindHandler(spec.handler, app)
    let pattern = mummyPattern(spec.path)
    case spec.httpMethod
    of hmGet: result.get(pattern, handleRequest)
    of hmPost: result.post(pattern, handleRequest)
    of hmPut: result.put(pattern, handleRequest)
    of hmPatch: result.patch(pattern, handleRequest)
    of hmDelete: result.delete(pattern, handleRequest)

proc accessLogLine*(httpMethod, path: string, status: int, durationMs: int64): string =
  ## Bentuk satu baris access log (T-130/API-6). `status` 0 = handler tidak merespons lewat helper
  ## (mis. respons ditulis langsung oleh Mummy), ditandai `-` supaya tidak terbaca "200".
  httpMethod & " " & path & " " & (if status > 0: $status else: "-") & " " &
    $durationMs & "ms"

proc logAccess(req: Request, status: int, durationMs: int64) =
  ## Satu baris per permintaan — dipanggil pembungkus, bukan tiap handler, jadi tidak ada rute yang
  ## bisa lupa. Trace id ikut sebagai field terstruktur (korelasi dengan amplop problem & audit).
  discard newLogger(app = "kran-api").info(
    accessLogLine($req.httpMethod, req.path, status, durationMs),
    traceId = requestScopeTrace())

proc requestHandler*(app: AppContext): RequestHandler =
  ## Router dipegang closure; Mummy memanggil handler ini dari worker thread-nya.
  var router = buildRouter(app)
  router.notFoundHandler = proc(req: Request) {.gcsafe.} =
    req.respondProblem(pkNotFound, "Not Found",
      "tidak ada rute untuk " & $req.httpMethod & " " & req.path)
  router.methodNotAllowedHandler = proc(req: Request) {.gcsafe.} =
    req.respondProblem(pkMethodNotAllowed, "Method Not Allowed",
      $req.httpMethod & " tidak didukung untuk " & req.path)
  # Penangan terakhir (T-130/API-1). Tanpa ini, `PoolError`/exception yang lolos dari handler
  # dijawab Mummy sebagai 500 **tanpa badan dan tanpa log** — klien tidak bisa membedakan "server
  # salah" dari "koneksi habis", dan operator tidak punya jejak apa pun.
  router.errorHandler = proc(req: Request, e: ref Exception) {.gcsafe.} =
    if e of PoolError:
      discard newLogger(lvlError).error("pool basis data tidak tersedia",
        [("detail", e.msg), ("method", $req.httpMethod), ("path", req.path)],
        traceId = requestScopeTrace())
      req.respondProblem(
        newProblem(pkUnavailable, "Service Unavailable",
          "basis data sedang sibuk; coba lagi sebentar lagi",
          traceId = requestScopeTrace(), params = @[("reason", "pool_unavailable")]),
        @[("Retry-After", "1")])
    else:
      # `e.msg` hanya ke log server: bisa memuat nama tabel/host. Klien menerima teks tetap.
      discard newLogger(lvlError).error("permintaan gagal tanpa penangan",
        [("detail", e.msg), ("method", $req.httpMethod), ("path", req.path)],
        traceId = requestScopeTrace())
      req.respondProblem(pkInternal, "Internal Server Error",
        "terjadi kesalahan pada server")
  let inner = router.toHandler()
  # Hitungan permintaan berjalan dibungkus di **satu** tempat (bukan di tiap handler), jadi tidak ada
  # rute yang bisa lupa dan membuat drain menggantung (T-032).
  result = proc(req: Request) {.gcsafe.} =
    beginRequest()
    beginRequestScope(req)
    let started = epochTime()
    try:
      # Spec §11.5 #3: selama business date `CLOSING`, perubahan lewat HTTP ditolak kecuali
      # institusi memilih `daycloser.txn_policy_during_close = ALLOW`. Satu pemeriksaan di
      # pembungkus, jadi rute baru tidak bisa lupa (sama seperti 415/405 di bawah).
      if closeGuardApplies($req.httpMethod, req.path) and
          not app.pool.isNil and not app.clock.isNil and
          closeGuardVerdict(app.pool, businessDateIso(app.clock)) == cgBlock:
        req.respondProblem(newProblem(pkConflict, "Conflict",
          "business date sedang ditutup", traceId = traceIdFrom(req),
          params = @[("reason", "business_date_closing")]))
        return
      # T-133/API-4: kontrak menyatakan badan permintaan JSON; badan yang datang dengan tipe lain
      # ditolak di sini (415) alih-alih di-parse dan gagal sebagai 400 yang menyalahkan isinya.
      # Satu pemeriksaan di pembungkus, jadi tidak ada rute yang bisa lupa.
      if acceptsJsonBody(req):
        inner(req)
      else:
        req.respondProblem(pkUnsupportedMediaType, "Unsupported Media Type",
          "badan permintaan harus application/json")
    finally:
      endRequest()
      logAccess(req, requestScopeStatus(), int64((epochTime() - started) * 1000))

proc websocketHandlerOf(app: AppContext): WebSocketHandler =
  ## Handler WebSocket dipasang sekali di awal (Mummy memakainya untuk semua koneksi).
  ## `nil` bila realtime tidak dikonfigurasi — Mummy menangani `nil` dengan aman.
  if app.events.isNil:
    nil
  else:
    app.events.websocketHandler()

proc apiWorkerThreads*(app: AppContext): int =
  ## `app.serverThreads` bila sudah dihitung composition root; selain itu default Mummy
  ## (`countProcessors() * 10`) supaya test dan peran non-API berperilaku seperti sebelumnya.
  if app.serverThreads > 0: app.serverThreads else: max(countProcessors() * 10, 1)

proc newApiServer*(app: AppContext, logHandler: LogHandler = nil): Server =
  newServer(requestHandler(app), websocketHandler = websocketHandlerOf(app),
            logHandler = logHandler, workerThreads = apiWorkerThreads(app))

proc serveApi*(app: AppContext, port: int, address: string) =
  let server = newApiServer(app)
  server.serve(Port(port), address)
