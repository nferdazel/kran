## Test integrasi pool DB (butuh `CBS_DATABASE_URL`; lihat docs/runbooks/dev-db.md).
##
## Cakupan: kueri parameterized, akuntansi pool, batas tunggu, transaksi explicit (BEGIN/COMMIT/
## ROLLBACK), pengembalian koneksi yang masih bertransaksi, kegagalan koneksi.
##
## Cakupan T-033: peminjaman koneksi paralel dari banyak thread (dengan kontensi pool kecil), dan
## penggantian koneksi yang sudah mati di server. Sebelumnya yang pertama hanya berupa asumsi.

import std/[atomics, strutils, tables, times, unittest]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itpool: CBS_DATABASE_URL kosong — dilewati"
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

type
  StressArgs = object
    pool: DbPool
    slot: int
    iterations: int

var
  stressErrors: Atomic[int]
  stressIterations: Atomic[int]
  stressPids: array[stressThreads, int]

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
    except CatchableError:
      discard stressErrors.fetchAdd(1)

proc runStress(pool: DbPool; iterations: int) =
  stressErrors.store(0)
  stressIterations.store(0)
  for i in 0 ..< stressThreads:
    stressPids[i] = 0
  var workers: array[stressThreads, Thread[StressArgs]]
  for i in 0 ..< stressThreads:
    createThread(workers[i], stressWorker, StressArgs(pool: pool, slot: i, iterations: iterations))
  for i in 0 ..< stressThreads:
    joinThread(workers[i])

suite "pool: paralel antar-thread":
  test "8 thread pada poolSize=3: tidak ada kebocoran dan batas pool dihormati":
    let pool = newDbPool(cfgWith(poolSize = 3, acquireTimeoutMs = 15_000))
    defer: pool.close()
    runStress(pool, 25)

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
    let pool = newDbPool(cfgWith(poolSize = 1, acquireTimeoutMs = 15_000))
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
