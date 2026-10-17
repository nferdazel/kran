## Test murni otorisasi (RBAC + branch scoping + SoD) dan kebijakan sesi/password (T-006).
## Tanpa DB: semua keputusan diuji sebagai fungsi.

import std/[unittest, sets, strutils, times]

import kernel/paramkey
import platform/domain/authz

proc grant(role, branch, permission: string): Grant =
  Grant(roleCode: role, branchId: branch, permission: permission)

proc now(): DateTime =
  dateTime(2026, mOct, 13, 9, 0, 0, zone = utc())

suite "izin: bentuk kode":
  test "kode valid `modul.resource.action`":
    for ok in ["platform.param.approve", "lending.loan.read", "report.gl.print",
               "platform.param-value.approve", "a.b.c"]:
      check validPermissionCode(ok)

  test "kode tidak valid ditolak (termasuk wildcard & huruf besar)":
    for bad in ["platform.param", "platform.param.approve.extra", "Platform.param.approve",
                "platform..approve", "platform.param.*", "platform.param.approve ",
                "platform.param.approve;drop", "", "platform/param/approve"]:
      check not validPermissionCode(bad)

suite "otorisasi: branch scoping":
  test "grant tanpa batas cabang berlaku di semua cabang termasuk institusi":
    let g = @[grant("param.admin", "", "platform.param.approve")]
    check authorize(g, "br-bandung", "platform.param.approve").allowed
    check authorize(g, "", "platform.param.approve").allowed

  test "grant khusus cabang hanya berlaku di cabang itu":
    let g = @[grant("teller", "br-bandung", "teller.session.open")]
    check authorize(g, "br-bandung", "teller.session.open").allowed
    check not authorize(g, "br-surabaya", "teller.session.open").allowed
    check authorize(g, "br-surabaya", "teller.session.open").reason == arBranchNotAllowed
    # aksi level institusi tidak boleh dengan grant cabang (least privilege)
    check not authorize(g, "", "teller.session.open").allowed
    check authorize(g, "", "teller.session.open").reason == arBranchNotAllowed

  test "izin tidak dimiliki → ditolak":
    let g = @[grant("teller", "br-bandung", "teller.session.open")]
    let d = authorize(g, "br-bandung", "platform.param.approve")
    check not d.allowed
    check d.reason == arNoPermission

  test "izin terpisah: cabang lain punya izin berbeda":
    let g = @[grant("teller", "br-surabaya", "teller.session.open"),
              grant("param.admin", "", "platform.param.approve")]
    check authorize(g, "br-surabaya", "platform.param.approve").allowed
    check authorize(g, "br-bandung", "teller.session.open").reason == arBranchNotAllowed

  test "kode izin tidak valid selalu ditolak (tidak ada wildcard)":
    let g = @[grant("admin", "", "platform.param.approve")]
    check not authorize(g, "", "platform.*.*").allowed
    check not authorize(g, "", "platform.param").allowed

suite "visibilitas scope parameter (D-046 butir 6, D-055)":
  const baca = "platform.param.read"
  let cabang = @[grant("teller", "br-bandung", baca)]
  let institusi = @[grant("param.admin", "", baca)]
  let tanpaIzin = @[grant("teller", "br-bandung", "teller.session.open")]

  test "GLOBAL terlihat oleh siapa pun yang memegang izin bacanya":
    check mayReadScope(cabang, baca, pstGlobal, "")
    check mayReadScope(institusi, baca, pstGlobal, "")

  test "GLOBAL tidak terlihat tanpa izin baca":
    check not mayReadScope(tanpaIzin, baca, pstGlobal, "")

  test "BRANCH hanya untuk cabang yang ditutup grant":
    check mayReadScope(cabang, baca, pstBranch, "br-bandung")
    check not mayReadScope(cabang, baca, pstBranch, "br-surabaya")
    # grant tanpa batas cabang menutup semua cabang
    check mayReadScope(institusi, baca, pstBranch, "br-surabaya")

  test "INSTITUTION butuh grant tanpa batas cabang":
    check mayReadScope(institusi, baca, pstInstitution, "")
    check not mayReadScope(cabang, baca, pstInstitution, "")

  test "PRODUCT/SEGMENT/ROLE fail-closed sampai model keanggotaannya ada":
    check not mayReadScope(institusi, baca, pstProduct, "prod-1")
    check not mayReadScope(institusi, baca, pstSegment, "seg-1")
    check not mayReadScope(institusi, baca, pstRole, "teller")

  test "pembacaan cabang di luar cabang tugas terdeteksi (D-046 butir 6)":
    # grant tanpa batas cabang: setiap nilai cabang yang dibaca = lintas-cabang
    check isCrossBranchRead(institusi, baca, "br-surabaya")
    check isCrossBranchRead(institusi, baca, "br-bandung")
    # cabang tugas sendiri bukan lintas-cabang, juga saat grant tanpa batas ikut dipegang
    check not isCrossBranchRead(cabang, baca, "br-bandung")
    let gabungan = @[grant("param.admin", "", baca), grant("teller", "br-bandung", baca)]
    check not isCrossBranchRead(gabungan, baca, "br-bandung")
    check isCrossBranchRead(gabungan, baca, "br-surabaya")
    # scope non-cabang (GLOBAL/institusi) bukan pembacaan cabang
    check not isCrossBranchRead(institusi, baca, "")

