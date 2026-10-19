## Otorisasi (RBAC + branch scoping + SoD) dan kebijakan sesi/password (spec §13, §18.2) — murni.
##
## Semua **angka kebijakan** (menit idle/absolut, panjang minimum password) datang dari parameter
## DB; yang tinggal di sini hanya aturan keputusan dan invarian matematis/teknis.

import std/[sets, strutils, times]

import kernel/paramkey

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
    ppTooSimple = "TOO_SIMPLE" ## kelas karakter kurang beragam (`password_min_classes`)
    ppReused = "REUSED"        ## sama dengan kata sandi yang berlaku atau N sebelumnya (O-052)

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

type
  ScopeFilter* = object
    ## Himpunan scope yang boleh dibaca pemegang satu izin (D-046 butir 6), dalam bentuk yang bisa
    ## diterjemahkan langsung ke SQL: `allBranches` = pemegang punya grant **tanpa batas cabang**,
    ## `branches` = cabang yang ditutup grant terbatas. Untuk deret audit, baris tanpa cabang
    ## diwakili string kosong di `branches` (lihat `auditScopeFilter`).
    allBranches*: bool
    branches*: HashSet[string]

proc readableScopeFilter*(grants: openArray[Grant], permission: string): ScopeFilter =
  ## Ringkasan grant untuk satu izin. **Satu-satunya** tempat aturan "grant mana menutupi scope
  ## mana" didefinisikan: `mayReadScope` menurunkannya dari sini, dan repo hanya menerjemahkan
  ## hasilnya ke SQL (`paramValueRows`, `listAudit`) — bukan aturan kedua di sisi DB.
  for g in grants:
    if g.permission != permission:
      continue
    if g.branchId.len == 0:
      result.allBranches = true
    else:
      result.branches.incl g.branchId

proc mayReadScope*(grants: openArray[Grant], permission: string,
                   scopeType: ParamScopeType, scopeId: string): bool =
  ## Visibilitas nilai ber-scope bagi pemegang `permission` (D-046 butir 6, D-055).
  ##
  ## GLOBAL terlihat oleh siapa pun yang memegang izin bacanya: nilai itu dipakai semua orang dan
  ## menyembunyikannya tidak melindungi apa pun. INSTITUTION hanya untuk grant tanpa batas cabang,
  ## BRANCH hanya bila grant menutupi cabang itu. PRODUCT/SEGMENT/ROLE **fail-closed**: belum ada
  ## model keanggotaan untuk ketiganya di mana pun (`Grant` hanya mengenal cabang), jadi menampilkan
  ## nilai yang keanggotaannya tidak bisa dievaluasi sama dengan membocorkannya.
  let filter = readableScopeFilter(grants, permission)
  case scopeType
  of pstGlobal:
    filter.allBranches or filter.branches.len > 0
  of pstInstitution:
    filter.allBranches
  of pstBranch:
    filter.allBranches or scopeId in filter.branches
  of pstProduct, pstSegment, pstRole:
    false

proc auditScopeFilter*(grants: openArray[Grant], permission: string): ScopeFilter =
  ## Deret audit: aksi tanpa cabang (tingkat institusi) selalu terlihat — sama alasannya dengan
  ## GLOBAL pada parameter, yaitu tidak ada yang dilindungi dengan menyembunyikannya. Aksi
  ## bercabang hanya bila grant menutupinya.
  result = readableScopeFilter(grants, permission)
  if not result.allBranches:
    result.branches.incl ""

proc isCrossBranchRead*(grants: openArray[Grant], permission, scopeId: string): bool =
  ## Apakah membaca nilai bercabang `scopeId` berarti keluar dari cabang tugas pemanggil
  ## (D-046 butir 6: pembacaan seperti itu dicatat audit). Grant tanpa batas cabang menutupi semua
  ## cabang tetapi tidak menjadikannya cabang tugas pemanggil — itulah yang terdeteksi di sini.
  scopeId.len > 0 and scopeId notin readableScopeFilter(grants, permission).branches

