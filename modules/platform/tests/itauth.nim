## Test integrasi identitas, sesi, izin (T-006). Butuh `CBS_DATABASE_URL`.
##
## Cakupan kriteria T-006: matriks authz (role + branch scoping + SoD) hijau, audit context
## terisi di alur use case (actor/cabang/IP/device/alasan/correlation di `audit_log`), sesi
## cookie (atribut HttpOnly/Secure/SameSite diuji murni di `tauthz`, di sini lifecycle-nya),
## lockout dari parameter, ganti password.
##
## Test ini **menghapus schema `platform`** di DB yang ditunjuk `CBS_DATABASE_URL` (DB dev).

import std/[json, options, os, sets, strutils, times, unittest]
import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[auditcontext, clock, ids, paramkey, result]
import platform/domain/[audit, authz, scope]
import platform/domain/param
import platform/infrastructure/[audit_repo, auth_repo, auth_service, calendar_repo, param_repo,
  password_hasher]

const
  repoRoot = "."
  iterationsKey = "platform.security.password_pbkdf2_iterations"
  sessionIdleKey = "platform.security.session_idle_minutes"
  absoluteKey = "platform.security.session_absolute_minutes"
  asOf = "2026-10-13"
  branchBandung = "11111111-1111-1111-1111-111111111111"
  branchSurabaya = "22222222-2222-2222-2222-222222222222"
  passwordAwal = "rahasia-panjang-123"

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itauth: CBS_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()
let sysClock = systemClock()

execScript(db, "DROP SCHEMA IF EXISTS platform CASCADE")
discard applyMigrations(db, repoRoot)
execScript(db, readFile(repoRoot / "packs/base/generated/param_definitions.sql"))
execScript(db, readFile(repoRoot / "packs/base/generated/param_values.sql"))

# Iterasi PBKDF2 diturunkan lewat jalur normal (maker-checker) supaya test tidak lambat;
# nilai pack (600.000) tetap yang dipakai kalau parameter tidak diubah.
let adminId = $newId(sysClock)
let adminCtx = newAuditContext(parseId(adminId).value(), sysClock)
let change = submitChange(db, adminCtx, sysClock, iterationsKey, "GLOBAL", "", %*1000,
  "2026-01-01", "", "uji: turunkan iterasi PBKDF2")
discard approveChange(db, newAuditContext(parseId($newId(sysClock)).value(), sysClock), sysClock,
  change.paramValueId)

let instScope = institutionScope()
let jamKerja = fakeClock(dateTime(2026, mOct, 13, 9, 0, 0, zone = utc()))

proc settings(): SecuritySettings =
  settingsOf(db, instScope, asOf)

proc ctxFor(userId: string; branch = branchBandung; reason = "uji otomatis"): AuditContext =
  ## Untuk user tak dikenal tidak ada id: konteks memakai id kosong (audit mencatat actor NULL).
  let id = if userId.len > 0: parseId(userId).value() else: Id("")
  newAuditContext(id, branchIds = @[parseId(branch).value()],
    ip = "10.0.0.5", device = "teller-pc-1", reason = reason, correlationId = "corr-uji",
    startedAt = jamKerja.now())

proc buatUser(username: string; password = passwordAwal; status = "ACTIVE"): string =
  result = $newId(sysClock)
  check insertUser(db, NewUser(userId: result, username: username, fullName: "Uji " & username,
    passwordHash: $hashPassword(password, 1000)))
  if status != "ACTIVE":
    check setUserStatus(db, result, status)

proc siapkanRole(roleCode, permissionCode: string) =
  ## Idempotent: role/izin yang sudah ada tidak dibuat ulang (ON CONFLICT pada kode).
  discard insertRole(db, $newId(sysClock), roleCode, "role." & roleCode)
  discard insertPermission(db, $newId(sysClock), permissionCode, "perm." & permissionCode)
  discard grantPermissionToRole(db, roleCode, permissionCode)
  check permissionCode in rolePermissions(db, roleCode)

proc auditRows(action: string): seq[Row] =
  db.getAllRows(sql"""
    SELECT actor_user_id::text, host(client_ip), device, request_id, branch_id::text,
           to_char(business_date, 'YYYY-MM-DD'), reason, after_value::text
      FROM platform.audit_log WHERE action = ? ORDER BY seq""", action)

