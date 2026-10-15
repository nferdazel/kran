## Token cookie → sesi → pengguna → izin, dan kebijakan topik realtime turunannya (T-012, spec §13,
## §19.1). Ini pelunasan D-021 ("kebijakan topik default menolak sampai T-012 memasang sesi").
##
## Otorisasi memakai jalur yang sudah ada (`auth_service.authorizeUser`: role + branch scoping +
## SoD) — berkas ini tidak menambah aturan izin baru, hanya menyesuaikan bentuk permintaan HTTP
## (cookie) ke bentuk domain.

import std/[options]

import mummy
import db_connector/db_postgres

import platform/infrastructure/[auth_repo, auth_service]
import kernel/[auditcontext, clock, ids, result]

import ./context
import ./db_bridge
import ./events
import ./identity
import ./problem

const
  ## Izin yang dipakai endpoint T-012 (spec §13: `modul.resource.action`). Didaftarkan sebagai
  ## data (role → permission) di `packs/base/seed/`; kode di sini hanya menuntutnya.
  permissionParamRead* = "platform.param.read"
  permissionParamSubmit* = "platform.param.submit"
  permissionParamApprove* = "platform.param.approve"
  permissionAuditRead* = "platform.audit.read"

  ## Topik realtime → izin yang membukanya (spec §19.1). Topik yang tidak terdaftar di sini
  ## **tidak pernah** diizinkan: menambah topik = menambah pemetaan, bukan melonggarkan saringan.
  topicPermissions* = [("param.changed", permissionParamRead)]

type
  Principal* = object
    ## Identitas satu permintaan: sesi aktif + pengguna + izin efektifnya.
    session*: SessionRow
    user*: UserRow
    roles*: seq[string]
    permissions*: seq[string]

proc permissionForTopic*(topic: string): string =
  for (name, permission) in topicPermissions:
    if name == topic:
      return permission
  ""

proc knownTopics*(): seq[string] =
  for (name, permission) in topicPermissions:
    result.add name

proc resolvePrincipal*(db: DbConn, clock: Clock, token: string): Option[Principal] =
  ## Pemanggilan repo platform dari konteks HTTP: query pada koneksi milik thread
  ## pemanggil dan `Clock` tanpa state bersama. Sama alasannya dengan `db_bridge`:
  ## asumsi ditegaskan sekali di sini, bukan di setiap pemanggil.
  {.cast(gcsafe).}:
    ## Token → sesi aktif → pengguna ACTIVE + izin efektif.
    ## `none` = tidak ada sesi sah (token kosong/kedaluwarsa/dicabut, atau pengguna non-aktif).
    if token.len == 0:
      return none(Principal)
    let session = sessionFor(db, clock, token)
    if session.isNone:
      return none(Principal)
    let user = userById(db, session.get().userId)
    if user.isNone or user.get().status != "ACTIVE":
      return none(Principal)
    var principal = Principal(session: session.get(), user: user.get())
    principal.roles = roleCodesOfUser(db, principal.user.userId)
    for grant in grantsOf(db, principal.user.userId):
      if grant.permission notin principal.permissions:
        principal.permissions.add grant.permission
    some(principal)

proc principalOf*(ctx: AppContext, req: Request): Option[Principal] =
  ## `none` bila DB tidak dikonfigurasi (rute sudah membalas 501) atau identitas tidak sah.
  if ctx.pool.isNil:
    return none(Principal)
  let token = identityFromRequest(req)
  withDbConn(ctx.pool, proc(db: DbConn): Option[Principal] {.gcsafe.} =
    resolvePrincipal(db, ctx.clock, token))

proc authorized*(db: DbConn, principal: Principal, permission: string): bool =
  ## Pemanggilan repo platform dari konteks HTTP: query pada koneksi milik thread
  ## pemanggil dan `Clock` tanpa state bersama. Sama alasannya dengan `db_bridge`:
  ## asumsi ditegaskan sekali di sini, bukan di setiap pemanggil.
  {.cast(gcsafe).}:
    ## Endpoint T-012 berjalan di **tingkat institusi** (`targetBranch = ""`), jadi hanya grant tanpa
    ## batas cabang yang berlaku. Parameter ber-scope `BRANCH`/`PRODUCT` belum punya konteks cabang
    ## di API ini — batasannya dicatat di `docs/tasks/T-012.md`.
    authorizeUser(db, principal.user.userId, "", permission).allowed

