## Helper idempotensi untuk composition root (T-084, D-098).
##
## Bukan middleware: setiap handler yang memakainya memanggil helper **di dalam** `withDbTx`
## miliknya, sehingga klaim dan operasi bisnis berbagi satu transaksi. Tanpa header, helper
## menjalankan operasi seperti biasa (T-085 yang mewajibkan header di endpoint rentan).
##
## Aturan replay (D-098): kunci + sidik jari sama → 200 + `Idempotent-Replayed`; kunci sama tapi
## operasi/sidik jari beda → 409. Klaim dan penutupannya satu transaksi, jadi baris in-flight yang
## ter-COMMIT tidak muncul (D-117); cabang 409 + `Retry-After` bersifat defensif. Respons non-2xx
## tidak pernah disimpan: `body()` **wajib** mengembalikan 2xx; pelanggaran itu bug server.

import std/[algorithm, json, options, strutils, times]

import mummy
import db_connector/db_postgres

import kernel/paramkey
import kernel/generated/paramkeys
import platform/domain/[idempotency, scope]
import platform/infrastructure/[idempotency_repo, param_repo]

import ./access
import ./http_util
import ./problem

const
  ## Klaim in-flight normalnya selesai dalam milidetik; menunggu sisa TTL penuh (bisa sehari)
  ## bukan jawaban yang berguna. Batas ini teknis, bukan kebijakan bisnis.
  maxRetryAfterSeconds* = 60 # nomagic:ok batas protokol Retry-After
  idempotencyHeader* = "Idempotency-Key"

type
  ## Sengaja **bukan** turunan `ValueError`: handler memetakan `ValueError` → 400 untuk kesalahan
  ## pemanggil, sedangkan dua kondisi ini kesalahan server/konfigurasi (500).
  IdempotencyConfigError* = object of CatchableError
  IdempotencyStateError* = object of CatchableError

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
  let node =
    try:
      activeValueJson(db, keyString(P_platform_idempotency_ttl_hours), asOf,
        lookupFor(institutionScope()))
    except ValueError as e:
      # Parameter hilang/rusak = konfigurasi, bukan permintaan klien. Tanpa pemetaan ini
      # `ValueError` akan dijawab 400 oleh handler dan menyembunyikan masalah server.
      raise newException(IdempotencyConfigError, e.msg)
  if node.kind != JInt or node.getInt() <= 0:
    raise newException(IdempotencyConfigError,
      "parameter platform.idempotency.ttl_hours harus bilangan positif")
  int(node.getInt())

proc withIdempotencyKey*(db: DbConn, principal: Principal, rawKey: Option[string],
    operationId, canonicalRequestBody: string, asOf: string, now: DateTime,
    body: proc(): tuple[status: int, payload: JsonNode] {.gcsafe.}): IdempotentOutcome =
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
    nowIso, nowIso, expiresAt)

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

proc requireIdempotencyKey*(req: Request): bool =
  ## `true` bila header ada **dan** isinya tidak kosong. Handler T-085 memakai ini untuk 400;
  ## helper sendiri membedakan absen (`none`) dari kosong (`some("")` → ditolak validator).
  req.headers.contains(idempotencyHeader) and
    req.headers[idempotencyHeader].strip.len > 0

proc respondIdempotent*(req: Request, outcome: IdempotentOutcome): bool =
  ## Menulis respons untuk hasil non-`idemProceed`. `false` = pemanggil harus menulis respons
  ## suksesnya sendiri (operasi baru saja dijalankan).
  case outcome.decision
  of idemProceed:
    false
  of idemReplay:
    req.respondJsonHeaders(200, outcome.payload, [("Idempotent-Replayed", "true")])
    true
  of idemMismatch:
    req.respondProblem(pkConflict, "Conflict",
      "Idempotency-Key sudah dipakai untuk permintaan lain")
    true
  of idemInFlight:
    req.respondProblem(
      newProblem(pkConflict, "Conflict", "permintaan dengan kunci ini masih diproses",
        traceId = traceIdFrom(req)), [("Retry-After", $outcome.retryAfterSeconds)])
    true

proc withIdempotency*(db: DbConn, principal: Principal, req: Request, operationId: string,
    requestBody: string, asOf: string, now: DateTime,
    body: proc(): tuple[status: int, payload: JsonNode] {.gcsafe.}): IdempotentOutcome =
  ## Pintu handler: membedakan header tidak ada dari header kosong, lalu menyerahkan sidik jari
  ## kanonik ke `withIdempotencyKey`.
  let rawKey =
    if req.headers.contains(idempotencyHeader):
      some(req.headers[idempotencyHeader])
    else:
      none(string)
  withIdempotencyKey(db, principal, rawKey, operationId, canonicalRequest(req, requestBody),
    asOf, now, body)
