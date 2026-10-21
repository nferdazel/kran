## Test integrasi helper idempotensi composition root (T-084, D-098). Butuh `KRAN_DATABASE_URL`.
##
## Membuktikan perilaku yang tidak terlihat dari repo saja: tanpa header operasi berjalan biasa,
## header yang sama tidak menjalankan ulang operasi (replay), isi berbeda ditolak 409, dan TTL
## diambil dari parameter `platform.idempotency.ttl_hours` (24 jam dari pack base).

import std/[json, os, times, unittest]

import db_connector/db_postgres

import dbtools/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"
import platform/domain/idempotency
import platform/infrastructure/[auth_repo, idempotency_repo]

import ../src/[access, idempotency]

const
  repoRoot = "."
  asOf = "2026-10-21"
  principalId = "11111111-1111-7111-8111-111111111111"
  now = "2026-10-21T00:00:00Z"

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

proc fixedNow(): DateTime = parse(now, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())

proc expiresOf(key: string): string =
  db.getValue(sql("""
    SELECT to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    FROM platform.idempotency_key
    WHERE principal_id = ?::uuid AND key = ?"""), principalId, key)

suite "idempotency helper":
  test "tanpa header: operasi berjalan dan tidak ada baris klaim":
    var dijalankan = 0
    let first = withIdempotencyKey(db, principal, "", "party.create", """{"a":1}""", asOf,
      fixedNow(), proc(): tuple[status: int, payload: JsonNode] =
      inc dijalankan
      (201, %*{"n": dijalankan}))
    check first.decision == idemProceed
    check dijalankan == 1
    check idempotencyCount(db, principalId) == 0

  test "header sama: operasi tidak dijalankan ulang, respons identik":
    var dijalankan = 0
    let body = proc(): tuple[status: int, payload: JsonNode] =
      inc dijalankan
      (201, %*{"partyId": "p-1", "n": dijalankan})

    let first = withIdempotencyKey(db, principal, "k-1", "party.create", """{"a":1}""", asOf,
      fixedNow(), body)
    check first.decision == idemProceed
    check dijalankan == 1

    let second = withIdempotencyKey(db, principal, "k-1", "party.create", """{"a":1}""", asOf,
      fixedNow(), body)
    check second.decision == idemReplay
    check second.status == 201
    check dijalankan == 1
    check second.payload["partyId"].getStr == "p-1"
    check second.payload["n"].getInt == 1

  test "header sama tapi isi berbeda: 409 tanpa menjalankan operasi":
    var dijalankan = 0
    let second = withIdempotencyKey(db, principal, "k-1", "party.create", """{"a":2}""", asOf,
      fixedNow(), proc(): tuple[status: int, payload: JsonNode] =
      inc dijalankan
      (201, %*{"n": dijalankan}))
    check second.decision == idemMismatch
    check second.status == 409
    check dijalankan == 0

  test "kedaluwarsa klaim mengikuti parameter TTL dari pack base":
    check expiresOf("k-1") == "2026-10-22T00:00:00Z"
