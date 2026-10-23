## Titik masuk `kran-api` (spec §12.5 konfigurasi bootstrap, §21.4 role proses).
##
##   kran-api --role=api [--port=8080] [--address=127.0.0.1] [--version=<string>]
##   kran-api --role=migrate [--check|--up|--seed|--contract|--down N] [--root=<dir>]
##                                              migrasi: terapkan expand, terapkan contract,
##                                              seed parameter base, batalkan N migrasi terakhir,
##                                              atau periksa saja
##   kran-api --role=ctl <perintah> [--root=<dir>] perintah operasional (read-only, kecuali
##                                                `bootstrap-admin` dan `reset-password`)
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

import std/[atomics, json, options, os, strutils, sysrand, times]
# Hanya yang dipakai dari `std/posix`: modul itu juga mengekspor `Clock`/`Id`, yang bertabrakan
# dengan `kernel/clock`/`kernel/ids` (dipakai perintah bootstrap admin).
from std/posix import signal, SIGINT, SIGTERM

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import "platform-lib/crypto/fieldcrypto"
import "platform/infrastructure/password_hasher"
import "platform-lib/log"
import dbtools/lib

import kernel/[auditcontext, clock, ids]
import platform/domain/[audit, authz, event, scope]
import platform/infrastructure/[audit_repo, auth_repo, auth_service, outbox_repo, realtime_config]

import ./access
import ./context
import ./drain
import ./events
import ./health
import ./posting
import ./readiness
import ./server
import ./version

const
  ## Nama perintah `ctl` yang membuat admin pertama; disebut di bantuan, penjagaan argumen, dan
  ## pengujian kontrak peran CLI.
  bootstrapAdminCmd* = "bootstrap-admin"

  ## Perintah `ctl` reset kata sandi (O-071/O-090 tindak lanjut): operator yang lupa kata sandi
  ## awal tidak punya jalur lain — hash tidak boleh diubah langsung lewat SQL (melewati audit).
  resetPasswordCmd* = "reset-password"

  ## Perintah `ctl` yang menyimpan kepala rantai audit ke berkas terpisah (O-009).
  auditAnchorCmd* = "audit-anchor"

  ## Provision an operational user (teller/checker) after the first admin exists. The first admin
  ## itself is still created by `bootstrap-admin`.
  createUserCmd* = "create-user"

  ## User lifecycle commands (RBAC hardening). Offboarding used to require raw SQL, which bypasses
  ## audit and session revocation; these run the same transactional/audit/session discipline as
  ## `reset-password`.
  assignRoleCmd* = "assign-role"
  revokeRoleCmd* = "revoke-role"
  disableUserCmd* = "disable-user"
  enableUserCmd* = "enable-user"
  unlockUserCmd* = "unlock-user"

  ## Perintah `ctl` yang menerima `--username` (semua perintah yang menyasar satu pengguna).
  usernameCommands* = [bootstrapAdminCmd, resetPasswordCmd, createUserCmd, assignRoleCmd,
                       revokeRoleCmd, disableUserCmd, enableUserCmd, unlockUserCmd]

  ## Perintah `ctl` yang menerima `--user-role` dan/atau `--branch`.
  roleAssignmentCommands* = [createUserCmd, assignRoleCmd, revokeRoleCmd]

  ## Role yang diberikan `bootstrap-admin`. `platform_admin` diisi migrasi
  ## `0008_platform_rbac_catalogue.sql` beserta seluruh izin yang dikenal, jadi admin pertama
  ## memang bisa bekerja — tanpa itu perintahnya hanya menghasilkan pengguna tanpa izin.
  bootstrapAdminRole* = "platform_admin"

  ## Alfabet kata sandi awal: 32 karakter (pangkat dua, sehingga satu byte acak dipetakan tanpa
  ## bias lewat `and 31`). Huruf yang mudah tertukar saat disalin dibuang (I, O, l, 0, 1) dan
  ## tidak ada spasi — kebijakan kata sandi menolak spasi.
  bootstrapAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  ## Kumpulan campuran untuk **menjamin** kelas karakter yang dituntut kebijakan (O-052):
  ## indeks 0..15 selalu huruf kecil, indeks 23..30 selalu simbol. 32 karakter, jadi pemetaannya
  ## tetap `and` (tanpa bias) — bukan `mod`.
  bootstrapMixed = "abcdefghjkmnpqrstuvwxyz!@#%^&*-="

const Usage =
  "pemakaian: kran-api --role=api|migrate|ctl|worker [--root=<dir>] [--port=8080] " &
  "[--address=127.0.0.1] [--version=<string>] [--check|--up|--seed|--contract|--down N] " &
  "[--username=<nama>] [--user-role=<peran>] [--branch=<uuid>] [--full-name=<nama>] " &
  "[--out=<berkas>] [<perintah ctl>]"

