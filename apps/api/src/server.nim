## Perakitan server HTTP (Mummy — ADR-002/D-019) dan pemilihan role proses (spec §12.5, §21.4).
##
## Handler dipanggil di **thread Mummy**, jadi boleh blocking — penting karena `db_connector`
## sinkron diwajibkan spec §12.1 (satu query sinkron tidak boleh membekukan seluruh API).

import mummy
import mummy/routers

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

proc buildRouter*(app: AppContext): Router =
  for spec in allRoutes():
    let handleRequest = bindHandler(spec.handler, app)
    case spec.httpMethod
    of hmGet: result.get(spec.path, handleRequest)
    of hmPost: result.post(spec.path, handleRequest)
    of hmPut: result.put(spec.path, handleRequest)
    of hmPatch: result.patch(spec.path, handleRequest)
    of hmDelete: result.delete(spec.path, handleRequest)

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

proc newApiServer*(app: AppContext): Server =
  ## Server HTTP saja; hub WebSocket menyusul di T-009.
  newServer(requestHandler(app))

proc serveApi*(app: AppContext, port: int, address: string) =
  let server = newApiServer(app)
  server.serve(Port(port), address)
