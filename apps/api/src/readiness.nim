## Pemeriksaan kesiapan (readiness) yang dipakai `/readyz` — spec §21.4 #11.
##
## Dipisah dari `main.nim` supaya bisa diuji (`apps/api/tests/itapi.nim`) tanpa menjalankan CLI.
## Yang diperiksa: dependensi bootstrap (DB), kesesuaian skema (O-019), kesehatan pump realtime
## (O-029), lag outbox terhadap pump (O-019), dan status drain (T-032). Tidak ada nilai bisnis di sini
## — ambang yang dipakai bersifat teknis dan diberi komentar.

import std/strutils

import db_connector/db_postgres

import dbtools/lib
import platform/infrastructure/outbox_repo

import "platform-lib/db/config"
import "platform-lib/db/pool"

import ./db_bridge
import ./drain
import ./events
import ./health

const
  ## Berapa lama pump realtime boleh tidak siap sebelum readiness dianggap gagal (detik). Gangguan
  ## sekejap (mis. DB restart) dipulihkan lewat penyambungan ulang (T-029) dalam hitungan
  ## milidetik–detik; mencabut instance dari trafik untuk itu justru merugikan.
  pumpReadyGraceSeconds* = 30

  ## Ambang lag outbox (detik): usia peristiwa outbox tertua yang belum diproses pump sebelum
  ## readiness dianggap gagal (O-019). Nilai **teknis**, mengikuti pola `pumpReadyGraceSeconds`:
  ## pump memutar setiap `pumpPollMs` (250 ms), jadi peristiwa sehat selesai jauh di bawah ambang
  ## ini. Nilainya sengaja **bukan** parameter DB — `/readyz` adalah gate deploy dan harus tetap
  ## jalan walau nilai parameter belum/ tidak tersedia.
  pumpLagSeconds* = 30

proc realtimeCheck*(pumping: bool; ready: bool; degradedSeconds, graceSeconds: int):
    ReadinessCheck =
  ## Keputusan readiness realtime dipisah dari `EventService` supaya bisa diuji deterministik.
  ## Realtime yang mati **bukan** pemadaman: klien masih bisa memutar ulang lewat HTTP/`resumeFrom`;
  ## jadi ini soal visibilitas operator, bukan soal proses hidup.
  if not pumping:
    ReadinessCheck(name: "realtime", status: csOk, detail: "tidak dijalankan")
  elif ready:
    ReadinessCheck(name: "realtime", status: csOk)
  elif degradedSeconds < graceSeconds:
    ReadinessCheck(name: "realtime", status: csOk,
                   detail: "pump menyambung ulang (" & $degradedSeconds & " detik)")
  else:
    ReadinessCheck(name: "realtime", status: csFailed,
                   detail: "pump realtime belum tersambung " & $degradedSeconds & " detik")

