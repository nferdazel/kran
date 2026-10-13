## Pool koneksi PostgreSQL (spec §12.1: "Wajib parameterized query; pool & timeout dibungkus").
##
## Sifat yang dijamin:
##   - **Parameterized**: selalu pakai `?`/`$1` + argumen (`db_postgres.exec/getAllRows` mengirim
##     `PQexecParams`). Jangan pernah merangkai SQL dengan string interpolation.
##   - **Transaksi eksplisit**: `withTx` = BEGIN/COMMIT/ROLLBACK; koneksi yang dikembalikan
##     dalam keadaan transaksi terbuka otomatis di-ROLLBACK sebelum masuk idle.
##   - **Batas pool**: maksimum `cfg.poolSize` koneksi; menunggu koneksi dibatasi
##     `cfg.acquireTimeoutMs` (bukan tanpa batas).
##
## Catatan implementasi (jujur): menunggu koneksi memakai *polling* `sleep(2 ms)` di bawah
## lock, bukan condition variable, karena `std/locks` tidak menyediakan `wait` bertimeout.
## Untuk ukuran pool kecil dan trafik Fase 0 ini memadai; bila nanti jadi leher botol,
## ganti dengan antrean bertimeout (ADR kecil).
##
## Nested `withTx` ditolak (raise) — satu use case = satu transaksi (spec §12.2).

import std/[os, times, locks]
import db_connector/db_postgres
import db_connector/postgres

import ./config

type
  PoolError* = object of IOError

  PoolStats* = object
    created*: int  ## koneksi hidup yang dikelola pool
    idle*: int     ## koneksi siap dipakai
    inUse*: int    ## koneksi sedang dipinjam
    leakedTx*: int ## pemakaian yang mengembalikan koneksi dalam transaksi terbuka

  DbPool* = ref object
    cfg*: DbConfig
    lock*: Lock
    idle*: seq[DbConn]
    created*: int
    closed*: bool
    stats*: PoolStats

proc newDbPool*(cfg: DbConfig): DbPool =
  new(result)
  initLock(result.lock)
  result.cfg = cfg
  result.idle = @[]

proc openRaw(cfg: DbConfig): DbConn =
  let t = cfg.target
  let opts = if t.options.len > 0: t.options.cstring else: nil
  result = pqsetdbLogin(t.host.cstring, t.port.cstring, opts, nil, t.database.cstring,
                        t.user.cstring, t.password.cstring)
  if pqstatus(result) != CONNECTION_OK:
    let msg = $pqerrorMessage(result)
    pqfinish(result)
    raise newException(PoolError,
      "gagal menyambung ke " & t.host & ":" & t.port & "/" & t.database & ": " & msg)

proc healthy(db: DbConn): bool =
  db != nil and pqstatus(db) == CONNECTION_OK

proc rollbackIfOpen(db: DbConn) =
  ## Mengembalikan koneksi ke keadaan IDLE. Aman dipanggil walau transaksi sudah gagal.
  if pqtransactionStatus(db) != PQTRANS_IDLE:
    let res = pqexec(db, "ROLLBACK".cstring)
    if res != nil:
      pqclear(res)

proc acquire*(p: DbPool): DbConn =
  ## Ambil satu koneksi. Raise `PoolError` bila pool ditutup atau melewati batas tunggu.
  let deadline = epochTime() * 1000.0 + float(p.cfg.acquireTimeoutMs)
  while true:
    var openNew = false
    withLock p.lock:
      if p.closed:
        raise newException(PoolError, "pool DB sudah ditutup")
      while p.idle.len > 0:
        let c = p.idle.pop()
        if healthy(c) or not p.cfg.validateOnAcquire:
          return c
        # koneksi sudah mati (server restart/jaringan putus): buang, lalu buat ulang.
        if c != nil:
          pqfinish(c)
        dec p.created
      if p.created < p.cfg.poolSize:
        inc p.created
        openNew = true

    if openNew:
      try:
        return openRaw(p.cfg)
      except CatchableError:
        withLock p.lock:
          dec p.created
        raise

    if epochTime() * 1000.0 >= deadline:
      raise newException(PoolError,
        "timeout menunggu koneksi DB (" & $p.cfg.acquireTimeoutMs & " ms, poolSize=" &
        $p.cfg.poolSize & "; semua koneksi sedang dipinjam)")
    sleep(2)

proc release*(p: DbPool, db: DbConn) =
  ## Kembalikan koneksi ke pool. Transaksi yang masih terbuka di-ROLLBACK lebih dulu.
  if db == nil:
    return
  var leaked = false
  if pqtransactionStatus(db) != PQTRANS_IDLE:
    leaked = true
    rollbackIfOpen(db)
  if not healthy(db) or pqtransactionStatus(db) != PQTRANS_IDLE:
    pqfinish(db)
    withLock p.lock:
      dec p.created
      if leaked:
        inc p.stats.leakedTx
    return
  withLock p.lock:
    if leaked:
      inc p.stats.leakedTx
    if p.closed:
      pqfinish(db)
      dec p.created
    else:
      p.idle.add db

proc withConn*[T](p: DbPool, body: proc(db: DbConn): T): T =
  ## Pinjam koneksi untuk satu blok kerja. Koneksi selalu dikembalikan.
  let db = p.acquire()
  try:
    result = body(db)
  finally:
    p.release(db)

proc withTx*[T](p: DbPool, body: proc(db: DbConn): T): T =
  ## Satu blok kerja = satu transaksi DB (spec §12.2).
  let db = p.acquire()
  if pqtransactionStatus(db) != PQTRANS_IDLE:
    p.release(db)
    raise newException(PoolError, "koneksi dipinjam dalam keadaan transaksi terbuka")
  var committed = false
  try:
    exec(db, sql"BEGIN")
    try:
      result = body(db)
      exec(db, sql"COMMIT")
      committed = true
    except CatchableError, Defect:
      exec(db, sql"ROLLBACK")
      raise
  finally:
    if not committed and pqtransactionStatus(db) != PQTRANS_IDLE:
      rollbackIfOpen(db)
    p.release(db)

proc statsOf*(p: DbPool): PoolStats =
  withLock p.lock:
    result.created = p.created
    result.idle = p.idle.len
    result.inUse = p.created - p.idle.len
    result.leakedTx = p.stats.leakedTx

proc close*(p: DbPool) =
  ## Tutup pool. Panggil setelah semua koneksi dikembalikan (koneksi yang masih dipinjam
  ## tidak dilacak lagi oleh pool).
  var toClose: seq[DbConn]
  withLock p.lock:
    if p.closed:
      return
    p.closed = true
    toClose = p.idle
    p.idle.setLen 0
    p.created = 0
  for c in toClose:
    pqfinish(c)
