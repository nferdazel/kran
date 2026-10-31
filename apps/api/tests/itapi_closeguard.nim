## Test integrasi gerbang transaksi saat business date `CLOSING` (T-135, spec §11.5 #3).
##
## Yang dibuktikan: pembungkus HTTP menolak **perubahan** dengan 409 `business_date_closing`,
## membiarkan pembacaan dan rute autentikasi, dan menghormati kebijakan
## `daycloser.txn_policy_during_close = ALLOW`.
##
## Test ini me-reset seluruh schema di DB dev (pola suite integrasi lain) dan menghapus baris
## `business_date` di akhir supaya e2e/suite berikutnya mulai dari keadaan tanpa penutupan.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/clock

import ../src/[context, readiness, server]

const
  repoRoot = "."
  ContractFreePath = "/api/v1/params/uji/changes"
  ReadPath = "/api/v1/params"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_closeguard: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

resetTestSchemas(db, repoRoot)
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

type
  ServeArgs = object
    server: Server
    port: int

var
  apiServer: Server
  baseUrl: string
  serverThread: Thread[ServeArgs]

proc freePort(): int =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = int(socket.getLocalAddr()[1])
  socket.close()

proc serveInThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard

let app = AppContext(version: "itapi-closeguard-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: systemClock(), readiness: databaseProbe())
let port = freePort()
baseUrl = "http://127.0.0.1:" & $port
apiServer = newApiServer(app)
createThread(serverThread, serveInThread, ServeArgs(server: apiServer, port: port))

# Thread server bisa belum selesai `bind` saat permintaan pertama dikirim; `httpclient` melempar
# `OSError` alih-alih mengembalikan kode. Tunggu sampai benar-benar melayani, bukan tidur tetap.
block:
  let deadline = epochTime() + 10.0
  var ready = false
  while not ready and epochTime() < deadline:
    try:
      let client = newHttpClient(timeout = 2000)
      try:
        discard client.get(baseUrl & "/healthz")
        ready = true
      finally:
        client.close()
    except CatchableError:
      sleep(50)
  if not ready:
    echo "itapi_closeguard: server tidak siap dalam 10 detik"
    quit(1)

proc postJson(path: string): tuple[code: int, body: JsonNode] =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let response = client.post(baseUrl & path, "{}")
  result.code = response.code.int
  result.body = parseJson(response.body)

proc getPath(path: string): int =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  client.get(baseUrl & path).code.int

proc setBusinessDate(state: string) =
  execScript(db, "DELETE FROM platform.business_date")
  execScript(db, "INSERT INTO platform.business_date " &
    "(scope_type, scope_id, current_business_date, state) " &
    "VALUES ('INSTITUTION', NULL, DATE '2026-10-28', '" & state & "')")

proc setPolicy(value: string) =
  execScript(db, "UPDATE platform.param_value SET value = '\"" & value & "\"'::jsonb " &
    "WHERE param_value_id = md5('daycloser.txn_policy_during_close|base')::uuid")

suite "gerbang penutupan buku (HTTP)":
  test "tanpa baris business_date semua perubahan lolos ke handler (401, bukan 409)":
    execScript(db, "DELETE FROM platform.business_date")
    check postJson(ContractFreePath).code == 401

  test "CLOSING menolak perubahan dengan 409 + reason, tetapi bukan pembacaan":
    setBusinessDate("CLOSING")
    let blocked = postJson(ContractFreePath)
    check blocked.code == 409
    check blocked.body{"code"}.getStr == "CONFLICT"
    check blocked.body{"params"}{"reason"}.getStr == "business_date_closing"
    check getPath(ReadPath) == 401

  test "rute autentikasi tetap hidup saat CLOSING":
    setBusinessDate("CLOSING")
    # Login dengan badan kosong ditolak validasi badan (400) atau kredensial (401), bukan oleh
    # gerbang penutupan. `!= 409` saja terlalu longgar: 404/500 juga akan lolos.
    check postJson("/api/v1/auth/login").code in [400, 401, 403]

  test "kebijakan ALLOW membiarkan perubahan lewat":
    setBusinessDate("CLOSING")
    setPolicy("ALLOW")
    check postJson(ContractFreePath).code == 401
    setPolicy("REJECT")
    check postJson(ContractFreePath).code == 409

  test "parameter kebijakan hilang = fail-closed (409), bukan 500 atau lolos":
    setBusinessDate("CLOSING")
    execScript(db, "DELETE FROM platform.param_value " &
      "WHERE param_value_id = md5('daycloser.txn_policy_during_close|base')::uuid")
    let blocked = postJson(ContractFreePath)
    check blocked.code == 409
    check blocked.body{"params"}{"reason"}.getStr() == "business_date_closing"
    # Kembalikan seed supaya test berikutnya dan suite lain melihat konfigurasi normal.
    execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

  test "OPEN tidak menahan apa pun":
    setBusinessDate("OPEN")
    check postJson(ContractFreePath).code == 401

# Jangan tinggalkan tanggal buku CLOSING untuk suite/e2e berikutnya.
execScript(db, "DELETE FROM platform.business_date")
