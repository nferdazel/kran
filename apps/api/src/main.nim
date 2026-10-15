## Titik masuk `kran-api` (spec §12.5 konfigurasi bootstrap, §21.4 role proses).
##
##   kran-api --role=api [--port=8080] [--address=127.0.0.1] [--version=<string>]
##   kran-api --role=migrate [--check|--up] [--root=<dir>]  migrasi: terapkan, atau periksa saja
##   kran-api --role=ctl <perintah> [--root=<dir>] perintah operasional (read-only, kecuali
##                                                `bootstrap-admin`)
##   kran-api --role=ctl bootstrap-admin --username=<nama>   admin pertama (kata sandi diacak,
##                                                          wajib ganti saat login pertama)
##   kran-api --role=worker                        belum ada pekerjaan di Fase 0 → gagal cepat
##
## Kontrak `ctl` berisi perintah yang **aman** (tanpa menulis data), kecuali `bootstrap-admin` yang
## memang menulis — ia sekali-jalan (menolak bila sudah ada pemegang role admin) dan hanya mencetak
## kata sandi awal ke stdout, tidak pernah menyimpannya. Skrip ops dan gate deploy memanggil
## perintah lain di role ini secara otomatis. Role `worker` masih gagal cepat dengan pesan jelas —
## lebih baik daripada diam-diam berjalan sebagai API (O-013).
##
## Yang dibaca dari lingkungan hanyalah konfigurasi bootstrap (koneksi DB, port) — bukan nilai
## bisnis; nilai bisnis selalu dari parameter DB (spec §10, §12.5).

import std/[atomics, os, strutils, sysrand, times]
# Hanya yang dipakai dari `std/posix`: modul itu juga mengekspor `Clock`/`Id`, yang bertabrakan
# dengan `kernel/clock`/`kernel/ids` (dipakai perintah bootstrap admin).
from std/posix import signal, SIGINT, SIGTERM

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import "platform-lib/log"
import dbtools/lib

import kernel/[auditcontext, clock, ids]
import platform/domain/[authz, event, scope]
import platform/infrastructure/[audit_repo, auth_service, outbox_repo]

import ./access
import ./context
import ./drain
import ./events
import ./health
import ./readiness
import ./server
import ./version

const
  ## Nama perintah `ctl` yang membuat admin pertama; disebut di bantuan, penjagaan argumen, dan
  ## pengujian kontrak peran CLI.
  bootstrapAdminCmd* = "bootstrap-admin"

  ## Role yang diberikan `bootstrap-admin`. `platform_admin` diisi migrasi
  ## `0008_platform_rbac_catalogue.sql` beserta seluruh izin yang dikenal, jadi admin pertama
  ## memang bisa bekerja — tanpa itu perintahnya hanya menghasilkan pengguna tanpa izin.
  bootstrapAdminRole* = "platform_admin"

  ## Alfabet kata sandi awal: 32 karakter (pangkat dua, sehingga satu byte acak dipetakan tanpa
  ## bias lewat `and 31`). Huruf yang mudah tertukar saat disalin dibuang (I, O, l, 0, 1) dan
  ## tidak ada spasi — kebijakan kata sandi menolak spasi.
  bootstrapAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

const Usage =
  "pemakaian: kran-api --role=api|migrate|ctl|worker [--root=<dir>] [--port=8080] " &
  "[--address=127.0.0.1] [--version=<string>] [--check|--up] [--username=<nama>] [<perintah ctl>]"

type
  CliOptions = object
    role: Role
    port: int
    address: string
    version: string
    root: string     ## akar repo untuk `--role=migrate` (letak `modules/*/migrations`)
    cmd: string      ## perintah posisi untuk `--role=ctl`
    sub: string      ## subperintah `--role=migrate`: --check | --up
    username: string ## `--role=ctl bootstrap-admin`: nama admin pertama

proc die(msg: string) =
  stderr.writeLine "kran-api: " & msg
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
    elif arg.startsWith("--username="):
      result.username = arg["--username=".len .. ^1]
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
  if result.username.len > 0 and
     not (result.role == roleCtl and result.cmd == bootstrapAdminCmd):
    die("--username hanya untuk `--role=ctl " & bootstrapAdminCmd & "`")

var shutdownRequested: Atomic[bool]

const
  ## Batas waktu menunggu permintaan berjalan saat berhenti (detik). Teknis, bukan nilai bisnis:
  ## batas ini menjaga deploy tidak menggantung tanpa akhir, sementara permintaan normal (termasuk
  ## login dengan PBKDF2 600.000 iterasi) selesai jauh di bawahnya.
  shutdownDrainSeconds* = 10.0

