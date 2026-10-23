## Repository identitas, akses, dan sesi (T-006, spec §9.2, §13, §18.2).
##
## Waktu selalu **eksplisit** (parameter `nowIso`, `expiresAtIso`, …) supaya bisa diuji
## deterministik; repo tidak memakai `now()` sendiri kecuali untuk kolom `created_at/updated_at`.

import std/[options, sets, strutils]

import db_connector/db_postgres

import ../domain/authz
import ./param_repo

type
  UserRow* = object
    userId*: string
    username*: string
    fullName*: string
    status*: string
    passwordHash*: string
    mustChangePassword*: bool
    failedAttempts*: int
    lockedUntil*: string ## "" bila tidak terkunci

  NewUser* = object
    userId*: string
    username*: string
    fullName*: string
    passwordHash*: string
    mustChangePassword*: bool ## true untuk admin pertama hasil bootstrap (T-027)

  SessionRow* = object
    sessionId*: string
    userId*: string
    expiresAt*: string
    absoluteExpiresAt*: string
    revoked*: bool

  RoleGrant* = object
    ## Satu pemberian role ke pengguna: kode role + cabangnya ("" = tingkat institusi).
    roleCode*: string
    branchId*: string

  RoleCatalogue* = object
    ## Baris katalog role untuk layar administrasi (T-117).
    code*: string
    scope*: string
    isSystem*: bool

## Konvensi waktu: semua timestamp dibaca sebagai UTC dengan bentuk tetap `...Z`, sehingga
## perbandingan string = perbandingan waktu (dipakai service, bukan `now()` di SQL).
const userColumns = """
    user_id::text, username, full_name, status, password_hash, must_change_password,
    failed_attempts,
    coalesce(to_char(locked_until AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')"""

proc userFromRow(row: Row): UserRow =
  UserRow(userId: row[0], username: row[1], fullName: row[2], status: row[3],
    passwordHash: row[4], mustChangePassword: row[5] == "t",
    failedAttempts: parseInt(row[6]), lockedUntil: row[7])

proc insertUser*(db: DbConn, user: NewUser): bool =
  ## Mengembalikan `false` **hanya** bila `user_id` sudah ada (`ON CONFLICT (user_id)`).
  ##
  ## Keunikan `username` ditegakkan index unik dan **tidak** ditangkap di sini: bentrokan username
  ## menaikkan `DbError`, bukan `false`. Pemanggil provisioning memeriksa username lebih dulu
  ## (`userByUsername`) di dalam kunci advisori, jadi bentrokan itu tidak seharusnya terjadi; bila
  ## tetap terjadi, transaksi dibatalkan dan `withRoleDb` melaporkannya sebagai galat basis data.
  let algo = user.passwordHash.split('$')[0]
  db.execAffectedRows(sql"""
    INSERT INTO platform.app_user
      (user_id, username, full_name, password_algo, password_hash, must_change_password)
    VALUES (?::uuid, lower(?), ?, ?, ?, ?)
    ON CONFLICT (user_id) DO NOTHING""",
    user.userId, user.username, user.fullName, algo, user.passwordHash,
    user.mustChangePassword) == 1

proc userByUsername*(db: DbConn, username: string): Option[UserRow] =
  let found = db.singleRow(sql("SELECT " & userColumns &
    " FROM platform.app_user WHERE username = lower(?)"), username)
  if found.isNone:
    return none(UserRow)
  some(userFromRow(found.get()))

proc userById*(db: DbConn, userId: string): Option[UserRow] =
  let found = db.singleRow(sql("SELECT " & userColumns &
    " FROM platform.app_user WHERE user_id = ?::uuid"), userId)
  if found.isNone:
    return none(UserRow)
  some(userFromRow(found.get()))

