## Helper idempotensi untuk composition root (T-084, D-098).
##
## Bukan middleware: setiap handler yang memakainya memanggil helper **di dalam** `withDbTx`
## miliknya, sehingga klaim dan operasi bisnis berbagi satu transaksi. Tanpa header, helper
## menjalankan operasi seperti biasa (T-085 yang mewajibkan header di endpoint rentan).
##
## Aturan replay (D-098): kunci + hash sama → respons tersimpan; kunci sama tapi operasi/hash
## beda → 409; klaim belum selesai → 409 + `Retry-After`. Respons non-2xx tidak pernah disimpan.

import std/[json, times]

import mummy
import db_connector/db_postgres

import kernel/paramkey
import kernel/generated/paramkeys
import platform/domain/[idempotency, scope]
import platform/infrastructure/[idempotency_repo, param_repo]

import ./access

type
  IdempotentOutcome* = object
    decision*: IdempotencyDecision
    status*: int
    payload*: JsonNode
    retryAfterSeconds*: int

proc utcIso(dt: DateTime): string =
  dt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc ttlHours(db: DbConn, asOf: string): int =
  ## Parameter dibaca di dalam transaksi yang sama: TTL yang dipakai adalah nilai yang berlaku
  ## saat operasi, bukan salinan saat start.
  let node = activeValueJson(db, keyString(P_platform_idempotency_ttl_hours), asOf,
    lookupFor(institutionScope()))
  if node.kind != JInt or node.getInt() <= 0:
    raise newException(ValueError,
      "parameter platform.idempotency.ttl_hours harus bilangan positif")
  int(node.getInt())

proc withIdempotencyKey*(db: DbConn, principal: Principal, rawKey, operationId: string,
    requestBody: string, asOf: string, now: DateTime,
    body: proc(): tuple[status: int, payload: JsonNode]): IdempotentOutcome =
  ## Inti helper tanpa `Request`, supaya bisa diuji langsung dengan `Principal` buatan test.
  ## `rawKey` kosong = header tidak dikirim: operasi berjalan tanpa replay (T-085 yang mewajibkan).
  if rawKey.len == 0:
    let (status, payload) = body()
    return IdempotentOutcome(decision: idemProceed, status: status, payload: payload)

  let key = validateIdempotencyKey(rawKey)
  let fingerprint = requestHash(requestBody)
  let expiresAt = utcIso(now + initDuration(hours = ttlHours(db, asOf)))
  let claim = claimIdempotency(db, principal.user.userId, key, operationId, fingerprint,
    expiresAt)

  case claim.decision
  of idemProceed:
    let (status, payload) = body()
    if status < 200 or status >= 300:
      raise newException(ValueError,
        "klaim idempotensi hanya boleh ditutup dengan respons 2xx")
    if not completeIdempotency(db, principal.user.userId, key, status, $payload):
      raise newException(ValueError, "klaim idempotensi hilang sebelum ditutup")
    IdempotentOutcome(decision: idemProceed, status: status, payload: payload)
  of idemReplay:
    IdempotentOutcome(decision: idemReplay, status: claim.status,
      payload: parseJson(claim.body))
  of idemMismatch:
    IdempotentOutcome(decision: idemMismatch, status: 409)
  of idemInFlight:
    let expires = parse(claim.expiresAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    let seconds = max(1, int((expires - now).inSeconds))
    IdempotentOutcome(decision: idemInFlight, status: 409, retryAfterSeconds: seconds)

proc withIdempotency*(db: DbConn, principal: Principal, req: Request, operationId: string,
    requestBody: string, asOf: string, now: DateTime,
    body: proc(): tuple[status: int, payload: JsonNode]): IdempotentOutcome =
  ## Pintu handler: membaca header `Idempotency-Key` lalu menyerahkan ke `withIdempotencyKey`.
  withIdempotencyKey(db, principal, req.headers["Idempotency-Key"], operationId, requestBody,
    asOf, now, body)