proc onStopSignal(sig: cint) {.noconv.} =
  ## Handler sinyal: seminimal mungkin (async-signal-safe). Tidak menulis log dan tidak menyentuh
  ## DB/Mummy di sini — pekerjaan penutupan dilakukan `watchStop` di thread lain.
  discard sig
  shutdownRequested.store(true)

proc watchStop(app: AppContext) {.thread.} =
  ## Berhenti dengan tenang saat SIGINT/SIGTERM, berurutan:
  ##   1. tandai proses sedang berhenti supaya `/readyz` gagal (penyeimbang beban berhenti mengirim
  ##      permintaan baru);
  ##   2. tunggu permintaan yang **sedang berjalan** selesai, dengan batas waktu;
  ##   3. hentikan pump realtime (beri kesempatan loopnya selesai, dengan batas waktu);
  ##   4. tulis satu baris log, keluar dengan **kode 0**.
  ##
  ## `server.close()` sengaja **tidak** dipakai: berhenti bersih tidak membutuhkannya, dan O-025
  ## mencatat SIGSEGV di jalur teardown itu (probe minimal tidak mereproduksinya — lihat
  ## `docs/spikes/O-025-shutdown.md`). Batas yang diketahui: koneksi yang sudah diterima tetapi belum
  ## sempat masuk ke handler tetap terpotong, dan soket realtime ditutup oleh keluarnya proses
  ## (klien menyambung ulang) — lihat `docs/tasks/T-032.md`.
  while not shutdownRequested.load():
    sleep(100)

  startDraining()
  let deadlineDrain = epochTime() + shutdownDrainSeconds
  while inFlightCount() > 0 and epochTime() < deadlineDrain:
    sleep(20)
  if inFlightCount() > 0:
    stderr.writeLine "kran-api: " & $inFlightCount() &
      " permintaan masih berjalan setelah " & $shutdownDrainSeconds &
      " detik; dilanjutkan berhenti (O-047)"
  else:
    stderr.writeLine "kran-api: permintaan berjalan selesai (drain)"

  if not app.events.isNil:
    app.events.stopPump()
    let deadline = epochTime() + 2.0
    while app.events.pumpReady() and epochTime() < deadline:
      sleep(20)
  stderr.writeLine "kran-api: berhenti dengan tenang (SIGINT/SIGTERM)"
  quit(0)

const CtlUsage* =
  "perintah ctl:\n" &
  "  verify-audit    : periksa rantai audit (kode keluar 1 bila ada entri tidak utuh)\n" &
  "  outbox-status   : jumlah peristiwa outbox per status\n" &
  "  bootstrap-admin : buat admin pertama (butuh --username=<nama>; kata sandi dicetak sekali,\n" &
  "                    wajib diganti saat login pertama; menolak bila admin sudah ada)\n" &
  "  daycloser-status: (belum ada di Fase 0 → kode 3)\n" &
  "  help            : tampilkan bantuan ini"

proc withRoleDb*(body: proc(db: DbConn): int, useTx = false): int =
  ## Peran operasional butuh basis data. Tanpa `KRAN_DATABASE_URL` keluar **kode 2** dengan pesan
  ## jelas (bukan stack trace), supaya skrip ops bisa membedakan salah konfigurasi dari kegagalan.
  ##
  ## `useTx = true` membungkus `body` dalam satu transaksi: dipakai perintah yang melakukan beberapa
  ## tulisan (`bootstrap-admin`: pengguna + role + audit) supaya kegagalan di tengah tidak
  ## meninggalkan pengguna setengah jadi. Perintah read-only cukup memakai koneksi biasa.
  if not databaseUrlSet(envTableFromProcess()):
    stderr.writeLine "kran-api: KRAN_DATABASE_URL kosong — peran ini membutuhkan basis data"
    return 2
  let pool = newDbPool(dbConfigFromProcessEnv())
  defer: pool.close()
  try:
    let run = proc(db: DbConn): int {.closure.} = body(db)
    if useTx:
      pool.withTx(run)
    else:
      pool.withConn(run)
  except DbError as e:
    stderr.writeLine "kran-api: gagal terhadap basis data: " & e.msg
    1
  except MigrateError as e:
    stderr.writeLine "kran-api: migrasi gagal: " & e.msg
    1
  except IOError as e:
    stderr.writeLine "kran-api: gagal membaca berkas: " & e.msg
    1
  except ValueError as e:
    # Kebijakan/konfigurasi tidak sah (mis. kombinasi parameter sesi, atau penugasan role yang
    # melanggar pemisahan tugas). Ditangkap di sini supaya peran operasional tidak pernah
    # menyerahkan stack trace ke skrip ops.
    stderr.writeLine "kran-api: perintah tidak bisa dijalankan: " & e.msg
    1

