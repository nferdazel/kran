## Alur autentikasi, sesi, dan pemeriksaan izin (T-006, spec §13, §18.2).
##
## **Catatan arsitektur**: alur ini memanggil repo langsung, jadi tinggal di `infrastructure`.
## Saat port/use case lapisan application lahir (pola T-016), isi berkas ini pindah ke
## `application/` dengan port `AuthSource`/`ParamSource`, dan berkas ini tinggal adaptornya.
##
## Semua angka kebijakan (panjang password, iterasi KDF, lockout, umur sesi) datang dari
## parameter DB — tidak ada default di kode (spec §10.6).

import std/[algorithm, json, options, strutils, times]

import db_connector/db_postgres

import ../domain/[audit, authz, scope]
import ./[audit_repo, auth_repo, calendar_repo, param_repo, password_hasher]
import kernel/[auditcontext, clock, ids, paramkey, result]
import kernel/generated/paramkeys

type
  SecuritySettings* = object
    minPasswordLength*: int
    minPasswordClasses*: int
    passwordHistoryCount*: int
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
    minPasswordClasses: db.activeParamInt(
      keyString(P_platform_security_password_min_classes), asOf, lookup),
    passwordHistoryCount: db.activeParamInt(
      keyString(P_platform_security_password_history_count), asOf, lookup),
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

proc businessDateFor*(db: DbConn, scope: ScopeRef, nowIso: string): string =
  ## Tanggal buku institusi bila sudah ada; kalau belum, tanggal UTC hari ini.
  ##
  ## Diekspor supaya penulisan audit di jalur lain (mis. MFA, T-046) memakai definisi yang sama —
  ## bukan salinan yang bisa menyimpang.
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

var
  ## Hash tiruan untuk akun tak dikenal, di-cache per thread. `threadvar` dipilih supaya tidak ada
  ## keadaan bersama yang perlu dikunci; kalau dua thread menghitung sendiri-sendiri, biayanya sama.
  dummyHashCache {.threadvar.}: string
  dummyHashIterations {.threadvar.}: int

proc dummyPasswordHash(iterations: int): string =
  ## Hash "kata sandi yang tidak akan pernah cocok" untuk akun tak dikenal (O-034): tanpa ini,
  ## login ke akun yang tidak ada selesai tanpa KDF sama sekali, dan selisih waktunya sendiri sudah
  ## cukup untuk menebak akun mana yang ada.
  ##
  ## Biayanya mengikuti parameter institusi saat ini — sama dengan yang dipakai hash akun baru.
  ## Catatan jujur: kalau hash akun lama dibuat dengan jumlah iterasi berbeda (mis. parameter
  ## dinaikkan setelah akun itu dibuat), biaya jalur tiruan tidak lagi setara dengan akun itu;
  ## yang dijaga adalah kesetaraan dengan "akun yang wajar", bukan dengan setiap akun.
  if dummyHashCache.len == 0 or dummyHashIterations != iterations:
    dummyHashIterations = iterations
    dummyHashCache = $hashPassword("biaya-setara-untuk-akun-tak-dikenal", iterations)
  dummyHashCache

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
  ##
  ## **Urutannya penting** (O-034): kata sandi diverifikasi lebih dulu, baru keadaan akun
  ## (`locked`/`inactive`) diberitahukan. Akun tak dikenal menjalankan PBKDF2 tiruan berbiaya
  ## setara, jadi waktu responsnya pun tidak membedakan.
  let now = clock.now()
  let nowIso = utcIso(now)
  let found = userByUsername(db, username)
  if found.isNone:
    # Akun tak dikenal tetap mengerjakan PBKDF2 (hash tiruan berbiaya setara) sebelum menjawab,
    # supaya waktu respons tidak membedakan "akun ada" dari "tidak ada" (O-034).
    discard verifyPassword(password, dummyPasswordHash(settings.pbkdf2Iterations))
    auditAuth(db, ctx, clock, scope, "auth.login.failure", "",
      %*{"reason": "unknown_user", "username_digest": usernameDigest(username)})
    return AuthResult(outcome: aoInvalidCredentials)

  var user = found.get()
  if not verifyPassword(password, user.passwordHash):
    user = recordLoginFailure(db, user.userId, settings.maxFailedLogins,
      settings.lockoutMinutes, nowIso)
    auditAuth(db, ctx, clock, scope, "auth.login.failure", user.userId,
      %*{"reason": "bad_password", "failed_attempts": user.failedAttempts,
         "status": user.status})
    # Selalu kredensial invalid — **termasuk** pada percobaan yang barusan mengunci akun. Menjawab
    # "terkunci" di sini akan memberi tahu penyerang bahwa akunnya ada (O-034).
    return AuthResult(outcome: aoInvalidCredentials, userId: user.userId)

  # Kata sandi benar: baru sekarang keadaan akun boleh diberitahukan kepada pengguna.
  if user.status == "LOCKED" and (user.lockedUntil.len == 0 or user.lockedUntil > nowIso):
    auditAuth(db, ctx, clock, scope, "auth.login.failure", user.userId,
      %*{"reason": "locked", "locked_until": user.lockedUntil})
    return AuthResult(outcome: aoLocked, userId: user.userId)

  if user.status in ["INACTIVE", "SUSPENDED"]:
    auditAuth(db, ctx, clock, scope, "auth.login.failure", user.userId,
      %*{"reason": "status", "status": user.status})
    return AuthResult(outcome: aoInactive, userId: user.userId)

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

