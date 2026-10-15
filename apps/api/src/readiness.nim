## Pemeriksaan kesiapan (readiness) yang dipakai `/readyz` — spec §21.4 #11.
##
## Dipisah dari `main.nim` supaya bisa diuji (`apps/api/tests/itapi.nim`) tanpa menjalankan CLI.
## Yang diperiksa hanya dependensi bootstrap (DB): nilai bisnis tetap dari parameter DB.

import "platform-lib/db/config"
import "platform-lib/db/pool"

import ./db_bridge
import ./events
import ./health

const
  ## Berapa lama pump realtime boleh tidak siap sebelum readiness dianggap gagal (detik). Gangguan
  ## sekejap (mis. DB restart) dipulihkan lewat penyambungan ulang (T-029) dalam hitungan
  ## milidetik–detik; mencabut instance dari trafik untuk itu justru merugikan.
  pumpReadyGraceSeconds* = 30

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
                              detail: "CBS_DATABASE_URL belum diisi")]
    try:
      if pool.isNil:
        pool = newDbPool(dbConfigFromProcessEnv())
      if not pingDatabase(pool):
        return @[ReadinessCheck(name: "database", status: csFailed,
                                detail: "jawaban tak terduga dari select 1")]
      @[ReadinessCheck(name: "database", status: csOk)]
    except CatchableError as e:
      @[ReadinessCheck(name: "database", status: csFailed, detail: e.msg)]