proc listUsers*(db: DbConn, limit: int): seq[UserRow] =
  ## Akun operator untuk layar administrasi (T-117), urut username. Batas baris datang dari
  ## pemanggil (batas ukuran respons, bukan aturan bisnis); password hash tidak pernah ikut keluar
  ## dari sini — handler yang memilih field (spec §13).
  for row in db.getAllRows(sql("SELECT " & userColumns &
    " FROM platform.app_user ORDER BY lower(username), user_id LIMIT ?::int"), limit):
    result.add userFromRow(row)

proc recordLoginFailure*(db: DbConn, userId: string, maxFailedLogins, lockoutMinutes: int,
                         nowIso: string): UserRow =
  ## Menaikkan penghitung gagal; begitu mencapai `maxFailedLogins` akun dikunci
  ## `lockoutMinutes`. Semua angka dari parameter (spec §10.4).
  let failed = db.getValue(sql"""
    UPDATE platform.app_user
       SET failed_attempts = failed_attempts + 1,
           status = CASE WHEN failed_attempts + 1 >= ?::int THEN 'LOCKED' ELSE status END,
           locked_until = CASE WHEN failed_attempts + 1 >= ?::int
                               THEN ?::timestamptz + make_interval(mins => ?::int)
                          END,
           updated_at = now()
     WHERE user_id = ?::uuid
    RETURNING failed_attempts""", maxFailedLogins, maxFailedLogins, nowIso, lockoutMinutes,
    userId)
  result = userById(db, userId).get()
  result.failedAttempts = parseInt(failed)

proc recordLoginSuccess*(db: DbConn, userId: string): bool =
  ## Reset penghitung & buka kunci (kebijakan: login sukses setelah masa lockout lewat).
  ## Akun `SUSPENDED`/`INACTIVE` tidak ikut diaktifkan kembali.
  db.execAffectedRows(sql"""
    UPDATE platform.app_user
       SET failed_attempts = 0, locked_until = NULL,
           status = CASE WHEN status = 'LOCKED' THEN 'ACTIVE' ELSE status END,
           updated_at = now()
     WHERE user_id = ?::uuid""", userId) == 1

proc setPassword*(db: DbConn, userId, passwordHash: string,
                  mustChange = false): bool =
  let algo = passwordHash.split('$')[0]
  db.execAffectedRows(sql"""
    UPDATE platform.app_user
       SET password_hash = ?, password_algo = ?,
           password_updated_at = now(), must_change_password = ?,
           failed_attempts = 0, locked_until = NULL, updated_at = now()
     WHERE user_id = ?::uuid""", passwordHash, algo, mustChange, userId) == 1

proc setUserStatus*(db: DbConn, userId, status: string): bool =
  db.execAffectedRows(sql"""
    UPDATE platform.app_user SET status = ?, updated_at = now()
     WHERE user_id = ?::uuid""", status, userId) == 1

proc enableInactiveUser*(db: DbConn, userId: string): bool =
  ## Mengaktifkan kembali akun yang **dinonaktifkan**: hanya `INACTIVE` → `ACTIVE` (CAS).
  ## `LOCKED`/`SUSPENDED` sengaja tidak ikut — yang pertama punya jalur `unlockUser`, yang kedua
  ## butuh keputusan berbeda (kebijakan konservatif). `true` = baris berubah.
  db.execAffectedRows(sql"""
    UPDATE platform.app_user SET status = 'ACTIVE', updated_at = now()
     WHERE user_id = ?::uuid AND status = 'INACTIVE'""", userId) == 1

proc unlockUser*(db: DbConn, userId: string): bool =
  ## Membuka akun yang terkunci: **hanya** `LOCKED` → `ACTIVE` (CAS), sekaligus mengosongkan
  ## penghitung gagal dan `locked_until`. Akun `INACTIVE`/`SUSPENDED` tidak ikut diaktifkan —
  ## percampuran keduanya pernah jadi sumber kesalahan (lihat `resetUserPassword` di ctl).
  db.execAffectedRows(sql"""
    UPDATE platform.app_user
       SET status = 'ACTIVE', failed_attempts = 0, locked_until = NULL, updated_at = now()
     WHERE user_id = ?::uuid AND status = 'LOCKED'""", userId) == 1