type
  CliOptions = object
    role: Role
    port: int
    address: string
    version: string
    root: string     ## akar repo untuk `--role=migrate` (letak `modules/*/migrations`)
    cmd: string      ## perintah posisi untuk `--role=ctl`
    sub: string      ## subperintah `--role=migrate`: --check | --up | --seed | --contract | --down
    subArg: string   ## angka `N` untuk `--role=migrate --down N`
    username: string ## `--role=ctl bootstrap-admin`: nama admin pertama
    userRole: string ## `--role=ctl create-user`: role RBAC yang diberikan
    branchId: string ## `--role=ctl create-user`: cabang penugasan role (opsional)
    fullName: string ## `--role=ctl create-user`: nama tampilan (opsional)
    outPath: string  ## `--role=ctl audit-anchor`: berkas tujuan (append)

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
    elif arg.startsWith("--user-role="):
      result.userRole = arg["--user-role=".len .. ^1]
    elif arg.startsWith("--branch="):
      result.branchId = arg["--branch=".len .. ^1]
    elif arg.startsWith("--full-name="):
      result.fullName = arg["--full-name=".len .. ^1]
    elif arg.startsWith("--out="):
      result.outPath = arg["--out=".len .. ^1]
    elif arg.startsWith("--root="):
      result.root = arg["--root=".len .. ^1]
    elif arg in ["--check", "--up", "--seed", "--contract", "--down"]:
      result.sub = arg
    elif arg in ["-h", "--help"]:
      echo Usage
      quit(0)
    elif arg.len > 0:
      if result.cmd.len > 0 or result.subArg.len > 0:
        die("terlalu banyak argumen: " & arg)
      # Angka telanjang hanya punya satu arti di role ini: jumlah rollback `--down N`.
      if arg[0] in {'0' .. '9'}:
        result.subArg = arg
      else:
        result.cmd = arg

  if result.cmd.len > 0 and result.role != roleCtl:
    die("argumen posisi hanya untuk --role=ctl: " & result.cmd)
  if result.subArg.len > 0 and (result.role != roleMigrate or result.sub != "--down"):
    die("angka jumlah rollback hanya untuk `--role=migrate --down N`: " & result.subArg)
  if result.sub.len > 0 and result.role != roleMigrate:
    die("subperintah " & result.sub & " hanya untuk --role=migrate")
  if result.outPath.len > 0 and
     not (result.role == roleCtl and result.cmd == auditAnchorCmd):
    die("--out hanya untuk `--role=ctl " & auditAnchorCmd & "`")
  if result.username.len > 0 and
     not (result.role == roleCtl and result.cmd in usernameCommands):
    die("--username hanya untuk perintah ctl: " & usernameCommands.join(", "))
  if (result.userRole.len > 0 or result.branchId.len > 0) and
     not (result.role == roleCtl and result.cmd in roleAssignmentCommands):
    die("--user-role dan --branch hanya untuk perintah ctl: " & roleAssignmentCommands.join(", "))
  if result.fullName.len > 0 and
     not (result.role == roleCtl and result.cmd == createUserCmd):
    die("--full-name hanya untuk `--role=ctl " & createUserCmd & "`")

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
  "  reset-password  : setel kata sandi baru acak untuk pengguna yang ada (butuh --username=<nama>;\n" &
  "                    dicetak sekali, wajib diganti, semua sesi dicabut, audit user.password_reset)\n" &
  "  audit-anchor    : catat kepala rantai audit (seq + hash) ke stdout dan/atau --out=<berkas>\n" &
  "  create-user     : provision an operator account (requires --username=<name>,\n" &
  "                    --user-role=<role>; optional --branch=<uuid>, --full-name=<name>; the\n" &
  "                    initial password is printed once and must be changed at first login)\n" &
  "  assign-role     : grant a role to an existing user (requires --username=<name>,\n" &
  "                    --user-role=<role>; optional --branch=<uuid>; audit user.role_grant)\n" &
  "  revoke-role     : revoke a role from a user (requires --username=<name>,\n" &
  "                    --user-role=<role>; optional --branch=<uuid>; refuses to revoke the last\n" &
  "                    platform_admin; audit user.role_revoke)\n" &
  "  disable-user    : set a user INACTIVE and revoke all sessions (requires --username=<name>;\n" &
  "                    audit user.disable)\n" &
  "  enable-user     : set an INACTIVE user back to ACTIVE (requires --username=<name>; only\n" &
  "                    INACTIVE -> ACTIVE; audit user.enable)\n" &
  "  unlock-user     : unlock a LOCKED user and clear the failure counter (requires\n" &
  "                    --username=<name>; only LOCKED -> ACTIVE; audit user.unlock)\n" &
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

