## Titik masuk `cbs-api` (spec §12.5 konfigurasi bootstrap, §21.4 role proses).
##
##   cbs-api --role=api [--port=8080] [--address=127.0.0.1] [--version=<string>]
##   cbs-api --role=migrate [--check|--up] [--root=<dir>]  migrasi: terapkan, atau periksa saja
##   cbs-api --role=ctl <perintah> [--root=<dir>] perintah operasional aman (read-only)
##   cbs-api --role=worker                        belum ada pekerjaan di Fase 0 → gagal cepat
##
## Kontrak `ctl` sengaja hanya berisi perintah yang **aman** (tanpa menulis data), karena skrip ops
## dan gate deploy memanggilnya otomatis. Role `worker` masih gagal cepat dengan pesan jelas —
## lebih baik daripada diam-diam berjalan sebagai API (O-013).
##
## Yang dibaca dari lingkungan hanyalah konfigurasi bootstrap (koneksi DB, port) — bukan nilai
## bisnis; nilai bisnis selalu dari parameter DB (spec §10, §12.5).

import std/[atomics, os, posix, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import "platform-lib/log"
import dbtools/lib

import kernel/clock
import platform/domain/event
import platform/infrastructure/[audit_repo, outbox_repo]

import ./access
import ./context
import ./events
import ./health
import ./readiness
import ./server
import ./version

const Usage =
  "pemakaian: cbs-api --role=api|migrate|ctl|worker [--root=<dir>] [--port=8080] " &
  "[--address=127.0.0.1] [--version=<string>] [--check|--up] [<perintah ctl>]"

type
  CliOptions = object
    role: Role
    port: int
    address: string
    version: string
    root: string ## akar repo untuk `--role=migrate` (letak `modules/*/migrations`)
    cmd: string  ## perintah posisi untuk `--role=ctl`
    sub: string  ## subperintah `--role=migrate`: --check | --up

proc die(msg: string) =
  stderr.writeLine "cbs-api: " & msg
  stderr.writeLine Usage
  quit(2)

proc parseArgs(argv: seq[string]): CliOptions =
  result = CliOptions(role: roleApi, port: 8080, address: "127.0.0.1",
                      version: appVersion(), root: ".")
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
    elif arg.startsWith("--root="):
      result.root = arg["--root=".len .. ^1]
    elif arg == "--check" or arg == "--up":
      result.sub = arg
    elif arg in ["-h", "--help"]:
      echo Usage
      quit(0)
    elif arg.len > 0:
      if result.cmd.len > 0:
        die("terlalu banyak argumen: " & arg)
      result.cmd = arg

  if result.cmd.len > 0 and result.role != roleCtl:
    die("argumen posisi hanya untuk --role=ctl: " & result.cmd)
  if result.sub.len > 0 and result.role != roleMigrate:
    die("subperintah " & result.sub & " hanya untuk --role=migrate")

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

const CtlUsage =
  "perintah ctl:\n" &
  "  verify-audit   : periksa rantai audit (kode keluar 1 bila ada entri tidak utuh)\n" &
  "  outbox-status  : jumlah peristiwa outbox per status\n" &
  "  daycloser-status: (belum ada di Fase 0 → kode 3)\n" &
  "  help           : tampilkan bantuan ini"

proc withRoleDb(body: proc(db: DbConn): int): int =
  ## Peran operasional butuh basis data. Tanpa `CBS_DATABASE_URL` keluar **kode 2** dengan pesan
  ## jelas (bukan stack trace), supaya skrip ops bisa membedakan salah konfigurasi dari kegagalan.
  if not databaseUrlSet(envTableFromProcess()):
    stderr.writeLine "cbs-api: CBS_DATABASE_URL kosong — peran ini membutuhkan basis data"
    return 2
  let pool = newDbPool(dbConfigFromProcessEnv())
  defer: pool.close()
  try:
    pool.withConn(proc(db: DbConn): int {.closure.} = body(db))
  except DbError as e:
    stderr.writeLine "cbs-api: gagal terhadap basis data: " & e.msg
    1
  except MigrateError as e:
    stderr.writeLine "cbs-api: migrasi gagal: " & e.msg
    1
  except IOError as e:
    stderr.writeLine "cbs-api: gagal membaca berkas: " & e.msg
    1

proc auditExitCode*(rows: openArray[AuditChainRow]): int =
  ## Kontrak keluar `ctl verify-audit`: **0** = rantai utuh, **1** = ada entri tidak utuh.
  ## Dipisah supaya kontraknya bisa diuji tanpa merusak rantai di DB dev.
  for row in rows:
    if not (row.rowHashOk and row.linkOk):
      return 1
  0

proc runCtl*(command, root: string): int =
  ## Peran `ctl`: perintah operasional yang aman (read-only), dipakai skrip ops dan freeze gate.
  if command.len == 0 or command == "help":
    echo CtlUsage
    return 0
  case command
  of "verify-audit":
    withRoleDb(proc(db: DbConn): int {.closure.} =
      let rows = verifyChain(db)
      let code = auditExitCode(rows)
      if code == 0:
        echo "cbs-api ctl verify-audit: rantai audit utuh (" & $rows.len & " entri)"
      else:
        var pertama = 0'i64
        var tautanUtuh = false
        for row in rows:
          if not (row.rowHashOk and row.linkOk):
            pertama = row.seq
            tautanUtuh = row.linkOk
            break
        stderr.writeLine "cbs-api ctl verify-audit: " &
          (if tautanUtuh: "payload berubah" else: "rantai putus") & " pada seq " &
          $pertama & " dari " & $rows.len & " entri"
      code)
  of "outbox-status":
    withRoleDb(proc(db: DbConn): int {.closure.} =
      for status in [Pending, InFlight, Done, Dead]:
        echo "  " & $status & ": " & $countByStatus(db, status)
      0)
  of "daycloser-status":
    # Dipanggil freeze gate `ops/scripts/deploy-vps.sh`. Framework `daycloser` belum ada di
    # Fase 0, jadi perintahnya **dikenali tapi belum diimplementasikan** (kode 3) — lebih jelas
    # daripada "perintah tidak dikenal" (kode 2) yang terbaca seperti salah ketik.
    stderr.writeLine "cbs-api: ctl daycloser-status belum ada di Fase 0 (framework daycloser " &
      "menyusul; lihat docs/OPEN_ITEMS.md O-013)"
    3
  else:
    stderr.writeLine "cbs-api: perintah ctl tidak dikenal: '" & command & "'"
    stderr.writeLine CtlUsage
    2

proc runMigrate*(root: string, sub = ""): int =
  ## Peran `migrate` (kontrak yang dipakai `ops/scripts/migrate.sh` dan gate deploy):
  ##   tanpa subperintah / `--up` : terapkan migrasi yang tertunda lalu keluar (idempoten)
  ##   `--check`                  : **read-only** — keluar 1 bila ada migrasi belum diterapkan atau
  ##                                isi migrasi yang sudah diterapkan berubah (drift)
  ## Memakai `dbtools/lib`, jalur yang sama dengan `./task dbtools migrate`/`validate`, supaya hanya
  ## ada satu implementasi migrasi (O-013). Migrasi contract/rollback (`--contract`/`--down`) belum
  ## ada di Fase 0 dan ditolak skripnya sendiri, bukan diam-diam dianggap `--up`.
  withRoleDb(proc(db: DbConn): int {.closure.} =
    let status = reportStatus(db, root)
    if sub == "--check":
      var belum = 0
      var drift = 0
      for s in status:
        if not s.applied:
          inc belum
        elif s.checksumChanged:
          inc drift
      echo "cbs-api migrate --check: " & $(status.len - belum) & "/" & $status.len &
        " diterapkan, " & $drift & " isinya berubah"
      if belum > 0 or drift > 0:
        1
      else:
        0
    else:
      let report = applyMigrations(db, root)
      echo "cbs-api migrate: " & $report.applied.len & " migrasi diterapkan, " &
        $report.skipped.len & " dilewati (sudah ada)"
      for id in report.applied:
        echo "  + " & id
      0)

proc main() =
  let opts = parseArgs(commandLineParams())

  if opts.role == roleMigrate:
    quit(runMigrate(opts.root, opts.sub))
  if opts.role == roleCtl:
    quit(runCtl(opts.cmd, opts.root))
  if opts.role == roleWorker:
    stderr.writeLine "cbs-api: role 'worker' belum ada pekerjaannya (Fase 0: 'api' dan peran " &
      "operasional 'migrate'/'ctl'; lihat docs/OPEN_ITEMS.md O-013)"
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

when isMainModule:
  main()
