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

import db_connector/db_postgres

import "platform-lib/db/pool"

proc withDbConn*[T](pool: DbPool, body: proc(db: DbConn): T {.gcsafe.}): T {.gcsafe.} =
  {.cast(gcsafe).}:
    pool.withConn(body)

proc withDbTx*[T](pool: DbPool, body: proc(db: DbConn): T {.gcsafe.}): T {.gcsafe.} =
  {.cast(gcsafe).}:
    pool.withTx(body)

proc pingDatabase*(pool: DbPool): bool {.gcsafe.} =
  ## Pemeriksaan readiness: DB menjawab `select 1`.
  pool.withDbConn(proc(db: DbConn): bool {.gcsafe.} =
    db.getRow(sql"select 1 as ok")[0] == "1")