proc randomPassword*(length, minClasses: int): string =
  ## Kata sandi acak dari `std/sysrand` (CSPRNG sistem operasi) — **bukan** `std/random`, yang
  ## bisa diprediksi dan tidak boleh dipakai untuk kredensial.
  ##
  ## Kelas karakter yang dituntut kebijakan (`minClasses`) **dijamin**, bukan diharapkan
  ## kebetulan: satu wakil tiap kelas ditaruh di posisi tetap (0 angka, 1 huruf besar, 2 huruf
  ## kecil, 3 simbol), sisanya diundi dari `bootstrapAlphabet`. Mengandalkan undian tidak cukup —
  ## alfabet dasarnya 24 huruf besar + 8 angka, jadi kata sandi panjang 20 bisa keluar tanpa angka
  ## sama sekali (~0,4%) dan langsung ditolak kebijakan institusi; `bootstrap-admin` lalu gagal di
  ## tengah jalan, tepat saat tidak ada cara lain masuk.
  ##
  ## Syarat pemanggil: `length >= 4` (dipakai `max(20, …)` di `runBootstrapAdmin`) dan
  ## `minClasses` 0..4.
  var bytes = newSeq[byte](length)
  if not urandom(bytes):
    return ""
  for b in bytes:
    result.add bootstrapAlphabet[int(b) and 31]
  if minClasses >= 2:
    result[0] = bootstrapAlphabet[24 + (int(bytes[0]) and 7)] # 24..31 = angka
    result[1] = bootstrapAlphabet[int(bytes[1]) and 23] # 0..23 = huruf besar
  if minClasses >= 3:
    result[2] = bootstrapMixed[int(bytes[2]) and 15] # 0..15 = huruf kecil
  if minClasses >= 4:
    result[3] = bootstrapMixed[23 + (int(bytes[3]) and 7)] # 23..30 = simbol

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
  let password = randomPassword(max(20, settings.minPasswordLength + 8),
    settings.minPasswordClasses)
  if password.len == 0:
    stderr.writeLine "kran-api: gagal membaca sumber acak sistem (urandom)"
    return 1
  let problems = passwordProblems(settings.minPasswordLength, settings.minPasswordClasses,
    username, password)
  if problems.len > 0:
    # Tidak seharusnya terjadi (kelas karakternya dijamin dan alfabetnya tanpa spasi). Kalau
    # terjadi, admin akan terjebak dengan kata sandi yang ditolak kebijakannya sendiri — lebih
    # baik gagal sekarang daripada menyerahkan kredensial yang tidak bisa dipakai.
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

proc runCreateUser*(db: DbConn, username, roleCode, branchId, fullName: string,
                    clock: Clock): tuple[code: int, password: string] =
  ## Provision an operator account with one RBAC role and print its initial password once.
  ##
  ## Codes: 0 success, 1 write/random failure, 2 missing arguments, 3 username/role rejected.
  ## The caller must run this inside `withRoleDb(..., useTx = true)`; user, role grant, and audit
  ## are committed together.
  if username.len == 0 or roleCode.len == 0:
    stderr.writeLine "kran-api: `ctl " & createUserCmd &
      "` requires --username=<name> and --user-role=<role>"
    return (2, "")

  let displayName = if fullName.len > 0: fullName else: username
  if userByUsername(db, username).isSome:
    stderr.writeLine "kran-api: user '" & username & "' already exists"
    return (3, "")
  if not roleExists(db, roleCode):
    stderr.writeLine "kran-api: unknown role '" & roleCode & "'"
    return (3, "")
  # Fail before inserting anything: a branch role needs a branch, an institution role must not
  # have one. Wrong combination = rejected (code 3), same class as an unknown role.
  let scopeProblem = roleAssignmentProblem(db, roleCode, branchId)
  if scopeProblem.len > 0:
    stderr.writeLine "kran-api: " & roleCode & ": " & scopeProblem
    return (3, "")

  let instScope = institutionScope()
  let now = clock.now()
  let nowIso = utcIso(now)
  let settings = settingsOf(db, instScope, nowIso[0 .. 9])
  let password = randomPassword(max(20, settings.minPasswordLength + 8),
    settings.minPasswordClasses)
  if password.len == 0:
    stderr.writeLine "kran-api: failed to read the system random source (urandom)"
    return (1, "")
  let problems = passwordProblems(settings.minPasswordLength, settings.minPasswordClasses,
    username, password)
  if problems.len > 0:
    stderr.writeLine "kran-api: generated password does not satisfy policy: " & $problems
    return (1, "")

  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "create operator user", startedAt = now)
  if not createUserWithRole(db, ctx, clock, instScope, username, displayName, roleCode,
                            branchId, password, settings.pbkdf2Iterations):
    stderr.writeLine "kran-api: user provisioning was rejected (username taken or role unknown)"
    return (3, "")
  (0, password)

