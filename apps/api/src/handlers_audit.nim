## Handler REST audit trail (T-012, spec §9.1(7): audit dapat dibaca kembali).
##
## Hanya baca. Penulisan audit terjadi di use case (repo outbox/param/auth) lewat `appendAudit`;
## tidak ada endpoint yang bisa menulis atau menghapus audit — rantai hash-nya pun diverifikasi
## di DB, bukan di sini.

import std/[json, options, strutils]

import mummy
import db_connector/db_postgres

import platform/infrastructure/audit_repo

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./problem

const
  ## Batas jumlah baris: nilai **teknis** (ukuran respons), bukan ambang bisnis.
  defaultAuditLimit* = 20 # nomagic:ok ukuran halaman default
  maxAuditLimit* = 200    # nomagic:ok batas atas ukuran respons

proc auditItemJson(item: AuditListItem): JsonNode =
  %*{
    "seq": item.seq,
    "recordedAt": item.recordedAt,
    "businessDate": item.businessDate,
    "actorUserId": item.actorUserId,
    "actorRole": item.actorRole,
    "action": item.action,
    "resourceType": item.resourceType,
    "resourceId": item.resourceId,
    "reason": item.reason,
    "after": item.afterValue}

proc handleListAudit*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/audit?limit=&action=` — jejak audit terbaru (urut terbaru dulu).
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  if not requirePermission(app, req, principal.get(), permissionAuditRead):
    return

  var limit = defaultAuditLimit
  let limitParam = queryValue(req, "limit").strip()
  if limitParam.len > 0:
    try:
      limit = parseInt(limitParam)
    except ValueError:
      req.respondProblem(pkBadRequest, "Bad Request", "limit harus angka")
      return
    if limit < 1 or limit > maxAuditLimit:
      req.respondProblem(pkBadRequest, "Bad Request",
        "limit harus antara 1 dan " & $maxAuditLimit)
      return

  let action = queryValue(req, "action").strip()
  var items: seq[AuditListItem]
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        items = listAudit(db, limit, action))
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "daftar audit gagal dibaca")
    return

  var body = newJArray()
  for item in items:
    body.add auditItemJson(item)
  req.respondJson(200, %*{"items": body})
