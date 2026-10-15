## Tabel rute aplikasi — **satu tempat** untuk semua endpoint HTTP.
##
## Gate `apps/api/tests/tcontract.nim` membandingkan tabel ini dengan
## `packages/contracts/openapi/kran-api.yaml` (spec §13: kontrak = sumber kebenaran), jadi
## menambah rute tanpa memperbarui kontrak (atau sebaliknya) membuat CI merah.
##
## Rute tumbuh bertahap: T-008 hanya endpoint sistem; T-009 menambah realtime; T-012 auth,
## parameter, dan audit.

import mummy

import ./events
import ./handlers_audit
import ./handlers_auth
import ./handlers_param
import ./health
import ./problem

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

proc handleEventsStream*(app: AppContext, req: Request) {.gcsafe.} =
  ## Perekat rute → layanan. Handshake WebSocket ada di `events.openStream`; di sini hanya
  ## penerjemahan `AppContext` dan penanganan kasus "realtime belum dikonfigurasi".
  if app.events.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan realtime tidak dikonfigurasi (KRAN_DATABASE_URL kosong saat start)")
    return
  app.events.openStream(req)

proc eventRoutes*(): seq[RouteSpec] =
  ## Satu rute; Mummy mengarahkan permintaan ber-`Upgrade` ke `websocketHandler` (dipasang di
  ## `server.newApiServer`), sedangkan GET tanpa Upgrade tetap sampai ke handler ini dan dibalas 426.
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/events/stream", operationId: "streamEvents",
              handler: handleEventsStream),
  ]

proc systemRoutes*(): seq[RouteSpec] =
  @[
    RouteSpec(httpMethod: hmGet, path: "/healthz", operationId: "getHealth",
              handler: handleHealth),
    RouteSpec(httpMethod: hmGet, path: "/readyz", operationId: "getReadiness",
              handler: handleReadiness),
  ]

proc authRoutes*(): seq[RouteSpec] =
  ## Sesi: masuk, identitas, keluar (spec §13).
  @[
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/login", operationId: "login",
              handler: handleLogin),
    RouteSpec(httpMethod: hmGet, path: "/api/v1/auth/session", operationId: "getSession",
              handler: handleSession),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/logout", operationId: "logout",
              handler: handleLogout),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/auth/password", operationId: "changePassword",
              handler: handleChangePassword),
  ]

proc paramRoutes*(): seq[RouteSpec] =
  ## Parameter: daftar, pengajuan (maker), persetujuan (checker) — spec §10.2/§10.7.
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/params", operationId: "listParams",
              handler: handleListParams),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/params/{key}/changes",
              operationId: "submitParamChange", handler: handleSubmitParamChange),
    RouteSpec(httpMethod: hmPost, path: "/api/v1/params/changes/{paramValueId}/approve",
              operationId: "approveParamChange", handler: handleApproveParamChange),
  ]

proc auditRoutes*(): seq[RouteSpec] =
  @[
    RouteSpec(httpMethod: hmGet, path: "/api/v1/audit", operationId: "listAudit",
              handler: handleListAudit),
  ]

proc allRoutes*(): seq[RouteSpec] =
  systemRoutes() & authRoutes() & paramRoutes() & auditRoutes() & eventRoutes()