# --- riwayat kata sandi (O-052) -------------------------------------------------------
# **HUMAN-REVIEW-REQUIRED**: hanya hash yang disimpan (tidak pernah kata sandi mentah), tetapi ini
# tetap area kredensial — D-058, invarian MODULE.md #21.

proc supersededPasswordHashes*(db: DbConn, userId: string, count: int): seq[string] =
  ## Hash kata sandi yang **sudah digantikan**, terbaru dulu, maksimum `count`.
  ## `count <= 0` berarti riwayat dimatikan: tidak ada hash yang dibaca (dan bukan berarti
  ## "semua hash").
  if count <= 0:
    return @[]
  for row in db.getAllRows(sql"""
    SELECT password_hash FROM platform.user_password_history
     WHERE user_id = ?::uuid ORDER BY seq DESC LIMIT ?::int""", userId, count):
    result.add row[0]

proc recordSupersededPassword*(db: DbConn, userId, passwordHash: string,
                               keep: int): int =
  ## Mencatat hash yang baru digantikan lalu memangkas riwayat ke `keep` baris terbaru
  ## (`keep = 0` mengosongkannya). Mengembalikan jumlah baris yang dipangkas.
  ##
  ## Pemangkasan ikut di sini, bukan tugas terjadwal terpisah: dengan begitu jumlah baris per
  ## pengguna selalu = nilai parameter yang berlaku saat perubahan terakhir, dan tidak ada
  ## tabel yang tumbuh tanpa batas.
  discard db.execAffectedRows(sql"""
    INSERT INTO platform.user_password_history (user_id, password_hash)
    VALUES (?::uuid, ?)""", userId, passwordHash)
  db.execAffectedRows(sql"""
    DELETE FROM platform.user_password_history
     WHERE user_id = ?::uuid AND seq NOT IN (
       SELECT seq FROM platform.user_password_history
        WHERE user_id = ?::uuid ORDER BY seq DESC LIMIT ?::int)""",
    userId, userId, keep)

# --- role & permission -------------------------------------------------------------

proc insertRole*(db: DbConn, roleId, code, nameKey: string, isSystem = false): bool =
  db.execAffectedRows(sql"""
    INSERT INTO platform.role (role_id, code, name_key, is_system)
    VALUES (?::uuid, lower(?), ?, ?)
    ON CONFLICT (code) DO NOTHING""", roleId, code, nameKey, isSystem) == 1

proc insertPermission*(db: DbConn, permissionId, code, descriptionKey: string): bool =
  ## `module.resource.action` dipecah otomatis; bentuk kode divalidasi di domain.
  if not validPermissionCode(code):
    raise newException(ValueError, "kode izin tidak sah: " & code)
  let parts = code.split('.')
  db.execAffectedRows(sql"""
    INSERT INTO platform.permission (permission_id, code, module, resource, action,
                                     description_key)
    VALUES (?::uuid, ?, ?, ?, ?, ?)
    ON CONFLICT (code) DO NOTHING""",
    permissionId, code, parts[0], parts[1], parts[2], descriptionKey) == 1

proc grantPermissionToRole*(db: DbConn, roleCode, permissionCode: string): bool =
  db.execAffectedRows(sql"""
    INSERT INTO platform.role_permission (role_id, permission_id)
    SELECT r.role_id, p.permission_id FROM platform.role r, platform.permission p
     WHERE r.code = lower(?) AND p.code = ?
    ON CONFLICT DO NOTHING""", roleCode, permissionCode) == 1