proc login(username, password: string; branch = branchBandung): AuthResult =
  ## Login dengan konteks lengkap seperti dari HTTP layer nanti.
  let found = userByUsername(db, username)
  let uid = if found.isSome: found.get().userId else: ""
  authenticate(db, ctxFor(uid, branch), jamKerja, instScope, settings(), username, password)

suite "login: sukses + audit context":
  test "login benar membuat sesi dan mencatat konteks lengkap di audit":
    let uid = buatUser("budi")
    let res = login("budi", passwordAwal)
    check res.outcome == aoSuccess
    check res.userId == uid
    check res.token.len >= 40
    check res.sessionId.len > 0

    let sesi = sessionFor(db, jamKerja, res.token)
    check sesi.isSome
    check sesi.get().userId == uid

    let rows = auditRows("auth.login.success")
    check rows.len == 1
    check rows[0][0] == uid # actor_user_id
    check rows[0][1] == "10.0.0.5" # client_ip
    check rows[0][2] == "teller-pc-1" # device
    check rows[0][3] == "corr-uji" # request_id (correlation id)
    check rows[0][4] == branchBandung # branch_id
    check rows[0][5] == "2026-10-13" # business_date
    check rows[0][6] == "uji otomatis" # reason
    check parseJson(rows[0][7])["session_id"].getStr == res.sessionId

  test "username tidak ada → kredensial invalid, audit tanpa username mentah":
    let res = login("tidak-ada", passwordAwal)
    check res.outcome == aoInvalidCredentials
    let rows = auditRows("auth.login.failure")
    check rows.len == 1
    check rows[0][0] == "" # actor tidak diketahui
    let after = parseJson(rows[0][7])
    check after["reason"].getStr == "unknown_user"
    check after.hasKey("username_digest")
    check "tidak-ada" notin rows[0][7] # username mentah tidak ditulis

  test "akun INACTIVE ditolak (bukan sekadar gagal password)":
    let uid = buatUser("duduk-perkara", passwordAwal, "INACTIVE")
    let res = login("duduk-perkara", passwordAwal)
    check res.outcome == aoInactive
    let rows = auditRows("auth.login.failure")
    check rows.len >= 1
    let terakhir = rows[rows.len - 1]
    check terakhir[0] == uid
    check parseJson(terakhir[7])["reason"].getStr == "status"

suite "lockout dari parameter":
  test "gagal berulang mengunci akun; password benar tetap ditolak saat terkunci":
    let uid = buatUser("salah-terus")
    let maks = settings().maxFailedLogins
    check maks >= 1
    for i in 1 .. maks:
      let res = login("salah-terus", "password-salah")
      check res.outcome == (if i == maks: aoLocked else: aoInvalidCredentials)
    # audit setiap percobaan gagal
    var gagal = 0
    for row in auditRows("auth.login.failure"):
      if row[0] == uid:
        inc gagal
    check gagal == maks
    # terkunci: password benar pun ditolak, pesannya beda dari kredensial salah
    check login("salah-terus", passwordAwal).outcome == aoLocked
    let terkunci = userById(db, uid).get()
    check terkunci.status == "LOCKED"
    check terkunci.lockedUntil.len > 0

  test "setelah masa lockout lewat, login benar berhasil dan penghitung direset":
    let uid = buatUser("kunci-lewat")
    for _ in 1 .. settings().maxFailedLogins:
      discard login("kunci-lewat", "password-salah")
    check userById(db, uid).get().status == "LOCKED"
    jamKerja.advance(int64(settings().lockoutMinutes) * 60 + 60)
    let res = login("kunci-lewat", passwordAwal)
    check res.outcome == aoSuccess
    let user = userById(db, uid).get()
    check user.status == "ACTIVE"
    check user.failedAttempts == 0
    check user.lockedUntil.len == 0
    jamKerja.setNow(dateTime(2026, mOct, 13, 9, 0, 0, zone = utc())) # kembalikan jam

