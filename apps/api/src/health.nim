## Kesehatan proses: `/healthz` (liveness) & `/readyz` (readiness) — spec §21.4 #11.
##
## - Liveness **tidak** menyentuh DB: proses yang hidup tapi DB mati bukan alasan mengulang
##   start (itu tugas readiness, yang memutuskan trafik/rollback).
## - Readiness menjalankan daftar pemeriksaan yang disuntikkan pemanggil (`AppContext.readiness`).
##   Daftar kosong = siap (tidak ada dependensi yang bisa diperiksa).
##
## Kontrak: `packages/contracts/openapi/cbs-api.yaml` (`Health`, `Readiness`).

import std/[json, times]

import mummy

import ./context
import ./http_util

export context

proc uptimeSeconds*(app: AppContext): int64 =
  ## Dibulatkan ke bawah; selalu >= 0 walaupun jam sistem mundur.
  max(0'i64, int64(epochTime() - app.startedAt))

proc healthJson*(app: AppContext): JsonNode =
  %*{
    "status": "ok",
    "version": app.version,
    "uptimeSeconds": app.uptimeSeconds(),
    "role": app.role,
  }

proc readinessJson*(app: AppContext): tuple[status: int, body: JsonNode] =
  var checks: seq[ReadinessCheck]
  if app.readiness != nil:
    checks = app.readiness()
  var failed = false
  var arr = newJArray()
  for c in checks:
    if c.status == csFailed:
      failed = true
    var item = %*{"name": c.name, "status": $c.status}
    if c.detail.len > 0:
      item["detail"] = %c.detail
    arr.add item
  let status = if failed: 503 else: 200
  result = (status: status, body: %*{"status": (if failed: "degraded" else: "ok"), "checks": arr})

proc handleHealth*(app: AppContext, req: Request) {.gcsafe.} =
  req.respondJson(200, app.healthJson())

proc handleReadiness*(app: AppContext, req: Request) {.gcsafe.} =
  let (status, body) = app.readinessJson()
  req.respondJson(status, body)
