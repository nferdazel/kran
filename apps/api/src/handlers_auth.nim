## Handler REST autentikasi & sesi (T-012, spec §13).
##
## Aturan yang **tidak** ada di sini: kebijakan login (lockout, umur sesi, keseragaman pesan
## salah-password) — semuanya milik `auth_service.authenticate`; handler hanya menerjemahkan
## hasil ke HTTP. Pesan error untuk pengguna tidak ditulis dalam bahasa apa pun: UI memakai
## `i18nKey` dari amplop Problem (spec §16).

import std/[json, options]

import mummy
import db_connector/db_postgres

import platform/domain/[authz, scope]
import platform/infrastructure/auth_service
import kernel/[auditcontext, clock, ids]

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./identity
import ./problem

const
  ## Nama field badan permintaan (kontrak OpenAPI) di satu tempat supaya handler, test, dan
  ## kontrak tidak menebak bentuk JSON.
  fieldUsername* = "username"
  fieldPassword* = "password"

proc utcDateOf(clock: Clock): string =
  ## Tanggal buku yang dipakai untuk membaca parameter: tanggal UTC hari ini. Kalender modul
  ## (`businessDateOf`) belum punya baris di Fase 0, sehingga `auth_service` pun memakai jatuh
  ## tempo yang sama.
  businessDateIso(clock)

proc handleLogin*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/auth/login` — kredensial → cookie sesi `HttpOnly` (spec §13).
  if app.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi (CBS_DATABASE_URL kosong saat start)")
    return

  let body = parseJsonBody(req)
  if body.isNone:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus JSON")
    return
  let username = body.get().jsonField(fieldUsername)
  let password = body.get().jsonField(fieldPassword)
  if username.len == 0 or password.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request",
      "username dan password wajib diisi")
    return

  let now = app.clock.now()
  var settings: SecuritySettings
  var authResult: AuthResult
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let instScope = institutionScope()
        settings = settingsOf(db, instScope, utcDateOf(app.clock))
        let ctx = newAuditContext(Id(""), ip = clientIp(req), device = deviceOf(req),
          reason = "login", correlationId = traceIdFrom(req), startedAt = now)
        authResult = authenticate(db, ctx, app.clock, instScope, settings, username, password))
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "login gagal diproses")
    return
  except ValueError as e:
    # Kebijakan keamanan dari parameter tidak sah (mis. `session_idle_minutes` >
    # `session_absolute_minutes`): konfigurasi institusi yang rusak, bukan kesalahan pengguna.
    # Tetap dijawab sebagai `problem+json` sesuai kontrak — bukan 500 mentah tanpa amplop — dan
    # sebabnya terlihat di `detail` supaya bisa langsung ditindaklanjuti.
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan tidak sah: " & e.msg)
    return

  case authResult.outcome
  of aoSuccess:
    let policy = sessionPolicy(settings.sessionIdleMinutes, settings.sessionAbsoluteMinutes)
    var headers = headersWithType(ContentTypeJson)
    # Token sesi **hanya** lewat cookie (spec §13): tidak ada salinan di badan respons, sehingga
    # skrip di halaman tidak bisa membacanya.
    headers["Set-Cookie"] = SessionCookieName & "=" & authResult.token & "; " &
      sessionCookieAttributes(policy)
    req.respond(200, headers, $ %*{
      "userId": authResult.userId,
      "sessionId": authResult.sessionId,
      "expiresAt": utcIso(sessionDeadlines(policy, now)[0])})
  of aoInvalidCredentials:
    req.respondProblem(newProblem(pkUnauthorized, "Unauthorized", "kredensial tidak cocok",
      traceId = traceIdFrom(req), params = @[("reason", "invalid_credentials")]))
  of aoLocked:
    req.respondProblem(newProblem(pkForbidden, "Forbidden", "akun terkunci sementara",
      traceId = traceIdFrom(req), params = @[("reason", "locked")]))
  of aoInactive:
    req.respondProblem(newProblem(pkForbidden, "Forbidden", "akun tidak aktif",
      traceId = traceIdFrom(req), params = @[("reason", "inactive")]))

proc handleSession*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/auth/session` — identitas & izin efektif; sekaligus denyut perpanjangan sesi.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  let p = principal.get()

  # Perpanjangan batas idle (spec §18.2) dikaitkan ke permintaan ini, bukan ke setiap permintaan:
  # satu tempat, dan UI memang memanggilnya saat memuat halaman. Kegagalan memperpanjang tidak
  # membatalkan permintaan — batas absolut tetap berlaku.
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let settings = settingsOf(db, institutionScope(), utcDateOf(app.clock))
        discard touch(db, app.clock, settings, p.session))
  except DbError, ValueError:
    # Perpanjangan bersifat best-effort: batas absolut tetap berlaku, dan kegagalan membaca
    # kebijakan (parameter hilang atau kombinasi tidak sah) tidak boleh menggagalkan permintaan.
    discard

  req.respondJson(200, %*{
    "userId": p.user.userId,
    "username": p.user.username,
    "fullName": p.user.fullName,
    "mustChangePassword": p.user.mustChangePassword,
    "roles": p.roles,
    "permissions": p.permissions,
    "expiresAt": p.session.expiresAt})

proc handleLogout*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/auth/logout` — cabut sesi + hapus cookie.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  let p = principal.get()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        discard logout(db, app.clock, p.session))
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "logout gagal diproses")
    return

  var headers = emptyHttpHeaders()
  headers["Set-Cookie"] = SessionCookieName & "=; " & clearedCookieAttributes()
  req.respond(204, headers)
