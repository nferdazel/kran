## Helper idempotensi untuk composition root (T-084, D-098).
##
## Bukan middleware: setiap handler yang memakainya memanggil helper **di dalam** `withDbTx`
## miliknya, sehingga klaim dan operasi bisnis berbagi satu transaksi. Tanpa header, helper
## menjalankan operasi seperti biasa (T-085 yang mewajibkan header di endpoint rentan).
##
## Aturan replay (D-098): kunci + sidik jari sama → 200 + `Idempotent-Replayed`; kunci sama tapi
## operasi/sidik jari beda → 409; klaim belum selesai → 409 + `Retry-After`. Respons non-2xx
## tidak pernah disimpan: `body()` **wajib** mengembalikan 2xx; pelanggaran itu bug server.

import std/[algorithm, json, options, strutils, times]

import mummy
import db_connector/db_postgres

import kernel/paramkey
import kernel/generated/paramkeys
import platform/domain/[idempotency, scope]
import platform/infrastructure/[idempotency_repo, param_repo]

import ./access

const
  ## Klaim in-flight normalnya selesai dalam milidetik; menunggu sisa TTL penuh (bisa sehari)
  ## bukan jawaban yang berguna. Batas ini teknis, bukan kebijakan bisnis.
  maxRetryAfterSeconds* = 60 # nomagic:ok batas protokol Retry-After

type
  ## Parameter TTL hilang/rusak = salah konfigurasi operator → handler memetakan ke 500.
  IdempotencyConfigError* = object of ValueError
  ## Klaim hilang/tertutup di tengah transaksi = bug server → 500, bukan 400.
  IdempotencyStateError* = object of ValueError

  IdempotentOutcome* = object
    decision*: IdempotencyDecision
    status*: int
    payload*: JsonNode
    retryAfterSeconds*: int

proc utcIso(dt: DateTime): string =
  dt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc canonicalOf*(httpMethod, path: string, query: seq[(string, string)],
    body: string): string =
  ## Bentuk kanonik permintaan untuk sidik jari. Tiap komponen diberi awalan panjang supaya
  ## nilai yang mengandung pemisah tidak bisa menabrak komponen lain (mis. `a=1&b=2` vs
  ## `a=1%26b=2`), dan query diurutkan supaya urutan parameter tidak mengubah identitas.
  var pairs: seq[string]
  for (k, v) in query:
    pairs.add($k.len & ":" & k & "=" & $v.len & ":" & v)
  pairs.sort()
  $httpMethod.len & ":" & httpMethod & "|" & $path.len & ":" & path & "|" &
    $pairs.len & ":" & pairs.join("") & "|" & $body.len & ":" & body

proc canonicalRequest*(req: Request, body: string): string =
  ## Sidik jari mencakup method, path, query (urut), dan body. Body saja tidak cukup: dua
  ## permintaan ke resource berbeda dengan body sama tidak boleh saling mereplay.
  var query: seq[(string, string)]
  for (k, v) in req.queryParams:
    query.add((k, v))
  canonicalOf(req.httpMethod, req.path, query, body)

proc ttlHours(db: DbConn, asOf: string): int =
  ## Parameter dibaca di dalam transaksi yang sama: TTL yang dipakai adalah nilai yang berlaku
  ## saat operasi, bukan salinan saat start.
  let node = activeValueJson(db, keyString(P_platform_idempotency_ttl_hours), asOf,
    lookupFor(institutionScope()))
  if node.kind != JInt or node.getInt() <= 0:
    raise newException(IdempotencyConfigError,
      "parameter platform.idempotency.ttl_hours harus bilangan positif")
  int(node.getInt())

proc withIdempotencyKey*(db: DbConn, principal: Principal, rawKey: Option[string],
    operationId, canonicalRequestBody: string, asOf: string, now: DateTime,
    body: proc(): tuple[status: int, payload: JsonNode]): IdempotentOutcome =
  ## Inti helper tanpa `Request`, supaya bisa diuji langsung dengan `Principal` buatan test.
  ## `rawKey = none` berarti header tidak dikirim: operasi berjalan tanpa replay. `some("")`
  ## (header ada tetapi kosong) **ditolak** validator — bukan diperlakukan sebagai absen.
  if rawKey.isNone:
    let (status, payload) = body()
    return IdempotentOutcome(decision: idemProceed, status: status, payload: payload)

  let key = validateIdempotencyKey(rawKey.get())
  let fingerprint = requestHash(canonicalRequestBody)
  let nowIso = utcIso(now)
  let expiresAt = utcIso(now + initDuration(hours = ttlHours(db, asOf)))
  let claim = claimIdempotency(db, principal.user.userId, key, operationId, fingerprint,
    nowIso, expiresAt)

  case claim.decision
  of idemProceed:
    let (status, payload) = body()
    if status < 200 or status >= 300:
      raise newException(IdempotencyStateError,
        "body idempotensi mengembalikan status non-2xx: " & $status)
    if not completeIdempotency(db, principal.user.userId, key, nowIso, status, $payload):
      raise newException(IdempotencyStateError, "klaim idempotensi hilang sebelum ditutup")
    IdempotentOutcome(decision: idemProceed, status: status, payload: payload)
  of idemReplay:
    # D-098 menetapkan replay = 200, bukan status asli (mis. 201).
    IdempotentOutcome(decision: idemReplay, status: 200, payload: parseJson(claim.body))
  of idemMismatch:
    IdempotentOutcome(decision: idemMismatch, status: 409)
  of idemInFlight:
    let seconds =
      if claim.expiresAt.len == 0:
        1
      else:
        let expires = parse(claim.expiresAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
        max(1, min(maxRetryAfterSeconds, int((expires - now).inSeconds)))
    IdempotentOutcome(decision: idemInFlight, status: 409, retryAfterSeconds: seconds)

proc withIdempotency*(db: DbConn, principal: Principal, req: Request, operationId: string,
    requestBody: string, asOf: string, now: DateTime,
    body: proc(): tuple[status: int, payload: JsonNode]): IdempotentOutcome =
  ## Pintu handler: membedakan header tidak ada dari header kosong, lalu menyerahkan sidik jari
  ## kanonik ke `withIdempotencyKey`.
  let rawKey =
    if req.headers.contains("Idempotency-Key"):
      some(req.headers["Idempotency-Key"])
    else:
      none(string)
  withIdempotencyKey(db, principal, rawKey, operationId, canonicalRequest(req, requestBody),
    asOf, now, body)
