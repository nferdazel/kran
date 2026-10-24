## Handler master cabang (T-121/O-101): **baca saja**.
##
## Layar operator butuh daftar cabang untuk dipilih (layar vault kas memilih cabang tempat uang
## disimpan). Sebelum ini cabang hanya terbaca lewat `ctl`/SQL, sehingga UI harus menuntut UUID.
##
## Penulisan cabang tetap milik `ctl create-branch` (D-130): tidak ada rute POST/PATCH di sini.
## Daftar ini tidak disaring per cabang: kode+nama cabang adalah data master yang tercetak di nomor
## rekening, sedangkan otorisasi per cabang tetap ditegakkan di setiap endpoint yang menyentuh kas
## (`authorizedAtBranch`).

import std/[json, options]

import mummy
import db_connector/db_postgres

import kernel/ids
import platform/infrastructure/branch_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const permissionBranchRead* = "platform.branch.read"

proc branchJson(b: Branch): JsonNode =
  %*{
    "branchId": $b.branchId,
    "code": b.code,
    "name": b.name,
    "status": b.status,
  }

proc handleListBranches*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/branches` — master cabang (kode 3 digit + nama), urut kode.
  ##
  ## Izin `platform.branch.read` cukup dipegang di mana pun (`requirePermission`, bukan
  ## `authorizedAtBranch(..., "")`): pemegang role ber-scope `BRANCH` justru pengguna yang paling
  ## butuh daftar ini, dan `user_role.branch_id` mereka tidak boleh membuat daftar master tertutup.
  let principalOpt = requirePrincipal(app, req)
  if principalOpt.isNone:
    return
  let principal = principalOpt.get()
  if not requirePermission(app, req, principal, permissionBranchRead):
    return

  var failed = false
  var items = newJArray()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        for b in listBranches(db):
          items.add branchJson(b))
  except DbError:
    failed = true

  if failed:
    req.respondProblem(pkInternal, "Internal Server Error", "daftar cabang gagal dibaca")
    return
  req.respondJson(200, %*{"items": items})
