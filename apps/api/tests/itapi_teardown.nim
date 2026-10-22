## Test teardown **in-process** server Mummy + pool DB + pump realtime (O-025, T-042). Butuh
## `KRAN_DATABASE_URL`; tanpa itu melewati dirinya sendiri (pola test integrasi lain).
##
## Kenapa terpisah dari `itapi_ws.nim`: test ini **benar-benar menutup** server (`server.close()`) dan
## pool dari dalam proses test. Kalau teardown memang bermasalah, kegagalannya harus terisolasi ke
## berkas ini — bukan menjatuhkan seluruh suite realtime.
##
## Temuan (reproduksi deterministik, lihat `docs/spikes/O-025-shutdown.md`): `server.close()` pada
## Mummy 0.4.8 + ORC **SIGSEGV** bila server dibangun di satu thread lalu `destroy`-nya (`=destroy`
## ServerObj) berjalan di thread lain — ORC menyimpan pembukuan siklus per-thread, jadi menghancurkan
## closure handler yang dialokasikan thread lain membaca state thread itu. Urutan aman: **bangun dan
## layani server di thread yang sama**, lalu `close()` dari thread lain (yang hanya memicu sinyal,
## bukan `destroy`). Itulah yang diuji di sini. Urutan shutdown produksi (T-024/D-031) tidak memanggil
## `close()` sama sekali — sinyal → hentikan pump → `quit(0)` — jadi tidak terpengaruh.

import std/[atomics, httpclient, json, net, os, times, unittest]

import mummy

import dbtools/lib
import "platform-lib/db/config"
import "platform-lib/db/pool"

import ../src/[events, health, readiness, server]
import ./wsclient

const EventsPath = "/api/v1/events/stream"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_teardown: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

type
  ServeArgs = object
    app: AppContext
    port: int

var
  gSrv: Server
  gReady: Atomic[bool]

proc buildAndServe(args: ServeArgs) {.thread.} =
  ## Bangun **dan** layani di thread yang sama: `newServer` (beserta closure handler-nya yang dikelola
  ## ORC) dialokasikan di sini, jadi `destroy` saat `close()` juga berjalan di thread ini.
  gSrv = newApiServer(args.app)
  gReady.store(true, moRelease)
  try:
    gSrv.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard # penutupan server memang bisa memunculkan error; itulah yang diuji

proc freePort(): int =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = int(socket.getLocalAddr()[1])
  socket.close()

proc allowOpen(identity: string): bool {.gcsafe.} =
  identity.len > 0

proc allowTopics(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
  discard identity
  requested

proc allowSession(identity: string): bool {.gcsafe.} =
  discard identity
  true

proc requireOk(cond: bool; msg: string) =
  ## `check` di dalam proc pembantu tidak menggagalkan uji (hanya mencetak), jadi jalur gagal di sini
  ## melempar pengecualian biasa supaya unittest melaporkannya sebagai kegagalan — pola yang sama
  ## dengan test dbtools T-035.
  if not cond:
    raise newException(ValueError, msg)

proc waitUntilServing(port: int) =
  let deadline = epochTime() + 10.0
  while epochTime() < deadline:
    try:
      let probe = newHttpClient(timeout = 1000)
      defer: probe.close()
      if probe.get("http://127.0.0.1:" & $port & "/healthz").code == Http200:
        return
    except CatchableError:
      discard
    sleep(20)
  requireOk(false, "server tidak pernah siap di port " & $port)

proc portClosed(port: int): bool =
  ## True bila tidak ada yang menerima koneksi di port itu lagi.
  try:
    let client = newHttpClient(timeout = 1000)
    defer: client.close()
    discard client.get("http://127.0.0.1:" & $port & "/healthz")
    false
  except CatchableError:
    true

proc runTeardownCycle(): int =
  ## Satu siklus hidup penuh (start → serve → minta → teardown in-process) dengan urutan aman.
  ## Mengembalikan port yang sudah ditutup supaya pemanggil memeriksa bahwa server benar-benar berhenti.
  let port = freePort()
  let dbPool = newDbPool(dbConfigFromEnv(envT))
  block:
    let db = dbPool.acquire()
    discard applyAllMigrations(db, ".")
    dbPool.release(db)

  let svc = newEventService(TopicPolicy(canOpen: allowOpen, allowedTopics: allowTopics,
                                        sessionValid: allowSession), dbPool)
  startPump(svc)
  let app = AppContext(version: "itapi-teardown-0.0.0", role: "api", startedAt: epochTime(),
                       events: svc, pool: dbPool, readiness: migrationProbe(dbPool, "."))

  gReady.store(false, moRelease)
  var serverThread: Thread[ServeArgs]
  createThread(serverThread, buildAndServe, ServeArgs(app: app, port: port))
  # Tunggu thread membangun server (`gSrv` siap dipakai `close()` dari sini).
  let buildDeadline = epochTime() + 10.0
  while epochTime() < buildDeadline and not gReady.load(moAcquire):
    sleep(10)
  requireOk(gReady.load(moAcquire), "thread server tidak pernah membangun server")
  waitUntilServing(port)

  # Satu permintaan HTTP yang menyentuh DB (readiness migrasi) + satu koneksi WebSocket hidup:
  # inilah "server + pool + pump" yang dimaksud O-025, dengan keadaan WebSocket aktif saat ditutup.
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  requireOk(client.get("http://127.0.0.1:" & $port & "/readyz").code.int == 200,
            "readyz tidak 200 saat server hidup")

  var ws = connect("127.0.0.1", port, EventsPath, @[("Cookie", "kran_session=uji")])
  ws.sendText("{\"type\":\"subscribe\",\"topics\":[\"test.teardown\"]}")
  requireOk(ws.nextOfType("subscribed", 5000)["denied"].len == 0, "langganan ditolak")
  defer: ws.close()

  # Teardown in-process, urutan aman: hentikan pump (tidak ada lagi kirim lintas-thread ke Mummy),
  # lalu `close()` dari thread ini — `destroy` berjalan di thread yang membangun/melayani server.
  svc.stopPump()
  let stopDeadline = epochTime() + 5.0
  while epochTime() < stopDeadline and svc.pumpReady():
    sleep(20)
  gSrv.close()
  joinThread(serverThread)
  dbPool.close()
  port

suite "teardown in-process server Mummy (O-025, T-042)":
  test "start → serve → stopPump → server.close → join → pool.close; proses tetap hidup":
    let port = runTeardownCycle()
    # Server benar-benar berhenti (port bebas), bukan hanya "proses tidak crash".
    check portClosed(port)
    check port > 0

  test "siklus kedua tetap berjalan (keadaan global ORC/Mummy tidak rusak)":
    let port = runTeardownCycle()
    check portClosed(port)
