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
import platform/infrastructure/[auth_service, calendar_repo]
import kernel/[auditcontext, clock, ids, result]

import ./access
import ./business_date_view
import ./context
import ./db_bridge
import ./http_util
import ./identity
import ./login_guard
import "platform-lib/log"
import ./problem

const
  ## Nama field badan permintaan (kontrak OpenAPI) di satu tempat supaya handler, test, dan
  ## kontrak tidak menebak bentuk JSON.
  fieldUsername* = "username"
  fieldPassword* = "password"
  ## Nama field badan permintaan ganti kata sandi (kontrak `ChangePasswordRequest`).
  fieldOldPassword* = "oldPassword"
  fieldNewPassword* = "newPassword"

proc utcDateOf(clock: Clock): string =
  ## Tanggal buku yang dipakai untuk membaca parameter: tanggal UTC hari ini. Kalender modul
  ## (`businessDateOf`) belum punya baris di Fase 0, sehingga `auth_service` pun memakai jatuh
  ## tempo yang sama.
  businessDateIso(clock)

proc handleLogin*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/auth/login` — kredensial → cookie sesi `HttpOnly` (spec §13).
  if app.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi (KRAN_DATABASE_URL kosong saat start)")
    return

  # Pembatas login (T-128) diperiksa **sebelum** parsing dan KDF: permintaan cacat pun dihitung,
  # dan PBKDF2 tidak pernah berjalan tanpa slot. Slot wajib dilepas lewat `defer`.
  let ip = clientIp(req)
  let slot = tryBegin(app.loginGuard, ip)
  if not slot.allowed:
    req.respondProblem(
      newProblem(pkTooManyRequests, "Too Many Requests",
        "terlalu banyak percobaan login; coba lagi nanti",
        traceId = traceIdFrom(req), params = @[("reason", "rate_limited")]),
      @[("Retry-After", $slot.retryAfter)])
    return
  defer:
    finish(app.loginGuard)

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
    # Sebabnya ke log server; teksnya memuat kunci/nilai kebijakan institusi sehingga
    # tidak boleh dikirim ke klien (T-128/API-2).
    discard newLogger(lvlError).error("kebijakan keamanan tidak sah",
      [("detail", e.msg)])
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan server tidak sah")
    return

  case authResult.outcome
  of aoSuccess:
    let policy = sessionPolicy(settings.sessionIdleMinutes, settings.sessionAbsoluteMinutes)
    var headers = headersWithType(ContentTypeJson)
    # Token sesi **hanya** lewat cookie (spec §13): tidak ada salinan di badan respons, sehingga
    # skrip di halaman tidak bisa membacanya.
    headers["Set-Cookie"] = SessionCookieName & "=" & authResult.token & "; " &
      sessionCookieAttributes(policy)
    req.respondRaw(200, headers, $ %*{
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
  #
  # Tanggal buku institusi dibaca di blok yang sama (O-116). Dulu hanya pembaca
  # `dayclose.run.read` yang bisa mengambilnya, sehingga teller — justru peran yang sesi kasnya
  # ditolak `session_business_date_mismatch` bila tanggalnya berbeda — tidak melihat tanggal yang
  # menjadi patokannya. Membacanya di sini membuat setiap peran back-office menerima nilai yang
  # sama tanpa permintaan tambahan per halaman.
  #
  # Tiga keadaan dibedakan, bukan dua: `some(objek)` = baris tanggal buku ada, `some(null)` =
  # institusi memang belum punya baris (sama seperti `GET /dayclose/status`), `none` = pembacaan
  # gagal sehingga field **dihilangkan**. Tanpa pembedaan itu, kegagalan DB akan dirender sebagai
  # "belum tersedia" — nilai yang tidak diketahui berpura-pura diketahui.
  var businessDate = none(JsonNode)
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let settings = settingsOf(db, institutionScope(), utcDateOf(app.clock))
        discard touch(db, app.clock, settings, p.session)
        let row = businessDateOf(db, institutionScope())
        businessDate = some(if row.isSome: businessDateJson(row.get()) else: newJNull()))
  except DbError, ValueError:
    # Perpanjangan bersifat best-effort: batas absolut tetap berlaku, dan kegagalan membaca
    # kebijakan (parameter hilang atau kombinasi tidak sah) tidak boleh menggagalkan permintaan.
    businessDate = none(JsonNode)

  var payload = %*{
    "userId": p.user.userId,
    "username": p.user.username,
    "fullName": p.user.fullName,
    "mustChangePassword": p.user.mustChangePassword,
    "roles": p.roles,
    "permissions": p.permissions,
    "expiresAt": p.session.expiresAt}
  if businessDate.isSome:
    payload["businessDate"] = businessDate.get()
  req.respondJson(200, payload)

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
  req.respondRaw(204, headers, "")

proc handlePasswordPolicy*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/auth/password-policy` — aturan bentuk kata sandi yang berlaku (O-051).
  ##
  ## Hanya angka yang memang membentuk aturan (panjang, jenis karakter, riwayat). Kebijakan yang
  ## **tidak** dibagikan sengaja: jumlah percobaan gagal, menit lockout, umur sesi, dan iterasi
  ## PBKDF2 — semuanya informasi untuk penyerang, bukan untuk pengguna yang sedang mengganti sandi.
  ##
  ## Butuh sesi sah: layar ganti sandi selalu berada di dalam `/app`, termasuk alur wajib ganti
  ## sesudah login pertama.
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return

  var payload = newJObject()
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let settings = settingsOf(db, institutionScope(), utcDateOf(app.clock))
        payload = %*{
          "minLength": settings.minPasswordLength,
          "minClasses": settings.minPasswordClasses,
          "historyCount": settings.passwordHistoryCount,
        })
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan kata sandi gagal dibaca")
    return
  except ValueError as e:
    # Sama seperti ganti sandi: detail kebijakan hanya ke log server, bukan ke klien.
    discard newLogger(lvlError).error("kebijakan keamanan tidak sah", [("detail", e.msg)])
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan server tidak sah")
    return

  req.respondJson(200, payload)