proc authorizeUserAnyBranch*(db: DbConn, userId, permission: string): AuthzDecision =
  ## Otorisasi pengguna **tanpa dimensi cabang** (T-058): izin dipegang atau tidak. Dipakai
  ## permintaan yang hasilnya disaring per baris; lihat `authorizeAnyBranch` untuk alasannya.
  authorizeAnyBranch(grantsOf(db, userId), permission, conflictPairs(db))

proc changePassword*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                     user: UserRow, settings: SecuritySettings,
                     oldPassword, newPassword: string, keepSessionId = ""): bool =
  ## Ganti password sendiri: password lama harus benar, password baru harus lolos kebijakan
  ## (panjang, kelas karakter, dan riwayat — dinilai **sebelum** hash supaya tidak ada hash
  ## sia-sia; pemeriksaan riwayat sendiri butuh PBKDF2 dan hanya dijalankan bila bentuknya lolos).
  ##
  ## Kata sandi yang baru digantikan masuk riwayat (N terakhir, dari parameter) supaya tidak bisa
  ## dipakai ulang. Riwayat menyimpan hash, dan **kata sandi tidak pernah kedaluwarsa** (D-046
  ## butir 8): tidak ada umur yang membuatnya harus diganti.
  ##
  ## Efek sampingnya menyatu di sini supaya pemanggil cukup membungkus satu transaksi: hash diganti,
  ## `must_change_password` dibersihkan (`setPassword`), audit ditulis, dan **sesi lain dicabut**
  ## kecuali `keepSessionId`. Kalau kata sandi diganti karena diduga bocor, sesi lama tidak boleh
  ## tetap hidup; pemiliknya sendiri tidak perlu login ulang.
  if not verifyPassword(oldPassword, user.passwordHash):
    # O-050 (D-046 butir 8): percobaan kata sandi lama yang salah tidak boleh senyap. Penghitung dan
    # pengunciannya memakai mekanisme yang **sama** dengan login (`recordLoginFailure`) supaya tidak
    # ada kebijakan kedua yang harus dijaga selaras: angkanya dari parameter yang sudah ada
    # (`max_failed_logins`, `lockout_minutes`), dan login yang berhasil mengosongkannya lagi.
    # Jejaknya hanya alasan + keadaan penghitung — tidak pernah bahan kata sandi.
    let failed = recordLoginFailure(db, user.userId, settings.maxFailedLogins,
      settings.lockoutMinutes, utcIso(clock.now()))
    auditAuth(db, ctx, clock, scope, "user.password_change.failure", user.userId,
      %*{"reason": "old_password_mismatch", "failed_attempts": failed.failedAttempts,
         "status": failed.status})
    return false
  var problems = passwordProblems(settings.minPasswordLength, settings.minPasswordClasses,
    user.username, newPassword)
  if problems.len == 0:
    # Riwayat (O-052, D-046 butir 8): kata sandi baru tidak boleh sama dengan yang **sedang
    # berlaku** maupun N yang sudah digantikan. Diperiksa hanya setelah bentuknya lolos —
    # memverifikasi PBKDF2 terhadap hash lama tidak berguna kalau kata sandinya memang belum
    # memenuhi kebijakan, dan PBKDF2 itu mahal.
    #
    # Termasuk `user.passwordHash` di sini, tidak hanya riwayat: akun yang lahir sebelum kebijakan
    # ini (atau hasil bootstrap) belum punya baris riwayat, dan "ganti" ke kata sandi yang sama
    # harus tetap ditolak.
    if verifyPassword(newPassword, user.passwordHash):
      problems.add ppReused
    else:
      for superseded in supersededPasswordHashes(db, user.userId,
                                                 settings.passwordHistoryCount):
        if verifyPassword(newPassword, superseded):
          problems.add ppReused
          break
  if problems.len > 0:
    raise (ref PasswordPolicyError)(msg: "password baru tidak memenuhi kebijakan: " & $problems)
  discard setPassword(db, user.userId, $hashPassword(newPassword, settings.pbkdf2Iterations))
  discard recordSupersededPassword(db, user.userId, user.passwordHash,
    settings.passwordHistoryCount)
  let revoked = revokeSessionsExcept(db, user.userId, keepSessionId, utcIso(clock.now()),
    "password_change")
  auditAuth(db, ctx, clock, scope, "user.password_change", user.userId,
    %*{"username": user.username, "otherSessionsRevoked": revoked})
  true

