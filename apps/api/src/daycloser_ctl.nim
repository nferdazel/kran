## Composition root perintah `ctl` day-close (spec §11.5, §12.5).
##
## Berkas ini hanya **penerjemah**: keputusan penutupan ada di `daycloser_service.nim` (dipakai juga
## oleh endpoint HTTP), sedangkan di sini yang tersisa adalah bentuk keluaran operator — teks dan
## kode keluar.
##
## Perintah (sengaja terpisah dari `runCtl` umum karena memegang pool sendiri):
##   daycloser-status                     status untuk operator & gate deploy (kode keluar)
##   daycloser-run --business-date=...    rencanakan + jalankan penutupan satu hari
##   daycloser-run --business-date=... --mode=SIMULATION
##                                        dry-run: tampilkan rencana task/chunk, tanpa menulis apa pun
##                                        (spec §11.7)
##   daycloser-resume --run=<uuid>        lanjutkan run PAUSED/FAILED/BLOCKED
##   daycloser-pause  --run=<uuid>        hentikan di batas chunk (langsung bila tak ada proses)
##   daycloser-cancel --run=<uuid>        batalkan; tanggal buku yang dibekukan dibuka kembali
##   daycloser-auto                       jalankan penutupan bila jadwal parameter sudah tiba
##                                        (dipanggil timer systemd; lihat ops/systemd)