proc auditExitCode*(rows: openArray[AuditChainRow]): int =
  ## Kontrak keluar `ctl verify-audit`: **0** = rantai utuh, **1** = ada entri tidak utuh.
  ## Dipisah supaya kontraknya bisa diuji tanpa merusak rantai di DB dev.
  for row in rows:
    if not (row.rowHashOk and row.linkOk):
      return 1
  0

proc randomPassword(length: int): string =
  ## Kata sandi acak dari `std/sysrand` (CSPRNG sistem operasi) — **bukan** `std/random`, yang
  ## bisa diprediksi dan tidak boleh dipakai untuk kredensial.
  var bytes = newSeq[byte](length)
  if not urandom(bytes):
    return ""
  for b in bytes:
    result.add bootstrapAlphabet[int(b) and 31]

proc runBootstrapAdmin(db: DbConn, username: string, clock: Clock): int =
  ## Admin pertama: buat pengguna, beri role admin, cetak kata sandi awal **sekali**.
  ##
  ## Kata sandinya diacak di sini dan hanya hidup di memori + stdout; yang tersimpan di DB hanya
  ## hash-nya. Pengguna dibuat dengan `must_change_password = true`, jadi kata sandi ini hanya
  ## berguna untuk satu kali masuk (lihat `handleChangePassword` dan penjagaan izin).
  ##
  ## Pemanggilnya wajib memakai `withRoleDb(..., useTx = true)`: rangkaian tulisan ini (pengguna,
  ## role, audit) harus seluruhnya berhasil atau tidak sama sekali.
  if username.len == 0:
    stderr.writeLine "kran-api: `ctl " & bootstrapAdminCmd & "` butuh --username=<nama>"
    return 2

  let instScope = institutionScope()
  # Nilai keamanan dibaca dari parameter DB (spec §10) — CLI tidak boleh punya ambang sendiri.
  # Tanggalnya tanggal UTC hari ini: parameter keamanan berlaku sejak jauh sebelumnya, dan
  # `settingsOf` memang meminta "per tanggal berapa nilainya dibaca".
  let now = clock.now()
  let utcDate = utcIso(now)
  let settings = settingsOf(db, instScope, utcDate[0 .. 9])
  # Panjangnya mengikuti kebijakan institusi dengan margin, bukan angka tetap di kode.
  let password = randomPassword(max(20, settings.minPasswordLength + 8))
  if password.len == 0:
    stderr.writeLine "kran-api: gagal membaca sumber acak sistem (urandom)"
    return 1
  let problems = passwordProblems(settings.minPasswordLength, username, password)
  if problems.len > 0:
    # Tidak seharusnya terjadi (alfabetnya tanpa spasi). Kalau terjadi, admin akan terjebak dengan
    # kata sandi yang ditolak kebijakannya sendiri — lebih baik gagal sekarang daripada
    # menyerahkan kredensial yang tidak bisa dipakai untuk menggantinya.
    stderr.writeLine "kran-api: kata sandi acak yang dihasilkan tidak lolos kebijakan: " & $problems
    return 1

  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "bootstrap admin pertama", startedAt = clock.now())
  if not bootstrapFirstAdmin(db, ctx, clock, instScope, username, username,
                             bootstrapAdminRole, password, settings.pbkdf2Iterations):
    stderr.writeLine "kran-api: bootstrap ditolak: sudah ada pengguna bernama '" & username &
      "' atau sudah ada pemegang role '" & bootstrapAdminRole & "'."
    stderr.writeLine "  Perintah ini sekali-jalan; untuk admin berikutnya pakai penugasan role biasa."
    return 3

  echo "kata sandi awal untuk '" & username & "' (ditampilkan sekali, tidak disimpan di mana pun):"
  echo password
  echo "Masuk dengan kata sandi itu, lalu ganti saat diminta — sebelum diganti, akun ini hanya"
  echo "bisa memakai /auth/session, /auth/password, dan /auth/logout."
  0

