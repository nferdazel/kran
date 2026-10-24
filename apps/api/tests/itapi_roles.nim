## Test peran CLI `kran-api` (T-026, O-013) — butuh `KRAN_DATABASE_URL`.
##
## Yang diuji adalah **kontrak** yang dipakai `ops/scripts/migrate.sh` dan gate deploy:
## `--role=migrate` idempoten, dan `--role=ctl <perintah>` dengan kode keluar yang bisa diandalkan.
## Peran dipanggil langsung (bukan lewat biner) supaya test tidak bergantung pada hasil
## `./task build`; biner-nya sendiri hanya menjalankan `main()` yang memanggil jalur yang sama.
##
## Catatan: test ini **tidak** menuntut rantai audit utuh, karena `itplatform` sengaja merusak rantai
## untuk membuktikan deteksi. Yang diuji di sini: kode keluar `ctl verify-audit` **konsisten** dengan
## hasil `verifyChain` pada DB yang sedang dipakai.

import std/[options, os, strutils, unittest]

import db_connector/db_postgres

import "platform-lib/db/config"
import "platform-lib/db/pool"
import dbtools/lib
import kernel/[auditcontext, clock, ids]
import platform/domain/scope
import platform/infrastructure/[audit_repo, auth_repo, auth_service, branch_repo,
  password_hasher, worker_repo]

import ../src/main

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_roles: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let dbPool = newDbPool(dbConfigFromEnv(envT))
let db = dbPool.acquire()

# --- prasyarat parameter (T-059) -----------------------------------------------------------------
# `ctl bootstrap-admin` membaca kebijakan keamanan dari parameter DB (`settingsOf`). Bila suite
# lain (mis. `itplatform`) baru membuat ulang schema `platform` tanpa menyemai nilai, perintah
# keluar 1 ("parameter … tidak punya nilai aktif") alih-alih kontrak 3 (ditolak karena admin sudah
# ada) — test gagal tanpa sebab yang terbaca. Harness menyiapkan prasyaratnya sendiri: migrasi +
# seed pack `generated/` yang idempoten (`ON CONFLICT`), jadi aman dijalankan walau nilainya sudah
# ada. Bila tetap tidak bisa, sebut sebabnya dan berhenti — jangan lanjut ke assertion yang
# membingungkan.
block:
  try:
    discard applyAllMigrations(db, ".")
    for rel in seedFiles("."):
      execScript(db, readFile(rel))
    # Buktikan prasyaratnya benar-benar terpenuhi lewat pembaca yang sama dengan produksi.
    discard settingsOf(db, institutionScope(), utcIso(systemClock().now())[0 .. 9])
  except CatchableError as e:
    echo "itapi_roles: prasyarat T-059 (parameter keamanan) tidak siap: " & e.msg
    quit(1)

