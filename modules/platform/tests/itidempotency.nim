## Test integrasi klaim idempotensi (T-084, D-098). Butuh `KRAN_DATABASE_URL`.
##
## Cakupan: klaim baru, replay 2xx, konflik hash/operasi, klaim belum selesai, dan balapan dua
## koneksi (tepat satu yang menjalankan operasi). Test ini menghapus schema modul di DB dev.
##
## Catatan: baris klaim ditulis di transaksi bisnis. Di test ini transaksi bisnis disimulasikan
## dengan `pool.withTx`, sama seperti handler.

import std/[atomics, json, options, os, strutils, times, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[paramkey]
import platform/domain/[idempotency, scope]
import platform/infrastructure/[idempotency_repo, param_repo]

const
  repoRoot = "."
  asOf = "2026-10-21"
  principalId = "11111111-1111-7111-8111-111111111111"
  expiresAt = "2026-10-22T00:00:00Z"
  ttlKey = "platform.idempotency.ttl_hours"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itidempotency: KRAN_DATABASE_URL kosong — dilewati"
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
  VALUES ('11111111-1111-7111-8111-111111111111', 'it-idem', 'It Idempotensi',
          'pbkdf2-hmac-sha256', 'x')
  ON CONFLICT DO NOTHING
""")

proc hashOf(body: string): string = requestHash(body)

suite "idempotency: parameter & klaim":
  test "TTL tersemai dari pack base":
    let node = activeValueJson(db, ttlKey, asOf, lookupFor(institutionScope()))
    check node.kind == JInt
    check node.getInt() == 24

  test "klaim baru, replay, dan isi respons tersimpan":
    let key = "replay-1"
    let fp = hashOf("""{"displayName":"A"}""")
    let first = claimIdempotency(db, principalId, key, "party.create", fp, expiresAt)
    check first.decision == idemProceed
    check completeIdempotency(db, principalId, key, 201, """{"partyId":"p-1"}""")

    let second = claimIdempotency(db, principalId, key, "party.create", fp, expiresAt)
    check second.decision == idemReplay
    check second.status == 201
    check parseJson(second.body)["partyId"].getStr == "p-1"

  test "kunci sama dengan hash atau operasi berbeda ditolak":
    let key = "mismatch-1"
    let fp = hashOf("""{"x":1}""")
    check claimIdempotency(db, principalId, key, "party.create", fp, expiresAt).decision ==
      idemProceed
    discard completeIdempotency(db, principalId, key, 201, """{"ok":true}""")

    check claimIdempotency(db, principalId, key, "party.create", hashOf("""{"x":2}"""),
      expiresAt).decision == idemMismatch
    check claimIdempotency(db, principalId, key, "kyc.rate", fp, expiresAt).decision ==
      idemMismatch

  test "klaim belum selesai dilaporkan in-flight dengan batas waktu":
    let key = "inflight-1"
    execScript(db, """
      INSERT INTO platform.idempotency_key
        (principal_id, key, operation_id, request_hash, expires_at)
      VALUES ('11111111-1111-7111-8111-111111111111', 'inflight-1', 'party.create',
              '""" & hashOf("""{"y":1}""") & """', '2026-10-22T00:00:00Z')
      ON CONFLICT DO NOTHING
    """)
    let claim = claimIdempotency(db, principalId, key, "party.create", hashOf("""{"y":1}"""),
      expiresAt)
    check claim.decision == idemInFlight
    check claim.expiresAt == expiresAt

  test "respons non-2xx tidak bisa menutup klaim":
    let key = "status-1"
    let fp = hashOf("""{"z":1}""")
    check claimIdempotency(db, principalId, key, "party.create", fp, expiresAt).decision ==
      idemProceed
    # Constraint DB menolak status di luar 2xx; helper juga menolak sebelum menulis.
    var failed = false
    try:
      discard completeIdempotency(db, principalId, key, 500, """{"error":true}""")
    except DbError:
      failed = true
    check failed

type
  RaceArgs = object
    index: int
    key: string

var
  raceGate: Atomic[bool]
  raceDone: Atomic[int]
  raceDecision: array[2, IdempotencyDecision]

proc racer(args: RaceArgs) {.thread.} =
  {.cast(gcsafe).}:
    while not raceGate.load():
      sleep(2)
    try:
      discard dbPool.withTx(proc(d: DbConn): bool {.closure.} =
        let claim = claimIdempotency(d, principalId, args.key, "party.create",
          hashOf("""{"race":true}"""), expiresAt)
        raceDecision[args.index] = claim.decision
        if claim.decision == idemProceed:
          # Tahan transaksi supaya koneksi lain benar-benar menunggu di unique index.
          sleep(150)
          discard completeIdempotency(d, principalId, args.key, 201, """{"ok":true}""")
        true)
    except DbError, ValueError:
      raceDecision[args.index] = idemInFlight
    discard raceDone.fetchAdd(1)

suite "idempotency: balapan":
  test "dua koneksi dengan kunci sama: satu eksekusi, satu replay":
    let key = "race-1"
    var threads: array[2, Thread[RaceArgs]]
    createThread(threads[0], racer, RaceArgs(index: 0, key: key))
    createThread(threads[1], racer, RaceArgs(index: 1, key: key))
    raceGate.store(true)
    joinThreads(threads)
    check raceDone.load() == 2

    let decisions = {raceDecision[0], raceDecision[1]}
    check idemProceed in decisions
    check idemReplay in decisions
    check idempotencyCount(db, principalId) >= 1
