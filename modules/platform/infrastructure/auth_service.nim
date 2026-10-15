## Alur autentikasi, sesi, dan pemeriksaan izin (T-006, spec §13, §18.2).
##
## **Catatan arsitektur**: alur ini memanggil repo langsung, jadi tinggal di `infrastructure`.
## Saat port/use case lapisan application lahir (pola T-016), isi berkas ini pindah ke
## `application/` dengan port `AuthSource`/`ParamSource`, dan berkas ini tinggal adaptornya.
##
## Semua angka kebijakan (panjang password, iterasi KDF, lockout, umur sesi) datang dari
## parameter DB — tidak ada default di kode (spec §10.6).

import std/[algorithm, json, options, times]

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

  PasswordPolicyError* = object of ValueError
    ## Kata sandi **baru** melanggar kebijakan, bukan kesalahan konfigurasi. Dipisahkan dari
    ## `ValueError` biasa supaya pemanggil HTTP bisa menjawab 400 (salah pengguna) alih-alih 500
    ## (konfigurasi institusi rusak), dan supaya exception-nya boleh menembus transaksi sehingga
    ## tulisan apa pun yang sudah terjadi dibatalkan — bukan ditangkap dan di-commit separuh.

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

proc sessionPolicyCandidateProblem*(db: DbConn, key: string, candidate: JsonNode,
                                    effectiveFrom, effectiveTo, asOf: string): string =
  ## `""` bila perubahan aman; pesan pelanggaran bila kombinasi kebijakan sesi yang **akan**
  ## berlaku melanggar aturan domain `sessionPolicy` (idle ≤ absolut, spec §18.2).
  ##
  ## Kenapa pemeriksaan ini ada: `session_idle_minutes` dan `session_absolute_minutes` masing-masing
  ## sah menurut schema-nya sendiri (idle ≤ 1440, absolut ≥ 5), tetapi kombinasinya bisa tidak sah
  ## (mis. idle 600 + absolut 480). Bila kombinasi seperti itu sampai ACTIVE, **seluruh login gagal**
  ## (`sessionPolicy` menolak) dan pemulihannya butuh akses DB langsung — persis situasi yang harus
  ## dicegah alur maker-checker. Dipanggil saat pengajuan **dan** saat persetujuan.
  ##
  ## Nilainya dinilai pada beberapa tanggal, bukan hanya hari ini:
  ##   - hari ini,
  ##   - tanggal efektif calon (perubahan ber-tanggal depan),
  ##   - tanggal mulai efektif sisi lainnya yang sudah disetujui (perubahan ber-tanggal depan di
  ##     sisi lain bisa membuat kombinasi tidak sah **setelah** perubahan kita disetujui).
  ##
  ## Pada tanggal yang tercakup periode calon, nilai sisi calon **sudah pasti** (tidak perlu dibaca
  ## dari DB) — kalau sisi itu yang gagal dibaca, seluruh tanggal depan akan terlewat dan jendela
  ## yang justru dicegah tetap terbuka. Yang boleh "tidak dapat dinilai" hanya sisi lainnya, dan itu
  ## memang keadaan belum lengkap yang harus tetap bisa **diperbaiki** lewat alur normal.
  ##
  ## Konteks scope penilaian = konteks tempat aplikasi membaca kebijakan sesi (`institutionScope()`,
  ## spec §13/§18.2), supaya vonisnya sama dengan perilaku login yang sesungguhnya.
  ##
  ## Hanya pasangan parameter ini yang diperiksa: aturan lintas-parameter lain belum ada di spec.
  if candidate.kind != JInt:
    return "" # tipe/schema ditangani `submitValue`; di sini bukan urusan bentuk nilai
  let idleKey = keyString(P_platform_security_session_idle_minutes)
  let absoluteKey = keyString(P_platform_security_session_absolute_minutes)
  if key != idleKey and key != absoluteKey:
    return ""
  # Serialisasi "periksa lalu aktifkan" untuk kedua key ini: tanpa ini, dua persetujuan yang
  # berjalan bersamaan (satu di tiap key) sama-sama membaca keadaan sebelum commit dan sama-sama
  # lolos. Kunci dilepas otomatis di akhir transaksi pemanggil.
  # `getAllRows` (bukan `exec`): driver ini menolak SELECT lewat `exec` — dan hasil kuncinya
  # memang tidak dipakai, hanya efek samping penguncian.
  discard db.getAllRows(sql"SELECT pg_advisory_xact_lock(hashtext('platform.security.session_policy'))")

  let lookup = lookupFor(institutionScope())
  let today = if asOf.len >= 10: asOf[0 .. 9] else: asOf
  let otherKey = if key == idleKey: absoluteKey else: idleKey

  var dates = @[today]
  if effectiveFrom >= today:
    dates.add effectiveFrom
  for date in db.committedFromDates(otherKey, today):
    dates.add date
  dates.sort()
  var unique: seq[string]
  for date in dates:
    if unique.len == 0 or unique[^1] != date:
      unique.add date

  for date in unique:
    # Periode calon = [effectiveFrom, effectiveTo). Di luar itu nilainya dibaca dari DB seperti biasa.
    let candidateApplies = date >= effectiveFrom and (effectiveTo.len == 0 or date < effectiveTo)
    var idle = 0
    var absolute = 0
    if candidateApplies and key == idleKey:
      idle = int(candidate.getInt)
    else:
      try:
        idle = db.activeParamInt(idleKey, date, lookup)
      except ValueError:
        continue
    if candidateApplies and key == absoluteKey:
      absolute = int(candidate.getInt)
    else:
      try:
        absolute = db.activeParamInt(absoluteKey, date, lookup)
      except ValueError:
        continue
    try:
      discard sessionPolicy(idle, absolute)
    except ValueError as e:
      return "pada " & date & ": " & e.msg
  ""

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

