## Test integrasi `/readyz` dengan DB nyata (butuh `KRAN_DATABASE_URL`).
##
## Kriteria T-008 (bagian readiness): endpoint kesiapan benar-benar memeriksa DB, bukan sekadar
## mengembalikan 200. Tanpa `KRAN_DATABASE_URL` test ini melewati dirinya sendiri (pola yang sama
## dengan test integrasi lain), sehingga CI tanpa DB tetap hijau.
##
## Test ini **tidak** mengubah schema: hanya menjalankan `select 1` lewat pool yang sama dengan
## yang dipakai `/readyz` pada proses `kran-api`.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy

import "platform-lib/db/config"
import "platform-lib/db/pool"
import kernel/clock

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
  echo "itapi: KRAN_DATABASE_URL kosong — dilewati"
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

suite "readiness migrasi (O-019)":
  test "expand tertunda -> failed dengan daftar; bersih -> ok":
    check migrationCheck(@[], verifiable = true).status == csOk
    let tertunda = migrationCheck(@["platform/0007_x"], verifiable = true)
    check tertunda.status == csFailed
    check tertunda.detail.contains("platform/0007_x")

  test "akar migrasi tidak terbaca -> ok + detail eksplisit (tidak membuat deploy rapuh)":
    let takTerbaca = migrationCheck(@[], verifiable = false)
    check takTerbaca.status == csOk
    check takTerbaca.detail.len > 0

suite "readiness lag outbox (O-019)":
  test "di bawah/tepat ambang -> ok; melewati ambang -> failed":
    check pumpLagCheck(0, 30).status == csOk
    check pumpLagCheck(30, 30).status == csOk
    let telat = pumpLagCheck(31, 30)
    check telat.status == csFailed
    check telat.detail.contains("31")

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
      # Server dijalankan di thread: percobaan pertama bisa mendahului `bind`, dan `httpclient`
      # melempar `OSError` alih-alih mengembalikan kode. Tanpa `try`, test gagal karena waktu,
      # bukan karena readiness — pernah terjadi di gate penuh yang mesinnya lebih sibuk.
      try:
        result = readinessResponse()
        if result.code == 200:
          break
      except CatchableError:
        discard
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

suite "API-1: pool bermasalah dijawab problem+json, bukan 500 kosong":
  test "rute ber-DB saat pool ditutup → 503 SERVICE_UNAVAILABLE + Retry-After":
    # Sebelum T-130, `PoolError` lolos dari handler dan Mummy menjawab 500 **tanpa badan dan tanpa
    # log**. Sekarang satu penangan terakhir menerjemahkannya jadi 503 yang bisa dibedakan klien.
    let deadPool = newDbPool(dbConfigFromEnv(envT))
    deadPool.close()
    let brokenApp = AppContext(version: "itapi-broken-0.0.0", role: "api",
      startedAt: epochTime(), pool: deadPool, clock: systemClock(),
      readiness: databaseProbe(deadPool))
    let port = freePort()
    let server = newApiServer(brokenApp)
    var thread: Thread[ServeArgs]
    createThread(thread, serveInThread, ServeArgs(server: server, port: port))
    let origin = "http://127.0.0.1:" & $port

    let client = newHttpClient(timeout = 15_000)
    defer: client.close()
    # Thread server bisa belum selesai `bind` saat permintaan pertama dikirim; `httpclient`
    # melempar `OSError` alih-alih mengembalikan kode (sama seperti test readyz di atas).
    var response: Response
    let deadline = epochTime() + 10.0
    while epochTime() < deadline:
      try:
        response = client.get(origin & "/api/v1/params")
        break
      except CatchableError:
        sleep(50)
    check response.code.int == 503
    check response.headers.getOrDefault("Content-Type").startsWith("application/problem+json")
    check response.headers.getOrDefault("Retry-After").len > 0
    let body = parseJson(response.body)
    check body["code"].getStr() == "SERVICE_UNAVAILABLE"
    check body["i18nKey"].getStr() == "error_service_unavailable"
    check body["params"]["reason"].getStr() == "pool_unavailable"

suite "ARC-1: readiness memakai pool yang sama dengan permintaan":
  test "pool yang sudah ditutup → check database failed, bukan hijau":
    # Probe dengan pool sendiri akan tetap hijau walau pool permintaan habis/putus — itu yang
    # membuat instance tetap menerima trafik tanpa bisa melayani.
    let deadPool = newDbPool(dbConfigFromEnv(envT))
    deadPool.close()
    let checks = databaseProbe(deadPool)()
    check checks.len == 1
    check checks[0].name == "database"
    check checks[0].status == csFailed