proc resetUserPassword*(db: DbConn, username: string, clock: Clock): tuple[code: int,
    password: string] =
  ## Setel kata sandi acak baru untuk pengguna yang **sudah ada**.
  ##
  ## Kenapa bukan SQL manual: hash langsung lewat SQL melewati audit dan pencabutan sesi. Jalur ini
  ## menulis hash + `must_change_password` + mencabut sesi + audit dalam **satu transaksi** (pemanggil
  ## wajib `withRoleDb(..., useTx = true)`), dan mengembalikan kata sandi hanya di memori untuk
  ## dicetak sekali oleh `ctl`.
  ##
  ## Kode: 0 berhasil, 1 gagal menulis/acak, 2 argumen kurang, 3 pengguna tidak ada.
  if username.len == 0:
    stderr.writeLine "kran-api: `ctl " & resetPasswordCmd & "` butuh --username=<nama>"
    return (2, "")

  let instScope = institutionScope()
  let now = clock.now()
  let nowIso = utcIso(now)
  let settings = settingsOf(db, instScope, nowIso[0 .. 9])
  let found = userByUsername(db, username)
  if found.isNone:
    stderr.writeLine "kran-api: tidak ada pengguna '" & username & "'"
    return (3, "")
  let user = found.get()

  let password = randomPassword(max(20, settings.minPasswordLength + 8),
    settings.minPasswordClasses)
  if password.len == 0:
    stderr.writeLine "kran-api: gagal membaca sumber acak sistem (urandom)"
    return (1, "")
  let problems = passwordProblems(settings.minPasswordLength, settings.minPasswordClasses,
    username, password)
  if problems.len > 0:
    stderr.writeLine "kran-api: kata sandi acak tidak lolos kebijakan: " & $problems
    return (1, "")

  if not setPassword(db, user.userId, $hashPassword(password, settings.pbkdf2Iterations),
                     mustChange = true):
    stderr.writeLine "kran-api: gagal menyetel kata sandi untuk '" & username & "'"
    return (1, "")

  # Riwayat ditulis **setelah** hash berhasil diganti (urutan sama dengan `changePassword`), supaya
  # jalur gagal tidak meninggalkan baris riwayat tanpa perubahan sandi.
  discard recordSupersededPassword(db, user.userId, user.passwordHash,
    settings.passwordHistoryCount)

  # Lockout dipulihkan dengan UPDATE **atomik**, bukan dari snapshot `user.status` yang bisa basi:
  # login gagal bersamaan dapat commit `LOCKED` setelah baris pengguna dibaca tetapi sebelum titik
  # ini. Hanya LOCKED → ACTIVE; INACTIVE/SUSPENDED sengaja tidak disentuh (reset bukan cara
  # mengaktifkan kembali akun yang dinonaktifkan).
  discard db.execAffectedRows(sql"""
    UPDATE platform.app_user SET status = 'ACTIVE', updated_at = now()
     WHERE user_id = ?::uuid AND status = 'LOCKED'""", user.userId)

  let revoked = revokeSessionsOfUser(db, user.userId, nowIso, "reset kata sandi oleh operator")
  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "reset kata sandi oleh operator", startedAt = now)
  discard appendAudit(db, newAuditEntry(ctx, "user.password_reset", "app_user", user.userId,
    clock, businessDate = businessDateFor(db, instScope, nowIso),
    after = %*{"username": user.username, "must_change_password": true,
               "sessions_revoked": revoked}))
  (0, password)

proc runAssignRole*(db: DbConn, username, roleCode, branchId: string, clock: Clock): int =
  ## Menugaskan role ke pengguna yang **sudah ada** (lifecycle/offboarding, RBAC hardening).
  ##
  ## Kode: 0 berhasil, 1 gagal menulis, 2 argumen kurang, 3 ditolak/tidak ditemukan (pengguna/role
  ## tidak ada, kombinasi scope/cabang tidak cocok, sudah memegang role itu, atau konflik SoD).
  ## Pemanggil wajib `withRoleDb(..., useTx = true)`: penugasan + audit harus lahir bersama.
  if username.len == 0 or roleCode.len == 0:
    stderr.writeLine "kran-api: `ctl " & assignRoleCmd &
      "` butuh --username=<nama> dan --user-role=<peran>"
    return 2
  let found = userByUsername(db, username)
  if found.isNone:
    stderr.writeLine "kran-api: tidak ada pengguna '" & username & "'"
    return 3
  if not roleExists(db, roleCode):
    stderr.writeLine "kran-api: role tidak dikenal '" & roleCode & "'"
    return 3
  let problem = roleAssignmentProblem(db, roleCode, branchId)
  if problem.len > 0:
    stderr.writeLine "kran-api: " & problem
    return 3
  let user = found.get()
  try:
    if not grantRole(db, user.userId, roleCode, branchId, ""):
      stderr.writeLine "kran-api: pengguna '" & username & "' sudah memegang role '" &
        roleCode & "' pada cabang itu"
      return 3
  except ValueError as e:
    # Pemisahan tugas (SoD): penugasan yang melahirkan pasangan terlarang ditolak `grantRole`.
    stderr.writeLine "kran-api: penugasan role ditolak: " & e.msg
    return 3
  let instScope = institutionScope()
  let now = clock.now()
  let nowIso = utcIso(now)
  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "assign role", startedAt = now)
  discard appendAudit(db, newAuditEntry(ctx, "user.role_grant", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, instScope, nowIso),
    after = %*{"username": user.username, "role": roleCode, "branch": branchId}))
  0