proc rolePermissions*(db: DbConn, roleCode: string): seq[string] =
  for row in db.getAllRows(sql"""
    SELECT p.code FROM platform.role_permission rp
      JOIN platform.role r ON r.role_id = rp.role_id
      JOIN platform.permission p ON p.permission_id = rp.permission_id
     WHERE r.code = lower(?) ORDER BY p.code""", roleCode):
    result.add row[0]

proc setRoleConflict*(db: DbConn, roleCodeA, roleCodeB, reasonKey: string): bool =
  ## Menyimpan pasangan SoD dalam bentuk kanonik (a < b) — urutan argumen tidak penting.
  let (a, b) = if roleCodeA < roleCodeB: (roleCodeA, roleCodeB)
               else: (roleCodeB, roleCodeA)
  if a == b:
    raise newException(ValueError, "pasangan SoD harus dua role berbeda")
  db.execAffectedRows(sql"""
    INSERT INTO platform.role_conflict (role_code_a, role_code_b, reason_key)
    VALUES (lower(?), lower(?), ?)
    ON CONFLICT DO NOTHING""", a, b, reasonKey) == 1

proc conflictPairs*(db: DbConn): seq[RolePair] =
  for row in db.getAllRows(sql"""
    SELECT role_code_a, role_code_b FROM platform.role_conflict ORDER BY role_code_a, role_code_b"""):
    result.add (row[0], row[1])

proc grantsOf*(db: DbConn, userId: string): seq[Grant] =
  ## Semua izin efektif pengguna: role → permission, dengan cabang dari penugasan role.
  for row in db.getAllRows(sql"""
    SELECT r.code, coalesce(ur.branch_id, ''), p.code
      FROM platform.user_role ur
      JOIN platform.role r ON r.role_id = ur.role_id
      JOIN platform.role_permission rp ON rp.role_id = r.role_id
      JOIN platform.permission p ON p.permission_id = rp.permission_id
     WHERE ur.user_id = ?::uuid
     ORDER BY r.code, p.code""", userId):
    result.add Grant(roleCode: row[0], branchId: row[1], permission: row[2])

proc roleCodesOfUser*(db: DbConn, userId: string): seq[string] =
  for row in db.getAllRows(sql"""
    SELECT DISTINCT r.code FROM platform.user_role ur
      JOIN platform.role r ON r.role_id = ur.role_id
     WHERE ur.user_id = ?::uuid ORDER BY r.code""", userId):
    result.add row[0]

proc roleGrantsOfUser*(db: DbConn, userId: string): seq[RoleGrant] =
  ## Pemberian role pengguna sebagai pasangan role+cabang (bukan per izin): bentuk yang dipakai
  ## layar administrasi. Diurut agar keluaran deterministik.
  for row in db.getAllRows(sql"""
    SELECT r.code, coalesce(ur.branch_id, '')
      FROM platform.user_role ur
      JOIN platform.role r ON r.role_id = ur.role_id
     WHERE ur.user_id = ?::uuid
     ORDER BY r.code, coalesce(ur.branch_id, '')""", userId):
    result.add RoleGrant(roleCode: row[0], branchId: row[1])

proc conflictsOfUser*(db: DbConn, userId: string): seq[RolePair] =
  ## Pasangan SoD yang benar-benar dipegang pengguna ini.
  conflictingPairs(roleCodesOfUser(db, userId).toHashSet, conflictPairs(db))

proc roleExists*(db: DbConn, roleCode: string): bool =
  ## True bila role ada di katalog. Dipakai jalur provisioning pengguna supaya role yang salah
  ## ketik ditolak dengan pesan jelas, bukan pengguna tanpa izin.
  db.getAllRows(sql"SELECT 1 FROM platform.role WHERE code = lower(?)", roleCode).len > 0

proc roleScope*(db: DbConn, roleCode: string): Option[string] =
  ## Scope penugasan role (`platform.role.scope`): `some("INSTITUTION")` atau `some("BRANCH")`.
  ## `none` bila role tidak ada — pemanggil memutuskan pesannya (bukan menganggapnya institusi).
  let found = db.singleRow(sql"SELECT scope FROM platform.role WHERE code = lower(?)", roleCode)
  if found.isNone:
    none(string)
  else:
    some(found.get()[0])

