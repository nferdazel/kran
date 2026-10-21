## Test integrasi pool DB (butuh `KRAN_DATABASE_URL`; lihat docs/runbooks/dev-db.md).
##
## Cakupan: kueri parameterized, akuntansi pool, batas tunggu, transaksi explicit (BEGIN/COMMIT/
## ROLLBACK), pengembalian koneksi yang masih bertransaksi, kegagalan koneksi.
##
## Cakupan T-033: peminjaman koneksi paralel dari banyak thread (dengan kontensi pool kecil), dan
## penggantian koneksi yang sudah mati di server. Sebelumnya yang pertama hanya berupa asumsi.

import std/[atomics, net, os, posix, strutils, tables, times, unittest]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itpool: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let baseCfg = dbConfigFromEnv(envT)

proc cfgWith(poolSize: int, acquireTimeoutMs: int): DbConfig =
  result = baseCfg
  result.poolSize = poolSize
  result.acquireTimeoutMs = acquireTimeoutMs

suite "pool: kueri & batas":
  test "withConn menjalankan kueri parameterized":
    let pool = newDbPool(baseCfg)
    defer: pool.close()
    let nilai = pool.withConn(proc(db: DbConn): string = db.getValue(sql"SELECT ?::text", 42))
    check nilai == "42"
    let baris = pool.withConn(proc(db: DbConn): seq[Row] =
      db.getAllRows(sql"SELECT n FROM generate_series(1, ?) AS n", 3))
    check baris.len == 3

  test "statsOf melacak koneksi dipinjam & idle":
    let pool = newDbPool(cfgWith(poolSize = 2, acquireTimeoutMs = 1_000))
    defer: pool.close()
    var s = pool.statsOf()
    check s.created == 0
    check s.idle == 0
    let a = pool.acquire()
    let b = pool.acquire()
    s = pool.statsOf()
    check s.created == 2
    check s.inUse == 2
    check s.idle == 0
    pool.release(a)
    pool.release(b)
    s = pool.statsOf()
    check s.inUse == 0
    check s.idle == 2

  test "pool habis -> PoolError setelah batas tunggu (bukan menggantung)":
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 120))
    defer: pool.close()
    let held = pool.acquire()
    var raised = false
    let start = epochTime()
    try:
      discard pool.acquire()
    except PoolError as e:
      raised = true
      check e.msg.contains("timeout")
    let elapsed = epochTime() - start
    check raised
    check elapsed >= 0.1
    check elapsed < 5.0
    pool.release(held)
    check pool.statsOf().inUse == 0

  test "koneksi gagal -> PoolError dengan pesan jelas":
    var badCfg = baseCfg
    badCfg.target.port = "1"
    let pool = newDbPool(badCfg)
    defer: pool.close()
    var raised = false
    try:
      discard pool.acquire()
    except PoolError as e:
      raised = true
      check e.msg.contains("gagal menyambung")
    check raised

const
  stressThreads = 8

  ## Anggaran tunggu pinjaman koneksi untuk test stress (O-074). Test ini menguji **kebocoran/
  ## invarian pool**, bukan SLA latensi: di gate penuh 8 thread + pool 3 + tunnel SSH bisa membuat
  ## satu pinjaman menunggu > 15 dtk walau pool benar. Menaikkan anggaran tidak melonggarkan
  ## assertion apa pun (galat tetap harus 0, `inUse` tetap 0, `created <= poolSize`); yang dilonggarkan
  ## hanya "berapa lama boleh menunggu sebelum dinyatakan gagal".
  stressAcquireTimeoutMs = 60_000

type
  StressArgs = object
    pool: DbPool
    slot: int
    iterations: int

var
  stressErrors: Atomic[int]
  stressIterations: Atomic[int]
  stressPids: array[stressThreads, int]
  ## Galat terakhir per thread. Hitungan saja tidak cukup untuk menyelidiki kegagalan yang jarang:
  ## tanpa pesannya, sekali muncul kita tetap tidak tahu apakah itu kebocoran/invarian pool atau
  ## koneksi yang putus di luar pool (pernah terjadi saat gate 15 Okt 2026 — 2 dari 200 iterasi).
  stressLastError: array[stressThreads, string]