proc runRevokeRole*(db: DbConn, username, roleCode, branchId: string, clock: Clock): int =
  ## Mencabut role dari pengguna (offboarding). Mencabut **persis** grant yang cocok: cabang kosong
  ## = grant tingkat institusi, cabang terisi = grant cabang itu.
  ##
  ## Penjaga penguncian-keluar: `platform_admin` terakhir tidak boleh dicabut — tanpa itu sistem
  ## bisa kehilangan satu-satunya akun yang bisa mengelola RBAC.
  ##
  ## Kode: 0 berhasil, 1 gagal menulis, 2 argumen kurang, 3 ditolak/tidak ditemukan.
  if username.len == 0 or roleCode.len == 0:
    stderr.writeLine "kran-api: `ctl " & revokeRoleCmd &
      "` butuh --username=<nama> dan --user-role=<peran>"
    return 2
  let found = userByUsername(db, username)
  if found.isNone:
    stderr.writeLine "kran-api: tidak ada pengguna '" & username & "'"
    return 3
  if not roleExists(db, roleCode):
    stderr.writeLine "kran-api: role tidak dikenal '" & roleCode & "'"
    return 3
  let problem = roleAssignmentProblem(db, roleCode, branchId)
  if problem.len > 0:
    stderr.writeLine "kran-api: " & problem
    return 3
  let user = found.get()
  if roleCode.toLowerAscii == bootstrapAdminRole and
     bootstrapAdminRole in roleCodesOfUser(db, user.userId) and
     countUsersWithRole(db, bootstrapAdminRole) <= 1:
    stderr.writeLine "kran-api: menolak mencabut role '" & bootstrapAdminRole &
      "' terakhir — tidak boleh mengunci semua admin keluar"
    return 3
  if not revokeRole(db, user.userId, roleCode, branchId):
    stderr.writeLine "kran-api: pengguna '" & username & "' tidak memegang role '" & roleCode &
      "' pada cabang itu"
    return 3
  let instScope = institutionScope()
  let now = clock.now()
  let nowIso = utcIso(now)
  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "revoke role", startedAt = now)
  discard appendAudit(db, newAuditEntry(ctx, "user.role_revoke", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, instScope, nowIso),
    after = %*{"username": user.username, "role": roleCode, "branch": branchId}))
  0

proc runDisableUser*(db: DbConn, username: string, clock: Clock): int =
  ## Menonaktifkan akun dan mencabut seluruh sesinya. Kode: 0 berhasil, 1 gagal menulis, 2 argumen
  ## kurang, 3 pengguna tidak ada. Pemanggil wajib `withRoleDb(..., useTx = true)`.
  if username.len == 0:
    stderr.writeLine "kran-api: `ctl " & disableUserCmd & "` butuh --username=<nama>"
    return 2
  let found = userByUsername(db, username)
  if found.isNone:
    stderr.writeLine "kran-api: tidak ada pengguna '" & username & "'"
    return 3
  let user = found.get()
  # Same lockout guard as `revoke-role`: disabling the last admin leaves nobody who can manage
  # RBAC, which is a one-way door without shell access.
  if bootstrapAdminRole in roleCodesOfUser(db, user.userId) and
     countUsersWithRole(db, bootstrapAdminRole) <= 1:
    stderr.writeLine "kran-api: menolak menonaktifkan role '" & bootstrapAdminRole &
      "' terakhir — tidak boleh mengunci semua admin keluar"
    return 3
  let instScope = institutionScope()
  let now = clock.now()
  let nowIso = utcIso(now)
  if not setUserStatus(db, user.userId, "INACTIVE"):
    stderr.writeLine "kran-api: gagal menonaktifkan '" & username & "'"
    return 1
  let revoked = revokeSessionsOfUser(db, user.userId, nowIso, "akun dinonaktifkan operator")
  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "disable user", startedAt = now)
  discard appendAudit(db, newAuditEntry(ctx, "user.disable", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, instScope, nowIso),
    after = %*{"username": user.username, "sessions_revoked": revoked}))
  0

proc runEnableUser*(db: DbConn, username: string, clock: Clock): int =
  ## Mengaktifkan kembali akun yang **dinonaktifkan**: hanya `INACTIVE` → `ACTIVE`. `LOCKED` dan
  ## `SUSPENDED` sengaja ditolak (yang pertama punya `unlock-user`, yang kedua butuh keputusan
  ## berbeda) — kebijakan konservatif supaya aktifkan-tidak-diam-diam mengubah keadaan lain.
  ## Kode: 0 berhasil, 1 gagal menulis, 2 argumen kurang, 3 pengguna tidak ada / bukan INACTIVE.
  if username.len == 0:
    stderr.writeLine "kran-api: `ctl " & enableUserCmd & "` butuh --username=<nama>"
    return 2
  let found = userByUsername(db, username)
  if found.isNone:
    stderr.writeLine "kran-api: tidak ada pengguna '" & username & "'"
    return 3
  let user = found.get()
  if not enableInactiveUser(db, user.userId):
    stderr.writeLine "kran-api: '" & username &
      "' tidak dalam status INACTIVE; hanya akun nonaktif yang bisa diaktifkan kembali"
    return 3
  let instScope = institutionScope()
  let now = clock.now()
  let nowIso = utcIso(now)
  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "enable user", startedAt = now)
  discard appendAudit(db, newAuditEntry(ctx, "user.enable", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, instScope, nowIso),
    after = %*{"username": user.username}))
  0

