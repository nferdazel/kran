## Endpoint `/metrics` — Prometheus text exposition (spec §7.5, T-250, O-138).
##
## Dua bagian yang sengaja dipisah:
##
## - **Proses**: angka dari atomik di memori, tanpa I/O. Tidak bisa gagal, jadi scrape selalu
##   punya isi walau basis data mati.
## - **Basis data**: tiga pembacaan agregat pada satu koneksi pool. Bila gagal, bloknya
##   **dihilangkan** dan `kran_metrics_scrape_errors_total` naik — endpoint metrik yang ikut mati
##   karena DB mati justru menghapus satu-satunya sinyal yang memberi tahu DB mati.
##
## Pembacaan basis data tidak dilakukan di sini: `readiness.outboxWorkerMetrics` dan
## `daycloser_ctl.closeRunMetrics` memegang seam repositori masing-masing, jadi modul handler ini
## tetap tidak menyentuh internal modul bisnis (batas arsitektur T-173).
##
## Aturan paparan: hanya peer loopback atau peer di `KRAN_TRUSTED_PROXY_CIDRS`. Bukan kehati-hatian
## berlebih, tapi konsekuensi deployment: container API bind `0.0.0.0` dan port di-forward podman
## rootless, jadi operator yang scrape dari host datang dari gateway bridge (`10.89.0.1`), bukan
## `127.0.0.1`. Jalur publik tetap tertutup dua kali: Caddy hanya mem-proxy `/api/*`, dan blok API
## terpisah di contoh Caddy membalas 403 untuk `/metrics` (§22).
##
## Tidak ada label path pada hitungan permintaan: label tak terbatas = kebocoran kardinalitas, dan
## access log sudah memuat method, path, status dan durasi per permintaan.

import std/[atomics, times]

import mummy

import "platform-lib/db/pool"

import ./context
import ./daycloser_ctl
import ./drain
import ./http_util
import ./identity
import ./problem
import ./readiness

const
  ## Kode status HTTP 100..599; array sebesar ini menghindari map berkunci pada jalur permintaan.
  statusCodeCount* = 600          # nomagic:ok kode status HTTP 100..599, batas protokol

  ## Batas bucket histogram (milidetik), mengikuti bentuk bawaan Prometheus untuk HTTP: cukup rapat
  ## di bawah 250 ms karena itu wilayah normal API ini, dan tetap memisahkan ekor lambat. Bilangan
  ## bulat milidetik supaya tidak ada literal desimal di jalur permintaan.
  durationBucketsMillis* = [
    5, 10, 25, 50, 100, 250, # nomagic:ok batas bucket histogram HTTP (ms), observabilitas
    500, 1000, 2500, 5000, 10000] # nomagic:ok batas bucket histogram HTTP (ms), observabilitas

var
  requestsByCode: array[statusCodeCount, Atomic[int64]]
  bucketCounts: array[durationBucketsMillis.len, Atomic[int64]]
  durationSumMillis: Atomic[int64]
  durationCount: Atomic[int64]
  loginFailures: Atomic[int64]
  scrapeErrors: Atomic[int64]

