## Alur autentikasi, sesi, dan pemeriksaan izin (T-006, spec §13, §18.2).
##
## **Catatan arsitektur**: alur ini memanggil repo langsung, jadi tinggal di `infrastructure`.
## Saat port/use case lapisan application lahir (pola T-016), isi berkas ini pindah ke
## `application/` dengan port `AuthSource`/`ParamSource`, dan berkas ini tinggal adaptornya.
##
## Semua angka kebijakan (panjang password, iterasi KDF, lockout, umur sesi) datang dari
## parameter DB — tidak ada default di kode (spec §10.6).

import std/[json, options, times]

import db_connector/db_postgres

import ../domain/[audit, authz, scope]
import ./[audit_repo, auth_repo, calendar_repo, param_repo, password_hasher]
import kernel/[auditcontext, clock, ids, paramkey]
import kernel/generated/paramkeys

type
  SecuritySettings* = object
    minPasswordLength*: int
    pbkdf2Iterations*: int
    maxFailedLogins*: int
    lockoutMinutes*: int
    sessionIdleMinutes*: int
    sessionAbsoluteMinutes*: int

  AuthOutcome* = enum
    aoSuccess = "SUCCESS"
    aoInvalidCredentials = "INVALID_CREDENTIALS"
    aoLocked = "LOCKED"
    aoInactive = "INACTIVE"

  AuthResult* = object
    outcome*: AuthOutcome
    userId*: string
    sessionId*: string
    token*: string ## token mentah; hanya ada di sini, DB menyimpan hash-nya

proc utcIso*(dt: DateTime): string =
  ## Bentuk waktu tetap untuk DB & perbandingan string (selalu UTC, akhiran `Z`).
  dt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc settingsOf*(db: DbConn, scope: ScopeRef, asOf: string): SecuritySettings =
  ## Membaca kebijakan keamanan dari parameter (gagal-cepat bila ada yang kosong).
  let lookup = lookupFor(scope)
  SecuritySettings(
    minPasswordLength: db.activeParamInt(
      keyString(P_platform_security_password_min_length), asOf, lookup),
    pbkdf2Iterations: db.activeParamInt(
      keyString(P_platform_security_password_pbkdf2_iterations), asOf, lookup),
    maxFailedLogins: db.activeParamInt(
      keyString(P_platform_security_max_failed_logins), asOf, lookup),
    lockoutMinutes: db.activeParamInt(
      keyString(P_platform_security_lockout_minutes), asOf, lookup),
    sessionIdleMinutes: db.activeParamInt(
      keyString(P_platform_security_session_idle_minutes), asOf, lookup),
    sessionAbsoluteMinutes: db.activeParamInt(
      keyString(P_platform_security_session_absolute_minutes), asOf, lookup))

proc businessDateFor(db: DbConn, scope: ScopeRef, nowIso: string): string =
  ## Tanggal buku institusi bila sudah ada; kalau belum, tanggal UTC hari ini.
  let row = businessDateOf(db, scope)
  if row.isSome:
    row.get().currentDate
  elif nowIso.len >= 10:
    nowIso[0 .. 9]
  else:
    nowIso

proc usernameDigest(username: string): string =
  ## Ringkasan username untuk audit percobaan login ke akun tak dikenal: cukup untuk
  ## korelasi percobaan berulang, tanpa menulis identitas mentah (spec §18.2 logging).
  tokenHash(username)[0 .. 15]

proc auditAuth(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
               action, userId: string, payload: JsonNode) =
  discard appendAudit(db, newAuditEntry(ctx, action, "app_user", userId, clock,
    businessDate = businessDateFor(db, scope, utcIso(clock.now())), after = payload))

