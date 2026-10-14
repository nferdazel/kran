## Perakitan server HTTP (Mummy — ADR-002/D-019) dan pemilihan role proses (spec §12.5, §21.4).
##
## Handler dipanggil di **thread Mummy**, jadi boleh blocking — penting karena `db_connector`
## sinkron diwajibkan spec §12.1 (satu query sinkron tidak boleh membekukan seluruh API).

import std/strutils

import mummy
import mummy/routers

import ./context
import ./events
import ./health
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

proc requestHandler*(app: AppContext): RequestHandler =
  ## Router dipegang closure; Mummy memanggil handler ini dari worker thread-nya.
  var router = buildRouter(app)
  router.notFoundHandler = proc(req: Request) {.gcsafe.} =
    req.respondProblem(pkNotFound, "Not Found",
      "tidak ada rute untuk " & $req.httpMethod & " " & req.path)
  router.methodNotAllowedHandler = proc(req: Request) {.gcsafe.} =
    req.respondProblem(pkMethodNotAllowed, "Method Not Allowed",
      $req.httpMethod & " tidak didukung untuk " & req.path)
  result = router.toHandler()

proc websocketHandlerOf(app: AppContext): WebSocketHandler =
  ## Handler WebSocket dipasang sekali di awal (Mummy memakainya untuk semua koneksi).
  ## `nil` bila realtime tidak dikonfigurasi — Mummy menangani `nil` dengan aman.
  if app.events.isNil:
    nil
  else:
    app.events.websocketHandler()

proc newApiServer*(app: AppContext, logHandler: LogHandler = nil): Server =
  newServer(requestHandler(app), websocketHandler = websocketHandlerOf(app),
            logHandler = logHandler)

proc serveApi*(app: AppContext, port: int, address: string) =
  let server = newApiServer(app)
  server.serve(Port(port), address)
