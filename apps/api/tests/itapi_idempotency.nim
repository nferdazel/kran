## Test integrasi helper idempotensi composition root (T-084, D-098). Butuh `KRAN_DATABASE_URL`.
##
## Membuktikan perilaku yang tidak terlihat dari repo saja: tanpa header operasi berjalan biasa,
## header kosong ditolak, header sama tidak menjalankan ulang operasi (replay 200), sidik jari
## membedakan method/path/query, isi berbeda 409, TTL dari parameter, klaim rollback saat operasi
## gagal, dan klaim in-flight memberi `Retry-After` yang dibatasi.

import std/[json, options, os, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"
import platform/domain/idempotency
import platform/infrastructure/auth_repo

import ../src/[access, idempotency]

const
  repoRoot = "."
  asOf = "2026-10-21"
  principalId = "11111111-1111-7111-8111-111111111111"
  nowIso = "2026-10-21T00:00:00Z"
  partyRequest = "POST /api/v1/parties?\n" & """{"a":1}"""
  partyOther = "POST /api/v1/parties/999/risk-rating?\n" & """{"a":1}"""

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_idempotency: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))
execScript(db, """
  INSERT INTO platform.app_user
    (user_id, username, full_name, password_algo, password_hash)
  VALUES ('11111111-1111-7111-8111-111111111111', 'it-idem-api', 'It Idem API',
          'pbkdf2-hmac-sha256', 'x')
  ON CONFLICT DO NOTHING
""")

let principal = Principal(
  session: SessionRow(sessionId: "", userId: principalId, expiresAt: "",
    absoluteExpiresAt: "", revoked: false),
  user: UserRow(userId: principalId, username: "it-idem-api", fullName: "It Idem API",
    status: "ACTIVE", passwordHash: "", mustChangePassword: false, failedAttempts: 0,
    lockedUntil: ""),
  roles: @[],
  permissions: @[])

proc fixedNow(): DateTime = parse(nowIso, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())

type Counter = ref object
  n: int

proc okBody(counter: Counter): proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
  result = proc(): tuple[status: int, payload: JsonNode] {.gcsafe.} =
    inc counter.n
    (201, %*{"n": counter.n})

proc countKey(key: string): string =
  db.getValue(sql("""
    SELECT count(*) FROM platform.idempotency_key
    WHERE principal_id = ?::uuid AND key = ?"""), principalId, key)

proc expiresOf(key: string): string =
  db.getValue(sql("""
    SELECT to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    FROM platform.idempotency_key
    WHERE principal_id = ?::uuid AND key = ?"""), principalId, key)

suite "canonical request":
  test "method, path, query, dan body membedakan sidik jari":
    let dasar = canonicalOf("POST", "/api/v1/parties", @[], """{"a":1}""")
    check canonicalOf("PUT", "/api/v1/parties", @[], """{"a":1}""") != dasar
    check canonicalOf("POST", "/api/v1/parties/1", @[], """{"a":1}""") != dasar
    check canonicalOf("POST", "/api/v1/parties", @[("x", "1")], """{"a":1}""") != dasar
    check canonicalOf("POST", "/api/v1/parties", @[], """{"a":2}""") != dasar

  test "urutan query tidak mengubah sidik jari":
    let a = canonicalOf("POST", "/p", @[("x", "1"), ("y", "2")], "{}")
    let b = canonicalOf("POST", "/p", @[("y", "2"), ("x", "1")], "{}")
    check a == b

  test "nilai berisi pemisah tidak bertabrakan":
    let a = canonicalOf("POST", "/p", @[("a", "1"), ("b", "2")], "{}")
    let b = canonicalOf("POST", "/p", @[("a", "1&b=2")], "{}")
    check a != b

