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

import ../src/[drain, health, readiness, server]

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

suite "readiness realtime (O-029)":
  test "realtime tidak dijalankan -> ok, bukan kegagalan":
    let c = realtimeCheck(pumping = false, ready = false, degradedSeconds = 9999, graceSeconds = 30)
    check c.status == csOk
    check c.detail == "tidak dijalankan"

  test "pump siap -> ok":
    check realtimeCheck(pumping = true, ready = true, degradedSeconds = 0, graceSeconds = 30
      ).status == csOk

  test "penyambungan ulang sekejap tetap ok (tidak mencabut instance dari trafik)":
    let c = realtimeCheck(pumping = true, ready = false, degradedSeconds = 2, graceSeconds = 30)
    check c.status == csOk
    check c.detail == "pump menyambung ulang (2 detik)"

  test "pump mati berlarut -> failed dan sebabnya terlihat":
    let c = realtimeCheck(pumping = true, ready = false, degradedSeconds = 31, graceSeconds = 30)
    check c.status == csFailed
    check c.detail == "pump realtime belum tersambung 31 detik"

  test "combineProbes menjalankan semua pemeriksaan (probe nil dilewati)":
    var probes: seq[ReadinessProbe]
    probes.add proc(): seq[ReadinessCheck] {.gcsafe.} =
      @[ReadinessCheck(name: "pertama", status: csOk)]
    probes.add nil
    probes.add proc(): seq[ReadinessCheck] {.gcsafe.} =
      @[ReadinessCheck(name: "kedua", status: csFailed, detail: "sebab")]
    let hasil = combineProbes(probes)()
    check hasil.len == 2
    check hasil[0].name == "pertama"
    check hasil[1].status == csFailed
    check hasil[1].detail == "sebab"

suite "drain saat berhenti (T-032)":
  test "readiness gagal saat proses sedang berhenti, dan tidak sebelum itu":
    check drainProbe()().len == 0
    startDraining()
    let saatBerhenti = drainProbe()()
    check saatBerhenti.len == 1
    check saatBerhenti[0].status == csFailed
    check saatBerhenti[0].name == "shutdown"
    check saatBerhenti[0].detail.len > 0

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