proc authenticate*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                   settings: SecuritySettings, username, password: string): AuthResult =
  ## Login: verifikasi password + kebijakan lockout → sesi baru.
  ##
  ## Pesan/gagal tidak membedakan "user tidak ada" dan "password salah" (`aoInvalidCredentials`)
  ## supaya tidak membocorkan keberadaan akun; bedanya hanya tercatat di audit.
  let now = clock.now()
  let nowIso = utcIso(now)
  let found = userByUsername(db, username)
  if found.isNone:
    auditAuth(db, ctx, clock, scope, "auth.login.failure", "",
      %*{"reason": "unknown_user", "username_digest": usernameDigest(username)})
    return AuthResult(outcome: aoInvalidCredentials)

  var user = found.get()
  let locked = user.status == "LOCKED" and
    (user.lockedUntil.len == 0 or user.lockedUntil > nowIso)
  if locked:
    auditAuth(db, ctx, clock, scope, "auth.login.failure", user.userId,
      %*{"reason": "locked", "locked_until": user.lockedUntil})
    return AuthResult(outcome: aoLocked, userId: user.userId)

  if user.status in ["INACTIVE", "SUSPENDED"]:
    auditAuth(db, ctx, clock, scope, "auth.login.failure", user.userId,
      %*{"reason": "status", "status": user.status})
    return AuthResult(outcome: aoInactive, userId: user.userId)

  if not verifyPassword(password, user.passwordHash):
    user = recordLoginFailure(db, user.userId, settings.maxFailedLogins,
      settings.lockoutMinutes, nowIso)
    auditAuth(db, ctx, clock, scope, "auth.login.failure", user.userId,
      %*{"reason": "bad_password", "failed_attempts": user.failedAttempts,
         "status": user.status})
    return AuthResult(
      outcome: (if user.status == "LOCKED": aoLocked else: aoInvalidCredentials),
      userId: user.userId)

  discard recordLoginSuccess(db, user.userId)
  let policy = sessionPolicy(settings.sessionIdleMinutes, settings.sessionAbsoluteMinutes)
  let (idleDeadline, absoluteDeadline) = sessionDeadlines(policy, now)
  let token = newSessionToken()
  let sessionId = $newId(clock)
  discard createSession(db, sessionId, user.userId, tokenHash(token),
    utcIso(idleDeadline), utcIso(absoluteDeadline), ctx.ip, ctx.device, ctx.correlationId)
  auditAuth(db, ctx, clock, scope, "auth.login.success", user.userId,
    %*{"session_id": sessionId, "must_change_password": user.mustChangePassword,
       "expires_at": utcIso(idleDeadline), "absolute_expires_at": utcIso(absoluteDeadline)})
  AuthResult(outcome: aoSuccess, userId: user.userId, sessionId: sessionId, token: token)

proc parseIsoZ*(s: string): DateTime =
  ## Kebalikan `utcIso`; dipakai saat nilai DB perlu dihitung di Nim.
  parse(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())

proc sessionFor*(db: DbConn, clock: Clock, token: string): Option[SessionRow] =
  ## Sesi aktif untuk token mentah (yang dipakai cookie).
  activeSessionByTokenHash(db, tokenHash(token), utcIso(clock.now()))

proc touch*(db: DbConn, clock: Clock, settings: SecuritySettings,
            session: SessionRow): bool =
  ## Memperpanjang batas idle sesuai kebijakan; batas absolut tidak pernah dilampaui.
  ## Aturan perpanjangan dipakai dari domain (`refreshedExpiry`) supaya hanya ada satu
  ## definisinya.
  let policy = sessionPolicy(settings.sessionIdleMinutes, settings.sessionAbsoluteMinutes)
  let now = clock.now()
  let state = SessionState(absoluteExpiresAt: parseIsoZ(session.absoluteExpiresAt))
  touchSession(db, session.sessionId, utcIso(now), utcIso(refreshedExpiry(state, policy, now)))

proc logout*(db: DbConn, clock: Clock, session: SessionRow, reason = "logout"): bool =
  revokeSession(db, session.sessionId, utcIso(clock.now()), reason)

proc logoutAll*(db: DbConn, clock: Clock, userId: string, reason: string): int =
  revokeSessionsOfUser(db, userId, utcIso(clock.now()), reason)

proc authorizeUser*(db: DbConn, userId, targetBranch, permission: string): AuthzDecision =
  ## Keputusan otorisasi untuk pengguna: izin efektif dari role + branch scoping + SoD.
  authorize(grantsOf(db, userId), targetBranch, permission, conflictPairs(db))

proc changePassword*(db: DbConn, user: UserRow, settings: SecuritySettings,
                     oldPassword, newPassword: string): bool =
  ## Ganti password sendiri: password lama harus benar, password baru harus lolos kebijakan
  ## (kecuali panjang minimum — dinilai **sebelum** hash supaya tidak ada hash sia-sia).
  if not verifyPassword(oldPassword, user.passwordHash):
    return false
  let problems = passwordProblems(settings.minPasswordLength, user.username, newPassword)
  if problems.len > 0:
    raise newException(ValueError, "password baru tidak memenuhi kebijakan: " & $problems)
  discard setPassword(db, user.userId, $hashPassword(newPassword, settings.pbkdf2Iterations))
  true
