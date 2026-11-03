## Batas parser HTTP/WebSocket dipin eksplisit di `server.nim` (T-044).
##
## Kenapa ada: insiden e2e 3 Nov 2026 (CI `2bec65e`, job "Web (svelte-check + axe + Playwright)")
## mematikan proses API dengan SIGSEGV di jalur **alokasi parser**: `afterRecvHttp` → potongan
## string baris permintaan (`system/indices.nim` `[]` → `newString`) → `alloc.nim` `rawAlloc` →
## `compensateCounters` ("Attempt to read from nil?") → 60+ test e2e gagal berantai dengan
## `ECONNREFUSED 127.0.0.1:8099`. Rerun job yang sama hijau, jadi ini intermiten.
##
## Test ini **tidak** mengklaim menyembuhkan akarnya (lihat `docs/tasks/T-044.md` + entri batas
## yang diterima): yang dijaga adalah satu hal yang memang milik kita — batas ukuran parser yang
## dulu diwarisi diam-diam dari bawaan Mummy. Yang diuji adalah **perilaku**, bukan angka konstanta:
## koneksi yang menyatakan badan/header melebihi batas harus ditutup parser sebelum handler
## dipanggil, dan koneksi wajar harus tetap dilayani (kontrol positif, supaya "semua ditutup" tidak
## lolos sebagai hijau).

import std/[atomics, net, os, strutils, times, unittest]

import mummy

import ../src/[context, server]

const
  ## Batas yang **dipin** test ini sebagai angka, bukan dibaca dari konstanta yang diuji: kalau
  ## muatan uji ikut naik saat batas dinaikkan, mutasi `apiMaxBodyLen` 1 MB → 4 MB lolos tanpa suara
  ## (sudah dicoba). Angka ini juga kontrak dokumentasi di `docs/ACCEPTED-LIMITS.md`.
  pinnedMaxBodyLen = 1024 * 1024
  pinnedMaxHeadersLen = 8 * 1024

type
  ServeArgs = object
    app: AppContext
    port: int

var
  gReady: Atomic[bool]
  gPort: int
  gServerThread: Thread[ServeArgs]

proc buildAndServe(args: ServeArgs) {.thread.} =
  ## Bangun **dan** layani di thread yang sama (urutan aman T-042/O-025: `destroy` harus berjalan
  ## di thread yang mengalokasikan closure handler yang dikelola ORC).
  let srv = newApiServer(args.app)
  gReady.store(true, moRelease)
  try:
    srv.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard # penutupan server memang bisa memunculkan error

proc freePort(): int =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = int(socket.getLocalAddr()[1])
  socket.close()

proc waitUntilServing(port: int) =
  let deadline = epochTime() + 10.0
  while epochTime() < deadline:
    try:
      let probe = newSocket()
      defer: probe.close()
      probe.connect("127.0.0.1", Port(port), timeout = 1000)
      probe.send("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
      return
    except CatchableError:
      sleep(20)
  raise newException(ValueError, "server tidak pernah siap di port " & $port)

proc startApi() =
  ## Server sengaja tidak ditutup di akhir test: `close()` dari thread uji bukan urutan aman yang
  ## diuji di sini (lihat O-025/T-042 dan `itapi_teardown.nim`); proses test berakhir sendiri.
  gPort = freePort()
  gReady.store(false, moRelease)
  let app = AppContext(version: "tapi-limits-0.0.0", role: "api", startedAt: epochTime(),
                       serverThreads: 2)
  createThread(gServerThread, buildAndServe, ServeArgs(app: app, port: gPort))
  let buildDeadline = epochTime() + 10.0
  while epochTime() < buildDeadline and not gReady.load(moAcquire):
    sleep(10)
  waitUntilServing(gPort)

proc rawConnect(port: int): Socket =
  result = newSocket()
  result.connect("127.0.0.1", Port(port), timeout = 2000)

proc closedByPeer(port: int, payload: string): bool =
  ## True bila parser menutup koneksi setelah `payload` (tanpa menjawab).
  let socket = rawConnect(port)
  defer: socket.close()
  socket.send(payload)
  var buf = newString(1024)
  # Batas baca 2 s: cukup untuk FIN loopback, dan "koneksi masih terbuka" (timeout) = false.
  try:
    result = socket.recv(buf, buf.len, timeout = 2000) == 0
  except CatchableError:
    result = false

proc responseTo(port: int, payload: string): string =
  ## Teks respons pertama (kontrol positif: server hidup dan handler berjalan).
  let socket = rawConnect(port)
  defer: socket.close()
  socket.send(payload)
  var buf = newString(4096)
  try:
    let n = socket.recv(buf, buf.len, timeout = 2000)
    if n > 0:
      result = buf[0 ..< n]
  except CatchableError:
    result = ""

suite "batas parser API dipin eksplisit (T-044)":
  setup:
    startApi()

  test "batas parser yang dipakai API masih angka yang dipin (1 MiB / 8 KiB)":
    check apiMaxBodyLen == pinnedMaxBodyLen
    check apiMaxHeadersLen == pinnedMaxHeadersLen

  test "badan melebihi batas ditutup parser sebelum handler dipanggil":
    ## `Content-Length` saja sudah cukup: Mummy menutup koneksi begitu header selesai dibaca, jadi
    ## tidak perlu mengirim 1 MB+ badan yang justru memperbesar memori yang diuji.
    let overLimit = "POST /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
      "Content-Type: application/json\r\nConnection: keep-alive\r\n" &
      "Content-Length: " & $(pinnedMaxBodyLen + 1) & "\r\n\r\n"
    check closedByPeer(gPort, overLimit)

  test "header melebihi batas ditutup parser":
    ## Tanpa `\r\n\r\n`: parser menyerah begitu buffer header melewati batas (bukan menunggu
    ## selamanya sampai klien kehabisan waktu).
    let overLimit = "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Pad: " &
      repeat('a', pinnedMaxHeadersLen) & "\r\n"
    check closedByPeer(gPort, overLimit)

  test "kontrol positif: badan kecil tetap dilayani (handler berjalan)":
    let body = "{}"
    let ok = "POST /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
      "Content-Type: application/json\r\nConnection: close\r\n" &
      "Content-Length: " & $body.len & "\r\n\r\n" & body
    # /healthz hanya menerima GET: 405 membuktikan permintaan sampai ke router (bukan ditutup
    # parser dan bukan 500 karena server setengah mati).
    check responseTo(gPort, ok).startsWith("HTTP/1.1 405")
