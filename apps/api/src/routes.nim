## Tabel rute aplikasi — **satu tempat** untuk semua endpoint HTTP.
##
## Gate `apps/api/tests/tcontract.nim` membandingkan tabel ini dengan
## `packages/contracts/openapi/cbs-api.yaml` (spec §13: kontrak = sumber kebenaran), jadi
## menambah rute tanpa memperbarui kontrak (atau sebaliknya) membuat CI merah.
##
## Rute tumbuh bertahap: T-008 hanya endpoint sistem; T-009 menambah realtime; T-012 auth,
## parameter, dan audit.

import mummy

import ./health

type
  HttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmPatch = "PATCH"
    hmDelete = "DELETE"

  RouteHandler* = proc(app: AppContext, req: Request) {.gcsafe.}

  RouteSpec* = object
    httpMethod*: HttpMethod
    path*: string ## pola kontrak, mis. `/api/v1/params/{key}`
    operationId*: string
    handler*: RouteHandler

proc key*(spec: RouteSpec): string =
  ## Kunci pembanding untuk contract test: `GET /healthz`.
  $spec.httpMethod & " " & spec.path

proc systemRoutes*(): seq[RouteSpec] =
  @[
    RouteSpec(httpMethod: hmGet, path: "/healthz", operationId: "getHealth",
              handler: handleHealth),
    RouteSpec(httpMethod: hmGet, path: "/readyz", operationId: "getReadiness",
              handler: handleReadiness),
  ]

proc allRoutes*(): seq[RouteSpec] =
  systemRoutes()