proc runUnlockUser*(db: DbConn, username: string, clock: Clock): int =
  ## Membuka akun yang terkunci: hanya `LOCKED` → `ACTIVE`, penghitung gagal dan `locked_until`
  ## dikosongkan. Kode: 0 berhasil, 1 gagal menulis, 2 argumen kurang, 3 pengguna tidak ada /
  ## bukan LOCKED.
  if username.len == 0:
    stderr.writeLine "kran-api: `ctl " & unlockUserCmd & "` butuh --username=<nama>"
    return 2
  let found = userByUsername(db, username)
  if found.isNone:
    stderr.writeLine "kran-api: tidak ada pengguna '" & username & "'"
    return 3
  let user = found.get()
  if not unlockUser(db, user.userId):
    stderr.writeLine "kran-api: '" & username &
      "' tidak terkunci; hanya akun LOCKED yang bisa dibuka"
    return 3
  let instScope = institutionScope()
  let now = clock.now()
  let nowIso = utcIso(now)
  let ctx = newAuditContext(Id(""), device = "kran-api ctl",
    reason = "unlock user", startedAt = now)
  discard appendAudit(db, newAuditEntry(ctx, "user.unlock", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, instScope, nowIso),
    after = %*{"username": user.username}))
  0

proc auditAnchorLine*(db: DbConn, clock: Clock): string =
  ## Satu baris anchor: waktu UTC, `seq` dan `hash` kepala rantai. Tanpa PII/kredensial.
  let head = auditHead(db)
  utcIso(clock.now()) & " seq=" & $head.seq & " hash=" & head.hash

proc runAuditAnchor*(db: DbConn, clock: Clock, outPath: string): string =
  ## Menghitung anchor dan (bila `outPath` diisi) **menambahkannya** ke berkas append-only.
  ## Berkas sengaja di luar DB: penyerang dengan hak tulis DB tetap tidak bisa menulis ulang
  ## seluruh rantai tanpa ketahuan saat anchor dibandingkan (spec §18.2).
  result = auditAnchorLine(db, clock)
  if outPath.len > 0:
    var f = open(outPath, fmAppend)
    try:
      f.writeLine result
      f.flushFile()
    finally:
      f.close()

proc runCtl*(command, root: string, username = "", outPath = "", userRole = "",
             branchId = "", fullName = ""): int =
  ## Peran `ctl`: perintah operasional yang aman (read-only), dipakai skrip ops dan freeze gate.
  ## Pengecualian yang memang menulis: `bootstrap-admin` (sekali-jalan), `create-user`
  ## (provisioning akun operator), `reset-password` (pemulihan darurat), dan siklus hidup pengguna
  ## `assign-role`/`revoke-role`/`disable-user`/`enable-user`/`unlock-user` — semuanya dengan audit
  ## dan (bila relevan) pencabutan sesi dalam satu transaksi.
  if command.len == 0 or command == "help":
    echo CtlUsage
    return 0
  case command
  of bootstrapAdminCmd:
    # `useTx = true`: pengguna, role, dan audit harus lahir bersama — lihat `bootstrapFirstAdmin`.
    withRoleDb(proc(db: DbConn): int {.closure.} =
      runBootstrapAdmin(db, username, systemClock()), useTx = true)
  of createUserCmd:
    # Password is printed after COMMIT, like `reset-password`: a credential that never took effect
    # must not reach the operator.
    var password = ""
    let code = withRoleDb(proc(db: DbConn): int {.closure.} =
      let r = runCreateUser(db, username, userRole, branchId, fullName, systemClock())
      password = r.password
      r.code, useTx = true)
    if code == 0:
      echo "initial password for '" & username & "' (shown once, not stored):"
      echo password
      echo "Sign in with it and change it when prompted."
    code
  of resetPasswordCmd:
    # Kata sandi dicetak **setelah** transaksi selesai: kalau COMMIT/audit gagal, operator tidak
    # boleh menerima kredensial yang sebenarnya tidak berlaku.
    var password = ""
    let code = withRoleDb(proc(db: DbConn): int {.closure.} =
      let r = resetUserPassword(db, username, systemClock())
      password = r.password
      r.code, useTx = true)
    if code == 0:
      echo "kata sandi baru untuk '" & username & "' (ditampilkan sekali, tidak disimpan):"
      echo password
      echo "Masuk dengan kata sandi itu, lalu ganti saat diminta."
    code
  of assignRoleCmd:
    # Satu transaksi: penugasan role + audit harus lahir bersama (pola `bootstrap-admin`).
    withRoleDb(proc(db: DbConn): int {.closure.} =
      runAssignRole(db, username, userRole, branchId, systemClock()), useTx = true)
  of revokeRoleCmd:
    withRoleDb(proc(db: DbConn): int {.closure.} =
      runRevokeRole(db, username, userRole, branchId, systemClock()), useTx = true)
  of disableUserCmd:
    withRoleDb(proc(db: DbConn): int {.closure.} =
      runDisableUser(db, username, systemClock()), useTx = true)
  of enableUserCmd:
    withRoleDb(proc(db: DbConn): int {.closure.} =
      runEnableUser(db, username, systemClock()), useTx = true)
  of unlockUserCmd:
    withRoleDb(proc(db: DbConn): int {.closure.} =
      runUnlockUser(db, username, systemClock()), useTx = true)
  of auditAnchorCmd:
    withRoleDb(proc(db: DbConn): int {.closure.} =
      echo runAuditAnchor(db, systemClock(), outPath)
      0)
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

