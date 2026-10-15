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
## Catatan implementasi (jujur): menunggu koneksi memakai *polling* `sleep(2 ms)` **di luar lock**
## (lock hanya dipegang untuk pembukuan daftar idle), bukan condition variable, karena `std/locks`
## tidak menyediakan `wait` bertimeout. Untuk ukuran pool kecil dan trafik Fase 0 ini memadai; bila
## nanti jadi leher botol, ganti dengan antrean bertimeout (ADR kecil).
##
## `validateOnAcquire` berarti **validasi nyata**: satu `select 1` untuk koneksi yang diambil dari
## daftar idle (koneksi baru tidak perlu). Harganya satu perjalanan bolak-balik; imbalannya koneksi
## yang sudah mati di server tidak lagi diserahkan ke pemanggil (T-033).
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

proc pingConn(db: DbConn): bool =
  ## Validasi **nyata** satu perjalanan bolak-balik ke server.
  ##
  ## `pqstatus` saja tidak cukup: koneksi yang sudah ditutup server (restart DB, jaringan putus,
  ## `pg_terminate_backend`) masih dilaporkan `CONNECTION_OK` sampai libpq mencoba I/O dan gagal.
  ## Tanpa validasi ini, koneksi mati dari daftar idle diserahkan ke pemanggil dan **permintaan
  ## pertama setelah DB hidup lagi gagal** — bukan crash, tetapi 500 yang seharusnya bisa dihindari
  ## (T-033). Hanya dipakai untuk koneksi yang berasal dari daftar idle, dan hanya bila
  ## `validateOnAcquire` aktif.
  if db == nil:
    return false
  let res = pqexec(db, "select 1".cstring)
  if res.isNil:
    return false
  let ok = pqresultStatus(res) == PGRES_TUPLES_OK
  pqclear(res)
  ok

proc rollbackIfOpen(db: DbConn) =
  ## Mengembalikan koneksi ke keadaan IDLE. Aman dipanggil walau transaksi sudah gagal.
  if pqtransactionStatus(db) != PQTRANS_IDLE:
    let res = pqexec(db, "ROLLBACK".cstring)
    if res != nil:
      pqclear(res)

proc acquire*(p: DbPool): DbConn =
  ## Ambil satu koneksi. Raise `PoolError` bila pool ditutup atau melewati batas tunggu.
  ##
  ## Validasi koneksi dari daftar idle dijalankan **di luar lock**: satu perjalanan bolak-balik di
  ## dalam lock akan menahan seluruh pool (T-033).
  let deadline = epochTime() * 1000.0 + float(p.cfg.acquireTimeoutMs)
  while true:
    var openNew = false
    var kandidat: DbConn = nil
    withLock p.lock:
      if p.closed:
        raise newException(PoolError, "pool DB sudah ditutup")
      while p.idle.len > 0:
        let c = p.idle.pop()
        if c == nil:
          dec p.created
          continue
        if healthy(c):
          kandidat = c
          break
        # koneksi sudah jelas mati (libpq sudah menandainya): buang, lalu buat ulang.
        pqfinish(c)
        dec p.created
      if kandidat.isNil and p.created < p.cfg.poolSize:
        inc p.created
        openNew = true

    if not kandidat.isNil:
      if not p.cfg.validateOnAcquire or pingConn(kandidat):
        return kandidat
      # Hidup menurut libpq, tetapi sudah mati di server: buang supaya pemanggil tidak menerima
      # koneksi yang pasti gagal, lalu ambil/buat yang lain.
      withLock p.lock:
        dec p.created
      pqfinish(kandidat)
      continue

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