proc handleChangePassword*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/auth/password` — ganti kata sandi sendiri (T-027).
  ##
  ## Rute ini tidak meminta izin apa pun, dan itu disengaja: pemilik sesi yang masih wajib
  ## mengganti kata sandi (admin pertama hasil bootstrap) justru harus bisa sampai ke sini,
  ## sementara rute ber-izin sudah ditolak `requirePermission` (alasan
  ## `password_change_required`).
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  let p = principal.get()

  let body = parseJsonBody(req)
  if body.isNone:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus JSON")
    return
  let oldPassword = body.get().jsonField(fieldOldPassword)
  let newPassword = body.get().jsonField(fieldNewPassword)
  if oldPassword.len == 0 or newPassword.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "oldPassword dan newPassword wajib diisi")
    return

  var changed = false
  try:
    # Satu transaksi: hash baru, pencabutan sesi lain, dan entri audit harus ikut bersama-sama.
    # Pelanggaran kebijakan (`PasswordPolicyError`) sengaja dibiarkan menembus blok ini — supaya
    # transaksinya dibatalkan, bukan di-commit dengan tulisan separuh.
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        let instScope = institutionScope()
        let settings = settingsOf(db, instScope, utcDateOf(app.clock))
        let ctx = newAuditContext(parseId(p.user.userId).value(), ip = clientIp(req),
          device = deviceOf(req), reason = "ganti kata sandi sendiri",
          correlationId = traceIdFrom(req), startedAt = app.clock.now())
        changed = changePassword(db, ctx, app.clock, instScope, p.user, settings,
          oldPassword, newPassword, keepSessionId = p.session.sessionId))
  except PasswordPolicyError:
    req.respondProblem(newProblem(pkBadRequest, "Bad Request",
      "kata sandi baru tidak memenuhi kebijakan",
      traceId = traceIdFrom(req), params = @[("reason", "password_policy")]))
    return
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "ganti kata sandi gagal diproses")
    return
  except ValueError as e:
    # Sebabnya ke log server; teksnya memuat kunci/nilai kebijakan institusi sehingga
    # tidak boleh dikirim ke klien (T-128/API-2).
    discard newLogger(lvlError).error("kebijakan keamanan tidak sah",
      [("detail", e.msg)])
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan server tidak sah")
    return

  if not changed:
    # 403, bukan 401: sesinya sah, yang salah hanya kata sandi lama. Klien yang memperlakukan 401
    # sebagai "sesi berakhir" tidak jadi mengeluarkan pengguna dari halaman ini.
    req.respondProblem(newProblem(pkForbidden, "Forbidden", "kata sandi lama tidak cocok",
      traceId = traceIdFrom(req), params = @[("reason", "old_password_mismatch")]))
    return

  # Cookie tidak diganti: sesi yang dipakai tetap sah, hanya sesi lain yang dicabut.
  req.respondRaw(204, emptyHttpHeaders(), "")