proc stressWorker(args: StressArgs) {.thread, gcsafe.} =
  ## Meminjam-mengembalikan koneksi berkali-kali dari satu thread. Kegagalan dicatat sebagai hitungan
  ## (bukan dilempar): satu thread tidak boleh mematikan test lain, dan yang diuji di sini justru
  ## "apakah ada yang gagal saat serentak".
  for putaran in 1 .. args.iterations:
    try:
      # `withConn`/`withTx` tidak dianotasi `gcsafe` di platform-lib (mereka memanggil `body` secara
      # tidak langsung, `GcUnsafe2`). Cast di sini adalah pernyataan asumsi yang sama dengan
      # `apps/api/src/db_bridge.nim`: yang belum terbukti adalah pemakaian pool lintas-thread — dan
      # justru itulah yang diuji berkas ini.
      {.cast(gcsafe).}:
        let pid = args.pool.withConn(proc(db: DbConn): int =
          parseInt(db.getValue(sql"SELECT pg_backend_pid()")))
        if putaran == 1 and args.slot < stressPids.len:
          stressPids[args.slot] = pid
        # Jalur transaksi ikut dikenai serentak, bukan hanya `withConn`.
        discard args.pool.withTx(proc(db: DbConn): string =
          db.getValue(sql"SELECT ?::text", "ok"))
        discard stressIterations.fetchAdd(1)
    except CatchableError as e:
      discard stressErrors.fetchAdd(1)
      if args.slot < stressLastError.len:
        # Tiap thread hanya menulis slotnya sendiri, jadi akses ini aman; cast-nya sama jenisnya
        # dengan `.cast(gcsafe)` untuk jalur pool di atas.
        {.cast(gcsafe).}:
          stressLastError[args.slot] = $e.name & ": " & e.msg

proc runStress(pool: DbPool; iterations: int) =
  stressErrors.store(0)
  stressIterations.store(0)
  for i in 0 ..< stressThreads:
    stressPids[i] = 0
    stressLastError[i] = ""
  var workers: array[stressThreads, Thread[StressArgs]]
  for i in 0 ..< stressThreads:
    createThread(workers[i], stressWorker, StressArgs(pool: pool, slot: i, iterations: iterations))
  for i in 0 ..< stressThreads:
    joinThread(workers[i])

suite "pool: paralel antar-thread":
  test "8 thread pada poolSize=3: tidak ada kebocoran dan batas pool dihormati":
    let pool = newDbPool(cfgWith(poolSize = 3, acquireTimeoutMs = stressAcquireTimeoutMs))
    defer: pool.close()
    runStress(pool, 25)

    # Pesan galat dicetak sebelum assertion: kalau ini muncul sekali di gate, penyebabnya harus
    # sudah terbaca dari log gate — bukan perlu direproduksi dulu.
    if stressErrors.load() > 0:
      for i in 0 ..< stressThreads:
        if stressLastError[i].len > 0:
          echo "  stress thread " & $i & ": " & stressLastError[i]

    check stressErrors.load() == 0
    check stressIterations.load() == stressThreads * 25
    let s = pool.statsOf()
    check s.inUse == 0 # setiap pinjaman dikembalikan
    check s.idle == s.created
    check s.created <= 3 # batas pool tidak pernah dilewati

    # Semua thread hanya bisa melihat backend milik pool ini: koneksi dipakai ulang, bukan liar.
    var unik: seq[int]
    for i in 0 ..< stressThreads:
      if stressPids[i] != 0 and stressPids[i] notin unik:
        unik.add stressPids[i]
    check unik.len == 3

  test "poolSize=1 dengan 8 thread: saling menunggu, bukan gagal":
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = stressAcquireTimeoutMs))
    defer: pool.close()
    runStress(pool, 5)

    check stressErrors.load() == 0
    check stressIterations.load() == stressThreads * 5
    check pool.statsOf().created == 1
    check pool.statsOf().inUse == 0

