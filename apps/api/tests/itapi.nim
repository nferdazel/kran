## Test integrasi `/readyz` dengan DB nyata (butuh `CBS_DATABASE_URL`).
##
## Kriteria T-008 (bagian readiness): endpoint kesiapan benar-benar memeriksa DB, bukan sekadar
## mengembalikan 200. Tanpa `CBS_DATABASE_URL` test ini melewati dirinya sendiri (pola yang sama
## dengan test integrasi lain), sehingga CI tanpa DB tetap hijau.
##
## Test ini **tidak** mengubah schema: hanya menjalankan `select 1` lewat pool yang sama dengan
## yang dipakai `/readyz` pada proses `cbs-api`.

import std/[httpclient, json, net, os, times, unittest]

import mummy

import "platform-lib/db/config"

import ../src/[health, readiness, server]

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
    discard # proses test berakhir dengan sendirinya (lihat catatan O-025)

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi: CBS_DATABASE_URL kosong — dilewati"
  quit(0)

let port = freePort()
baseUrl = "http://127.0.0.1:" & $port
apiServer = newServer(requestHandler(AppContext(
  version: "itapi-0.0.0",
  role: "api",
  startedAt: epochTime(),
  readiness: databaseProbe(),
)))
createThread(serverThread, serveInThread, ServeArgs(server: apiServer, port: port))

proc readinessResponse(): tuple[code: int, body: JsonNode] =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  let response = client.get(baseUrl & "/readyz")
  result.code = response.code.int
  result.body = parseJson(response.body)

suite "readyz dengan DB nyata":
  test "DB hidup -> 200 dengan check database ok":
    var result: tuple[code: int, body: JsonNode]
    let deadline = epochTime() + 10.0
    while epochTime() < deadline:
      result = readinessResponse()
      if result.code == 200:
        break
      sleep(100)

    check result.code == 200
    check result.body["status"].getStr() == "ok"
    var found = false
    for checkItem in result.body["checks"]:
      if checkItem["name"].getStr() == "database":
        found = true
        check checkItem["status"].getStr() == "ok"
    check found

  test "liveness tetap bebas DB (200 walau readiness diperiksa)":
    let client = newHttpClient(timeout = 5000)
    defer: client.close()
    let response = client.get(baseUrl & "/healthz")
    check response.code.int == 200
    let body = parseJson(response.body)
    check body["status"].getStr() == "ok"
    check body["role"].getStr() == "api"
