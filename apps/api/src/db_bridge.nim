## Jembatan pemakaian pool DB dari handler HTTP.
##
## `DbPool.withConn` dari `platform-lib` tidak dianotasi `{.gcsafe.}` karena memanggil `body`
## secara tidak langsung (`GcUnsafe2`), sementara handler Mummy **wajib** `{.gcsafe.}` (Mummy
## memanggil handler dari worker thread). Pool sendiri melindungi `acquire`/`release` dengan
## `Lock` dan memang dirancang dipakai antar-thread — tetapi pemakaian paralelnya belum diuji di
## CI (O-011).
##
## Karena itu asumsi "pool aman dipakai dari worker thread" ditegaskan **satu kali** di sini
## (`{.cast(gcsafe).}`), bukan tersebar di tiap handler. Kalau asumsi itu keliru, tempat ini yang
## pertama harus dilihat — dan stress test O-011 yang harus membuktikannya.
##
## Itulah juga alasan template `dbCalls` di bawah ada: setiap closure yang dikirim ke `withDbConn`
## memanggil repo platform yang belum (dan tidak perlu) dianotasi `gcsafe` — yang belum terbukti
## aman adalah pemanggilan lintas-thread lewat pool, bukan isi closure-nya. Alasannya ditulis di
## satu tempat (sini), bukan diulang di tiap handler.

import db_connector/db_postgres

import "platform-lib/db/pool"

template dbCalls*(body: untyped): untyped =
  ## Isi closure `withDbConn`/`withDbTx`: query pada koneksi milik thread pemanggil, `Clock` tanpa
  ## state bersama. Cast di sini adalah pernyataan asumsi yang sama dengan di `withDbConn`.
  {.cast(gcsafe).}:
    body

proc withDbConn*[T](pool: DbPool, body: proc(db: DbConn): T): T {.gcsafe.} =
  {.cast(gcsafe).}:
    pool.withConn(body)

proc withDbTx*[T](pool: DbPool, body: proc(db: DbConn): T): T {.gcsafe.} =
  {.cast(gcsafe).}:
    pool.withTx(body)

proc withDbConn*(pool: DbPool, body: proc(db: DbConn)) {.gcsafe.} =
  ## Varian tanpa nilai kembalian. Ada karena closure yang mengembalikan `void` tidak bisa
  ## dicocokkan ke parameter generik (`T` tidak dapat disimpulkan dari `void`) — bukan pilihan
  ## gaya, tapi batas inferensi Nim 2.2 (closure pembungkus mengembalikan nilai tetap).
  {.cast(gcsafe).}:
    discard pool.withConn(proc(db: DbConn): int =
      dbCalls:
        body(db)
      0)

proc withDbTx*(pool: DbPool, body: proc(db: DbConn)) {.gcsafe.} =
  {.cast(gcsafe).}:
    discard pool.withTx(proc(db: DbConn): int =
      dbCalls:
        body(db)
      0)

proc pingDatabase*(pool: DbPool): bool {.gcsafe.} =
  ## Pemeriksaan readiness: DB menjawab `select 1`.
  pool.withDbConn(proc(db: DbConn): bool {.gcsafe.} =
    db.getRow(sql"select 1 as ok")[0] == "1")
