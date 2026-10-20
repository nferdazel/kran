import std/[httpclient, json, net, os, strutils, times, unittest]

import openapi/lib

import mummy

import platform/domain/authz

import platform/infrastructure/worker_repo

import ../src/[access, health, main, readiness, server]

## Test server HTTP tanpa layanan eksternal (tanpa DB): aman dijalankan di CI mana pun, jadi
## dinamai `t*` (unit) dan bukan `it*`. Yang diuji: respons nyata **sesuai kontrak** (spec §13) —
## status, `Content-Type`, dan bentuk JSON (subset JSON Schema di `tools/openapi`).
##
## Readiness yang menyentuh DB diuji terpisah di `itapi.nim` (butuh KRAN_DATABASE_URL).

const ContractPath = "packages/contracts/openapi/kran-api.yaml"

type
  ServeArgs = object
    server: Server
    port: int

var
  contract: Contract
  apiServer: Server
  baseUrl: string
  serverThread: Thread[ServeArgs]

proc freePort(): int =
  ## Tanya OS port bebas: bind ke port 0, baca hasilnya, lalu tutup.
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = int(socket.getLocalAddr()[1])
  socket.close()

proc serveInThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard # penutupan server di akhir test memang bisa memunculkan error

proc startServer(readiness: ReadinessProbe): tuple[server: Server, url: string] =
  let port = freePort()
  result.url = "http://127.0.0.1:" & $port
  result.server = newServer(requestHandler(AppContext(
    version: "test-0.0.0",
    role: "api",
    startedAt: epochTime(),
    readiness: readiness,
  )))
  createThread(serverThread, serveInThread, ServeArgs(server: result.server, port: port))

proc waitUntilServing(url: string) =
  let deadline = epochTime() + 5.0
  while epochTime() < deadline:
    try:
      let probe = newHttpClient(timeout = 1000)
      defer: probe.close()
      if probe.get(url & "/healthz").code == Http200:
        return
    except CatchableError:
      discard
    sleep(50)
  check false # server tidak pernah siap

proc getJson(client: HttpClient, path: string):
    tuple[code: int, contentType: string, body: JsonNode] =
  let response = client.get(baseUrl & path)
  result.code = response.code.int
  result.contentType = response.headers["Content-Type"]
  result.body = parseJson(response.body)

proc failuresFor(path, verb, status: string, body: JsonNode): seq[string] =
  ## Bentuk respons nyata vs skema kontrak.
  contract.validateValue(contract.responseSchema(path, verb, status), body, "$")