proc changePassword*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                     user: UserRow, settings: SecuritySettings,
                     oldPassword, newPassword: string, keepSessionId = ""): bool =
  ## Ganti password sendiri: password lama harus benar, password baru harus lolos kebijakan
  ## (dinilai **sebelum** hash supaya tidak ada hash sia-sia).
  ##
  ## Efek sampingnya menyatu di sini supaya pemanggil cukup membungkus satu transaksi: hash diganti,
  ## `must_change_password` dibersihkan (`setPassword`), audit ditulis, dan **sesi lain dicabut**
  ## kecuali `keepSessionId`. Kalau kata sandi diganti karena diduga bocor, sesi lama tidak boleh
  ## tetap hidup; pemiliknya sendiri tidak perlu login ulang.
  if not verifyPassword(oldPassword, user.passwordHash):
    return false
  let problems = passwordProblems(settings.minPasswordLength, user.username, newPassword)
  if problems.len > 0:
    raise (ref PasswordPolicyError)(msg: "password baru tidak memenuhi kebijakan: " & $problems)
  discard setPassword(db, user.userId, $hashPassword(newPassword, settings.pbkdf2Iterations))
  let revoked = revokeSessionsExcept(db, user.userId, keepSessionId, utcIso(clock.now()),
    "password_change")
  auditAuth(db, ctx, clock, scope, "user.password_change", user.userId,
    %*{"username": user.username, "otherSessionsRevoked": revoked})
  true

proc bootstrapFirstAdmin*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                          username, fullName, roleCode, password: string,
                          iterations: int): bool =
  ## Admin pertama (prosedur bootstrap produksi; keputusan D-034, task T-027). Membuat user dengan
  ## `must_change_password = true`, memberi role, dan menulis audit `user.bootstrap`.
  ##
  ## Mengembalikan `false` bila username sudah ada **atau** sudah ada pengguna yang memegang
  ## `roleCode`. Penjagaan kedua itu yang membuat perintah ini benar-benar sekali-jalan: tanpa itu,
  ## bootstrap bisa diam-diam jadi jalur membuat admin berikutnya.
  ##
  ## Kata sandinya diacak pemanggil (CLI) dan tidak pernah dicatat di sini; yang tersimpan hanya
  ## hash-nya.
  ##
  ## **Pemanggil wajib membungkus ini dalam satu transaksi** (pengguna + role + audit harus lahir
  ## bersama; lihat `withRoleDb(..., useTx = true)`). Di dalam transaksi itu, kunci mutex di bawah
  ## menutup celah check-then-act: dua `bootstrap-admin` yang berjalan bersamaan tidak bisa
  ## sama-sama lolos pemeriksaan lalu membuat dua admin.
  discard db.getValue(sql"SELECT pg_advisory_xact_lock(hashtext('cbs:bootstrap_first_admin'))")
  if userByUsername(db, username).isSome or countUsersWithRole(db, roleCode) > 0:
    return false
  let userId = $newId(clock)
  if not insertUser(db, NewUser(userId: userId, username: username, fullName: fullName,
    passwordHash: $hashPassword(password, iterations), mustChangePassword: true)):
    return false
  discard grantRole(db, userId, roleCode, "", "")
  auditAuth(db, ctx, clock, scope, "user.bootstrap", userId,
    %*{"username": username, "role": roleCode, "mustChangePassword": true})
  true