proc seedBaseFiles*(root: string): seq[string] =
  ## Berkas seed yang boleh dipakai produksi: **hanya** `packs/*/generated/*.sql`.
  ## `packs/*/seed/` (data dev/test) tidak pernah ikut — satu titik yang diuji `itapi_roles`.
  seedFiles(root, dev = false)

proc runMigrate*(root: string, sub = "", subArg = ""): int =
  ## Peran `migrate` (kontrak yang dipakai `ops/scripts/migrate.sh` dan gate deploy):
  ##   tanpa subperintah / `--up` : terapkan migrasi expand yang tertunda lalu keluar (idempoten)
  ##   `--check`                  : **read-only** — keluar 1 bila ada migrasi expand belum diterapkan
  ##                                atau isi migrasi yang sudah diterapkan berubah (drift)
  ##   `--seed`                   : terapkan `packs/*/generated/*.sql` (parameter base) — idempoten,
  ##                                **tanpa** seed dev/test; dipakai deploy sebelum worker start
  ##   `--contract`               : terapkan migrasi bertanda contract (opt-in manual, §21.4)
  ##   `--down N`                 : batalkan N migrasi yang terakhir diterapkan (butuh pasangan
  ##                                `<nama>.down.sql`)
  ## Memakai `dbtools/lib`, jalur yang sama dengan `./task dbtools migrate`/`validate`, supaya hanya
  ## ada satu implementasi migrasi (O-013).
  ##
  ## Kode keluar punya arti tetap: 0 berhasil, 1 salah data (mis. isi migrasi berubah), 2 salah pakai,
  ## 3 = **dikenali tetapi sengaja ditolak pada keadaan itu** (N tidak jelas, expand masih tertunda,
  ## berkas pasangan rollback tidak ada, atau `--seed` tidak menemukan berkas seed — root salah).
  ## Skrip ops membaca bedanya.
  withRoleDb(proc(db: DbConn): int {.closure.} =
    let status = reportStatus(db, root)
    case sub
    of "--check":
      # Migrasi contract tidak dihitung sebagai "tertunda": berkas contract memang menunggu operator
      # memutuskan kapan dijalankan, jadi menghitungnya akan membuat gate deploy gagal selamanya
      # begitu sebuah berkas contract dirilis.
      var belum = 0
      var drift = 0
      # Satu daftar dipakai untuk hitungan **dan** allowlist deploy; dua loop terpisah bisa
      # menyimpang dan membuat gate memverifikasi subset yang salah.
      var ids: seq[string]
      for s in status:
        if s.migration.contract and not s.applied:
          ids.add s.migration.id
        elif not s.applied:
          inc belum
        elif s.checksumChanged:
          inc drift
      let contractTertunda = ids.len
      echo "kran-api migrate --check: " & $(status.len - belum - contractTertunda) & "/" &
        $status.len & " diterapkan, " & $drift & " isinya berubah"
      # Baris mesin selalu ada supaya skrip deploy bisa membedakan "tidak ada contract" dari
      # "format keluaran berubah"; keduanya dulu sama-sama berarti "lewati contract".
      echo "  contract_pending=" & $contractTertunda
      if contractTertunda > 0:
        echo "  migrasi contract menunggu `--contract` (bukan urusan --check): " & ids.join(", ")
        echo "  contract_ids=" & ids.join(", ")
      if belum > 0 or drift > 0:
        1
      else:
        0
    of "--seed":
      # O-090: deploy me-restart worker sebelum parameter tersemai → worker exit 2. Seed base
      # dijalankan di jalur yang sama dengan migrasi supaya urutannya tidak bisa terlewat.
      # Berkas generated idempoten (`param_definitions` DO UPDATE metadata, `param_values`
      # DO NOTHING) dan **tidak** memuat seed dev/test.
      try:
        let files = seedBaseFiles(root)
        if files.len == 0:
          stderr.writeLine "kran-api migrate --seed: tidak ada berkas seed di " & root &
            " — salah konfigurasi (repo selalu punya packs/*/generated/*.sql)"
          return 3
        for rel in files:
          execScript(db, readFile(root / rel))
          echo "  + " & rel
        echo "kran-api migrate --seed: " & $files.len & " berkas diterapkan (idempoten)"
        0
      except CatchableError as e:
        stderr.writeLine "kran-api migrate --seed: ditolak — " & e.msg
        1

    of "--contract":
      let tertunda = expandPending(status)
      if tertunda.len > 0:
        stderr.writeLine "kran-api migrate --contract: " & $tertunda.len &
          " migrasi expand masih tertunda: " & tertunda.join(", ")
        stderr.writeLine "  Contract selalu datang setelah expand — jalankan `--up` lebih dulu."
        return 3
      try:
        let report = applyMigrations(db, root, contract = true)
        echo "kran-api migrate --contract: " & $report.applied.len & " diterapkan, " &
          $report.skipped.len & " dilewati (sudah ada)"
        for id in report.applied:
          echo "  + " & id
        0
      except MigrateError as e:
        stderr.writeLine "kran-api migrate --contract: ditolak — " & e.msg
        3
    of "--down":
      if subArg.len == 0:
        stderr.writeLine "kran-api migrate --down: butuh jumlah N (mis. `--down 1`)"
        stderr.writeLine "  N tidak pernah ditebak: angka yang salah = skema mundur terlalu jauh."
        return 3
      var n: int
      try:
        n = parseInt(subArg)
      except ValueError:
        stderr.writeLine "kran-api migrate --down: jumlah bukan angka: '" & subArg & "'"
        return 2
      try:
        let undone = rollbackMigrations(db, root, n)
        echo "kran-api migrate --down: " & $undone.len & " migrasi dibatalkan"
        for id in undone:
          echo "  - " & id
        0
      except MigrateError as e:
        stderr.writeLine "kran-api migrate --down: ditolak — " & e.msg
        3
    else:
      let blocked = destructivePending(status)
      if blocked.len > 0:
        stderr.writeLine "kran-api migrate: " & $blocked.len &
          " migrasi bertanda destruktif belum diterapkan: " & blocked.join(", ")
        stderr.writeLine "  Jalur expand sengaja menolaknya: berkas seperti itu memakai penanda " &
          "`-- dbtools:contract <alasan>` dan dijalankan lewat `--contract`."
        3
      else:
        let report = applyMigrations(db, root)
        echo "kran-api migrate: " & $report.applied.len & " migrasi diterapkan, " &
          $report.skipped.len & " dilewati (sudah ada)"
        for id in report.applied:
          echo "  + " & id
        if report.contractPending.len > 0:
          echo "  " & $report.contractPending.len & " migrasi contract menunggu `--contract` " &
            "(tidak dijalankan jalur expand)"
        0)