suite "sesi: idle, logout, perangkat":
  test "sesi lewat batas idle tidak lagi aktif":
    discard buatUser("sesi-idle")
    let res = login("sesi-idle", passwordAwal)
    check sessionFor(db, jamKerja, res.token).isSome
    jamKerja.advance(int64(settings().sessionIdleMinutes) * 60 + 60)
    check sessionFor(db, jamKerja, res.token).isNone
    jamKerja.setNow(dateTime(2026, mOct, 13, 9, 0, 0, zone = utc()))

  test "perpanjangan idle memperpanjang sesi tapi tidak melewati batas absolut":
    discard buatUser("sesi-perpanjang")
    let res = login("sesi-perpanjang", passwordAwal)
    let sesi = sessionFor(db, jamKerja, res.token).get()
    jamKerja.advance(60 * 10) # 10 menit
    let diperpanjang = touch(db, jamKerja, settings(), sesi)
    check diperpanjang
    let sesudah = sessionFor(db, jamKerja, res.token).get()
    check sesudah.expiresAt == utcIso(parseIsoZ(sesi.expiresAt) + initDuration(minutes = 10))
    check sesudah.absoluteExpiresAt == sesi.absoluteExpiresAt
    check touchSession(db, sesi.sessionId, utcIso(jamKerja.now()),
      utcIso(parseIsoZ(sesi.absoluteExpiresAt) + initDuration(minutes = 600))) # coba lewati absolut

    check sessionFor(db, jamKerja, res.token).get().absoluteExpiresAt ==
      sesi.absoluteExpiresAt
    jamKerja.setNow(dateTime(2026, mOct, 13, 9, 0, 0, zone = utc()))

  test "logout mencabut satu sesi; logoutAll mencabut semuanya":
    let uid = buatUser("sesi-logout")
    let sesi1 = login("sesi-logout", passwordAwal)
    let sesi2 = login("sesi-logout", passwordAwal)
    check activeSessionCount(db, uid, utcIso(jamKerja.now())) == 2
    check logout(db, jamKerja, sessionFor(db, jamKerja, sesi1.token).get())
    check sessionFor(db, jamKerja, sesi1.token).isNone
    check sessionFor(db, jamKerja, sesi2.token).isSome
    check logoutAll(db, jamKerja, uid, "uji cabut semua") == 1
    check sessionFor(db, jamKerja, sesi2.token).isNone
    check activeSessionCount(db, uid, utcIso(jamKerja.now())) == 0
    check purgeExpiredSessions(db, utcIso(jamKerja.now())) == 2
    check sessionAnyState(db, tokenHash(sesi2.token)).isNone # sudah dibersihkan

suite "otoisasi: role + branch scoping + SoD":
  test "izin berlaku hanya di cabang yang ditugaskan":
    siapkanRole("teller", "teller.session.open")
    siapkanRole("param-admin", "platform.param.approve")
    let uid = buatUser("petugas")
    check grantRole(db, uid, "teller", branchBandung, adminId)
    check grantRole(db, uid, "param-admin", "", adminId)

    check authorizeUser(db, uid, branchBandung, "teller.session.open").allowed
    let ditolak = authorizeUser(db, uid, branchSurabaya, "teller.session.open")
    check not ditolak.allowed
    check ditolak.reason == arBranchNotAllowed
    # role tanpa batas cabang berlaku di mana saja
    check authorizeUser(db, uid, branchSurabaya, "platform.param.approve").allowed
    # izin yang tidak dimiliki
    check authorizeUser(db, uid, branchBandung, "lending.loan.read").reason == arNoPermission
    # izin tidak sah (tidak ada wildcard)
    check not authorizeUser(db, uid, branchBandung, "teller.*.*").allowed

  test "penugasan role berkonflik ditolak sejak awal (SoD)":
    siapkanRole("maker", "platform.param.submit")
    siapkanRole("checker", "platform.param.approve")
    check setRoleConflict(db, "checker", "maker", "sod.param.maker_checker")
    check conflictPairs(db) == @[("checker", "maker")]
    let uid = buatUser("orang-dua-topi")
    check grantRole(db, uid, "maker", "", adminId)
    var raised = false
    try:
      discard grantRole(db, uid, "checker", "", adminId)
    except ValueError as e:
      raised = true
      check e.msg.contains("pemisahan tugas")
    check raised
    check roleCodesOfUser(db, uid) == @["maker"]

  test "konflik yang lolos ke DB tetap ditolak saat otorisasi (pertahanan berlapis)":
    let uid = buatUser("dua-topi-paksa")
    check grantRole(db, uid, "maker", "", adminId)
    # menulis langsung ke tabel (mensimulasikan data lama / jalur istimewa)
    db.exec(sql"""
      INSERT INTO platform.user_role (user_id, role_id)
      SELECT ?::uuid, r.role_id FROM platform.role r WHERE r.code = 'checker'""", uid)
    check conflictsOfUser(db, uid) == @[("checker", "maker")]
    let d = authorizeUser(db, uid, "", "platform.param.submit")
    check not d.allowed
    check d.reason == arRoleConflict

  test "role dicabut → izin hilang":
    let uid = buatUser("petugas-sementara")
    check grantRole(db, uid, "teller", branchBandung, adminId)
    check authorizeUser(db, uid, branchBandung, "teller.session.open").allowed
    check revokeRole(db, uid, "teller", branchBandung)
    check not authorizeUser(db, uid, branchBandung, "teller.session.open").allowed

