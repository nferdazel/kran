## Test integrasi pool DB (butuh `CBS_DATABASE_URL`; lihat docs/runbooks/dev-db.md).
##
## Cakupan: kueri parameterized, akuntansi pool, batas tunggu, transaksi explicit (BEGIN/COMMIT/
## ROLLBACK), pengembalian koneksi yang masih bertransaksi, kegagalan koneksi.
##
## Belum tercakup di sini: peminjaman koneksi paralel dari beberapa thread. Pool dilindungi
## `std/locks` dan kompilasi `--threads:on` diverifikasi terpisah (lihat docs/tasks/T-004.md);
## stress test bersamaan menyusul bersama beban nyata (T-006 ke atas).

import std/[unittest, tables, os, times, strutils]
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