proc assertNoSchemaProblems(path, verb, status: string, body: JsonNode,
                            contentType = "application/json") =
  let problems = contract.validateValue(
    contract.responseSchema(path, verb, status, contentType), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc assertProblemEnvelope(body: JsonNode) =
  ## Amplop RFC 9457 dipakai untuk error yang tidak terikat operasi (mis. 404 rute tak dikenal).
  let problems = contract.validateValue(
    contract.doc["components"]["schemas"]["Problem"], body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

suite "respons sistem sesuai kontrak OpenAPI":
  setup:
    contract = loadContractFile(ContractPath)
    (apiServer, baseUrl) = startServer(nil)
    waitUntilServing(baseUrl)

  # Server sengaja tidak ditutup di akhir test. `server.close()` pada Mummy 0.4.8 + ORC men-`destroy`
  # di thread pelayan, sedangkan di harness ini server dibangun di thread test — urutan itu SIGSEGV
  # (repro + urutan aman ada di T-042 / docs/spikes/O-025-shutdown.md). Suite ini tetap butuh server
  # hidup sepanjang run, dan proses test berakhir sendiri sehingga thread server ikut berakhir.

  test "/healthz -> 200 sesuai skema Health":
    let client = newHttpClient(timeout = 2000)
    defer: client.close()

    let response = getJson(client, "/healthz")
    check response.code == 200
    check "application/json" in response.contentType
    check response.body["status"].getStr() == "ok"
    check response.body["role"].getStr() == "api"
    assertNoSchemaProblems("/healthz", "GET", "200", response.body)

  test "/readyz tanpa probe -> 200 ok sesuai skema Readiness":
    let client = newHttpClient(timeout = 2000)
    defer: client.close()

    let response = getJson(client, "/readyz")
    check response.code == 200
    check response.body["status"].getStr() == "ok"
    check response.body["checks"].len == 0
    assertNoSchemaProblems("/readyz", "GET", "200", response.body)

  test "/readyz dengan probe gagal -> 503 degraded sesuai skema Readiness":
    ## Kontrak mengizinkan 503 dengan bentuk Readiness yang sama; bentuknya harus tetap valid.
    let failing = startServer(proc(): seq[ReadinessCheck] {.gcsafe.} =
      @[ReadinessCheck(name: "database", status: csFailed, detail: "sengaja gagal")])
    waitUntilServing(failing.url)
    let client = newHttpClient(timeout = 2000)
    defer: client.close()

    let response = client.get(failing.url & "/readyz")
    check response.code.int == 503
    let body = parseJson(response.body)
    check body["status"].getStr() == "degraded"
    check body["checks"][0]["status"].getStr() == "failed"
    assertNoSchemaProblems("/readyz", "GET", "503", body)

  test "rute tak dikenal -> 404 problem+json sesuai skema Problem":
    let client = newHttpClient(timeout = 2000)
    defer: client.close()

    let response = client.get(baseUrl & "/tidak-ada-rute")
    check response.code.int == 404
    check "application/problem+json" in response.headers["Content-Type"]

    let body = parseJson(response.body)
    assertProblemEnvelope(body)
    check body["code"].getStr() == "NOT_FOUND"
    check body["i18nKey"].getStr() == "error_not_found"
    check body["traceId"].getStr().len > 0

  test "traceId meneruskan X-Request-Id dari proxy":
    let client = newHttpClient(timeout = 2000)
    defer: client.close()

    client.headers["X-Request-Id"] = "trace-dari-caddy"
    let response = client.get(baseUrl & "/tidak-ada-rute")
    check parseJson(response.body)["traceId"].getStr() == "trace-dari-caddy"

  test "rute realtime tanpa layanan event -> 501 problem+json sesuai kontrak":
    ## `tapi` menyusun `AppContext` tanpa `events` (tanpa DB): rute stream harus membalas problem
    ## terdeklarasi, bukan crash. Jalur 426/401/403/101 diuji `itapi_ws.nim` (butuh DB + pump).
    let client = newHttpClient(timeout = 2000)
    defer: client.close()

    let response = client.get(baseUrl & "/api/v1/events/stream")
    check response.code.int == 501
    check "application/problem+json" in response.headers["Content-Type"]
    let body = parseJson(response.body)
    check body["code"].getStr() == "NOT_IMPLEMENTED"
    assertNoSchemaProblems("/api/v1/events/stream", "GET", "501", body, "application/problem+json")

  test "rute hanya menerima method yang dideklarasikan":
    let client = newHttpClient(timeout = 2000)
    defer: client.close()

    # /healthz hanya GET; method lain dibalas 405 dengan amplop problem (dideklarasikan kontrak).
    let response = client.post(baseUrl & "/healthz", "")
    check response.code.int == 405
    check "application/problem+json" in response.headers["Content-Type"]
    let body = parseJson(response.body)
    check body["code"].getStr() == "METHOD_NOT_ALLOWED"
    assertNoSchemaProblems("/healthz", "GET", "405", body, "application/problem+json")

suite "rute T-012 tanpa basis data":
  test "auth/parameter/audit membalas 501 problem+json sesuai kontrak":
    ## `tapi` menyusun `AppContext` tanpa `pool`: rute yang butuh DB harus membalas problem yang
    ## dideklarasikan kontrak, bukan crash atau diam. Jalur 200/401/403/409-nya diuji
    ## `itapi_auth.nim` (butuh DB + seed dev).
    setup:
      contract = loadContractFile(ContractPath)
      (apiServer, baseUrl) = startServer(nil)
      waitUntilServing(baseUrl)

    let cases = [
      ("POST", "/api/v1/auth/login", "login"),
      ("GET", "/api/v1/auth/session", "getSession"),
      ("POST", "/api/v1/auth/logout", "logout"),
      ("GET", "/api/v1/params", "listParams"),
      ("POST", "/api/v1/params/platform.security.max_failed_logins/changes",
       "submitParamChange"),
      ("POST", "/api/v1/params/changes/00000000-0000-7000-8000-000000000000/approve",
       "approveParamChange"),
      ("GET", "/api/v1/audit", "listAudit"),
    ]
    for (verb, path, operationId) in cases:
      let client = newHttpClient(timeout = 2000)
      defer: client.close()
      var response: Response
      if verb == "GET":
        response = client.get(baseUrl & path)
      else:
        response = client.post(baseUrl & path, "{}")
      check response.code.int == 501
      check "application/problem+json" in response.headers["Content-Type"]
      let body = parseJson(response.body)
      check body["code"].getStr() == "NOT_IMPLEMENTED"
      # Path ber-parameter di kontrak memakai `{nama}`; yang diuji di sini path nyata.
      let contractPath =
        if operationId == "submitParamChange": "/api/v1/params/{key}/changes"
        elif operationId == "approveParamChange":
          "/api/v1/params/changes/{paramValueId}/approve"
        else: path
      assertNoSchemaProblems(contractPath, verb, "501", body, "application/problem+json")

suite "pola rute & pemetaan topik (murni)":
  test "pola kontrak `{nama}` diterjemahkan ke router Mummy `@nama`":
    check mummyPattern("/healthz") == "/healthz"
    check mummyPattern("/api/v1/params/{key}/changes") == "/api/v1/params/@key/changes"
    check mummyPattern("/api/v1/params/changes/{paramValueId}/approve") ==
      "/api/v1/params/changes/@paramValueId/approve"

  test "setiap topik realtime punya izin yang membukanya":
    check permissionForTopic("param.changed") == "platform.param.read"
    check permissionForTopic("topik.tak.dikenal") == ""
    check knownTopics().len == topicPermissions.len
    for topic in knownTopics():
      check permissionForTopic(topic).len > 0

suite "bootstrap: kata sandi acak (murni, tanpa DB)":
  ## `randomPassword` hidup di `main.nim` (peran CLI) tetapi murni: hanya `std/sysrand` +
  ## `domain/authz.passwordClasses`. Diuji di suite `t*` supaya jaminan kelas karakternya tidak
  ## bergantung pada DB dev.
  test "jumlah kelas karakter yang dituntut kebijakan selalu terpenuhi":
    ## Tanpa jaminan ini, kata sandi panjang 20 bisa keluar tanpa angka (~0,4% untuk
    ## `minClasses = 3`) dan `bootstrap-admin` gagal saat tidak ada cara lain masuk.
    for _ in 1 .. 250:
      let terkuat = randomPassword(20, 4)
      check terkuat.len == 20
      check passwordClasses(terkuat) >= 4
      check passwordClasses(randomPassword(20, 3)) >= 3
      check passwordClasses(randomPassword(20, 2)) >= 2
    # `minClasses = 1` hanya menuntut panjang; alfabetnya sendiri sudah memberi >= 1 kelas.
    check passwordClasses(randomPassword(20, 1)) >= 1

suite "readiness worker konsumen (O-081)":
  ## Logika murni di sini (tanpa DB), jadi ikut berjalan di CI yang tidak menyediakan Postgres.
  test "denyut segar → ok":
    check workerCheck(ageSeconds = 3, uptimeSeconds = 600).status == csOk

  test "belum pernah melapor, masih masa tenggang → ok (deploy/restart baru)":
    let c = workerCheck(ageSeconds = -1, uptimeSeconds = 30)
    check c.status == csOk
    check c.detail == "menunggu denyut pertama"

  test "belum pernah melapor melewati masa tenggang → gagal":
    let c = workerCheck(ageSeconds = -1, uptimeSeconds = workerStartupGraceSeconds + 1)
    check c.status == csFailed
    check c.detail == "worker konsumen belum pernah melapor"

  test "denyut basi setelah masa tenggang → gagal dengan usia":
    let stale = workerStaleSeconds + 5
    let c = workerCheck(ageSeconds = int64(stale), uptimeSeconds = 600)
    check c.status == csFailed
    check c.detail.contains($stale)

  test "batas tepat ambang masih ok, satu detik lewat gagal":
    check workerCheck(ageSeconds = 30, uptimeSeconds = 600, staleSeconds = 30).status == csOk
    check workerCheck(ageSeconds = 31, uptimeSeconds = 600, staleSeconds = 30).status == csFailed

  test "anggaran denyut menutup poll interval maksimum (60 dtk)":
    # `poll_interval_ms` maksimum di seed adalah 60000 ms; ambang harus lebih longgar dari itu
    # ditambah satu interval tulis, kalau tidak worker idle yang sehat akan gagal rutin.
    check workerStaleSeconds > 60 + heartbeatWriteSeconds

  test "event DEAD terlihat tanpa menggagalkan readiness":
    check outboxDeadCheck(dead = 0).status == csOk
    check outboxDeadCheck(dead = 0).detail.len == 0
    let c = outboxDeadCheck(dead = 2)
    check c.name == "outbox-dead"
    check c.status == csOk
    check c.detail.contains("2 event DEAD")