proc listRoles*(db: DbConn): seq[RoleCatalogue] =
  ## Katalog role (kode, scope, sistem) untuk layar administrasi (T-117), urut kode. Izin per role
  ## **tidak** ikut: layar hanya butuh scope untuk memutuskan bentuk penugasan.
  for row in db.getAllRows(sql"""
    SELECT code, scope, is_system FROM platform.role ORDER BY code"""):
    result.add RoleCatalogue(code: row[0], scope: row[1], isSystem: row[2] == "t")

proc grantRole*(db: DbConn, userId, roleCode, branchId, grantedBy: string): bool =
  ## Menugaskan role ke pengguna. **Menolak** bila penugasan itu melahirkan pasangan SoD
  ## (spec §18.2) — penjagaan utama; `authorize` hanya pertahanan berlapis.
  let newRoles = roleCodesOfUser(db, userId) & @[roleCode]
  var willConflict: seq[RolePair]
  for (a, b) in conflictPairs(db):
    if a in newRoles and b in newRoles:
      willConflict.add (a, b)
  if willConflict.len > 0:
    raise newException(ValueError,
      "penugasan role ditolak: konflik pemisahan tugas " & $willConflict[0] &
      " (spec §18.2)")
  db.execAffectedRows(sql"""
    INSERT INTO platform.user_role (user_id, role_id, branch_id, granted_by)
    SELECT ?::uuid, r.role_id, NULLIF(?, ''), NULLIF(?, '')::uuid
      FROM platform.role r WHERE r.code = lower(?)
    ON CONFLICT DO NOTHING""", userId, branchId, grantedBy, roleCode) == 1

proc revokeRole*(db: DbConn, userId, roleCode, branchId: string): bool =
  db.execAffectedRows(sql"""
    DELETE FROM platform.user_role ur
     USING platform.role r
     WHERE ur.role_id = r.role_id AND ur.user_id = ?::uuid
       AND r.code = lower(?) AND coalesce(ur.branch_id, '') = ?""",
    userId, roleCode, branchId) == 1

# --- sesi --------------------------------------------------------------------------

proc createSession*(db: DbConn, sessionId, userId, tokenHash, expiresAtIso,
                    absoluteExpiresAtIso, ip, device, correlationId: string): bool =
  db.execAffectedRows(sql"""
    INSERT INTO platform.session
      (session_id, user_id, token_hash, expires_at, absolute_expires_at, ip, device,
       correlation_id)
    VALUES (?::uuid, ?::uuid, ?, ?::timestamptz, ?::timestamptz, NULLIF(?, ''), NULLIF(?, ''),
            NULLIF(?, ''))
    ON CONFLICT (session_id) DO NOTHING""",
    sessionId, userId, tokenHash, expiresAtIso, absoluteExpiresAtIso, ip, device,
    correlationId) == 1

proc sessionFromRow(row: Row): SessionRow =
  SessionRow(sessionId: row[0], userId: row[1], expiresAt: row[2],
    absoluteExpiresAt: row[3], revoked: row[4] == "t")

const sessionColumns = """
    session_id::text, user_id::text,
    to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    to_char(absolute_expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    (revoked_at IS NOT NULL)"""

proc activeSessionByTokenHash*(db: DbConn, tokenHash, nowIso: string): Option[SessionRow] =
  ## Sesi aktif pada `nowIso`: belum dicabut, belum lewat batas idle, belum lewat batas absolut.
  let found = db.singleRow(sql("SELECT " & sessionColumns &
      """
    FROM platform.session
    WHERE token_hash = ? AND revoked_at IS NULL
      AND ?::timestamptz < expires_at AND ?::timestamptz < absolute_expires_at"""),
    tokenHash, nowIso, nowIso)
  if found.isNone:
    return none(SessionRow)
  some(sessionFromRow(found.get()))

