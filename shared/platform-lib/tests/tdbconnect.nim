## Batas waktu jalur DB (T-061 / T-044 H1), **tanpa** DB nyata.
##
## Yang dibuktikan: peer yang menerima TCP lalu diam (black-hole) tidak lagi membuat `acquire`
## menunggu tanpa batas — `connect_timeout` di conninfo membuatnya menjadi `PoolError` cepat.
## Ini regresi untuk `pqsetdbLogin`, yang tidak bisa menyatakan `connect_timeout`.

import std/[net, strutils, tables, times, unittest]

import "platform-lib/db/config"
import "platform-lib/db/pool"

proc env(pairs: openArray[(string, string)]): Table[string, string] =
  for (k, v) in pairs:
    result[k] = v

proc blackHolePort(): (Socket, Port) =
  ## Socket yang listen tetapi **tidak pernah** accept: kernel menyelesaikan handshake TCP,
  ## libpq mengirim startup packet, lalu tidak ada jawaban selamanya.
  result[0] = newSocket()
  result[0].setSockOpt(OptReuseAddr, true)
  result[0].bindAddr(Port(0), "127.0.0.1")
  result[0].listen()
  result[1] = result[0].getLocalAddr()[1]

suite "conninfo: batas waktu & escaping":
  test "connect_timeout ikut serta (minimum libpq 2 detik)":
    let c = dbConfigFromEnv(env({"KRAN_DATABASE_URL": "postgres://u:p@h:5432/db",
                                 "KRAN_DB_CONNECT_TIMEOUT_MS": "2000"}))
    let ci = connInfo(c)
    check ci.contains("connect_timeout=2")
    check ci.contains("keepalives=1")

  test "nilai < 2 detik dinaikkan ke 2 (0 = tanpa batas, jangan pernah dipakai)":
    let c = dbConfigFromEnv(env({"KRAN_DATABASE_URL": "postgres://u:p@h:5432/db",
                                 "KRAN_DB_CONNECT_TIMEOUT_MS": "500"}))
    check connInfo(c).contains("connect_timeout=2")

  test "password dengan kutip/backslash di-escape":
    let c = dbConfigFromEnv(env(
      {"KRAN_DATABASE_URL": "postgres://u:p%27a%5Cb@h:5432/db"}))
    check c.target.password == "p'a\\b"
    check connInfo(c).contains("password='p\\'a\\\\b'")

  test "options (spasi) tetap satu nilai":
    let c = dbConfigFromEnv(env({"KRAN_DATABASE_URL": "postgres://u:p@h:5432/db"}))
    check connInfo(c).contains("options='-c statement_timeout=15000")

suite "pool: peer diam tidak boleh menggantung (T-044 H1)":
  test "black-hole: PoolError < 10 detik, pesannya tetap 'gagal menyambung'":
    let (listener, port) = blackHolePort()
    defer: listener.close()

    let c = dbConfigFromEnv(env({
      "KRAN_DATABASE_URL": "postgres://u:p@127.0.0.1:" & $port & "/db",
      "KRAN_DB_CONNECT_TIMEOUT_MS": "2000",
    }))
    let p = newDbPool(c)
    defer: p.close()

    let t0 = epochTime()
    var raised = false
    try:
      discard p.acquire()
    except PoolError as e:
      raised = true
      check e.msg.contains("gagal menyambung")
    check raised
    let elapsed = epochTime() - t0
    # Bukti untuk laporan: tanpa fix, angka ini tidak pernah tercetak (menggantung).
    echo "    (black-hole gagal dalam ", formatFloat(elapsed, ffDecimal, 2), " s)"
    check elapsed < 10.0
    # Batas bawah membuktikan yang diuji memang *menunggu lalu menyerah* karena `connect_timeout`,
    # bukan gagal seketika karena sebab lain. Tanpa ini, regresi ke `pqsetdbLogin` akan menggantung
    # (bukan merah) dan test hanya lolos secara tidak bermakna.
    check elapsed >= 1.5

  test "kontrol: port tertutup tetap gagal cepat":
    var probe = newSocket()
    probe.setSockOpt(OptReuseAddr, true)
    probe.bindAddr(Port(0), "127.0.0.1")
    let port = probe.getLocalAddr()[1]
    probe.close()

    let c = dbConfigFromEnv(env({
      "KRAN_DATABASE_URL": "postgres://u:p@127.0.0.1:" & $port & "/db",
      "KRAN_DB_CONNECT_TIMEOUT_MS": "2000",
    }))
    let p = newDbPool(c)
    defer: p.close()

    let t0 = epochTime()
    var raised = false
    try:
      discard p.acquire()
    except PoolError:
      raised = true
    check raised
    check epochTime() - t0 < 10.0
