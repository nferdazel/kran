## Unit test access log & ukuran worker HTTP (T-130/API-6, ARC-1).
##
## Access log ditulis satu tempat (pembungkus di `server.nim`), jadi bentuknya bisa diuji tanpa
## server: yang penting setiap permintaan menghasilkan satu baris dengan method, rute, status, dan
## durasi — plus trace id sebagai field terstruktur.

import std/unittest

import ../src/[context, server]

suite "accessLogLine (T-130/API-6)":
  test "satu baris memuat method, rute, status, dan durasi":
    check accessLogLine("GET", "/api/v1/params", 200, 12) == "GET /api/v1/params 200 12ms"

  test "status tidak dikenal ditandai '-'":
    # 0 = handler tidak merespons lewat helper; jangan terbaca seperti 200.
    check accessLogLine("POST", "/api/v1/auth/login", 0, 3) == "POST /api/v1/auth/login - 3ms"

suite "apiWorkerThreads (T-130/ARC-1)":
  test "serverThreads yang dihitung composition root dipakai apa adanya":
    check apiWorkerThreads(AppContext(serverThreads: 7)) == 7

  test "tanpa nilai eksplisit: default Mummy (test/role non-API)":
    check apiWorkerThreads(AppContext()) > 0
