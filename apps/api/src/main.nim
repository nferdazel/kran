## Titik masuk `cbs-api` (spec §12.5 konfigurasi bootstrap, §21.4 role proses).
##
##   cbs-api --role=api [--port=8080] [--address=127.0.0.1] [--version=<string>]
##
## Role lain (`worker`, `ctl`, `migrate`) belum punya pekerjaan di Fase 0 dan **gagal cepat**
## dengan pesan jelas — lebih baik daripada diam-diam berjalan sebagai API (O-013).
##
## Yang dibaca dari lingkungan hanyalah konfigurasi bootstrap (koneksi DB, port) — bukan nilai
## bisnis; nilai bisnis selalu dari parameter DB (spec §10, §12.5).

import std/[atomics, os, posix, strutils, times]

import "platform-lib/db/config"
import "platform-lib/db/pool"
import "platform-lib/log"

import kernel/clock

import ./access
import ./context
import ./events
import ./health
import ./readiness
import ./server
import ./version

const Usage =
  "pemakaian: cbs-api --role=api|worker|ctl|migrate [--port=8080] " &
  "[--address=127.0.0.1] [--version=<string>]"

type
  CliOptions = object
    role: Role
    port: int
    address: string
    version: string

proc die(msg: string) =
  stderr.writeLine "cbs-api: " & msg
  stderr.writeLine Usage
  quit(2)

proc parseArgs(argv: seq[string]): CliOptions =
  result = CliOptions(role: roleApi, port: 8080, address: "127.0.0.1",
                      version: appVersion())
  for arg in argv:
    if arg.startsWith("--role="):
      try:
        result.role = parseRole(arg["--role=".len .. ^1])
      except ValueError as e:
        die(e.msg)
    elif arg.startsWith("--port="):
      try:
        result.port = parseInt(arg["--port=".len .. ^1])
      except ValueError:
        die("port bukan angka: " & arg)
      if result.port < 1 or result.port > 65535:
        die("port di luar rentang 1..65535: " & $result.port)
    elif arg.startsWith("--address="):
      result.address = arg["--address=".len .. ^1]
    elif arg.startsWith("--version="):
      result.version = arg["--version=".len .. ^1]
    elif arg in ["-h", "--help"]:
      echo Usage
      quit(0)
    elif arg.len > 0:
      die("argumen tidak dikenal: " & arg)

var shutdownRequested: Atomic[bool]

proc onStopSignal(sig: cint) {.noconv.} =
  ## Handler sinyal: seminimal mungkin (async-signal-safe). Tidak menulis log dan tidak menyentuh
  ## DB/Mummy di sini — pekerjaan penutupan dilakukan `watchStop` di thread lain.
  discard sig
  shutdownRequested.store(true)

proc watchStop(app: AppContext) {.thread.} =
  ## Berhenti dengan tenang saat SIGINT/SIGTERM: hentikan pump realtime (beri kesempatan loopnya
  ## selesai, dengan batas waktu), tulis satu baris log, lalu keluar dengan **kode 0**.
  ##
  ## `server.close()` sengaja **tidak** dipakai: berhenti bersih tidak membutuhkannya, dan O-025
  ## mencatat SIGSEGV di jalur teardown itu (probe minimal tidak mereproduksinya — lihat
  ## `docs/spikes/O-025-shutdown.md`). Batas yang diketahui: permintaan yang sedang berjalan
  ## dipotong saat proses keluar (O-047).
  while not shutdownRequested.load():
    sleep(100)
  if not app.events.isNil:
    app.events.stopPump()
    let deadline = epochTime() + 2.0
    while app.events.pumpReady() and epochTime() < deadline:
      sleep(20)
  stderr.writeLine "cbs-api: berhenti dengan tenang (SIGINT/SIGTERM)"
  quit(0)

proc main() =
  let opts = parseArgs(commandLineParams())

  if opts.role != roleApi:
    stderr.writeLine "cbs-api: role '" & $opts.role &
      "' belum diimplementasikan (Fase 0: hanya 'api'; lihat docs/OPEN_ITEMS.md O-013)"
    quit(3)

  let logger = newLogger(app = "cbs-api")

  # Satu pool per proses: dipakai handler REST (auth/parameter/audit), kebijakan realtime, dan
  # pump `LISTEN` (pump meminjam satu koneksi seumur proses).
  # Tanpa `CBS_DATABASE_URL` API tetap hidup untuk `/healthz`, dan rute yang butuh DB membalas 501.
  var pool: DbPool
  if databaseUrlSet(envTableFromProcess()):
    pool = newDbPool(dbConfigFromProcessEnv())

  var app = AppContext(
    version: opts.version,
    role: $opts.role,
    startedAt: epochTime(),
    readiness: databaseProbe(),
    pool: pool,
    clock: systemClock(),
  )

  if pool.isNil:
    discard logger.warn("CBS_DATABASE_URL kosong: basis data & realtime tidak aktif", [])
  else:
    app.events = newEventService(realtimePolicy(app), pool)
    startPump(app.events)
    discard logger.info("realtime hub aktif",
      [("policy", "sesi cookie + izin per topik (T-012)")])

  # Berhenti bersih (O-025): tanpa ini SIGTERM mematikan proses sebagai sinyal (kode 143) tanpa
  # jalur penutupan apa pun; dengan ini pump dihentikan dan proses keluar kode 0.
  discard signal(SIGINT, onStopSignal)
  discard signal(SIGTERM, onStopSignal)
  var stopThread: Thread[AppContext]
  createThread(stopThread, watchStop, app)

  discard logger.info("cbs-api start", [("role", $opts.role),
                                        ("port", $opts.port),
                                        ("address", opts.address),
                                        ("version", opts.version)])
  serveApi(app, opts.port, opts.address)

main()
