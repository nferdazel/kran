## Otorisasi (RBAC + branch scoping + SoD) dan kebijakan sesi/password (spec §13, §18.2) — murni.
##
## Semua **angka kebijakan** (menit idle/absolut, panjang minimum password) datang dari parameter
## DB; yang tinggal di sini hanya aturan keputusan dan invarian matematis/teknis.

import std/[sets, strutils, times]

type
  Grant* = object
    ## Satu izin efektif: peran apa, berlaku di cabang mana, izin apa.
    roleCode*: string
    branchId*: string ## "" = semua cabang (termasuk aksi level institusi)
    permission*: string

  AuthzReason* = enum
    arAllowed = "ALLOWED"
    arNoPermission = "NO_PERMISSION"
    arBranchNotAllowed = "BRANCH_NOT_ALLOWED"
    arRoleConflict = "ROLE_CONFLICT"

  AuthzDecision* = object
    allowed*: bool
    reason*: AuthzReason

  RolePair* = tuple[a, b: string]

  SessionPolicy* = object
    idleMinutes*: int
    absoluteMinutes*: int

  SessionState* = object
    createdAt*: DateTime
    lastSeenAt*: DateTime
    expiresAt*: DateTime         ## batas idle (diperbarui setiap dipakai)
    absoluteExpiresAt*: DateTime ## batas mutlak sejak dibuat
    revoked*: bool

  PasswordProblem* = enum
    ppTooShort = "TOO_SHORT"
    ppTooLong = "TOO_LONG"
    ppEqualsUsername = "EQUALS_USERNAME"
    ppHasSpaces = "HAS_SPACES"

const
  permissionSegments* = 3  # nomagic:ok invarian format `modul.resource.action` (spec §13)
  ## Batas atas panjang password: menahan biaya PBKDF2 (teknis, bukan kebijakan).
  maxPasswordLength* = 128 # nomagic:ok batas teknis
  secondsPerMinute* = 60

proc allowed*(reason = arAllowed): AuthzDecision =
  AuthzDecision(allowed: true, reason: reason)

proc denied*(reason: AuthzReason): AuthzDecision =
  AuthzDecision(allowed: false, reason: reason)

proc validPermissionCode*(code: string): bool =
  ## Izin berbentuk `modul.resource.action`, huruf kecil, segmen tidak kosong (spec §13).
  let parts = code.split('.')
  if parts.len != permissionSegments:
    return false
  for p in parts:
    if p.len == 0 or p != p.toLowerAscii():
      return false
    for c in p:
      if not (c in {'a' .. 'z', '0' .. '9', '_', '-'}):
        return false
  true

proc roleCodesOf*(grants: openArray[Grant]): HashSet[string] =
  for g in grants:
    result.incl g.roleCode

proc branchApplies*(grantBranch, targetBranch: string): bool =
  ## Grant berlaku bila tanpa batas cabang ("") atau cocok dengan cabang target.
  ## Aksi level institusi (`targetBranch == ""`) hanya boleh dengan grant tanpa batas.
  grantBranch.len == 0 or grantBranch == targetBranch

proc conflictingPairs*(roleCodes: HashSet[string],
                       pairs: openArray[RolePair]): seq[RolePair] =
  ## Pasangan SoD yang benar-benar dipegang bersamaan (spec §18.2).
  for (a, b) in pairs:
    if a in roleCodes and b in roleCodes:
      result.add (a, b)

proc permissionsAt*(grants: openArray[Grant], targetBranch: string): HashSet[string] =
  for g in grants:
    if branchApplies(g.branchId, targetBranch):
      result.incl g.permission

proc authorize*(grants: openArray[Grant], targetBranch, required: string,
                conflictPairs: openArray[RolePair] = []): AuthzDecision =
  ## Keputusan otorisasi. Fail-closed:
  ##   1. pengguna yang memegang pasangan SoD ditolak **apa pun** izinnya (pertahanan berlapis;
  ##      penjagaan utamanya ada saat pemberian role),
  ##   2. izin harus ada **dan** berlaku di cabang target,
  ##   3. kode izin yang tidak valid = ditolak.
  if not validPermissionCode(required):
    return denied(arNoPermission)
  if conflictingPairs(roleCodesOf(grants), conflictPairs).len > 0:
    return denied(arRoleConflict)
  var permissionFound = false
  for g in grants:
    if g.permission != required:
      continue
    permissionFound = true
    if branchApplies(g.branchId, targetBranch):
      return allowed()
  if permissionFound:
    denied(arBranchNotAllowed)
  else:
    denied(arNoPermission)

proc sessionPolicy*(idleMinutes, absoluteMinutes: int): SessionPolicy =
  ## Validasi kebijakan: idle <= absolut (spec §18.2 "sesi pendek").
  if idleMinutes <= 0 or absoluteMinutes <= 0:
    raise newException(ValueError, "kebijakan sesi harus positif")
  if idleMinutes > absoluteMinutes:
    raise newException(ValueError,
      "idle (" & $idleMinutes & " menit) tidak boleh melebihi umur absolut (" &
      $absoluteMinutes & " menit)")
  SessionPolicy(idleMinutes: idleMinutes, absoluteMinutes: absoluteMinutes)

proc sessionDeadlines*(policy: SessionPolicy, now: DateTime): (DateTime, DateTime) =
  ## (batas idle, batas absolut) untuk sesi yang baru dibuat.
  (now + initDuration(minutes = policy.idleMinutes),
   now + initDuration(minutes = policy.absoluteMinutes))

proc sessionIsActive*(s: SessionState, now: DateTime): bool =
  ## Aktif bila belum dicabut dan belum lewat salah satu batas.
  not s.revoked and now < s.expiresAt and now < s.absoluteExpiresAt

proc refreshedExpiry*(s: SessionState, policy: SessionPolicy,
                      now: DateTime): DateTime =
  ## Perpanjangan idle tidak boleh melewati batas absolut.
  let candidate = now + initDuration(minutes = policy.idleMinutes)
  if candidate > s.absoluteExpiresAt: s.absoluteExpiresAt else: candidate

proc sessionCookieAttributes*(policy: SessionPolicy): string =
  ## Atribut cookie sesi (spec §13): HttpOnly + Secure + SameSite=Strict, tanpa nilai.
  "Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=" &
    $(policy.absoluteMinutes * secondsPerMinute)

proc passwordProblems*(minLength: int, username, plaintext: string): seq[PasswordProblem] =
  ## Kebijakan panjang dulu (aturan kompleksitas menyusul bila institusi meminta).
  if plaintext.len < minLength:
    result.add ppTooShort
  if plaintext.len > maxPasswordLength:
    result.add ppTooLong
  if plaintext.len > 0 and plaintext == username:
    result.add ppEqualsUsername
  if plaintext.strip() != plaintext:
    result.add ppHasSpaces