import std/[options, os, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"

import kernel/[clock, dayclose]

import platform/domain/[calendar, scope]
import platform/infrastructure/calendar_repo

import daycloser/domain/[run, types]
import daycloser/infrastructure/run_repo

import ./daycloser_auto
import ./daycloser_service

export daycloser_service

const
  dayCloserStatusCmd* = "daycloser-status"
  dayCloserRunCmd* = "daycloser-run"
  dayCloserResumeCmd* = "daycloser-resume"
  dayCloserPauseCmd* = "daycloser-pause"
  dayCloserCancelCmd* = "daycloser-cancel"
  dayCloserAutoCmd* = "daycloser-auto"

  dayCloserCommands* = [dayCloserStatusCmd, dayCloserRunCmd, dayCloserResumeCmd,
                        dayCloserPauseCmd, dayCloserCancelCmd, dayCloserAutoCmd]

proc printRun(snap: RunSnapshot) =
  var ok, failed, skipped, done = 0
  for t in snap.tasks:
    case t.state
    of tsSucceeded: inc ok; inc done
    of tsFailed: inc failed
    of tsSkipped: inc skipped; inc done
    of tsCanceled: inc done
    else: discard
  echo "run " & snap.runId & ": tanggal=" & snap.businessDate & " level=" &
    levelsCsv(snap.levels) & " state=" & $snap.state & " task=" & $done & "/" &
    $snap.tasks.len & " (ok=" & $ok & ", gagal=" & $failed & ", lewati=" & $skipped & ")" &
    (if snap.summaryHash.len > 0: " segel=" & snap.summaryHash[0 ..< 12] else: "")

proc statusCmd(pool: DbPool; clock: Clock): int =
  var active: seq[RunSnapshot]
  var bd: Option[BusinessDateRow]
  var last: Option[RunSnapshot]
  discard pool.withConn(proc(db: DbConn): int =
    active = db.activeRuns()
    bd = businessDateOf(db, institutionScope())
    last = db.latestRun(dayCloseScopeType, "")
    1)

  var frozen = false
  if bd.isSome:
    echo "tanggal buku: " & bd.get.currentDate & " " & $bd.get.state
    if bd.get.state == bdsClosing:
      frozen = true
  else:
    echo "tanggal buku: (belum ada baris platform.business_date)"

  if active.len > 0:
    frozen = true
    for run in active:
      printRun(run)
  else:
    echo "run aktif: tidak ada"
    if last.isSome:
      printRun(last.get)

  echo (if frozen: "deploy: DITAHAN (ada penutupan belum selesai)" else: "deploy: boleh")
  if frozen:
    return 1
  0

proc report(res: ActionResult; echoBody: bool; requireCompleted = false): int =
  ## Satu tempat yang memutuskan kode keluar, supaya `ctl` dan HTTP tidak bisa berbeda pendapat
  ## soal aksi mana yang "ditolak" dan mana yang "salah pakai".
  ##
  ## `requireCompleted` menjaga arti kode keluar untuk gate deploy: run yang berakhir `BLOCKED`
  ## atau `FAILED` bukan keberhasilan, walaupun perintahnya sendiri berjalan normal.
  if res.status == asOk:
    if echoBody:
      echo res.message
    if res.hasSnapshot:
      printRun(res.snapshot)
      if requireCompleted and res.snapshot.state != rsCompleted:
        return 1
    return 0
  stderr.writeLine "kran-api: " & res.message
  if res.hasSnapshot and res.status != asNotFound:
    printRun(res.snapshot)
  case res.status
  of asInvalid: 2
  else: 3

proc runCmd(pool: DbPool; clock: Clock; businessDateRaw: string; bootstrap: bool): int =
  report(startRunAction(pool, clock, businessDateRaw, bootstrap), echoBody = true,
    requireCompleted = true)

proc simulateCmd(pool: DbPool; clock: Clock; businessDateRaw: string): int =
  ## Dry-run tidak pernah "berhasil menutup", jadi `requireCompleted` tidak dipakai: laporan
  ## rencana yang tercetak adalah hasilnya, dan kode keluar mengikuti status aksinya.
  report(startSimulationAction(pool, clock, businessDateRaw), echoBody = true)

proc resumeCmd(pool: DbPool; clock: Clock; runIdRaw: string): int =
  report(resumeRunAction(pool, clock, runIdRaw), echoBody = true, requireCompleted = true)

proc controlCmd(pool: DbPool; clock: Clock; runIdRaw: string;
                control: RunControl): int =
  report(controlRunAction(pool, clock, runIdRaw, control), echoBody = true)

proc runDayCloserCtl*(command, businessDate, runId: string;
                      bootstrap = false; simulate = false): int =
  ## Titik masuk dari `main`. Kode keluar: 0 sukses/idle, 1 gagal atau ada penutupan yang belum
  ## selesai (gate deploy membacanya sebagai "tahan"), 2 salah pakai/konfigurasi, 3 ditolak
  ## pada keadaan sekarang.
  if not databaseUrlSet(envTableFromProcess()):
    stderr.writeLine "kran-api: KRAN_DATABASE_URL kosong — perintah day-close butuh basis data"
    return 2
  let clock = systemClock()
  let pool = newDbPool(dbConfigFromProcessEnv())
  defer: pool.close()
  try:
    case command
    of dayCloserStatusCmd: statusCmd(pool, clock)
    of dayCloserRunCmd:
      if simulate:
        simulateCmd(pool, clock, businessDate)
      else:
        runCmd(pool, clock, businessDate, bootstrap)
    of dayCloserResumeCmd: resumeCmd(pool, clock, runId)
    of dayCloserPauseCmd: controlCmd(pool, clock, runId, rcPause)
    of dayCloserCancelCmd: controlCmd(pool, clock, runId, rcCancel)
    of dayCloserAutoCmd: autoRun(pool, clock)
    else:
      stderr.writeLine "kran-api: perintah day-close tidak dikenal: " & command
      2
  except DayCloserError as e:
    stderr.writeLine "kran-api: day-close ditolak: " & e.msg
    3
  except IOError as e:
    # DbError dan PoolError (batas waktu pool/soket mati) sama-sama IOError.
    stderr.writeLine "kran-api: gagal terhadap basis data: " & e.msg
    1
  except ValueError as e:
    stderr.writeLine "kran-api: nilai tidak sah: " & e.msg
    2
