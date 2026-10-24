## Pemeriksaan kesiapan (readiness) yang dipakai `/readyz` — spec §21.4 #11.
##
## Dipisah dari `main.nim` supaya bisa diuji (`apps/api/tests/tapi.nim` untuk keputusan murni,
## `itapi.nim` untuk endpoint dengan DB) tanpa menjalankan CLI.
## Yang diperiksa: dependensi bootstrap (DB), kesesuaian skema (O-019), kesehatan pump realtime
## (O-029), lag outbox terhadap pump (O-019), denyut worker konsumen + event `DEAD` (O-081), dan
## status drain (T-032). Tidak ada nilai bisnis di sini
## — ambang yang dipakai bersifat teknis dan diberi komentar.

import std/[strutils, times]
import "platform-lib/log"

import db_connector/db_postgres

import dbtools/lib
import platform/infrastructure/[outbox_repo, worker_repo]

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

  ## Umur maksimum denyut worker konsumen sebelum readiness gagal (O-081). Worker menulis denyut
  ## paling jarang tiap `heartbeatWriteSeconds` (15 dtk) dan **juga di dalam batch**, jadi usia
  ## normal jauh di bawah ambang; 3 menit memberi ruang untuk `poll_interval_ms` maksimum (60 dtk)
  ## dan satu putaran lambat tanpa alarm palsu. Nilai **teknis**, mengikuti pola `pumpLagSeconds`:
  ## `/readyz` adalah gate deploy dan tidak boleh bergantung pada parameter DB yang mungkin belum
  ## tersedia.
  workerStaleSeconds* = heartbeatWriteSeconds * 12

  ## Masa tenggang setelah proses API start sebelum "worker belum pernah melapor" dianggap gagal.
  ## Deploy menyalakan API dan worker hampir bersamaan; gate kesehatan berjalan beberapa detik
  ## setelah restart dan mengulang, jadi masa tenggang ini menutup start pertama tanpa menunda
  ## deteksi worker yang denyutnya **basi** (itu langsung gagal: basi = worker memang tidak jalan).
  workerStartupGraceSeconds* = 180

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

proc databaseProbe*(sharedPool: DbPool = nil): ReadinessProbe =
  ## Readiness DB. `sharedPool` = pool milik proses API, sehingga probe melihat kondisi pool yang
  ## **sama** dengan permintaan: pool penuh/putus membuat `/readyz` ikut merah, bukan hijau karena
  ## probe punya koneksinya sendiri (T-130/ARC-1). Tanpa `sharedPool` (test, konstruksi awal) probe
  ## membuat pool kecilnya sendiri — `/healthz` tetap tidak menyentuh DB.
  ##
  ## Pesan `detail` sengaja tidak memuat kredensial — hanya sebab kegagalan.
  var localPool: DbPool
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if not databaseUrlSet(envTableFromProcess()):
      return @[ReadinessCheck(name: "database", status: csFailed,
                              detail: "KRAN_DATABASE_URL belum diisi")]
    var pool = sharedPool
    try:
      if pool.isNil:
        if localPool.isNil:
          localPool = newDbPool(dbConfigFromProcessEnv())
        pool = localPool
      if not pingDatabase(pool):
        return @[ReadinessCheck(name: "database", status: csFailed,
                                detail: "jawaban tak terduga dari select 1")]
      @[ReadinessCheck(name: "database", status: csOk)]
    except CatchableError as e:
      # `detail` adalah endpoint **tanpa autentikasi**: pesan libpq memuat host/port/user.
      # Sebabnya ke log server, klien hanya menerima kode tetap (T-128/API-2).
      discard newLogger(lvlError).error("readiness: database tidak dapat dihubungi",
        [("detail", e.msg)])
      @[ReadinessCheck(name: "database", status: csFailed,
                       detail: "database tidak dapat dihubungi")]

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

proc workerCheck*(ageSeconds: int64; uptimeSeconds: int64;
                  staleSeconds = workerStaleSeconds;
                  startupGraceSeconds = workerStartupGraceSeconds): ReadinessCheck =
  ## Keputusan readiness worker konsumen (O-081), dipisah dari I/O supaya bisa diuji deterministik.
  ##
  ## `ageSeconds < 0` = worker belum pernah melapor; hanya kasus itu yang mendapat masa tenggang
  ## start (worker mungkin belum sempat menulis denyut pertama). Denyut **basi** langsung gagal:
  ## worker sehat menulis paling lambat tiap 60 dtk (`poll_interval_ms` maksimum), jadi usia > 180
  ## dtk berarti worker tidak jalan — bukan sekadar API baru start.
  if ageSeconds < 0:
    if uptimeSeconds < startupGraceSeconds:
      ReadinessCheck(name: "worker", status: csOk, detail: "menunggu denyut pertama")
    else:
      ReadinessCheck(name: "worker", status: csFailed,
                     detail: "worker konsumen belum pernah melapor")
  elif ageSeconds > staleSeconds:
    ReadinessCheck(name: "worker", status: csFailed,
                   detail: "worker konsumen tidak melapor " & $ageSeconds & " detik")
  else:
    ReadinessCheck(name: "worker", status: csOk)

proc outboxDeadCheck*(dead: int64): ReadinessCheck =
  ## Peristiwa `DEAD` perlu re-drive operator, tetapi **bukan** alasan mencabut API dari trafik:
  ## deploy ulang tidak menghidupkannya, dan gate deploy yang gagal hanya akan berputar rollback.
  ## Karena itu statusnya `ok` dengan jumlah di `detail` — terlihat di `/readyz`, tidak memblokir.
  if dead == 0:
    ReadinessCheck(name: "outbox-dead", status: csOk)
  else:
    ReadinessCheck(name: "outbox-dead", status: csOk,
                   detail: $dead & " event DEAD menunggu re-drive (`ctl outbox-status`)")

proc workerProbe*(pool: DbPool; workerName: string;
                  startedAt: float): ReadinessProbe =
  ## Readiness worker konsumen (O-081): denyut + jumlah event `DEAD`.
  ##
  ## Tanpa pool (mis. test tanpa DB) tidak ada yang diperiksa — `databaseProbe` yang melaporkan.
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if pool.isNil:
      return @[]
    try:
      let snapshot = withDbConn(pool,
        proc(db: DbConn): tuple[ageSeconds: int64; dead: int64] {.gcsafe.} =
        dbCalls:
          (workerHeartbeatAgeSeconds(db, workerName), deadEventCount(db)))
      let uptime = int64(max(0.0, epochTime() - startedAt))
      @[workerCheck(snapshot.ageSeconds, uptime), outboxDeadCheck(snapshot.dead)]
    except CatchableError as e:
      # DB tidak terjangkau sudah dilaporkan `databaseProbe`; jangan gagal dua kali.
      @[ReadinessCheck(name: "worker", status: csOk,
                       detail: "tidak dapat diperiksa: " & e.msg)]