suite "pool: koneksi mati di server":
  test "koneksi yang sudah mati dibuang, bukan diserahkan ke pemanggil":
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 5_000))
    defer: pool.close()
    let korban = pool.withConn(proc(db: DbConn): string =
      db.getValue(sql"SELECT pg_backend_pid()"))

    # Bunuh backend itu dari koneksi lain (pool lain), seperti restart DB atau tindakan DBA.
    let pembunuh = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 5_000))
    defer: pembunuh.close()
    let dibunuh = pembunuh.withConn(proc(db: DbConn): string =
      db.getValue(sql"SELECT pg_terminate_backend(?::int)::text", korban))
    check dibunuh == "true"

    # Tanpa validasi nyata, pinjaman berikutnya mengembalikan koneksi mati itu dan kueri pemanggil
    # gagal. Yang benar: koneksi mati dibuang, koneksi baru dibuat.
    let pengganti = pool.withConn(proc(db: DbConn): string =
      db.getValue(sql"SELECT pg_backend_pid()"))
    check pengganti != korban
    check pool.statsOf().created == 1

suite "pool: transaksi":
  test "withTx commit dan mengembalikan nilai":
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 1_000))
    defer: pool.close()
    let nilai = pool.withTx(proc(db: DbConn): string =
      discard db.getValue(sql"SELECT pg_advisory_xact_lock(hashtext('itpool.commit'))")
      db.getValue(sql"SELECT 'ok'"))
    check nilai == "ok"
    check pool.statsOf().inUse == 0

  test "withTx rollback saat body melempar, pool tetap terpakai":
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 1_000))
    defer: pool.close()
    var raised = false
    try:
      discard pool.withTx(proc(db: DbConn): string =
        exec(db, sql"CREATE TEMP TABLE itpool_rollback (id int)")
        raise newException(ValueError, "gagal di tengah transaksi"))
    except ValueError:
      raised = true
    check raised
    # TABEL sementara dari transaksi yang gagal harus hilang (perubahan di-ROLLBACK).
    let sisa = pool.withConn(proc(db: DbConn): string =
      db.getValue(sql"SELECT (to_regclass('pg_temp.itpool_rollback') IS NULL)::text"))
    check sisa == "true"

  test "withTx yang gagal tidak dihitung sebagai transaksi bocor":
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 1_000))
    defer: pool.close()
    var raised = false
    try:
      discard pool.withTx(proc(db: DbConn): string =
        raise newException(ValueError, "gagal di tengah transaksi"))
    except ValueError:
      raised = true
    check raised
    check pool.statsOf().leakedTx == 0

  test "koneksi dikembalikan saat masih bertransaksi -> di-ROLLBACK & tercatat":
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 1_000))
    defer: pool.close()
    let db = pool.acquire()
    exec(db, sql"BEGIN")
    exec(db, sql"CREATE TEMP TABLE itpool_leak (id int)")
    pool.release(db)
    check pool.statsOf().leakedTx == 1
    # poolSize=1: koneksi yang sama dipinjam ulang, dan tabel sementara sudah hilang.
    let sisa = pool.withConn(proc(db: DbConn): string =
      db.getValue(sql"SELECT (to_regclass('pg_temp.itpool_leak') IS NULL)::text"))
    check sisa == "true"

# --- T-065: koneksi membeku di tengah kueri ---------------------------------
#
# Perantara TCP yang meneruskan trafik lalu berhenti meneruskan, sementara socket tetap terbuka dan
# kernel tetap meng-ACK. Ini pola tunnel SSH yang prosesnya hidup tetapi jalur datanya mati:
# keepalive TCP **tidak** memicu (peer masih menjawab probe) dan `statement_timeout` tidak berlaku
# (kueri tidak pernah sampai server). Yang diuji: `queryDeadlineMs` memutusnya.

const freezeDeadlineMs = 700

var proxyFrozen: Atomic[bool]

type
  ProxyArgs = object
    ## Hanya fd (nilai biasa) yang menyeberang thread — objek `Socket` tetap milik satu thread.
    listenerFd: int32
    upHost: string
    upPort: int