suite "otorisasi: pemisahan tugas (SoD)":
  let semua = @[grant("maker", "", "platform.param.submit"),
                grant("checker", "", "platform.param.approve")]

  test "tanpa matriks konflik, maker+checker boleh ada di satu orang":
    check authorize(semua, "", "platform.param.submit").allowed

  test "pasangan SoD yang dipegang bersamaan → semua aksi ditolak":
    let conflicts = @[("checker", "maker")]
    let d = authorize(semua, "", "platform.param.submit", conflicts)
    check not d.allowed
    check d.reason == arRoleConflict
    check conflictingPairs(roleCodesOf(semua), conflicts) == @[("checker", "maker")]

  test "konflik hanya bila kedua role benar-benar dipegang":
    let hanyaMaker = @[grant("maker", "", "platform.param.submit")]
    check conflictingPairs(roleCodesOf(hanyaMaker), @[("checker", "maker")]).len == 0
    check authorize(hanyaMaker, "", "platform.param.submit", @[("checker", "maker")]).allowed

suite "izin efektif per cabang":
  test "permissionsAt menggabungkan grant yang berlaku":
    let g = @[grant("teller", "br-bandung", "teller.cash.count"),
              grant("teller", "br-bandung", "teller.session.open"),
              grant("param.admin", "", "platform.param.approve")]
    check permissionsAt(g, "br-bandung") ==
      toHashSet(["teller.cash.count", "teller.session.open", "platform.param.approve"])
    check permissionsAt(g, "br-surabaya") == toHashSet(["platform.param.approve"])

suite "kebijakan sesi":
  test "batas idle & absolut dari parameter":
    let p = sessionPolicy(30, 480)
    check p.idleMinutes == 30
    check p.absoluteMinutes == 480
    let (idle, absolute) = sessionDeadlines(p, now())
    check idle == now() + initDuration(minutes = 30)
    check absolute == now() + initDuration(minutes = 480)

  test "kebijakan tidak sah ditolak":
    for (idle, absolute) in [(0, 480), (30, 0), (60, 30), (-1, 480)]:
      var raised = false
      try:
        discard sessionPolicy(idle, absolute)
      except ValueError:
        raised = true
      check raised

  test "sesi aktif hanya bila belum dicabut & belum lewat batas":
    let p = sessionPolicy(30, 480)
    let (idle, absolute) = sessionDeadlines(p, now())
    let s = SessionState(createdAt: now(), lastSeenAt: now(), expiresAt: idle,
      absoluteExpiresAt: absolute, revoked: false)
    check sessionIsActive(s, now() + initDuration(minutes = 10))
    check not sessionIsActive(s, now() + initDuration(minutes = 31)) # idle lewat
    check not sessionIsActive(s, now() + initDuration(minutes = 481)) # absolut lewat
    var revoked = s
    revoked.revoked = true
    check not sessionIsActive(revoked, now())

  test "perpanjangan idle tidak melewati batas absolut":
    let p = sessionPolicy(30, 60)
    let (idle, absolute) = sessionDeadlines(p, now())
    let s = SessionState(createdAt: now(), lastSeenAt: now(), expiresAt: idle,
      absoluteExpiresAt: absolute, revoked: false)
    check refreshedExpiry(s, p, now() + initDuration(minutes = 50)) == absolute
    check refreshedExpiry(s, p, now() + initDuration(minutes = 10)) ==
      now() + initDuration(minutes = 40)

  test "atribut cookie sesi: HttpOnly + Secure + SameSite=Strict":
    let attr = sessionCookieAttributes(sessionPolicy(30, 480))
    check "HttpOnly" in attr
    check "Secure" in attr
    check "SameSite=Strict" in attr
    check "Path=/" in attr
    check "Max-Age=28800" in attr
    check "Domain=" notin attr

suite "kebijakan password":
  test "panjang minimum dari parameter":
    check passwordProblems(12, "budi", "pendek").contains(ppTooShort)
    check passwordProblems(12, "budi", "cukup-panjang-123").len == 0

  test "batas atas & kesamaan dengan username":
    check passwordProblems(8, "budi", repeat("a", 200)).contains(ppTooLong)
    check passwordProblems(8, "budi", "budi").contains(ppEqualsUsername)

  test "spasi di awal/akhir ditolak (mudah salah ketik)":
    check passwordProblems(8, "budi", " rahasia-panjang").contains(ppHasSpaces)
    check passwordProblems(8, "budi", "rahasia-panjang ").contains(ppHasSpaces)