const
  roleScopeInstitution* = "INSTITUTION" ## grant role tanpa cabang
  roleScopeBranch* = "BRANCH"           ## grant role harus menamai satu cabang

proc roleAssignmentProblem*(db: DbConn, roleCode, branchId: string): string =
  ## `""` bila pasangan role+cabang sah menurut scope role; pesan masalah bila tidak.
  ##
  ## Aturan (RBAC hardening): role `BRANCH` wajib diberi **tepat satu** cabang berbentuk UUID,
  ## role `INSTITUTION` wajib **tanpa** cabang. Sebelum ini kombinasi yang salah diterima begitu
  ## saja: role bercabang tanpa cabang mendapat grant global (melihat semua cabang), dan role
  ## institusi dengan cabang menghasilkan akun mati karena rute institusi mengotorisasi pada
  ## `targetBranch = ""` dan grant berbatas cabang tidak menutupinya.
  ##
  ## UUID cabang diperiksa di sini supaya nilai salah bentuk ditolak dengan pesan jelas, bukan
  ## gagal di cast DB (meski `user_role.branch_id` bertipe text, jejaknya harus konsisten bentuk).
  ##
  ## `roleCode` diasumsikan sudah lolos `roleExists`; bila tidak (scope `none`), pesannya "role
  ## tidak ada" supaya pemanggil baru pun tetap ditolak, bukan dilewatkan.
  if branchId.len > 0 and parseId(branchId).isErr():
    return "branch bukan UUID yang sah: " & branchId
  let scope = roleScope(db, roleCode)
  if scope.isNone:
    return "role tidak ada: " & roleCode
  case scope.get()
  of roleScopeBranch:
    if branchId.len == 0:
      return "role '" & roleCode & "' bercabang: --branch=<uuid> wajib diisi"
  of roleScopeInstitution:
    if branchId.len > 0:
      return "role '" & roleCode & "' tingkat institusi: --branch harus kosong"
  else:
    return "scope role tidak dikenal: " & scope.get()
  ""

proc createUserWithRole*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                         username, fullName, roleCode, branchId, password: string,
                         iterations: int): bool =
  ## Provision an operational user with exactly one role (pilot/e2e operator accounts).
  ##
  ## Unlike `bootstrapFirstAdmin` this is not a one-shot procedure: it is meant for creating
  ## teller/checker accounts after the first admin exists. The password is generated by the CLI
  ## and only its hash is stored. `must_change_password` is set so the printed password can be
  ## used exactly once.
  ##
  ## Returns `false` when the username is already taken, the role does not exist, or the
  ## role/branch combination violates the role scope (`roleAssignmentProblem`). All of those are
  ## checked **before** any row is written, so a `false` return leaves nothing behind.
  ##
  ## A role-grant failure **after** `insertUser` raises instead of returning `false`: the caller
  ## wraps this in `withRoleDb(..., useTx = true)`, and `withTx` COMMITs whatever the body wrote
  ## whenever it returns normally (`shared/platform-lib/db/pool.nim`) — so returning `false` there
  ## would commit a half-provisioned account. Raising rolls the user row back.
  ##
  ## The advisory lock closes the check-then-act gap between two concurrent provisioning runs.
  discard db.getValue(sql"SELECT pg_advisory_xact_lock(hashtext('kran:create_user'))")
  if userByUsername(db, username).isSome or not roleExists(db, roleCode):
    return false
  if roleAssignmentProblem(db, roleCode, branchId).len > 0:
    return false
  let userId = $newId(clock)
  if not insertUser(db, NewUser(userId: userId, username: username, fullName: fullName,
    passwordHash: $hashPassword(password, iterations), mustChangePassword: true)):
    return false
  if not grantRole(db, userId, roleCode, branchId, ""):
    raise newException(ValueError,
      "penugasan role '" & roleCode & "' gagal setelah pengguna '" & username & "' dibuat")
  auditAuth(db, ctx, clock, scope, "user.create", userId,
    %*{"username": username, "role": roleCode, "branchId": branchId,
       "mustChangePassword": true})
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
  discard db.getValue(sql"SELECT pg_advisory_xact_lock(hashtext('kran:bootstrap_first_admin'))")
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