proc proxyLoop(args: ProxyArgs) {.thread.} =
  ## Perantara TCP: teruskan dua arah sampai `proxyFrozen` menyala, lalu **tetap membaca** (supaya
  ## buffer klien tidak penuh) tetapi berhenti meneruskan.
  let cfd = posix.accept(SocketHandle(args.listenerFd), nil, nil)
  if int(cfd) < 0:
    return
  let up = newSocket()
  up.connect(args.upHost, Port(args.upPort))
  let ufd = up.getFd()
  var buf: array[16_384, char]
  var fds: array[2, posix.TPollfd]
  fds[0] = posix.TPollfd(fd: cint(cfd), events: posix.POLLIN)
  fds[1] = posix.TPollfd(fd: cint(ufd), events: posix.POLLIN)
  while true:
    if posix.poll(addr fds[0], 2, 200) < 0:
      break
    for i in 0 ..< 2:
      if (fds[i].revents and posix.POLLIN) != 0:
        let got = posix.recv(SocketHandle(fds[i].fd), addr buf[0], buf.len, 0)
        if got <= 0:
          up.close()
          discard posix.close(cint(cfd))
          return
        if proxyFrozen.load():
          continue
        var off = 0
        while off < got:
          let sent = posix.send(SocketHandle(fds[1 - i].fd), addr buf[off], got - off, 0)
          if sent <= 0:
            up.close()
            discard posix.close(cint(cfd))
            return
          off += sent

type ProbeArgs = object
  pool: DbPool

var
  probeDone: Atomic[bool]
  probeRaised: Atomic[bool]
  probeMsg: string

proc freezeProbe(args: ProbeArgs) {.thread.} =
  ## Satu-satunya penulis `probeMsg`; pembaca menunggu `probeDone` (atomics, urutan seq_cst).
  try:
    {.cast(gcsafe).}:
      discard args.pool.withConn(proc(db: DbConn): string = db.getValue(sql"SELECT 1::text"))
  except CatchableError as e:
    probeRaised.store(true)
    {.cast(gcsafe).}:
      probeMsg = e.msg
  probeDone.store(true)

suite "pool: batas blok kerja (T-065)":
  test "kueri pada koneksi beku gagal <= batas, koneksi dibuang":
    let listener = newSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let proxyPort = listener.getLocalAddr()[1]
    proxyFrozen.store(false)
    var proxyThread: Thread[ProxyArgs]
    createThread(proxyThread, proxyLoop,
      ProxyArgs(listenerFd: int32(listener.getFd()), upHost: baseCfg.target.host,
                upPort: parseInt(baseCfg.target.port)))

    var viaProxy = baseCfg
    viaProxy.target.host = "127.0.0.1"
    viaProxy.target.port = $proxyPort
    # Ping saat acquire dimatikan: yang diuji adalah kueri di dalam blok kerja.
    viaProxy.validateOnAcquire = false
    viaProxy.queryDeadlineMs = freezeDeadlineMs
    let pool = newDbPool(viaProxy)
    defer: pool.close()

    check pool.withConn(proc(db: DbConn): string = db.getValue(sql"SELECT 'ok'::text")) == "ok"

    proxyFrozen.store(true)
    probeDone.store(false)
    probeRaised.store(false)
    probeMsg = ""
    let start = epochTime()
    var worker: Thread[ProbeArgs]
    createThread(worker, freezeProbe, ProbeArgs(pool: pool))
    # Jangan menggantung bila mekanismenya rusak: batas 5 detik untuk seluruh uji.
    while not probeDone.load() and epochTime() - start < 5.0:
      sleep(20)
    let elapsed = epochTime() - start

    check probeDone.load()
    check probeRaised.load()
    check probeMsg.contains("batas")
    check elapsed >= float(freezeDeadlineMs) / 1000.0 * 0.8
    check elapsed < 2.0
    # Koneksi yang kena batas **dibuang**, bukan dikembalikan ke daftar idle.
    check pool.statsOf().created == 0
    check pool.statsOf().inUse == 0
