## Token cookie → sesi → pengguna → izin, dan kebijakan topik realtime turunannya (T-012, spec §13,
## §19.1). Ini pelunasan D-021 ("kebijakan topik default menolak sampai T-012 memasang sesi").
##
## Otorisasi memakai jalur yang sudah ada (`auth_service.authorizeUser`: role + branch scoping +
## SoD) — berkas ini tidak menambah aturan izin baru, hanya menyesuaikan bentuk permintaan HTTP
## (cookie) ke bentuk domain.

import std/[options]

import mummy
import db_connector/db_postgres

import platform/domain/authz
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
    ## Izin di **tingkat institusi** (`targetBranch = ""`): hanya grant tanpa batas cabang yang
    ## berlaku.
    ##
    ## Dipakai jalur yang memang institusi — khususnya langganan realtime (`topicsAllowedFor`),
    ## yang **tidak** disaring per baris: membukanya untuk grant khusus cabang berarti mengirim
    ## seluruh peristiwa `param.changed` lintas cabang. Rute HTTP tidak memakai fungsi ini; ia
    ## memakai `authorizedAnyBranch` (daftar, disaring per baris) atau `authorizedAtBranch` (satu
    ## objek ber-cabang). Sisa pekerjaan realtime: O-070.
    authorizeUser(db, principal.user.userId, "", permission).allowed

proc authorizedAnyBranch*(db: DbConn, principal: Principal, permission: string): bool =
  ## Izin dipegang untuk **setidaknya satu** cabang (T-058, D-062): gerbang untuk permintaan yang
  ## hasilnya disaring per baris (`readableScopeFilter`/`auditScopeFilter`). Bukan gerbang akhir —
  ## yang menentukan apa yang terlihat adalah penyaringan itu sendiri.
  {.cast(gcsafe).}:
    authorizeUserAnyBranch(db, principal.user.userId, permission).allowed

type
  BranchAuthz* = object
    ## Izin efektif pemanggil yang **dimuat sekali** untuk menyaring banyak baris (T-130/ARC-2).
    ## Tanpa ini, daftar rekening 200 baris menjalankan 2 query otorisasi per baris.
    grants: seq[Grant]
    conflicts: seq[RolePair]

proc loadBranchAuthz*(db: DbConn, principal: Principal): BranchAuthz =
  ## Satu kali baca grant + pasangan SoD; keputusannya tetap lewat `authorize` yang sama dengan
  ## `authorizedAtBranch`, jadi aturannya tidak bercabang dua.
  {.cast(gcsafe).}:
    BranchAuthz(grants: grantsOf(db, principal.user.userId), conflicts: conflictPairs(db))

proc allowedAt*(snapshot: BranchAuthz, targetBranch, permission: string): bool =
  ## Padanan `authorizedAtBranch` untuk pemeriksaan berulang pada satu permintaan.
  authorize(snapshot.grants, targetBranch, permission, snapshot.conflicts).allowed

proc authorizedAtBranch*(db: DbConn, principal: Principal, targetBranch,
                         permission: string): bool =
  ## Izin untuk **satu** cabang target (T-058, D-062) — dipakai begitu cabang objek yang disentuh
  ## permintaan diketahui (nilai parameter ber-scope `BRANCH`). `targetBranch = ""` = aksi tingkat
  ## institusi, dan hanya grant tanpa batas cabang yang berlaku.
  {.cast(gcsafe).}:
    authorizeUser(db, principal.user.userId, targetBranch, permission).allowed