proc runCtl*(command, root: string, username = ""): int =
  ## Peran `ctl`: perintah operasional yang aman (read-only), dipakai skrip ops dan freeze gate.
  ## Satu-satunya pengecualian adalah `bootstrap-admin`, yang memang harus menulis dan sengaja
  ## sekali-jalan.
  if command.len == 0 or command == "help":
    echo CtlUsage
    return 0
  case command
  of bootstrapAdminCmd:
    # `useTx = true`: pengguna, role, dan audit harus lahir bersama — lihat `bootstrapFirstAdmin`.
    withRoleDb(proc(db: DbConn): int {.closure.} =
      runBootstrapAdmin(db, username, systemClock()), useTx = true)
  of "verify-audit":
    withRoleDb(proc(db: DbConn): int {.closure.} =
      let rows = verifyChain(db)
      let code = auditExitCode(rows)
      if code == 0:
        echo "kran-api ctl verify-audit: rantai audit utuh (" & $rows.len & " entri)"
      else:
        var pertama = 0'i64
        var tautanUtuh = false
        for row in rows:
          if not (row.rowHashOk and row.linkOk):
            pertama = row.seq
            tautanUtuh = row.linkOk
            break
        stderr.writeLine "kran-api ctl verify-audit: " &
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
    stderr.writeLine "kran-api: ctl daycloser-status belum ada di Fase 0 (framework daycloser " &
      "menyusul; lihat docs/OPEN_ITEMS.md O-013)"
    3
  else:
    stderr.writeLine "kran-api: perintah ctl tidak dikenal: '" & command & "'"
    stderr.writeLine CtlUsage
    2

proc destructivePending*(status: seq[MigrationStatus]): seq[string] =
  ## Migrasi yang **belum diterapkan** dan bertanda `-- dbtools:destructive`. `--up` menolaknya:
  ## menerapkan DDL destruktif secara otomatis bertabrakan dengan kebijakan expand-only (spec §21.7)
  ## dan dengan janji `ops/scripts/migrate.sh --up` ("migrasi expand-only"). Jalur contract belum ada
  ## di Fase 0, jadi menolak lebih benar daripada menerapkannya diam-diam (O-048).
  for s in status:
    if not s.applied and s.migration.destructive:
      result.add s.migration.id

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
      echo "kran-api migrate --check: " & $(status.len - belum) & "/" & $status.len &
        " diterapkan, " & $drift & " isinya berubah"
      if belum > 0 or drift > 0:
        1
      else:
        0
    else:
      let blocked = destructivePending(status)
      if blocked.len > 0:
        stderr.writeLine "kran-api migrate: " & $blocked.len &
          " migrasi bertanda destruktif belum diterapkan: " & blocked.join(", ")
        stderr.writeLine "  Jalur contract/rollback belum ada di Fase 0 (docs/OPEN_ITEMS.md O-048); " &
          "`--up` sengaja menolaknya."
        3
      else:
        let report = applyMigrations(db, root)
        echo "kran-api migrate: " & $report.applied.len & " migrasi diterapkan, " &
          $report.skipped.len & " dilewati (sudah ada)"
        for id in report.applied:
          echo "  + " & id
        0)

proc main() =
  let opts = parseArgs(commandLineParams())

  if opts.role == roleMigrate:
    quit(runMigrate(opts.root, opts.sub))
  if opts.role == roleCtl:
    quit(runCtl(opts.cmd, opts.root, opts.username))
  if opts.role == roleWorker:
    stderr.writeLine "kran-api: role 'worker' belum ada pekerjaannya (Fase 0: 'api' dan peran " &
      "operasional 'migrate'/'ctl'; lihat docs/OPEN_ITEMS.md O-013)"
    quit(3)

  let logger = newLogger(app = "kran-api")

  # Satu pool per proses: dipakai handler REST (auth/parameter/audit), kebijakan realtime, dan
  # pump `LISTEN` (pump meminjam satu koneksi seumur proses).
  # Tanpa `KRAN_DATABASE_URL` API tetap hidup untuk `/healthz`, dan rute yang butuh DB membalas 501.
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
    discard logger.warn("KRAN_DATABASE_URL kosong: basis data & realtime tidak aktif", [])
  else:
    app.events = newEventService(realtimePolicy(app), pool)
    startPump(app.events)
    discard logger.info("realtime hub aktif",
      [("policy", "sesi cookie + izin per topik (T-012)")])

  # Readiness = dependensi bootstrap (DB) + realtime (O-029): pump yang mati berlarut harus terlihat
  # dari `/readyz`, tetapi penyambungan ulang sekejap tidak boleh mencabut instance dari trafik.
  app.readiness = combineProbes(@[databaseProbe(), realtimeProbe(app.events), drainProbe()])

  # Berhenti bersih (O-025): tanpa ini SIGTERM mematikan proses sebagai sinyal (kode 143) tanpa
  # jalur penutupan apa pun; dengan ini pump dihentikan dan proses keluar kode 0.
  discard signal(SIGINT, onStopSignal)
  discard signal(SIGTERM, onStopSignal)
  var stopThread: Thread[AppContext]
  createThread(stopThread, watchStop, app)

  discard logger.info("kran-api start", [("role", $opts.role),
                                        ("port", $opts.port),
                                        ("address", opts.address),
                                        ("version", opts.version)])
  serveApi(app, opts.port, opts.address)

when isMainModule:
  main()