suite "ganti password":
  test "password lama harus benar; password baru dinilai kebijakan; sesi baru bisa login":
    let uid = buatUser("ganti-password")
    let user = userById(db, uid).get()
    check not changePassword(db, user, settings(), "password-salah", "password-baru-panjang")
    var raised = false
    try:
      discard changePassword(db, user, settings(), passwordAwal, "pendek")
    except ValueError:
      raised = true
    check raised
    check changePassword(db, user, settings(), passwordAwal, "password-baru-panjang")
    check login("ganti-password", passwordAwal).outcome == aoInvalidCredentials
    check login("ganti-password", "password-baru-panjang").outcome == aoSuccess

suite "kebijakan sesi: aturan lintas-parameter":
  test "kandidat yang melanggar idle <= absolut dilaporkan; yang sah tidak":
    # Aturan domainnya milik `sessionPolicy` (spec §18.2). Yang diuji di sini adalah pemeriksaan
    # **calon nilai** terhadap nilai sisi lainnya yang sedang aktif — jalan yang mencegah nilai
    # sah-per-schema (mis. idle 600 + absolut 480) disetujui dan mematikan seluruh login.
    let kebijakan = settings()
    check kebijakan.sessionAbsoluteMinutes > 0
    let melanggar = sessionPolicyCandidateProblem(db, sessionIdleKey,
      %*(kebijakan.sessionAbsoluteMinutes + 1), "INSTITUTION", "", asOf, asOf)
    check melanggar.contains("tidak boleh melebihi")

    # Tepat pada batas (idle = absolut) masih sah.
    check sessionPolicyCandidateProblem(db, sessionIdleKey,
      %*kebijakan.sessionAbsoluteMinutes, "INSTITUTION", "", asOf, asOf) == ""

    # Key yang bukan bagian kebijakan sesi tidak diperiksa di sini.
    check sessionPolicyCandidateProblem(db, iterationsKey, %*1, "INSTITUTION", "", asOf, asOf) == ""

    # Nilai yang bukan integer bukan urusan pemeriksaan ini (bentuk nilai dijaga `submitValue`).
    check sessionPolicyCandidateProblem(db, sessionIdleKey, %*"bukan-angka", "INSTITUTION", "",
      asOf, asOf) == ""

  test "perubahan ber-tanggal depan dinilai pada tanggal efektifnya, bukan hanya hari ini":
    # Nilai absolut disetujui untuk tanggal depan: mulai 2026-12-01 kebijakan yang berlaku adalah
    # idle 30 / absolut 100. Calon idle yang dinilai **hanya di hari ini** akan lolos (30 ≤ 480),
    # padahal pada tanggal itu kombinasi baru tidak sah — inilah jendela yang harus ditutup.
    let upcoming = "2026-12-01"
    # `INSTITUTION` wajib ber-`scope_id` konkret (CHECK `param_value_global_scope_chk`).
    let ubahAbsolut = submitChange(db, adminCtx, sysClock, absoluteKey, "INSTITUTION", "inst-1",
      %*100, upcoming, "", "uji: batas absolut untuk tanggal depan")
    discard approveChange(db, newAuditContext(parseId($newId(sysClock)).value(), sysClock),
      sysClock, ubahAbsolut.paramValueId)

    let melanggar = sessionPolicyCandidateProblem(db, sessionIdleKey, %*150, "INSTITUTION",
      "inst-1", upcoming, asOf)
    check melanggar.contains(upcoming)
    check melanggar.contains("tidak boleh melebihi")

    # idle 50 pada tanggal itu tetap sah.
    check sessionPolicyCandidateProblem(db, sessionIdleKey, %*50, "INSTITUTION", "inst-1",
      upcoming, asOf) == ""