proc sessionAnyState*(db: DbConn, tokenHash: string): Option[SessionRow] =
  ## Termasuk yang sudah dicabut/kedaluwarsa — untuk test & investigasi.
  let found = db.singleRow(sql("SELECT " & sessionColumns &
    " FROM platform.session WHERE token_hash = ?"), tokenHash)
  if found.isNone:
    return none(SessionRow)
  some(sessionFromRow(found.get()))

proc touchSession*(db: DbConn, sessionId, nowIso, expiresAtIso: string): bool =
  ## Memperpanjang batas idle. Batas absolut tidak pernah ikut naik (dijaga `refreshedExpiry`).
  db.execAffectedRows(sql"""
    UPDATE platform.session
       SET last_seen_at = ?::timestamptz,
           expires_at = LEAST(?::timestamptz, absolute_expires_at)
     WHERE session_id = ?::uuid AND revoked_at IS NULL""",
    nowIso, expiresAtIso, sessionId) == 1

proc revokeSession*(db: DbConn, sessionId, nowIso, reason: string): bool =
  db.execAffectedRows(sql"""
    UPDATE platform.session SET revoked_at = ?::timestamptz, revoked_reason = ?
     WHERE session_id = ?::uuid AND revoked_at IS NULL""",
    nowIso, reason, sessionId) == 1

proc revokeSessionsOfUser*(db: DbConn, userId, nowIso, reason: string): int =
  db.execAffectedRows(sql"""
    UPDATE platform.session SET revoked_at = ?::timestamptz, revoked_reason = ?
     WHERE user_id = ?::uuid AND revoked_at IS NULL""", nowIso, reason, userId)

proc revokeSessionsExcept*(db: DbConn, userId, keepSessionId, nowIso, reason: string): int =
  ## Mencabut semua sesi aktif pengguna **kecuali** satu (sesi yang sedang dipakai). Dipakai saat
  ## pengguna mengganti kata sandinya sendiri: sesi yang dipakai tetap hidup, sesi lain diputus.
  ## `keepSessionId` kosong = cabut semuanya (sama seperti `revokeSessionsOfUser`).
  db.execAffectedRows(sql"""
    UPDATE platform.session SET revoked_at = ?::timestamptz, revoked_reason = ?
     WHERE user_id = ?::uuid AND revoked_at IS NULL
       AND (? = '' OR session_id::text <> ?)""",
    nowIso, reason, userId, keepSessionId, keepSessionId)

proc countUsersWithRole*(db: DbConn, roleCode: string): int =
  ## Berapa pengguna (status apa pun) yang memegang `roleCode`. Dipakai bootstrap admin pertama
  ## untuk memastikan perintahnya benar-benar sekali-jalan (T-027).
  parseInt(db.getValue(sql"""
    SELECT count(DISTINCT ur.user_id)
      FROM platform.user_role ur JOIN platform.role r ON r.role_id = ur.role_id
     WHERE r.code = lower(?)""", roleCode))

proc activeSessionCount*(db: DbConn, userId, nowIso: string): int =
  parseInt(db.getValue(sql"""
    SELECT count(*) FROM platform.session
     WHERE user_id = ?::uuid AND revoked_at IS NULL
       AND ?::timestamptz < expires_at AND ?::timestamptz < absolute_expires_at""",
    userId, nowIso, nowIso))

proc purgeExpiredSessions*(db: DbConn, nowIso: string): int =
  ## Menghapus sesi yang sudah tidak mungkin aktif (idle & absolut lewat, atau dicabut).
  db.execAffectedRows(sql"""
    DELETE FROM platform.session
     WHERE revoked_at IS NOT NULL
        OR ?::timestamptz >= absolute_expires_at
        OR ?::timestamptz >= expires_at""", nowIso, nowIso)