proc authorize*(grants: openArray[Grant], targetBranch, required: string,
                conflictPairs: openArray[RolePair] = []): AuthzDecision =
  ## Keputusan otorisasi untuk **satu** cabang target. Fail-closed:
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

proc authorizeAnyBranch*(grants: openArray[Grant], required: string,
                         conflictPairs: openArray[RolePair] = []): AuthzDecision =
  ## Keputusan otorisasi **tanpa dimensi cabang**: izin dianggap dipegang bila ada minimal satu
  ## grant yang memberikannya, apa pun batas cabangnya (T-058).
  ##
  ## Dipakai hanya untuk permintaan yang hasilnya disaring **per baris** (daftar parameter, daftar
  ## audit). Di sana satu cabang target tidak bisa menyatakan "sebagian hasil boleh dilihat", dan
  ## menuntutnya akan menolak pembacaan yang sah. Penjagaan sebenarnya ada di
  ## `readableScopeFilter`/`auditScopeFilter`. Permintaan yang menyentuh **satu** objek ber-cabang
  ## tetap memakai `authorize` dengan cabang objek itu.
  ##
  ## SoD dan bentuk kode izin ditegakkan sama seperti `authorize` — yang dilonggarkan hanya dimensi
  ## cabang, bukan syarat lainnya.
  if not validPermissionCode(required):
    return denied(arNoPermission)
  if conflictingPairs(roleCodesOf(grants), conflictPairs).len > 0:
    return denied(arRoleConflict)
  for g in grants:
    if g.permission == required:
      return allowed()
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

const sessionCookieAttributeList* = "Path=/; HttpOnly; Secure; SameSite=Strict"
  ## Daftar atribut cookie sesi (spec §13) tanpa `Max-Age`: satu definisi, dipakai cookie hidup
  ## maupun cookie penghapus — cookie dengan bentuk berbeda akan diabaikan browser, dan sesi
  ## tidak benar-benar terhapus.

proc sessionCookieAttributes*(policy: SessionPolicy): string =
  ## Atribut cookie sesi (spec §13): HttpOnly + Secure + SameSite=Strict, tanpa nilai.
  sessionCookieAttributeList & "; Max-Age=" & $(policy.absoluteMinutes * secondsPerMinute)

proc clearedCookieAttributes*(): string =
  ## Atribut untuk **menghapus** cookie saat logout (umur 0).
  sessionCookieAttributeList & "; Max-Age=0"

proc passwordClasses*(plaintext: string): int =
  ## Jumlah kelas karakter yang ada: huruf kecil, huruf besar, angka, dan sisanya (simbol —
  ## termasuk aksara non-ASCII, yang dihitung satu kelas "simbol" karena batasnya ASCII).
  var lower, upper, digit, other = false
  for c in plaintext:
    if c in {'a' .. 'z'}:
      lower = true
    elif c in {'A' .. 'Z'}:
      upper = true
    elif c in {'0' .. '9'}:
      digit = true
    else:
      other = true
  ord(lower) + ord(upper) + ord(digit) + ord(other)

proc passwordProblems*(minLength, minClasses: int, username,
                       plaintext: string): seq[PasswordProblem] =
  ## Kebijakan kata sandi baru (spec §10.4): panjang, keragaman kelas, dan bukan username/spasi.
  ## Semua angkanya dari parameter — tidak ada default di sini. Semua pelanggaran dikumpulkan,
  ## bukan berhenti di yang pertama: pemanggil menampilkan daftarnya.
  if plaintext.len < minLength:
    result.add ppTooShort
  if plaintext.len > maxPasswordLength:
    result.add ppTooLong
  if plaintext.len > 0 and plaintext == username:
    result.add ppEqualsUsername
  if plaintext.strip() != plaintext:
    result.add ppHasSpaces
  if minClasses > 0 and passwordClasses(plaintext) < minClasses:
    result.add ppTooSimple