proc auditContextFor*(principal: Principal, req: Request, clock: Clock,
                      reason: string, branch = ""): AuditContext =
  ## Pemanggilan repo platform dari konteks HTTP: query pada koneksi milik thread
  ## pemanggil dan `Clock` tanpa state bersama. Sama alasannya dengan `db_bridge`:
  ## asumsi ditegaskan sekali di sini, bukan di setiap pemanggil.
  {.cast(gcsafe).}:
    ## Konteks audit dari permintaan HTTP: aktor, IP, perangkat, alasan, korelasi trace, dan
    ## **cabang yang disentuh** permintaan (T-058, D-062) bila ada.
    ##
    ## Cabangnya berasal dari objek (nilai parameter ber-scope `BRANCH`, cabang yang dibaca pada
    ## jejak lintas-cabang), bukan dari cabang tugas pelaku: auditor cabang harus melihat tindakan
    ## siapa pun atas data cabangnya — termasuk pembacaan dari pusat.
    ##
    ## `platform.audit_log.branch_id` bertipe uuid dan ditulis lewat `NULLIF(?, '')::uuid`
    ## (`audit_repo.appendAudit`), jadi cabang hanya bisa ikut tercatat bila pengenalnya berbentuk
    ## uuid (`parseId`). Pengenal lain (mis. `"itapi-cabang-b"`) tidak dipaksa: pengenalnya tetap
    ## utuh di `resource_id`/payload, barisnya tetap tanpa cabang, dan kesenjangan representasi itu
    ## dicatat sebagai O-017.
    var branchIds: seq[Id]
    if branch.len > 0:
      let cabang = parseId(branch)
      if cabang.isOk:
        branchIds = @[cabang.value()]
    newAuditContext(parseId(principal.user.userId).value(),
      branchIds = branchIds,
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
    ##
    ## Gerbangnya **tanpa dimensi cabang** (O-070): mana peristiwa yang boleh sampai disaring per
    ## baris oleh `EventScope` di `hub` (`scopeAllows`). Tanpa ini, pengguna yang izinnya khusus
    ## cabang tidak menerima peristiwa sama sekali, dan membuka topiknya tanpa penyaringan akan
    ## mengirim peristiwa semua cabang ke semua pelanggan.
    let principal = resolvePrincipal(db, clock, identity)
    if principal.isNone:
      return @[]
    let wanted = if "*" in requested: knownTopics() else: requested
    for topic in wanted:
      let permission = permissionForTopic(topic)
      if permission.len > 0 and authorizedAnyBranch(db, principal.get(), permission):
        result.add topic

proc eventScopeFor*(db: DbConn, clock: Clock, identity: string): EventScope =
  ## Cakupan cabang untuk penyaringan peristiwa realtime (O-070). Tidak menambah aturan izin:
  ## memakai grant + pasangan SoD yang sama dengan `authorized`/`authorizedAtBranch`.
  ##
  ## `institutionWide` = izin dipegang tanpa batas cabang; `branchIds` = cabang tempat izin baca
  ## parameter dipegang. Peristiwa `param.changed` ber-scope cabang lain tidak dikirim.
  {.cast(gcsafe).}:
    let principal = resolvePrincipal(db, clock, identity)
    if principal.isNone:
      return EventScope()
    let grants = grantsOf(db, principal.get().user.userId)
    let conflicts = conflictPairs(db)
    if authorize(grants, "", permissionParamRead, conflicts).allowed:
      return EventScope(institutionWide: true)
    for grant in grants:
      if grant.permission != permissionParamRead or grant.branchId.len == 0:
        continue
      if authorize(grants, grant.branchId, permissionParamRead, conflicts).allowed and
          grant.branchId notin result.branchIds:
        result.branchIds.add grant.branchId

proc requirePrincipal*(ctx: AppContext, req: Request): Option[Principal] =
  ## Penjaga rute: membalas 501 (DB tidak dikonfigurasi) atau 401 (tanpa sesi sah) sendiri dan
  ## mengembalikan `none`; handler cukup berhenti.
  if ctx.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi (KRAN_DATABASE_URL kosong saat start)")
    return none(Principal)
  let principal = principalOf(ctx, req)
  if principal.isNone:
    req.respondProblem(pkUnauthorized, "Unauthorized", "sesi tidak ada atau sudah berakhir")
  principal

proc requirePermission*(ctx: AppContext, req: Request, principal: Principal,
                        permission: string): bool =
  ## Penjaga izin tingkat rute: membalas 403 dan mengembalikan `false` bila permintaan tidak boleh
  ## lanjut.
  ##
  ## Gerbangnya **tanpa dimensi cabang** (T-058, D-062): permintaan daftar tidak punya satu cabang
  ## target (hasilnya disaring per baris), dan permintaan yang menyentuh satu objek ber-cabang belum
  ## tahu cabangnya di titik ini. Karena itu 403 di sini berarti "izin tidak dipegang di cabang mana
  ## pun"; cabang objek diperiksa `authorizedAtBranch` begitu objeknya dibaca.
  if ctx.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi")
    return false
  if principal.user.mustChangePassword:
    # Kata sandi sementara (admin pertama hasil bootstrap, T-027) hanya boleh dipakai untuk
    # menggantinya. Rute ber-izin ditolak di satu tempat ini — bukan di tiap handler — supaya tidak
    # ada rute baru yang lupa. `getSession`, `logout`, dan `changePassword` tidak melewati fungsi
    # ini, jadi alur wajib-ganti tetap bisa diselesaikan.
    req.respondProblem(newProblem(pkForbidden, "Forbidden",
      "kata sandi harus diganti lebih dulu",
      traceId = traceIdFrom(req), params = @[("reason", "password_change_required")]))
    return false
  let allowed = withDbConn(ctx.pool, proc(db: DbConn): bool {.gcsafe.} =
    authorizedAnyBranch(db, principal, permission))
  if not allowed:
    req.respondProblem(newProblem(pkForbidden, "Forbidden", "tidak punya izin " & permission,
      traceId = traceIdFrom(req), params = @[("permission", permission)]))
  allowed

proc sessionCanWork*(ctx: AppContext, identity: string): bool {.gcsafe.} =
  ## Sesi yang boleh **bekerja**: ada, sah, dan tidak sedang wajib ganti kata sandi (T-027).
  ## Dipakai jalur realtime supaya sesi ber-kata-sandi-sementara tidak bisa menyedot data lewat
  ## langganan, sejalan dengan penjagaan `requirePermission`.
  if ctx.pool.isNil:
    return false
  withDbConn(ctx.pool, proc(db: DbConn): bool {.gcsafe.} =
    let p = resolvePrincipal(db, ctx.clock, identity)
    p.isSome and not p.get().user.mustChangePassword)

proc realtimePolicy*(ctx: AppContext): TopicPolicy =
  ## Kebijakan untuk `events.newEventService`: koneksi hanya dibuka bila cookie sesinya sah dan
  ## topik disaring per izin.
  TopicPolicy(
    canOpen: proc(identity: string): bool {.gcsafe.} =
    sessionCanWork(ctx, identity),
    allowedTopics: proc(identity: string, requested: seq[string]): seq[string] {.gcsafe.} =
    if ctx.pool.isNil:
      return @[]
    withDbConn(ctx.pool, proc(db: DbConn): seq[string] {.gcsafe.} =
      topicsAllowedFor(db, ctx.clock, identity, requested)),
    eventScope: proc(identity: string): EventScope {.gcsafe.} =
    # Penyaringan per cabang untuk peristiwa `param.changed` (O-070). Dibaca saat klien
    # berlangganan, jadi perubahan grant berlaku pada langganan berikutnya.
    if ctx.pool.isNil:
      return EventScope()
    withDbConn(ctx.pool, proc(db: DbConn): EventScope {.gcsafe.} =
      eventScopeFor(db, ctx.clock, identity)),
    sessionValid: proc(identity: string): bool {.gcsafe.} =
    # Dipakai pump untuk memeriksa ulang langganan yang sudah terbuka (O-036): sesi bisa
    # dicabut/kedaluwarsa setelah handshake. Definisi yang sama dengan `canOpen` supaya
    # "sesi yang boleh bekerja" hanya punya satu arti (termasuk pengguna yang dinonaktifkan).
    sessionCanWork(ctx, identity))