proc realtimeProbe*(svc: EventService; graceSeconds = pumpReadyGraceSeconds): ReadinessProbe =
  ## Readiness realtime (O-029). Tanpa ini, pump yang mati tidak terlihat dari luar sama sekali.
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if svc == nil:
      return @[]
    let degraded = svc.pumpDegradedSeconds()
    @[realtimeCheck(pumping = degraded >= 0, ready = svc.pumpReady(),
                    degradedSeconds = int(max(degraded, 0'i64)), graceSeconds = graceSeconds)]

proc drainProbe*(): ReadinessProbe =
  ## Saat proses sedang berhenti, readiness **gagal** dengan sengaja: itu cara memberi tahu penyeimbang
  ## beban agar berhenti mengirim permintaan baru selagi yang sedang berjalan diselesaikan (T-032).
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if isDraining():
      @[ReadinessCheck(name: "shutdown", status: csFailed,
                       detail: "proses sedang berhenti; permintaan berjalan diselesaikan lebih dulu")]
    else:
      @[]

proc combineProbes*(probes: seq[ReadinessProbe]): ReadinessProbe =
  ## Gabungkan beberapa dependensi menjadi satu daftar pemeriksaan (urutan dipertahankan).
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    for probe in probes:
      if probe != nil:
        result.add probe()

proc databaseProbe*(): ReadinessProbe =
  ## Readiness DB: pool dibuat sekali (lazy) supaya `/healthz` tetap tidak menyentuh DB.
  ## Pesan `detail` sengaja tidak memuat kredensial — hanya sebab kegagalan.
  var pool: DbPool
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if not databaseUrlSet(envTableFromProcess()):
      return @[ReadinessCheck(name: "database", status: csFailed,
                              detail: "KRAN_DATABASE_URL belum diisi")]
    try:
      if pool.isNil:
        pool = newDbPool(dbConfigFromProcessEnv())
      if not pingDatabase(pool):
        return @[ReadinessCheck(name: "database", status: csFailed,
                                detail: "jawaban tak terduga dari select 1")]
      @[ReadinessCheck(name: "database", status: csOk)]
    except CatchableError as e:
      @[ReadinessCheck(name: "database", status: csFailed, detail: e.msg)]

proc migrationCheck*(pendingExpand: seq[string]; verifiable: bool): ReadinessCheck =
  ## Keputusan readiness migrasi (O-019). Dipisah dari I/O supaya bisa diuji deterministik
  ## (pola `realtimeCheck`).
  ##
  ## `verifiable = false` (akar repo tidak terbaca) **bukan** kegagalan: `/readyz` dipakai health
  ## gate deploy **dengan auto-rollback**, dan akar migrasi yang tidak dikonfigurasi akan membuat
  ## setiap deploy mundur tanpa henti. Keadaannya tetap terlihat eksplisit di `detail`, bukan
  ## disembunyikan sebagai "ok" polos. Migrasi **expand** yang benar-benar tertunda tetap `csFailed`.
  if not verifiable:
    ReadinessCheck(name: "migrations", status: csOk,
                   detail: "akar migrasi tidak tersedia; skema tidak diverifikasi")
  elif pendingExpand.len > 0:
    ReadinessCheck(name: "migrations", status: csFailed,
                   detail: "migrasi expand tertunda: " & pendingExpand.join(", "))
  else:
    ReadinessCheck(name: "migrations", status: csOk)

proc pumpLagCheck*(lagSeconds, thresholdSeconds: int): ReadinessCheck =
  ## Keputusan readiness lag outbox: usia (detik) peristiwa outbox tertua yang belum diproses pump.
  if lagSeconds <= thresholdSeconds:
    ReadinessCheck(name: "outbox", status: csOk)
  else:
    ReadinessCheck(name: "outbox", status: csFailed,
                   detail: "peristiwa outbox tertua belum diproses " & $lagSeconds & " detik")

proc migrationProbe*(pool: DbPool; root: string): ReadinessProbe =
  ## Readiness migrasi (O-019, spec §21.4 #11): basis data harus sudah menerapkan seluruh migrasi
  ## **expand** repo. Contract/destructive tidak dihitung — sama seperti `--check` (D-040). Jalur ini
  ## sengaja memakai `appliedMigrationIds` (satu query, tanpa checksum) supaya gate deploy yang
  ## memanggil `/readyz` berulang kali tetap cepat.
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if pool.isNil:
      # Tidak ada DB: `databaseProbe` yang melaporkannya; jangan gagal dua kali.
      return @[migrationCheck(@[], verifiable = false)]
    var migra: seq[Migration]
    try:
      migra = migrationsOf(root)
    except CatchableError:
      migra = @[]
    if migra.len == 0:
      return @[migrationCheck(@[], verifiable = false)]
    try:
      let applied = withDbConn(pool, proc(db: DbConn): seq[string] {.gcsafe.} =
        dbCalls:
          appliedMigrationIds(db))
      @[migrationCheck(pendingExpand(migra, applied), verifiable = true)]
    except CatchableError as e:
      # DB tidak terjangkau: urusan `databaseProbe`; di sini jangan menambah kegagalan.
      @[ReadinessCheck(name: "migrations", status: csOk,
                       detail: "tidak dapat diperiksa: " & e.msg)]

proc pumpLagProbe*(svc: EventService; pool: DbPool;
                   thresholdSeconds = pumpLagSeconds): ReadinessProbe =
  ## Readiness lag outbox (O-019): seberapa jauh konsumen in-process (pump realtime) tertinggal.
  ##
  ## Tanpa kursor (pump belum menetapkan titik mulai) tidak ada yang diperiksa — pump yang belum
  ## siap sudah ditangani `realtimeProbe`; di sini jangan mengukur dari nol yang bisa salah.
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if svc.isNil or pool.isNil:
      return @[]
    let cursor = svc.pumpCursor()
    if cursor.len == 0:
      return @[]
    try:
      let lag = withDbConn(pool, proc(db: DbConn): int64 {.gcsafe.} =
        dbCalls:
          oldestUndeliveredSeconds(db, cursor))
      @[pumpLagCheck(int(lag), thresholdSeconds)]
    except CatchableError as e:
      @[ReadinessCheck(name: "outbox", status: csOk,
                       detail: "tidak dapat diperiksa: " & e.msg)]