# --- administrasi pengguna (T-117) ------------------------------------------------------------
# Aturan siklus hidup akun (kuat-sandi, status, dan penjagaan admin terakhir) **satu definisi** di
# sini, dipakai dua jalur: perintah `ctl` di `apps/api` dan rute HTTP `/api/v1/users*`. Pemanggil
# menyelesaikan pengguna lebih dulu (nama untuk CLI, id untuk HTTP) lalu memetakan hasilnya ke kode
# keluar atau status HTTP — bukan menyalin aturannya.

const
  platformAdminRole* = "platform_admin"
  userManagePermission* = "platform.user.manage"

type
  UserAdminOutcome* = enum
    uaoOk
    uaoRoleNotFound ## kode role tidak ada di katalog (salah ketik), bukan konflik.
    uaoRejected     ## ditolak aturan: scope role, SoD, pengelola terakhir, atau status salah.
    uaoWriteFailed  ## perubahan status gagal ditulis (mis. baris hilang di tengah transaksi).

  UserAdminResult* = object
    outcome*: UserAdminOutcome
    reason*: string ## kode stabil untuk pemetaan HTTP (`already_granted`, `sod_conflict`, …).
    detail*: string ## pesan untuk operator (dipakai CLI; boleh dibawa HTTP sebagai `detail`).

proc locksOutLastAdmin*(db: DbConn, user: UserRow, roleBeingRevoked = ""): bool =
  ## True bila operasi menyisakan **nol** pengguna ACTIVE yang bisa mengelola pengguna, yaitu nol
  ## pemegang izin `platform.user.manage` (bukan kode role tertentu): `platform_admin` dan
  ## `ops_admin` sama-sama memegang izin itu, jadi keduanya terlindungi (T-118, K-7). Tanpa ini
  ## instalasi bisa kehilangan satu-satunya akun yang bisa mengelola RBAC — satu pintu keluar tanpa
  ## akses shell.
  ##
  ## `roleBeingRevoked` kosong (operasi status/`disable`) = seluruh peran dihitung. Terisi
  ## (`revoke-role`) = hanya berpengaruh bila role itu memberi izin **dan** bukan satu-satunya jalur
  ## `user` ke izin itu (peran pengelola lain tetap membuatnya mampu mengelola).
  ##
  ## Satu definisi, dipakai kedua jalur (`ctl` dan rute HTTP).
  if user.status != "ACTIVE":
    return false
  if roleBeingRevoked.len > 0:
    if not roleGrantsPermission(db, roleBeingRevoked, userManagePermission):
      return false
    if userHasPermissionExcludingRole(db, user.userId, roleBeingRevoked, userManagePermission):
      return false
  elif not userHasPermission(db, user.userId, userManagePermission):
    return false
  countActiveUsersWithPermission(db, userManagePermission) <= 1

proc grantUserRole*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                    user: UserRow, roleCode, branchId: string): UserAdminResult =
  ## Menugaskan role ke pengguna yang sudah ada. Menolak role tak dikenal, pasangan role/cabang
  ## yang melanggar scope (`roleAssignmentProblem`), role yang sudah dipegang, dan pasangan SoD
  ## (`grantRole` melempar). Audit `user.role_grant` ditulis dalam transaksi yang sama.
  if not roleExists(db, roleCode):
    return UserAdminResult(outcome: uaoRoleNotFound, reason: "role_not_found",
      detail: "role tidak dikenal: " & roleCode)
  let problem = roleAssignmentProblem(db, roleCode, branchId)
  if problem.len > 0:
    return UserAdminResult(outcome: uaoRejected, reason: "role_scope", detail: problem)
  try:
    if not grantRole(db, user.userId, roleCode, branchId, ""):
      return UserAdminResult(outcome: uaoRejected, reason: "already_granted",
        detail: "pengguna sudah memegang role '" & roleCode & "' pada cabang itu")
  except ValueError as e:
    return UserAdminResult(outcome: uaoRejected, reason: "sod_conflict", detail: e.msg)
  let now = clock.now()
  discard appendAudit(db, newAuditEntry(ctx, "user.role_grant", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, scope, utcIso(now)),
    after = %*{"username": user.username, "role": roleCode, "branch": branchId}))
  UserAdminResult(outcome: uaoOk)