proc newReq(headers: seq[(string, string)] = @[], path = "/api/v1/parties",
    query: seq[(string, string)] = @[]): Request =
  ## `Request` adalah ptr; alokasi heap supaya aman dipakai lintas pemanggilan test.
  let p = cast[ptr RequestObj](alloc0(sizeof(RequestObj)))
  p[] = RequestObj(httpMethod: "POST", uri: path, path: path, body: "{}",
    queryParams: QueryParams(query), headers: HttpHeaders(headers))
  p

suite "request seam (pintu handler)":
  test "canonicalRequest memakai method/path/query; urutan query tidak mengubah":
    let a = newReq(query = @[("x", "1"), ("y", "2")])
    let b = newReq(query = @[("y", "2"), ("x", "1")])
    check canonicalRequest(a, "{}") == canonicalRequest(b, "{}")
    let lain = newReq(query = @[("x", "1"), ("y", "2")], path = "/api/v1/other")
    check canonicalRequest(a, "{}") != canonicalRequest(lain, "{}")

  test "tanpa header operasi berjalan; header kosong ditolak":
    let dijalankan = Counter()
    let tanpa = withIdempotency(db, principal, newReq(), "party.create", "{}", asOf,
      fixedNow(), okBody(dijalankan))
    check tanpa.decision == idemProceed
    check dijalankan.n == 1

    var ditolak = false
    try:
      discard withIdempotency(db, principal,
        newReq(headers = @[("Idempotency-Key", "")]), "party.create", "{}", asOf,
        fixedNow(), okBody(Counter()))
    except ValueError:
      ditolak = true
    check ditolak

  test "header ada: permintaan kedua lewat pintu Request adalah replay":
    let req = newReq(headers = @[("Idempotency-Key", "k-req")])
    let dijalankan = Counter()
    check withIdempotency(db, principal, req, "party.create", "{}", asOf, fixedNow(),
      okBody(dijalankan)).decision == idemProceed
    let second = withIdempotency(db, principal, req, "party.create", "{}", asOf,
      fixedNow(), okBody(dijalankan))
    check second.decision == idemReplay
    check dijalankan.n == 1

