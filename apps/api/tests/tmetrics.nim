## Test murni `/metrics` (T-250): akuntansi hitungan/histogram, bentuk teks eksposisi, dan aturan
## peer. Tidak menyalakan server atau DB; bentuk respons nyata diuji `tapi.nim`.

import std/[strutils, unittest]

import ../src/[context, identity, metrics]

proc bucketCount(le: string): int64 =
  ## Nilai satu bucket histogram dari render proses. `-1` bila barisnya tidak ada.
  let text = renderProcessMetrics(AppContext(version: "test", startedAt: 0.0), 1.0)
  let prefix = "kran_http_request_duration_seconds_bucket{le=\"" & le & "\"}"
  for line in text.splitLines():
    if line.startsWith(prefix):
      return parseBiggestInt(line.split(' ')[^1])
  -1

suite "metrics: akuntansi permintaan":
  test "hitungan per kode status bertambah dan kode di luar rentang diabaikan":
    let before = requestCount(418)
    recordRequest(418, 10)
    check requestCount(418) == before + 1
    # 0 = handler tidak menjawab lewat helper; tidak boleh membuat baris `code="0"`.
    let zeroBefore = requestCount(0)
    recordRequest(0, 10)
    check requestCount(0) == zeroBefore

  test "histogram kumulatif: satu observasi masuk ke semua bucket di atasnya":
    let countBefore = durationObservations()
    let lowBefore = bucketCount("0.01")
    let midBefore = bucketCount("0.025")
    let infBefore = bucketCount("+Inf")
    # 20 ms: di atas 10 ms, di bawah 25 ms.
    recordRequest(200, 20)
    check durationObservations() == countBefore + 1
    check bucketCount("0.01") == lowBefore
    check bucketCount("0.025") == midBefore + 1
    check bucketCount("+Inf") == infBefore + 1

suite "metrics: bentuk teks eksposisi":
  test "setiap seri punya baris HELP dan TYPE, nama berawalan kran_":
    let text = renderProcessMetrics(AppContext(version: "test", startedAt: 100.0), 160.0)
    for series in ["kran_http_requests_total", "kran_http_request_duration_seconds",
                   "kran_http_requests_in_flight", "kran_process_uptime_seconds",
                   "kran_metrics_scrape_errors_total"]:
      check ("# HELP " & series) in text
      check ("# TYPE " & series) in text
    check "kran_process_uptime_seconds 60" in text

  test "uptime tidak pernah negatif walau jam sistem mundur":
    let text = renderProcessMetrics(AppContext(version: "test", startedAt: 500.0), 100.0)
    check "kran_process_uptime_seconds 0" in text

  test "bucket +Inf selalu sama dengan jumlah observasi":
    let text = renderProcessMetrics(AppContext(version: "test", startedAt: 0.0), 1.0)
    var inf = -1'i64
    var total = -1'i64
    for line in text.splitLines():
      if line.startsWith("kran_http_request_duration_seconds_bucket{le=\"+Inf\"}"):
        inf = parseBiggestInt(line.split(' ')[^1])
      elif line.startsWith("kran_http_request_duration_seconds_count "):
        total = parseBiggestInt(line.split(' ')[^1])
    check inf >= 0
    check inf == total

  test "tanpa pool, blok basis data kosong (bukan galat)":
    check renderDbMetrics(AppContext(version: "test")) == ""

suite "metrics: aturan peer":
  test "loopback dalam semua bentuk diizinkan":
    let none = TrustedProxySet()
    check metricsPeerAllowed("127.0.0.1:55000", none)
    check metricsPeerAllowed("[::1]:55000", none)
    check metricsPeerAllowed("127.0.0.1", none)

  test "peer lain ditolak tanpa rentang tepercaya":
    check not metricsPeerAllowed("203.0.113.7:40000", TrustedProxySet())

  test "gateway bridge podman diizinkan hanya bila ada di rentang tepercaya":
    let trusted = trustedProxyCidrsFromEnv()
    check metricsPeerAllowed("10.89.0.1:40000", trusted) ==
      isTrustedPeer("10.89.0.1", trusted)