proc revokeUserRole*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                     user: UserRow, roleCode, branchId: string): UserAdminResult =
  ## Mencabut **persis** grant yang cocok: cabang kosong = grant institusi, cabang terisi = grant
  ## cabang itu. Role terakhir yang membuat pengguna mampu mengelola pengguna tidak boleh dicabut.
  ## Audit `user.role_revoke`.
  if not roleExists(db, roleCode):
    return UserAdminResult(outcome: uaoRoleNotFound, reason: "role_not_found",
      detail: "role tidak dikenal: " & roleCode)
  let problem = roleAssignmentProblem(db, roleCode, branchId)
  if problem.len > 0:
    return UserAdminResult(outcome: uaoRejected, reason: "role_scope", detail: problem)
  if locksOutLastAdmin(db, user, roleBeingRevoked = roleCode):
    return UserAdminResult(outcome: uaoRejected, reason: "last_admin",
      detail: "menolak mencabut role '" & roleCode &
        "': akan tidak ada pengguna aktif yang bisa mengelola pengguna")
  if not revokeRole(db, user.userId, roleCode, branchId):
    return UserAdminResult(outcome: uaoRejected, reason: "not_granted",
      detail: "pengguna tidak memegang role '" & roleCode & "' pada cabang itu")
  let now = clock.now()
  discard appendAudit(db, newAuditEntry(ctx, "user.role_revoke", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, scope, utcIso(now)),
    after = %*{"username": user.username, "role": roleCode, "branch": branchId}))
  UserAdminResult(outcome: uaoOk)

proc disableUserAccount*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                         user: UserRow): UserAdminResult =
  ## Menonaktifkan akun dan mencabut seluruh sesinya; pengelola pengguna terakhir dijaga. Audit
  ## `user.disable`.
  if locksOutLastAdmin(db, user):
    return UserAdminResult(outcome: uaoRejected, reason: "last_admin",
      detail: "menolak menonaktifkan akun: akan tidak ada pengguna aktif yang bisa mengelola pengguna")
  let now = clock.now()
  let nowIso = utcIso(now)
  if not setUserStatus(db, user.userId, "INACTIVE"):
    return UserAdminResult(outcome: uaoWriteFailed, detail: "gagal menonaktifkan akun")
  let revoked = revokeSessionsOfUser(db, user.userId, nowIso, "akun dinonaktifkan operator")
  discard appendAudit(db, newAuditEntry(ctx, "user.disable", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, scope, nowIso),
    after = %*{"username": user.username, "sessions_revoked": revoked}))
  UserAdminResult(outcome: uaoOk)

proc enableUserAccount*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                        user: UserRow): UserAdminResult =
  ## Mengaktifkan kembali akun yang **dinonaktifkan**: hanya `INACTIVE` → `ACTIVE` (CAS). Audit
  ## `user.enable`.
  if not enableInactiveUser(db, user.userId):
    return UserAdminResult(outcome: uaoRejected, reason: "not_inactive",
      detail: "akun tidak dalam status INACTIVE")
  let now = clock.now()
  discard appendAudit(db, newAuditEntry(ctx, "user.enable", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, scope, utcIso(now)),
    after = %*{"username": user.username}))
  UserAdminResult(outcome: uaoOk)

proc unlockUserAccount*(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
                        user: UserRow): UserAdminResult =
  ## Membuka akun terkunci: hanya `LOCKED` → `ACTIVE` (CAS), penghitung gagal dikosongkan. Audit
  ## `user.unlock`.
  if not unlockUser(db, user.userId):
    return UserAdminResult(outcome: uaoRejected, reason: "not_locked",
      detail: "akun tidak dalam status LOCKED")
  let now = clock.now()
  discard appendAudit(db, newAuditEntry(ctx, "user.unlock", "app_user", user.userId, clock,
    businessDate = businessDateFor(db, scope, utcIso(now)),
    after = %*{"username": user.username}))
  UserAdminResult(outcome: uaoOk)
