## Pemeriksaan kesiapan (readiness) yang dipakai `/readyz` — spec §21.4 #11.
##
## Dipisah dari `main.nim` supaya bisa diuji (`apps/api/tests/itapi.nim`) tanpa menjalankan CLI.
## Yang diperiksa hanya dependensi bootstrap (DB): nilai bisnis tetap dari parameter DB.

import "platform-lib/db/config"
import "platform-lib/db/pool"

import ./db_bridge
import ./health

proc databaseProbe*(): ReadinessProbe =
  ## Readiness DB: pool dibuat sekali (lazy) supaya `/healthz` tetap tidak menyentuh DB.
  ## Pesan `detail` sengaja tidak memuat kredensial — hanya sebab kegagalan.
  var pool: DbPool
  result = proc(): seq[ReadinessCheck] {.gcsafe.} =
    if not databaseUrlSet(envTableFromProcess()):
      return @[ReadinessCheck(name: "database", status: csFailed,
                              detail: "CBS_DATABASE_URL belum diisi")]
    try:
      if pool.isNil:
        pool = newDbPool(dbConfigFromProcessEnv())
      if not pingDatabase(pool):
        return @[ReadinessCheck(name: "database", status: csFailed,
                                detail: "jawaban tak terduga dari select 1")]
      @[ReadinessCheck(name: "database", status: csOk)]
    except CatchableError as e:
      @[ReadinessCheck(name: "database", status: csFailed, detail: e.msg)]