suite "kran-api: peran CLI (O-013)":
  test "ctl tanpa perintah / help → 0; perintah tak dikenal → 2":
    check runCtl("", ".") == 0
    check runCtl("help", ".") == 0
    check runCtl("bukan-perintah", ".") == 2

  test "kontrak kode keluar verify-audit: utuh 0, tidak utuh 1":
    check auditExitCode(@[AuditChainRow(seq: 1, rowHashOk: true, linkOk: true,
      expectedHash: "a", actualHash: "a")]) == 0
    check auditExitCode(@[
      AuditChainRow(seq: 1, rowHashOk: true, linkOk: true, expectedHash: "a", actualHash: "a"),
      AuditChainRow(seq: 2, rowHashOk: false, linkOk: true, expectedHash: "b",
        actualHash: "a")]) == 1
    check auditExitCode(@[AuditChainRow(seq: 2, rowHashOk: true, linkOk: false,
      expectedHash: "b", actualHash: "b")]) == 1

  test "verify-audit pada DB nyata: kode keluar konsisten dengan verifyChain":
    let baris = verifyChain(db)
    check runCtl("verify-audit", ".") == auditExitCode(baris)

  test "outbox-status → 0":
    check runCtl("outbox-status", ".") == 0

  test "ctl daycloser-status: dikenali, tapi belum ada di Fase 0 → 3":
    check runCtl("daycloser-status", ".") == 3

  test "ctl audit-anchor: kepala rantai ke berkas append (O-009)":
    let path = getTempDir() / ("kran-anchor-" & $newId(systemClock()) & ".txt")
    defer: removeFile(path)
    let line = runAuditAnchor(db, systemClock(), path)
    let head = auditHead(db)
    check line.contains("seq=" & $head.seq)
    check line.contains("hash=" & head.hash)
    check readFile(path).strip() == line
    # Anchor kedua menambah baris (append), bukan menimpa.
    discard runAuditAnchor(db, systemClock(), path)
    check readFile(path).strip().splitLines().len == 2

  test "ctl bootstrap-admin: tanpa --username → 2 (salah pakai), bantuan menyebutnya":
    # `bootstrap-admin` salah satu dari dua perintah `ctl` yang menulis (D-100), jadi kontraknya diuji eksplisit.
    # Alur sukses + kata sandi yang dicetak sekali diuji di `itauth` (butuh skema bersih); di sini
    # yang penting: salah pakai tidak diam-diam membuat admin, dan perintahnya terlihat di bantuan.
    check runCtl(bootstrapAdminCmd, ".", "") == 2
    check CtlUsage.contains(bootstrapAdminCmd)

  test "ctl bootstrap-admin: menolak bila sudah ada pemegang role admin (kode 3)":
    let uid = $newId(systemClock())
    let siap = insertUser(db, NewUser(userId: uid, username: "itapi-admin-lama",
      fullName: "Uji Admin Lama", passwordHash: "x"))
    if siap:
      discard grantRole(db, uid, bootstrapAdminRole, "", "")
    defer:
      discard db.execAffectedRows(sql"DELETE FROM platform.user_role WHERE user_id = ?::uuid", uid)
      discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    # Kode 3 = "dikenali, tapi tidak bisa dijalankan sekarang" (kontrak T-026) — bukan 2 (salah
    # pakai) dan bukan 0 (seolah-olah berhasil).
    check runCtl(bootstrapAdminCmd, ".", "itapi-admin-baru") == 3

  test "ctl create-user: argument contract + teller provisioning (T-115)":
    # Missing arguments must not create a half-provisioned account.
    check runCtl(createUserCmd, ".", "") == 2
    check runCtl(createUserCmd, ".", "itapi-teller-x") == 2
    check CtlUsage.contains(createUserCmd)

    let branch = "b0000000-0000-4000-8000-000000000001"
    let uname = "itapi-teller-" & $newId(systemClock())
    # Unknown role is rejected (code 3) before a user row is written.
    check runCtl(createUserCmd, ".", uname, "", "role-tidak-ada") == 3
    check userByUsername(db, uname).isNone

    let code = runCtl(createUserCmd, ".", uname, "", "teller", branch, "Uji Teller")
    check code == 0
    let created = userByUsername(db, uname)
    check created.isSome
    defer:
      discard db.execAffectedRows(sql"DELETE FROM platform.user_role WHERE user_id = ?::uuid",
        created.get().userId)
      discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid",
        created.get().userId)
    check created.get().mustChangePassword
    check "teller" in roleCodesOfUser(db, created.get().userId)
    # The branch grant is the one that was asked for — not a global grant.
    check db.getValue(sql"""
      SELECT coalesce(branch_id, 'schema-null') FROM platform.user_role
       WHERE user_id = ?::uuid""", created.get().userId) == branch

  test "create-user enforces role scope before inserting (RBAC hardening)":
    let branch = "b0000000-0000-4000-8000-000000000001"
    # Branch role without a branch must be rejected, and must leave no user row behind: the grant
    # would otherwise be global and the account would see every branch.
    let tellerName = "itapi-scope-teller-" & $newId(systemClock())
    check runCtl(createUserCmd, ".", tellerName, "", "teller", "", "Uji Teller") == 3
    check userByUsername(db, tellerName).isNone
    # Institution role with a branch is a dead account (institution routes authorize at branch "");
    # rejected before insert.
    let checkerName = "itapi-scope-checker-" & $newId(systemClock())
    check runCtl(createUserCmd, ".", checkerName, "", "product_checker", branch,
      "Uji Checker") == 3
    check userByUsername(db, checkerName).isNone
    # Invalid branch shape is rejected too.
    let badBranch = "itapi-scope-bad-" & $newId(systemClock())
    check runCtl(createUserCmd, ".", badBranch, "", "teller", "bukan-uuid") == 3
    check userByUsername(db, badBranch).isNone

    # Valid institution role without a branch still works.
    let okName = "itapi-scope-ok-" & $newId(systemClock())
    check runCtl(createUserCmd, ".", okName, "", "product_checker") == 0
    let okUser = userByUsername(db, okName)
    check okUser.isSome
    defer:
      discard db.execAffectedRows(sql"DELETE FROM platform.user_role WHERE user_id = ?::uuid",
        okUser.get().userId)
      discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid",
        okUser.get().userId)
    check "product_checker" in roleCodesOfUser(db, okUser.get().userId)
    check db.getValue(sql"""
      SELECT coalesce(branch_id, 'schema-null') FROM platform.user_role
       WHERE user_id = ?::uuid""", okUser.get().userId) == "schema-null"

  test "0028: teller reads parameters and role scopes are catalogued":
    # UI renders the configured F4/F5/F9 shortcuts from `platform.ui.shortcut.*`, which require
    # the parameter read permission; without it the shortcuts never load.
    check "platform.param.read" in rolePermissions(db, "teller")
    # Read-only: no submit/approve leaks into the teller role.
    check "platform.param.submit" notin rolePermissions(db, "teller")
    check "platform.param.approve" notin rolePermissions(db, "teller")
    check roleScope(db, "teller").get() == roleScopeBranch
    check roleScope(db, "product_checker").get() == roleScopeInstitution
    check roleScope(db, "platform_admin").get() == roleScopeInstitution
    check roleScope(db, "param_maker").get() == roleScopeInstitution

  test "ctl assign-role/revoke-role: branch vs institution scope (RBAC hardening)":
    let branch = "b0000000-0000-4000-8000-000000000001"
    let other = "b0000000-0000-4000-8000-000000000009"
    let uid = $newId(systemClock())
    let uname = "itapi-life-" & uid[0 .. 7]
    check insertUser(db, NewUser(userId: uid, username: uname, fullName: "Uji Lifecycle",
      passwordHash: "x"))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)

    # Missing arguments / unknown target.
    check runCtl(assignRoleCmd, ".", "") == 2
    check runCtl(assignRoleCmd, ".", uname) == 2
    check runCtl(revokeRoleCmd, ".", "") == 2
    check runCtl(assignRoleCmd, ".", "tidak-ada", "", "teller", branch) == 3
    check runCtl(assignRoleCmd, ".", uname, "", "role-tidak-ada") == 3

    # Scope is enforced: branch role needs a branch, institution role must not have one. Nothing is
    # granted on rejection.
    check runCtl(assignRoleCmd, ".", uname, "", "teller") == 3
    check runCtl(assignRoleCmd, ".", uname, "", "teller", "bukan-uuid") == 3
    check runCtl(assignRoleCmd, ".", uname, "", "product_checker", branch) == 3
    check roleCodesOfUser(db, uid).len == 0

    # Valid grants.
    check runCtl(assignRoleCmd, ".", uname, "", "teller", branch) == 0
    check "teller" in roleCodesOfUser(db, uid)
    check runCtl(assignRoleCmd, ".", uname, "", "product_checker") == 0
    check "product_checker" in roleCodesOfUser(db, uid)
    # Granting the same role+branch again is a no-op, not an error code 0.
    check runCtl(assignRoleCmd, ".", uname, "", "teller", branch) == 3
    # Audit carries username/role/branch.
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'user.role_grant' AND after_value->>'username' = ?
         AND after_value->>'role' = 'teller' AND after_value->>'branch' = ?""",
      uname, branch) == "1"

    # Revoke targets the exact branch: a different branch does not match, the asked branch does.
    check runCtl(revokeRoleCmd, ".", uname, "", "teller", other) == 3
    check runCtl(revokeRoleCmd, ".", uname, "", "teller", branch) == 0
    check "teller" notin roleCodesOfUser(db, uid)
    check runCtl(revokeRoleCmd, ".", uname, "", "product_checker") == 0
    check roleCodesOfUser(db, uid).len == 0
    # Revoking something not held is rejected (not silently successful).
    check runCtl(revokeRoleCmd, ".", uname, "", "teller", branch) == 3
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'user.role_revoke' AND after_value->>'username' = ?""", uname) == "2"

  test "ctl post-opening-balance: satu jurnal saldo awal, idempoten, audit (O-105)":
    check CtlUsage.contains(openingBalanceCmd)
    # Argumen kurang / nominal nol / tanggal tidak sah = 2 (salah pakai), bukan 3.
    check runCtl(openingBalanceCmd, ".") == 2
    let branch = "b0000000-0000-4000-8000-000000000001"
    let uname = "itapi-opener-" & $newId(systemClock())
    check runCtl(createUserCmd, ".", username = uname, userRole = "ops_admin",
      fullName = "Uji Opener") == 0
    check runCtl(openingBalanceCmd, ".", username = uname, branchId = branch,
      amount = "0.0000", businessDate = "2026-02-15") == 2
    check runCtl(openingBalanceCmd, ".", username = uname, branchId = branch,
      amount = "1234.0000", businessDate = "2026-13-01") == 2

    # Periode OPEN untuk tanggal uji (idempoten; suite lain bisa saja sudah punya).
    discard db.execAffectedRows(sql"""
      INSERT INTO platform.branch (branch_id, code, name)
      VALUES ('b0000000-0000-4000-8000-000000000001', '001', 'Cabang Pilot')
      ON CONFLICT DO NOTHING""")
    discard db.execAffectedRows(sql"""
      INSERT INTO ledger.period (period_id, starts_on, ends_on, status, created_by, updated_by)
      SELECT md5('itapi-roles|opening|2026-02')::uuid, '2026-02-01'::date, '2026-02-28'::date,
             'OPEN', md5('itapi-roles|fixture')::uuid, md5('itapi-roles|fixture')::uuid
      WHERE NOT EXISTS (
        SELECT 1 FROM ledger.period
         WHERE '2026-02-15'::date BETWEEN starts_on AND ends_on)""")

    # Tanggal di luar periode OPEN = ditolak (3), tanpa jurnal.
    check runCtl(openingBalanceCmd, ".", username = uname, branchId = branch,
      amount = "1234.0000", businessDate = "2025-01-01") == 3
    check db.getValue(sql"""SELECT count(*)::text FROM ledger.journal
                             WHERE source_event = 'LedgerCashOpening'""") == "0"

    check runCtl(openingBalanceCmd, ".", username = uname, branchId = branch,
      amount = "1234.0000", businessDate = "2026-02-15") == 0
    check runCtl(openingBalanceCmd, ".", username = uname, branchId = branch,
      amount = "1234.0000", businessDate = "2026-02-15") == 0

    # Tetap **satu** jurnal: jalankan ulang tidak menambah, koreksi kelak = jurnal pembalik.
    check db.getValue(sql"""SELECT count(*)::text FROM ledger.journal
                             WHERE source_event = 'LedgerCashOpening'""") == "1"
    check db.getValue(sql"""SELECT count(*)::text FROM ledger.journal_line l
                              JOIN ledger.journal j ON j.journal_id = l.journal_id
                             WHERE j.source_event = 'LedgerCashOpening'
                               AND l.gl_account = '101.1' AND l.debit = 1234""") == "1"
    check db.getValue(sql"""SELECT count(*)::text FROM ledger.journal_line l
                              JOIN ledger.journal j ON j.journal_id = l.journal_id
                             WHERE j.source_event = 'LedgerCashOpening'
                               AND l.gl_account = '203' AND l.credit = 1234""") == "1"
    check db.getValue(sql"""SELECT count(*)::text FROM platform.audit_log
                             WHERE action = 'ledger.opening_balance'""") == "1"

  test "0035: teller tidak memegang izin vault submit/approve (K-8)":
    # Kontrak SoD: penyediaan kas (vault) terpisah dari operasi kas (laci). Migrasi yang menambah
    # kedua izin ini ke `teller` melanggar keputusan D-134 dan harus gagal di sini.
    check not roleGrantsPermission(db, "teller", "teller.vault.submit")
    check not roleGrantsPermission(db, "teller", "teller.vault.approve")
    check roleGrantsPermission(db, "cash_admin", "teller.vault.approve")

  test "ctl create-branch: kode 3 digit, unik, dan ber-audit":
    check runCtl(createBranchCmd, ".", "", "", "", "", "", "", "") == 2
    check runCtl(createBranchCmd, ".", "", "", "", "", "", "77", "Cabang Pendek") == 3
    check runCtl(createBranchCmd, ".", "", "", "", "", "", "77a", "Cabang Salah") == 3

    # Kode uji yang tidak dipakai cabang pilot/dev mana pun; dibersihkan supaya bisa dijalankan ulang.
    const testCode = "777"
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.branch WHERE code = ?", testCode)
    check branchByCode(db, testCode).isNone

    check runCtl(createBranchCmd, ".", "", "", "", "", "", testCode, "  Cabang Uji CLI  ") == 0
    let created = branchByCode(db, testCode)
    check created.isSome
    check created.get().name == "Cabang Uji CLI"
    check created.get().status == "ACTIVE"
    # Kode duplikat ditolak, bukan diam-diam menimpa cabang yang sudah ada.
    check runCtl(createBranchCmd, ".", "", "", "", "", "", testCode, "Cabang Lain") == 3
    check branchByCode(db, testCode).get().name == "Cabang Uji CLI"
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'branch.create' AND after_value->>'code' = ?""", testCode) == "1"

  test "ctl disable-user/enable-user: status and session revocation":
    let uid = $newId(systemClock())
    let uname = "itapi-disable-" & uid[0 .. 7]
    check insertUser(db, NewUser(userId: uid, username: uname, fullName: "Uji Disable",
      passwordHash: "x"))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    let nowIso = utcIso(systemClock().now())
    for i in 1 .. 2:
      check createSession(db, $newId(systemClock()), uid, "token-disable-" & uid & "-" & $i,
        nowIso, nowIso, "", "", "")
    check db.getValue(sql"""SELECT count(*) FROM platform.session
                             WHERE user_id = ?::uuid AND revoked_at IS NULL""", uid) == "2"

    check runCtl(disableUserCmd, ".", "") == 2
    check runCtl(disableUserCmd, ".", "tidak-ada") == 3
    check runCtl(disableUserCmd, ".", uname) == 0
    check userById(db, uid).get().status == "INACTIVE"
    # Every session revoked, so an offboarded account cannot keep working.
    check db.getValue(sql"""SELECT count(*) FROM platform.session
                             WHERE user_id = ?::uuid AND revoked_at IS NULL""", uid) == "0"
    check db.getValue(sql"""SELECT count(*) FROM platform.audit_log
                             WHERE action = 'user.disable' AND after_value->>'username' = ?""",
      uname) == "1"

    # Re-enable only restores INACTIVE accounts.
    check runCtl(enableUserCmd, ".", uname) == 0
    check userById(db, uid).get().status == "ACTIVE"
    check runCtl(enableUserCmd, ".", uname) == 3 # already ACTIVE
    check setUserStatus(db, uid, "SUSPENDED")
    check runCtl(enableUserCmd, ".", uname) == 3 # SUSPENDED is not silently revived
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'user.enable' AND after_value->>'username' = ?""", uname) == "1"

  test "ctl unlock-user: only LOCKED -> ACTIVE, clears failure counter":
    let uid = $newId(systemClock())
    let uname = "itapi-unlock-" & uid[0 .. 7]
    check insertUser(db, NewUser(userId: uid, username: uname, fullName: "Uji Unlock",
      passwordHash: "x"))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    # Not locked: rejected.
    check runCtl(unlockUserCmd, ".", "") == 2
    check runCtl(unlockUserCmd, ".", uname) == 3
    # Lock it the way login does (one allowed failure → LOCKED with counter and deadline set).
    discard recordLoginFailure(db, uid, 1, 30, utcIso(systemClock().now()))
    let locked = userById(db, uid).get()
    check locked.status == "LOCKED"
    check locked.failedAttempts == 1
    check locked.lockedUntil.len > 0

    check runCtl(unlockUserCmd, ".", uname) == 0
    let after = userById(db, uid).get()
    check after.status == "ACTIVE"
    check after.failedAttempts == 0
    check after.lockedUntil.len == 0
    check runCtl(unlockUserCmd, ".", uname) == 3 # no longer LOCKED
    # INACTIVE is not touched by unlock (that is enable-user's job).
    check setUserStatus(db, uid, "INACTIVE")
    check runCtl(unlockUserCmd, ".", uname) == 3
    check userById(db, uid).get().status == "INACTIVE"
    check db.getValue(sql"""
      SELECT count(*) FROM platform.audit_log
       WHERE action = 'user.unlock' AND after_value->>'username' = ?""", uname) == "1"

  test "0032: peran admin sempit — izin eksplisit & scope INSTITUTION (T-118)":
    for code in ["ops_admin", "ledger_admin", "cash_admin", "product_maker"]:
      check roleExists(db, code)
      check roleScope(db, code).get() == roleScopeInstitution
    # `ops_admin` menggantikan `platform_admin` untuk administrasi harian pengguna/anggota/rekening,
    # tetapi TIDAK memegang kas/vault atau pembalik jurnal.
    let ops = rolePermissions(db, "ops_admin")
    check "platform.user.manage" in ops
    check "deposit.account.manage" in ops
    check "teller.vault.topup" notin ops
    check "ledger.journal.reverse" notin ops
    # Yang membukukan tidak mengendalikan injeksi kas, tetapi boleh membalik jurnal.
    let ledger = rolePermissions(db, "ledger_admin")
    check "ledger.coa.manage" in ledger
    check "ledger.journal.reverse" in ledger
    check "teller.vault.topup" notin ledger
    let cash = rolePermissions(db, "cash_admin")
    check "teller.vault.topup" in cash
    check "teller.vault.read" in cash
    check "ledger.coa.manage" notin cash
    # Pembuat katalog tidak boleh menyetujui (itu tugas `product_checker`).
    let maker = rolePermissions(db, "product_maker")
    check "product.catalog.manage" in maker
    check "product.catalog.approve" notin maker
    # `platform_admin` tetap break-glass: izin manajemen pengguna tidak dicabut dari sana.
    check "platform.user.manage" in rolePermissions(db, "platform_admin")

  test "0032: pasangan SoD tersemai (kanonik a < b) & penugasan berkonflik ditolak (T-118)":
    let pairs = conflictPairs(db)
    let expected = @[
      (a: "product_checker", b: "product_maker"),
      (a: "cash_admin", b: "ledger_admin"),
      (a: "ledger_admin", b: "ops_admin"),
      (a: "ledger_admin", b: "teller"),
      (a: "cash_admin", b: "teller")]
    for pair in expected:
      check pair in pairs
    for pair in pairs:
      check pair.a < pair.b # CHECK `role_conflict_order_chk` (0006) tidak boleh dilanggar.

    let uid = $newId(systemClock())
    let uname = "itapi-sod-" & uid[0 .. 7]
    check insertUser(db, NewUser(userId: uid, username: uname, fullName: "Uji SoD",
      passwordHash: "x"))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    let ctx = newAuditContext(newId(systemClock()), systemClock())

    # maker-checker katalog produk: satu orang tidak boleh memegang keduanya.
    check grantRole(db, uid, "product_checker", "", "")
    let makerRes = grantUserRole(db, ctx, systemClock(), institutionScope(), userById(db, uid).get(),
      "product_maker", "")
    check makerRes.outcome == uaoRejected
    check makerRes.reason == "sod_conflict"
    check "product_maker" notin roleCodesOfUser(db, uid)

    # yang membukukan tidak boleh mengendalikan injeksi kas.
    check grantRole(db, uid, "ledger_admin", "", "")
    let cashRes = grantUserRole(db, ctx, systemClock(), institutionScope(), userById(db, uid).get(),
      "cash_admin", "")
    check cashRes.outcome == uaoRejected
    check cashRes.reason == "sod_conflict"
    check "cash_admin" notin roleCodesOfUser(db, uid)

  test "penjaga pengelola terakhir: berbasis izin platform.user.manage (T-118, K-7)":
    # Deterministik apa pun yang ditinggalkan suite lain: park SEMUA grant yang membuat pemegangnya
    # mampu mengelola pengguna (`platform_admin` maupun `ops_admin`), pulihkan sesudahnya.
    var parked: seq[tuple[userId, roleCode, branchId: string]]
    for row in db.getAllRows(sql"""
      SELECT DISTINCT ur.user_id::text, r.code, coalesce(ur.branch_id, '')
        FROM platform.user_role ur
        JOIN platform.role r ON r.role_id = ur.role_id
        JOIN platform.role_permission rp ON rp.role_id = r.role_id
        JOIN platform.permission p ON p.permission_id = rp.permission_id
       WHERE p.code = 'platform.user.manage'"""):
      parked.add (row[0], row[1], row[2])
    for (uid, roleCode, branchId) in parked:
      discard revokeRole(db, uid, roleCode, branchId)
    defer:
      for (uid, roleCode, branchId) in parked:
        discard db.execAffectedRows(sql"""
          INSERT INTO platform.user_role (user_id, role_id, branch_id)
          SELECT ?::uuid, r.role_id, NULLIF(?, '')::uuid
            FROM platform.role r WHERE r.code = ?
          ON CONFLICT DO NOTHING""", uid, branchId, roleCode)

    # Satu-satunya pengelola memakai `ops_admin`, bukan `platform_admin`: membuktikan penjaganya
    # mengikuti izin, bukan kode role.
    let uid = $newId(systemClock())
    let uname = "itapi-lastmanager-" & uid[0 .. 7]
    check insertUser(db, NewUser(userId: uid, username: uname, fullName: "Uji Pengelola Terakhir",
      passwordHash: "x"))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    check grantRole(db, uid, "ops_admin", "", "")
    check countActiveUsersWithPermission(db, "platform.user.manage") == 1

    # Mencabut role pengelola terakhir dan menonaktifkannya sama-sama satu pintu keluar.
    check runCtl(revokeRoleCmd, ".", uname, "", "ops_admin") == 3
    check "ops_admin" in roleCodesOfUser(db, uid)
    check runCtl(disableUserCmd, ".", uname) == 3
    check userById(db, uid).get().status == "ACTIVE"

    # Dengan pengelola kedua (akun lain), pencabutan yang menyisakan pengelola diizinkan.
    let uid2 = $newId(systemClock())
    check insertUser(db, NewUser(userId: uid2, username: "itapi-lastmanager2-" & uid2[0 .. 7],
      fullName: "Uji Pengelola Kedua", passwordHash: "x"))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid2)
    check grantRole(db, uid2, bootstrapAdminRole, "", "")
    check countActiveUsersWithPermission(db, "platform.user.manage") == 2
    check runCtl(revokeRoleCmd, ".", uname, "", "ops_admin") == 0
    check runCtl(disableUserCmd, ".", uname) == 0

  test "withRoleDb(useTx = true): kegagalan di tengah membatalkan seluruh tulisan":
    # Bootstrap menulis tiga hal (pengguna, role, audit). Kalau salah satunya gagal dan transaksinya
    # tidak membatalkan yang lain, yang tersisa adalah pengguna setengah jadi tanpa role — dan itu
    # membuat namanya terpakai selamanya tanpa bisa dipakai bekerja.
    let uid = $newId(systemClock())
    let code = withRoleDb(proc(db: DbConn): int {.closure.} =
      discard insertUser(db, NewUser(userId: uid, username: "itapi-rollback",
        fullName: "Uji Rollback", passwordHash: "x"))
      # Sengaja gagal setelah tulisan pertama: pembagian dengan nol → `DbError`.
      discard db.getValue(sql"select (1/0)::int")
      0, useTx = true)
    check code == 1
    check db.getValue(sql"select count(*) from platform.app_user where user_id = ?::uuid",
      uid) == "0"

  test "tanpa useTx, koneksi perintah tidak membuka transaksi (perilaku lama tetap)":
    # Penjagaan untuk perubahan di atas: perintah read-only tidak perlu (dan tidak boleh dipaksa)
    # berjalan dalam transaksi — kalau kelak `useTx` dibalik jadi default, test ini gagal.
    let uid = $newId(systemClock())
    check withRoleDb(proc(db: DbConn): int {.closure.} =
      discard insertUser(db, NewUser(userId: uid, username: "itapi-no-tx",
        fullName: "Uji Tanpa Tx", passwordHash: "x"))
      0) == 0
    check db.getValue(sql"select count(*) from platform.app_user where user_id = ?::uuid",
      uid) == "1"
    discard db.execAffectedRows(sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)

  test "migrate idempoten: jalan pertama & kedua → 0, jalan kedua tidak menerapkan apa pun":
    check runMigrate(".") == 0
    check runMigrate(".") == 0
    check runMigrate(".", "--up") == 0
    check applyAllMigrations(db, ".").applied.len == 0

  test "ctl reset-password: hash baru, wajib ganti, sesi dicabut, audit, lockout pulih (O-071)":
    let uid = $newId(systemClock())
    let uname = "itapi-reset-" & uid[0 .. 7]
    check insertUser(db, NewUser(userId: uid, username: uname,
      fullName: "Uji Reset", passwordHash: $hashPassword("sandi-lama-123", 1000)))
    defer: discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uid)
    # Skenario nyata pemicu reset: akun terkunci + ada sesi aktif di beberapa perangkat.
    check setUserStatus(db, uid, "LOCKED")
    let nowIso = utcIso(systemClock().now())
    for i in 1 .. 2:
      check createSession(db, $newId(systemClock()), uid, "token-reset-" & uid & "-" & $i,
        nowIso, nowIso, "", "", "")
    let setelan = settingsOf(db, institutionScope(), nowIso[0 .. 9])

    let r = resetUserPassword(db, uname, systemClock())
    check r.code == 0
    check r.password.len >= 12
    let sesudah = userById(db, uid).get()
    check sesudah.status == "ACTIVE" # LOCKED tidak boleh terkunci permanen
    check sesudah.mustChangePassword
    check sesudah.failedAttempts == 0
    check sesudah.lockedUntil.len == 0
    check verifyPassword(r.password, sesudah.passwordHash)
    check not verifyPassword("sandi-lama-123", sesudah.passwordHash)
    check sesudah.passwordHash.split('$')[1] == $setelan.pbkdf2Iterations
    check db.getValue(sql"""select count(*) from platform.session
                             where user_id = ?::uuid and revoked_at is null""", uid) == "0"
    check db.getValue(sql"""select count(*) from platform.user_password_history
                             where user_id = ?::uuid""", uid) == "1"
    check verifyPassword("sandi-lama-123", db.getValue(
      sql"""select password_hash from platform.user_password_history
             where user_id = ?::uuid""", uid))
    check db.getValue(sql"""select after_value->>'must_change_password'
                              from platform.audit_log
                             where action = 'user.password_reset' and resource_id = ?""",
      uid) == "true"
    # Status yang sengaja dinonaktifkan tidak ikut diaktifkan oleh reset.
    let uidNonaktif = $newId(systemClock())
    let unameNonaktif = "itapi-reset-off-" & uidNonaktif[0 .. 7]
    check insertUser(db, NewUser(userId: uidNonaktif, username: unameNonaktif,
      fullName: "Uji Reset Nonaktif", passwordHash: $hashPassword("sandi-lama-123", 1000)))
    check setUserStatus(db, uidNonaktif, "INACTIVE")
    check resetUserPassword(db, unameNonaktif, systemClock()).code == 0
    check userById(db, uidNonaktif).get().status == "INACTIVE"
    discard db.execAffectedRows(
      sql"DELETE FROM platform.app_user WHERE user_id = ?::uuid", uidNonaktif)

    # Kontrak CLI (tanpa menyentuh akun nyata): argumen kurang = 2, pengguna tidak ada = 3.
    check runCtl(resetPasswordCmd, ".", "") == 2
    check runCtl(resetPasswordCmd, ".", "tidak-ada") == 3

  test "denyut worker: tulis, usia, throttle, isolasi nama, hitung DEAD (O-081)":
    let wname = "it-denyut-" & $newId(systemClock())
    let wnameLain = "it-denyut-lain-" & $newId(systemClock())
    defer:
      discard db.execAffectedRows(sql"""
        DELETE FROM platform.worker_heartbeat WHERE worker_name IN (?, ?)""", wname, wnameLain)
    check workerHeartbeatAgeSeconds(db, wname) == -1
    check touchWorkerHeartbeat(db, wname)
    check workerHeartbeatAgeSeconds(db, wname) >= 0
    # Baris worker lain yang basi tidak boleh memengaruhi usia worker ini (WHERE tidak boleh hilang).
    check touchWorkerHeartbeat(db, wnameLain)
    discard db.execAffectedRows(sql"""
      UPDATE platform.worker_heartbeat SET last_seen_at = now() - interval '1 hour'
       WHERE worker_name = ?""", wnameLain)
    check workerHeartbeatAgeSeconds(db, wname) < 60
    check workerHeartbeatAgeSeconds(db, wnameLain) >= 3500
    # Putaran berikutnya dalam <15 detik tidak menulis ulang (throttle).
    check not touchWorkerHeartbeat(db, wname)
    # Denyut yang sudah basi ditulis ulang.
    discard db.execAffectedRows(sql"""
      UPDATE platform.worker_heartbeat SET last_seen_at = now() - interval '1 minute'
       WHERE worker_name = ?""", wname)
    check touchWorkerHeartbeat(db, wname)
    check workerHeartbeatAgeSeconds(db, wname) <= 5
    # Jam mundur/NTP: denyut di masa depan tidak boleh terbaca sebagai "belum pernah melapor".
    discard db.execAffectedRows(sql"""
      UPDATE platform.worker_heartbeat SET last_seen_at = now() + interval '1 hour'
       WHERE worker_name = ?""", wname)
    check workerHeartbeatAgeSeconds(db, wname) == 0
    check deadEventCount(db) >= 0

  test "migrate --seed: menulis ulang nilai hilang, tanpa seed dev (O-090)":
    # Selektor: hanya pack generated; seed dev/test (`packs/*/seed/`) tidak boleh ikut.
    # Dipaku pada fungsi yang dipakai `--seed` (bukan `seedFiles` langsung), supaya mutasi
    # `dev = true` di jalur produksi membuat test ini gagal.
    for f in seedBaseFiles("."):
      check "/seed/" notin f
    var adaDev = false
    for f in seedFiles(".", dev = true):
      if "/seed/" in f:
        adaDev = true
    check adaDev

    # Bukti menulis: hapus satu nilai seed deterministik, lalu `--seed` harus mengembalikannya.
    # (Tanpa langkah ini, test bisa hijau walau subperintah `--seed` tidak melakukan apa pun.)
    let seedId = db.getValue(sql"select md5('ledger.posting.batch_size|base')")
    discard db.execAffectedRows(
      sql"DELETE FROM platform.param_value WHERE param_value_id = ?::uuid", seedId)
    # Kembalikan baris apa pun hasil assertion berikut (mis. EXCLUDE karena DB dev punya ACTIVE
    # non-seed untuk key ini), supaya kegagalan tidak meninggalkan DB tanpa nilai posting.
    defer: discard runMigrate(".", "--seed")
    check db.getValue(
      sql"select count(*) from platform.param_value where param_value_id = ?::uuid", seedId) == "0"
    check runMigrate(".", "--seed") == 0
    check db.getValue(
      sql"select value::text from platform.param_value where param_value_id = ?::uuid", seedId) == "50"
    check db.getValue(
      sql"select status from platform.param_value where param_value_id = ?::uuid", seedId) == "ACTIVE"
    check db.getValue(
      sql"select count(*) from platform.param_value where key = 'ledger.posting.batch_size' and status = 'ACTIVE'") == "1"
    # Idempoten: jalan kedua tidak menggandakan baris ACTIVE.
    check runMigrate(".", "--seed") == 0
    check db.getValue(
      sql"select count(*) from platform.param_value where key = 'ledger.posting.batch_size' and status = 'ACTIVE'") == "1"

  test "migrate --check (read-only): 0 saat tidak ada yang tertunda atau berubah isinya":
    check runMigrate(".", "--check") == 0

  test "`--up` menolak migrasi bertanda destruktif yang belum diterapkan (O-048)":
    let status = @[
      MigrationStatus(migration: Migration(id: "0001_ok", seq: 1, destructive: false),
        applied: false),
      MigrationStatus(migration: Migration(id: "0002_drop", seq: 2, destructive: true),
        applied: true), # sudah diterapkan: bukan urusan `--up`
      MigrationStatus(migration: Migration(id: "0003_drop", seq: 3, destructive: true),
        applied: false)]
    check destructivePending(status) == @["0003_drop"]
    check destructivePending(@[]).len == 0
    # Di repo ini belum ada migrasi berpenanda destruktif, jadi `--up` tetap jalan.
    check runMigrate(".", "--up") == 0

  test "migrate --contract/--down: kode keluar 0 / 2 / 3 sesuai kontrak (T-035)":
    # Root sintetis: seluruh modul disalin seperti root repo, lalu ditambah satu berkas contract.
    # Migrasi nyata sudah diterapkan test sebelumnya di suite ini, jadi yang baru hanya berkas ini.
    let root = ".build/itapi-roles/dua-tahap"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    copyDir("modules", root / "modules")

    let nama = "0900_probe_cli"
    let id = "platform/" & nama
    let berkas = root / "modules" / "platform" / "migrations" / (nama & ".sql")
    let pasangan = root / "modules" / "platform" / "migrations" / (nama & ".down.sql")
    writeFile(berkas, "-- dbtools:contract uji kode keluar CLI (sintetis)\n" &
      "CREATE TABLE platform.probe_cli (id int);\n")
    writeFile(pasangan, "DROP TABLE platform.probe_cli;\n")
    # Bersihkan sisa nama ini bila ada (uji lain/mutasi bisa meninggalkannya): tanpa ini uji hanya
    # benar sekali, dan itu membuat hasil ulangnya menyesatkan.
    execScript(db, "DROP TABLE IF EXISTS platform.probe_cli;")
    discard db.execAffectedRows(
      sql"DELETE FROM platform.schema_migration WHERE migration_id = ?", id)

    # Gate `--check` tidak boleh merah hanya karena ada berkas contract menunggu keputusan operator.
    check runMigrate(root, "--check") == 0
    # Jalur expand melewatinya: tidak diterapkan, jadi tabelnya belum ada.
    check runMigrate(root, "--up") == 0
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NULL)::text") == "true"

    check runMigrate(root, "--contract") == 0
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NOT NULL)::text") == "true"
    check runMigrate(root, "--contract") == 0 # idempoten
    check runMigrate(root, "--up") == 0 # expand tetap tidak menyentuh berkas contract

    # Keadaan membahayakan → 3 (dikenali tetapi ditolak), salah pakai → 2. Tidak ada yang ditebak.
    check runMigrate(root, "--down") == 3
    check runMigrate(root, "--down", "0") == 3
    check runMigrate(root, "--down", "abc") == 2
    check runMigrate(root, "--down", "99") == 3

    # Pasangan rollback hilang: ditolak **sebelum** ada tulisan apa pun.
    removeFile(pasangan)
    check runMigrate(root, "--down", "1") == 3
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NOT NULL)::text") == "true"

    # Dipulihkan: pasangan dikembalikan, rollback jalan, dan DB kembali seperti sebelum uji.
    writeFile(pasangan, "DROP TABLE platform.probe_cli;\n")
    check runMigrate(root, "--down", "1") == 0
    check db.getValue(sql"SELECT (to_regclass('platform.probe_cli') IS NULL)::text") == "true"
    check db.getValue(
      sql"SELECT count(*) FROM platform.schema_migration WHERE migration_id = ?", id) == "0"