proc main() =
  let opts = parseArgs(commandLineParams())

  if opts.role == roleMigrate:
    quit(runMigrate(opts.root, opts.sub, opts.subArg))
  if opts.role == roleCtl:
    quit(runCtl(opts.cmd, opts.root, opts.username, opts.outPath, opts.userRole,
      opts.branchId, opts.fullName))
  if opts.role == roleWorker:
    quit(runWorker())

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

  # Enkripsi field (T-054, spec §18.2): `KRAN_KEK_FILE` kosong → belum ada kolom terenkripsi,
  # aplikasi lanjut apa adanya. Diset → berkas KEK dibaca & divalidasi SEKARANG (hilang/rusak/
  # mode salah/kid tidak sah → tolak start). Tanpa fallback diam-diam (O-056/D-046 butir 6).
  try:
    app.fieldCrypto = fieldCryptoFromProcessEnv()
  except KekError as e:
    stderr.writeLine "kran-api: " & e.msg
    quit(2)

  if pool.isNil:
    discard logger.warn("KRAN_DATABASE_URL kosong: basis data & realtime tidak aktif", [])
  else:
    # Batas langganan realtime dari parameter (O-030): dibaca di konteks institusi akar, sama
    # seperti pembacaan parameter wajib lain. Gagal-cepat bila parameter belum tersemai — lebih
    # baik menolak start daripada memakai angka yang bukan konfigurasi institusi.
    let limits = pool.withConn(proc(db: DbConn): SubscriptionLimits =
      realtimeLimits(db, institutionScope(), businessDateIso(app.clock)))
    app.events = newEventService(realtimePolicy(app), pool, limits = limits)
    startPump(app.events)
    discard logger.info("realtime hub aktif",
      [("policy", "sesi cookie + izin per topik (T-012)"),
        ("maxTopics", $limits.maxTopics), ("maxTopicLen", $limits.maxTopicLen)])

  # Readiness = dependensi bootstrap (DB) + skema (O-019) + realtime (O-029) + lag outbox (O-019) +
  # denyut worker konsumen (O-081): pump yang mati berlarut harus terlihat dari `/readyz`, tetapi
  # penyambungan ulang sekejap tidak boleh mencabut instance dari trafik. `opts.root` = akar repo
  # untuk membaca daftar migrasi (default "."; di produksi diarahkan unit systemd ke checkout
  # monorepo).
  app.readiness = combineProbes(@[
    databaseProbe(),
    migrationProbe(app.pool, opts.root),
    realtimeProbe(app.events),
    pumpLagProbe(app.events, app.pool),
    workerProbe(app.pool, consumerName, app.startedAt),
    drainProbe(),
  ])

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
