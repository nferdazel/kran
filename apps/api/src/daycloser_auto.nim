## Penjadwal harian day-close (T-139b, O-094): `ctl daycloser-auto`.
##
## Dijalankan oleh timer systemd tiap beberapa menit, bukan oleh proses API. Alasannya bukan
## kerapian: penutupan menahan koneksi dan mengunci scope, sedangkan proses API harus tetap
## melayani permintaan. Timer yang mengulang juga membuat penjadwal tahan mati/restart — tidak ada
## keadaan di memori yang harus dipulihkan.
##
## Semua penjagaan bersifat "tidak melakukan apa-apa" (kode keluar 0) kecuali konfigurasi rusak:
## hari libur, tanggal buku yang belum ada, run yang sudah ada, dan jam yang belum jatuh tempo
## bukan kegagalan jadwal.

import std/[json, options, strutils, times]

import db_connector/db_postgres

import "platform-lib/db/pool"

import kernel/[clock, paramkey]
import kernel/generated/paramkeys

import platform/domain/[calendar, scope]
import platform/infrastructure/[calendar_repo, param_repo]

import daycloser/domain/[run, schedule, types]
import daycloser/infrastructure/run_repo

import ./daycloser_service

const
  dayCloserAutoCmd* = "daycloser-auto"

type
  AutoConfig* = object
    enabled*: bool
    runAt*: ClockTime
    utcOffsetMinutes*: int

proc autoConfig*(db: DbConn; asOf: string): AutoConfig =
  ## Nilai hilang atau bertipe salah = **kesalahan konfigurasi**, bukan "mati": penjadwal yang
  ## diam karena parameternya belum tersemai akan terlihat seperti hari tanpa penutupan.
  let lookup = lookupFor(institutionScope())
  let enabled = activeValueJson(db, keyString(P_daycloser_auto_enabled), asOf, lookup)
  if enabled.kind != JBool:
    raise newException(ValueError,
      "parameter daycloser.auto.enabled harus boolean, bukan " & $enabled.kind)
  let runAt = activeValueJson(db, keyString(P_daycloser_auto_run_at), asOf, lookup)
  if runAt.kind != JString:
    raise newException(ValueError,
      "parameter daycloser.auto.run_at harus string HH:MM, bukan " & $runAt.kind)
  let offset = activeParamInt(db, keyString(P_daycloser_auto_utc_offset_minutes), asOf, lookup)
  AutoConfig(enabled: enabled.getBool(), runAt: parseClockTime(runAt.getStr()),
    utcOffsetMinutes: offset)

proc dueConfig*(cfg: AutoConfig; nowUtc: DateTime): bool =
  ## Murni: apakah jadwal hari ini sudah terlewati. Dipisah supaya bisa diuji tanpa DB.
  let utcMinutes = nowUtc.hour * 60 + nowUtc.minute
  dueNow(localMinutesOfDay(utcMinutes, cfg.utcOffsetMinutes), cfg.runAt.toMinutes())

proc autoRun*(pool: DbPool; clock: Clock): int =
  ## Kode keluar mengikuti `ctl`: 0 = tidak ada yang perlu dikerjakan atau penutupan selesai,
  ## 1 = penutupan berjalan tetapi tidak selesai (BLOCKED/FAILED/PAUSED), 2 = konfigurasi/salah
  ## pakai, 3 = ditolak keadaan sekarang.
  let nowUtc = clock.now().utc
  let asOf = format(nowUtc, "yyyy-MM-dd")
  var cfg: AutoConfig
  try:
    cfg = pool.withConn(proc(db: DbConn): AutoConfig = autoConfig(db, asOf))
  except ValueError as e:
    stderr.writeLine "kran-api: konfigurasi penjadwal tidak sah: " & e.msg
    return 2

  if not cfg.enabled:
    echo "penjadwal nonaktif (daycloser.auto.enabled = false)"
    return 0
  if not dueConfig(cfg, nowUtc):
    echo "belum waktunya: jadwal " & $cfg.runAt.hour & ":" &
      (if cfg.runAt.minute < 10: "0" else: "") & $cfg.runAt.minute &
      " lokal (offset " & $cfg.utcOffsetMinutes & " menit)"
    return 0

  var bd: Option[BusinessDateRow]
  var existing: Option[RunSnapshot]
  discard pool.withConn(proc(db: DbConn): int =
    bd = businessDateOf(db, institutionScope())
    if bd.isSome:
      existing = db.runForDate(dayCloseScopeType, "", bd.get().currentDate)
    1)

  if bd.isNone:
    stderr.writeLine "kran-api: belum ada baris business_date; penjadwal tidak bisa menutup buku " &
      "yang belum ditetapkan (jalankan daycloser-run --bootstrap sekali)"
    return 3
  let row = bd.get()
  if row.state != bdsOpen:
    echo "tanggal buku " & row.currentDate & " berstatus " & $row.state &
      "; penjadwal tidak melakukan apa pun"
    return 0
  if existing.isSome and existing.get().state != rsCanceled:
    echo "sudah ada run untuk " & row.currentDate & " (" & $existing.get().state & ", " &
      existing.get().runId & "); penjadwal tidak mengulang"
    return 0

  let res = startRunAction(pool, clock, row.currentDate)
  case res.status
  of asOk:
    echo res.message
    if res.hasSnapshot and res.snapshot.state != rsCompleted:
      return 1
    0
  of asBusy:
    # Scope dipegang proses lain: bukan kegagalan jadwal, cukup dicatat.
    echo res.message
    0
  else:
    stderr.writeLine "kran-api: penutupan otomatis ditolak: " & res.message
    3