suite "idempotency helper":
  test "tanpa header: operasi berjalan dan tidak ada baris klaim":
    let dijalankan = Counter()
    let outcome = withIdempotencyKey(db, principal, none(string), "party.create",
      partyRequest, asOf, fixedNow(), okBody(dijalankan))
    check outcome.decision == idemProceed
    check dijalankan.n == 1
    check countKey("k-none") == "0"

  test "header ada tetapi kosong ditolak, operasi tidak berjalan":
    let dijalankan = Counter()
    var ditolak = false
    try:
      discard withIdempotencyKey(db, principal, some(""), "party.create",
        partyRequest, asOf, fixedNow(), okBody(dijalankan))
    except ValueError:
      ditolak = true
    check ditolak
    check dijalankan.n == 0

  test "header sama: replay 200, operasi tidak dijalankan ulang":
    let dijalankan = Counter()
    let first = withIdempotencyKey(db, principal, some("k-1"), "party.create",
      partyRequest, asOf, fixedNow(), okBody(dijalankan))
    check first.decision == idemProceed
    check first.status == 201
    check dijalankan.n == 1

    let second = withIdempotencyKey(db, principal, some("k-1"), "party.create",
      partyRequest, asOf, fixedNow(), okBody(dijalankan))
    check second.decision == idemReplay
    check second.status == 200
    check dijalankan.n == 1
    check second.payload["n"].getInt == 1

  test "path berbeda dengan body sama bukan replay":
    check withIdempotencyKey(db, principal, some("k-path"), "party.create",
      partyRequest, asOf, fixedNow(), okBody(Counter())).decision == idemProceed

    let dijalankan = Counter()
    let outcome = withIdempotencyKey(db, principal, some("k-path"), "party.create",
      partyOther, asOf, fixedNow(), okBody(dijalankan))
    check outcome.decision == idemMismatch
    check outcome.status == 409
    check dijalankan.n == 0

  test "kedaluwarsa klaim mengikuti parameter TTL dari pack base":
    let dijalankan = Counter()
    discard withIdempotencyKey(db, principal, some("k-ttl"), "party.create",
      partyRequest, asOf, fixedNow(), okBody(dijalankan))
    check expiresOf("k-ttl") == "2026-10-22T00:00:00Z"

  test "operasi gagal me-rollback klaim; kunci yang sama boleh dicoba lagi":
    var gagal = false
    try:
      discard dbPool.withTx(proc(d: DbConn): bool {.closure.} =
        discard withIdempotencyKey(d, principal, some("k-rollback"), "party.create",
          partyRequest, asOf, fixedNow(), proc(): tuple[status: int, payload: JsonNode] =
          raise newException(ValueError, "gagal di tengah operasi"))
        true)
    except ValueError:
      gagal = true
    check gagal
    check countKey("k-rollback") == "0"

    let dijalankan = Counter()
    let retry = withIdempotencyKey(db, principal, some("k-rollback"), "party.create",
      partyRequest, asOf, fixedNow(), okBody(dijalankan))
    check retry.decision == idemProceed
    check dijalankan.n == 1

  test "body non-2xx tidak menyimpan klaim":
    var gagal = false
    try:
      discard dbPool.withTx(proc(d: DbConn): bool {.closure.} =
        discard withIdempotencyKey(d, principal, some("k-500"), "party.create",
          partyRequest, asOf, fixedNow(), proc(): tuple[status: int, payload: JsonNode] =
          (500, %*{"error": true}))
        true)
    except IdempotencyStateError:
      gagal = true
    check gagal
    check countKey("k-500") == "0"

  test "klaim in-flight memberi Retry-After yang dibatasi, bukan sisa TTL penuh":
    execScript(db, """
      INSERT INTO platform.idempotency_key
        (principal_id, key, operation_id, request_hash, created_at, expires_at)
      VALUES ('11111111-1111-7111-8111-111111111111', 'k-flight', 'party.create',
              '""" & requestHash(partyRequest) & """', '2026-10-21T00:00:00Z',
              '2026-10-21T06:00:00Z')
      ON CONFLICT DO NOTHING
    """)
    let outcome = withIdempotencyKey(db, principal, some("k-flight"), "party.create",
      partyRequest, asOf, fixedNow(), proc(): tuple[status: int, payload: JsonNode] =
      (201, %*{}))
    check outcome.decision == idemInFlight
    check outcome.status == 409
    check outcome.retryAfterSeconds == maxRetryAfterSeconds

  test "klaim kedaluwarsa boleh dipakai ulang":
    execScript(db, """
      INSERT INTO platform.idempotency_key
        (principal_id, key, operation_id, request_hash, created_at, expires_at)
      VALUES ('11111111-1111-7111-8111-111111111111', 'k-expired', 'party.create',
              '""" & requestHash(partyRequest) & """', '2026-10-21T00:00:00Z',
              '2026-10-21T06:00:00Z')
      ON CONFLICT DO NOTHING
    """)
    let outcome = withIdempotencyKey(db, principal, some("k-expired"), "party.create",
      partyRequest, asOf, parse("2026-10-21T07:00:00Z", "yyyy-MM-dd'T'HH:mm:ss'Z'", utc()),
      proc(): tuple[status: int, payload: JsonNode] = (201, %*{}))
    check outcome.decision == idemProceed

  test "parameter TTL hilang adalah konfigurasi server, bukan 400":
    execScript(db, "DELETE FROM platform.param_value WHERE key = 'platform.idempotency.ttl_hours'")
    var raised = false
    try:
      discard withIdempotencyKey(db, principal, some("k-cfg"), "party.create",
        partyRequest, asOf, fixedNow(), okBody(Counter()))
    except IdempotencyConfigError:
      raised = true
    check raised
    execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))