proc auditContextFor*(principal: Principal, req: Request, clock: Clock,
                      reason: string): AuditContext =
  ## Pemanggilan repo platform dari konteks HTTP: query pada koneksi milik thread
  ## pemanggil dan `Clock` tanpa state bersama. Sama alasannya dengan `db_bridge`:
  ## asumsi ditegaskan sekali di sini, bukan di setiap pemanggil.
  {.cast(gcsafe).}:
    ## Konteks audit dari permintaan HTTP: aktor, IP, perangkat, alasan, korelasi trace.
    newAuditContext(parseId(principal.user.userId).value(),
      ip = clientIp(req), device = deviceOf(req), reason = reason,
      correlationId = traceIdFrom(req), startedAt = clock.now())

proc topicsAllowedFor*(db: DbConn, clock: Clock, identity: string,
                       requested: seq[string]): seq[string] =
  ## Pemanggilan repo platform dari konteks HTTP: query pada koneksi milik thread
  ## pemanggil dan `Clock` tanpa state bersama. Sama alasannya dengan `db_bridge`:
  ## asumsi ditegaskan sekali di sini, bukan di setiap pemanggil.
  {.cast(gcsafe).}:
    ## Topik yang benar-benar diizinkan untuk identitas ini. `*` diperluas ke topik yang **izinnya
    ## dimiliki**, bukan ke seluruh topik yang ada (spec §18.2: perluasan tetap gagal-tertutup).
    let principal = resolvePrincipal(db, clock, identity)
    if principal.isNone:
      return @[]
    let wanted = if "*" in requested: knownTopics() else: requested
    for topic in wanted:
      let permission = permissionForTopic(topic)
      if permission.len > 0 and authorized(db, principal.get(), permission):
        result.add topic

proc requirePrincipal*(ctx: AppContext, req: Request): Option[Principal] =
  ## Penjaga rute: membalas 501 (DB tidak dikonfigurasi) atau 401 (tanpa sesi sah) sendiri dan
  ## mengembalikan `none`; handler cukup berhenti.
  if ctx.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi (CBS_DATABASE_URL kosong saat start)")
    return none(Principal)
  let principal = principalOf(ctx, req)
  if principal.isNone:
    req.respondProblem(pkUnauthorized, "Unauthorized", "sesi tidak ada atau sudah berakhir")
  principal

proc requirePermission*(ctx: AppContext, req: Request, principal: Principal,
                        permission: string): bool =
  ## Penjaga izin: membalas 403 dan mengembalikan `false` bila permintaan tidak boleh lanjut.
  if ctx.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi")
    return false
  let allowed = withDbConn(ctx.pool, proc(db: DbConn): bool {.gcsafe.} =
    authorized(db, principal, permission))
  if not allowed:
    req.respondProblem(newProblem(pkForbidden, "Forbidden", "tidak punya izin " & permission,
      traceId = traceIdFrom(req), params = @[("permission", permission)]))
  allowed

proc realtimePolicy*(ctx: AppContext): TopicPolicy =
  ## Kebijakan untuk `events.newEventService`: koneksi hanya dibuka bila cookie sesinya sah dan
  ## topik disaring per izin.
  TopicPolicy(
    canOpen: proc(identity: string): bool {.gcsafe.} =
    if ctx.pool.isNil:
      return false
    withDbConn(ctx.pool, proc(db: DbConn): bool {.gcsafe.} =
      resolvePrincipal(db, ctx.clock, identity).isSome),
    allowedTopics: proc(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
    if ctx.pool.isNil:
      return @[]
    withDbConn(ctx.pool, proc(db: DbConn): seq[string] {.gcsafe.} =
      topicsAllowedFor(db, ctx.clock, identity, requested)),
    sessionValid: proc(identity: string): bool {.gcsafe.} =
    # Dipakai pump untuk memeriksa ulang langganan yang sudah terbuka (O-036): sesi bisa
    # dicabut/kedaluwarsa setelah handshake. Resolusi principal yang sama dengan `canOpen` supaya
    # "identitas sah" hanya punya satu definisi (termasuk pengguna yang dinonaktifkan).
    if ctx.pool.isNil:
      return false
    withDbConn(ctx.pool, proc(db: DbConn): bool {.gcsafe.} =
      resolvePrincipal(db, ctx.clock, identity).isSome))
