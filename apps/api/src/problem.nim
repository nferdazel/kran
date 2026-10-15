## Error HTTP dengan amplop RFC 9457 (`application/problem+json`), spec §13.
##
## Aturan bentuk: `type`, `title`, `status`, `code`, `i18nKey`, `traceId` (wajib) + opsional
## `detail` dan `params`. Pesan untuk pengguna **tidak** dikirim dalam bahasa apa pun di sini —
## frontend menerjemahkan `i18nKey` + `params` (spec §16.1, satu tempat untuk semua teks).
##
## Kontrak: `packages/contracts/openapi/kran-api.yaml#/components/schemas/Problem`.

import std/[json, strutils]

import mummy

import kernel/ids

import ./http_util

type
  ProblemKind* = enum
    pkNotFound = "NOT_FOUND"
    pkUnauthorized = "UNAUTHORIZED"
    pkForbidden = "FORBIDDEN"
    pkBadRequest = "BAD_REQUEST"
    pkMethodNotAllowed = "METHOD_NOT_ALLOWED"
    pkUpgradeRequired = "UPGRADE_REQUIRED"
    pkConflict = "CONFLICT"
    pkNotImplemented = "NOT_IMPLEMENTED"
    pkInternal = "INTERNAL_ERROR"

  Problem* = object
    kind*: ProblemKind
    title*: string
    detail*: string
    traceId*: string
    params*: seq[tuple[key, value: string]]

proc statusOf*(kind: ProblemKind): int =
  case kind
  of pkBadRequest: 400
  of pkUnauthorized: 401
  of pkForbidden: 403
  of pkNotFound: 404
  of pkMethodNotAllowed: 405
  of pkUpgradeRequired: 426
  of pkConflict: 409
  of pkNotImplemented: 501
  of pkInternal: 500

proc i18nKeyOf*(kind: ProblemKind): string =
  ## Kunci katalog frontend, mis. `error_not_found`. Diterjemahkan di UI (id/en).
  "error_" & ($kind).toLowerAscii()

proc typeUriOf*(kind: ProblemKind): string =
  "/problems/" & ($kind).toLowerAscii().replace('_', '-')

proc newProblem*(kind: ProblemKind, title: string, detail = "",
                 traceId: string, params: seq[tuple[key, value: string]] = @[]): Problem =
  Problem(kind: kind, title: title, detail: detail, traceId: traceId, params: params)

proc toJson*(p: Problem): JsonNode =
  result = %*{
    "type": typeUriOf(p.kind),
    "title": p.title,
    "status": statusOf(p.kind),
    "code": $p.kind,
    "i18nKey": i18nKeyOf(p.kind),
    "traceId": p.traceId,
  }
  if p.detail.len > 0:
    result["detail"] = %p.detail
  if p.params.len > 0:
    var params = newJObject()
    for (key, value) in p.params:
      params[key] = %value
    result["params"] = params

proc traceIdFrom*(req: Request): string =
  ## Ambil `X-Request-Id` dari proxy (Caddy) bila ada; kalau tidak, buat korelasi baru.
  let fromProxy = req.headers["X-Request-Id"]
  if fromProxy.len > 0:
    return fromProxy
  newCorrelationId()

proc respondProblem*(req: Request, problem: Problem) =
  req.respond(statusOf(problem.kind), headersWithType(ContentTypeProblem), $problem.toJson)

proc respondProblem*(req: Request, kind: ProblemKind, title: string, detail = "") =
  req.respondProblem(newProblem(kind, title, detail, traceId = traceIdFrom(req)))