proc recordRequest*(statusCode: int; durationMillis: int64) =
  ## Dipanggil pembungkus permintaan (satu tempat, bukan tiap handler), sama seperti access log.
  ## `statusCode` di luar 100..599 (mis. 0 saat handler tidak menjawab lewat helper) tidak dihitung
  ## per kode, tetapi durasinya tetap masuk histogram: permintaan itu memang terjadi.
  if statusCode >= 100 and statusCode < statusCodeCount:
    discard requestsByCode[statusCode].fetchAdd(1)
  let millis = max(0'i64, durationMillis)
  for i, bound in durationBucketsMillis:
    if millis <= int64(bound):
      discard bucketCounts[i].fetchAdd(1)
  discard durationSumMillis.fetchAdd(millis)
  discard durationCount.fetchAdd(1)

proc recordLoginFailure*() =
  ## Dipanggil `handleLogin` pada hasil `aoInvalidCredentials`, `aoLocked`, `aoInactive`.
  ##
  ## Hitungan per proses, bukan kueri `platform.audit_log` per scrape: scrape tidak boleh menambah
  ## beban DB, dan Prometheus menangani reset proses lewat `rate()`. `aoMfaRequired` tidak dihitung:
  ## kata sandi benar, yang kurang faktor kedua, dan itu seri tersendiri.
  discard loginFailures.fetchAdd(1)

proc requestCount*(statusCode: int): int64 =
  ## Untuk test dan diagnosa; `-1` bila kode di luar rentang yang dilacak.
  if statusCode < 100 or statusCode >= statusCodeCount:
    return -1
  requestsByCode[statusCode].load()

proc durationObservations*(): int64 = durationCount.load()

proc loginFailureCount*(): int64 = loginFailures.load()

proc scrapeErrorCount*(): int64 = scrapeErrors.load()

proc metricLine(name: string; value: int64): string =
  name & " " & $value & "\n"

proc metricLine(name: string; value: float64): string =
  ## `$` pada float selalu memakai titik desimal (tidak bergantung locale); Prometheus menerima
  ## bentuk itu apa adanya, jadi tidak perlu presisi tetap.
  name & " " & $value & "\n"

proc labelled(name, label, value: string; amount: int64): string =
  name & "{" & label & "=\"" & value & "\"} " & $amount & "\n"

proc renderProcessMetrics*(app: AppContext; now: float): string =
  ## Bagian yang tidak bisa gagal: atomik proses + uptime. `now` dikirim pemanggil supaya bisa
  ## diuji tanpa jam nyata.
  result.add "# HELP kran_http_requests_total Permintaan HTTP yang dilayani, per kode status.\n"
  result.add "# TYPE kran_http_requests_total counter\n"
  for code in 100 ..< statusCodeCount:
    let total = requestsByCode[code].load()
    if total > 0:
      result.add labelled("kran_http_requests_total", "code", $code, total)

  result.add "# HELP kran_http_request_duration_seconds Durasi penanganan permintaan HTTP.\n"
  result.add "# TYPE kran_http_request_duration_seconds histogram\n"
  for i, bound in durationBucketsMillis:
    result.add "kran_http_request_duration_seconds_bucket{le=\"" &
      $(float64(bound) / float64(1000)) & "\"} " & $bucketCounts[i].load() & "\n"
  result.add "kran_http_request_duration_seconds_bucket{le=\"+Inf\"} " &
    $durationCount.load() & "\n"
  result.add "kran_http_request_duration_seconds_sum " &
    $(float64(durationSumMillis.load()) / float64(1000)) & "\n"
  result.add metricLine("kran_http_request_duration_seconds_count", durationCount.load())

  result.add "# HELP kran_http_requests_in_flight Permintaan yang sedang ditangani proses ini.\n"
  result.add "# TYPE kran_http_requests_in_flight gauge\n"
  result.add metricLine("kran_http_requests_in_flight", int64(inFlightCount()))

  result.add "# HELP kran_auth_login_failures_total Login yang ditolak sejak proses start.\n"
  result.add "# TYPE kran_auth_login_failures_total counter\n"
  result.add metricLine("kran_auth_login_failures_total", loginFailures.load())

  result.add "# HELP kran_process_uptime_seconds Usia proses API.\n"
  result.add "# TYPE kran_process_uptime_seconds gauge\n"
  result.add metricLine("kran_process_uptime_seconds",
    max(0'i64, int64(now - app.startedAt)))

  result.add "# HELP kran_metrics_scrape_errors_total Scrape yang tidak dapat membaca basis data.\n"
  result.add "# TYPE kran_metrics_scrape_errors_total counter\n"
  result.add metricLine("kran_metrics_scrape_errors_total", scrapeErrors.load())

proc renderDbMetrics*(app: AppContext): string =
  ## Blok basis data. Kueri berjalan pada koneksi pool yang sama dengan permintaan: pool penuh
  ## akan menunggu `acquireTimeoutMs` lalu gagal, dan kegagalan itu hanya menaikkan penghitung
  ## scrape error. Status outbox yang belum punya baris tidak dirender (tidak ada seri nol buatan).
  if app.pool.isNil:
    return ""

  result.add "# HELP kran_db_pool_connections Koneksi pool basis data per keadaan.\n"
  result.add "# TYPE kran_db_pool_connections gauge\n"
  result.add labelled("kran_db_pool_connections", "state", "created",
    int64(app.pool.stats.created))
  result.add labelled("kran_db_pool_connections", "state", "idle", int64(app.pool.stats.idle))
  result.add labelled("kran_db_pool_connections", "state", "in_use", int64(app.pool.stats.inUse))
  result.add labelled("kran_db_pool_connections", "state", "leaked_tx",
    int64(app.pool.stats.leakedTx))

  let outbox = outboxWorkerMetrics(app.pool, app.workerName)
  result.add "# HELP kran_outbox_events Peristiwa outbox per status.\n"
  result.add "# TYPE kran_outbox_events gauge\n"
  for row in outbox.outbox:
    result.add labelled("kran_outbox_events", "status", row.status, row.total)

  result.add "# HELP kran_outbox_dead_events Peristiwa DEAD yang menunggu re-drive.\n"
  result.add "# TYPE kran_outbox_dead_events gauge\n"
  result.add metricLine("kran_outbox_dead_events", outbox.dead)

  result.add "# HELP kran_worker_heartbeat_age_seconds Usia denyut worker konsumen; -1 = belum pernah melapor.\n"
  result.add "# TYPE kran_worker_heartbeat_age_seconds gauge\n"
  result.add metricLine("kran_worker_heartbeat_age_seconds", outbox.heartbeatAgeSeconds)

  let close = closeRunMetrics(app.pool)
  result.add "# HELP kran_dayclose_open_runs Run day-close yang belum selesai atau dibatalkan.\n"
  result.add "# TYPE kran_dayclose_open_runs gauge\n"
  result.add metricLine("kran_dayclose_open_runs", close.openRuns)
  result.add "# HELP kran_dayclose_last_run_duration_seconds Durasi run day-close terakhir yang selesai.\n"
  result.add "# TYPE kran_dayclose_last_run_duration_seconds gauge\n"
  result.add metricLine("kran_dayclose_last_run_duration_seconds", close.lastDurationSeconds)
  result.add "# HELP kran_dayclose_last_run_finished_timestamp_seconds Waktu selesai run day-close terakhir (epoch).\n"
  result.add "# TYPE kran_dayclose_last_run_finished_timestamp_seconds gauge\n"
  result.add metricLine("kran_dayclose_last_run_finished_timestamp_seconds",
    close.lastFinishedEpoch)

proc renderMetrics*(app: AppContext; now: float): string =
  ## Isi lengkap satu scrape. Kegagalan DB tidak menjatuhkan endpoint.
  result = renderProcessMetrics(app, now)
  try:
    result.add renderDbMetrics(app)
  except CatchableError:
    discard scrapeErrors.fetchAdd(1)

proc metricsPeerAllowed*(peerAddress: string; trusted: TrustedProxySet): bool =
  ## Dipisah dari `Request` supaya bisa diuji tanpa server: peer boleh loopback (host yang sama)
  ## atau salah satu rentang tepercaya (gateway bridge podman, tempat operator scrape dari host).
  let peer = withoutPort(peerAddress)
  isLoopback(peer) or isTrustedPeer(peer, trusted)

proc handleMetrics*(app: AppContext; req: Request) {.gcsafe.} =
  if not metricsPeerAllowed(req.remoteAddress, processTrustedProxies):
    req.respondProblem(pkForbidden, "Forbidden",
      "metrik hanya tersedia dari host ini")
    return
  req.respondRaw(200, @[("Content-Type", "text/plain; version=0.0.4; charset=utf-8")],
    app.renderMetrics(epochTime()))
