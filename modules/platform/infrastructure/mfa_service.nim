## Layanan MFA TOTP (T-046, spec §13/§18.2). **HUMAN-REVIEW-REQUIRED (kripto/autentikasi)**.
##
## Dua lapis kebijakan, sengaja terpisah:
##   * `platform.security.mfa.enabled` = layanan MFA hidup (rute pendaftaran bisa dipakai);
##   * `platform.security.mfa.require_login` = faktor kedua **wajib** saat login untuk akun yang
##     sudah punya faktor `ACTIVE` (O-071). Kebijakan ini dibaca `authenticate` lewat
##     `mfaRequireLogin`; berkas ini menyediakan jalur verifikasi sesi-setengahnya
##     (`verifyLoginChallenge`). Kewajiban itu terpisah supaya institusi bisa membuka pendaftaran
##     lebih dulu tanpa langsung mengunci pengguna yang belum mendaftar.
##
## Semua angka (digit, periode, toleransi jam, penerbit) dari parameter DB lewat `mfaSettingsOf`.
## Bentuk rahasia (digit/periode) **disimpan per pendaftaran** dan dipakai saat verifikasi, bukan
## dibaca ulang dari parameter: mengubah parameter hanya memengaruhi pendaftaran baru.

import std/[json, options, times]

import db_connector/db_postgres

import "platform-lib/crypto/fieldcrypto"
import "platform-lib/crypto/totp"

import ../domain/[audit, scope]
import ./[audit_repo, auth_service, mfa_repo, param_repo]
import kernel/[auditcontext, clock, paramkey]
import kernel/generated/paramkeys

const
  ## AAD/nama tabel untuk field crypto. Harus sama dengan nama tabel di migrasi `0012`: ciphertext
  ## terikat ke nama ini, jadi tidak bisa dipindah ke tabel lain tanpa didekripsi ulang.
  mfaTableName* = "user_mfa"

type
  MfaSettings* = object
    enabled*: bool
    issuer*: string
    digits*: int
    periodSeconds*: int
    driftSteps*: int

  MfaStatus* = enum
    msNone = "NONE"       ## belum pernah mendaftar
    msPending = "PENDING" ## rahasia ada, belum dikonfirmasi kode
    msActive = "ACTIVE"   ## terkonfirmasi

  MfaEnrolment* = object
    secret*: string ## rahasia base32; **hanya** dikembalikan di respons ini
    otpauthUri*: string
    digits*: int
    periodSeconds*: int

  MfaEnrolOutcome* = enum
    meoStarted
    meoAlreadyActive

  MfaVerifyOutcome* = enum
    mvoActivated
    mvoInvalidCode
    mvoNoPending

  MfaLoginOutcome* = enum
    ## Hasil verifikasi kode pada sesi **setengah** (login, O-071).
    mloVerified = "VERIFIED"
    mloInvalidCode = "INVALID_CODE" ## termasuk kode yang sudah pernah dipakai (anti-replay)
    mloNoActiveFactor = "NO_ACTIVE_FACTOR"

  MfaDataError* = object of CatchableError
    ## Rahasia tersimpan tidak bisa dipakai (ciphertext rusak / bukan base32). Ini keadaan data,
    ## bukan kesalahan pengguna: pemanggil HTTP menjawab 500.

proc mfaEnabledFlag(db: DbConn, scope: ScopeRef, asOf: string): bool =
  ## Saklar layanan MFA. Fail-closed ke **mati** bila nilainya belum ada (`activeValueOpt`, bukan
  ## `activeValueJson`): instalasi baru — atau produksi yang seed parameter MFA-nya belum dijalankan
  ## — harus menjawab 403 `mfa_disabled`, bukan galat 500. Nilai non-bool = kebijakan rusak
  ## (`ValueError`), bukan diam-diam dianggap mati.
  let enabled = db.activeValueOpt(keyString(P_platform_security_mfa_enabled), asOf, lookupFor(scope))
  if enabled.isNone:
    return false
  if enabled.get().kind != JBool:
    raise newException(ValueError, "parameter mfa.enabled bukan boolean: " & $enabled.get())
  enabled.get().getBool

proc mfaRequireLogin*(db: DbConn, scope: ScopeRef, asOf: string): bool =
  ## Kewajiban faktor kedua saat login (O-071). Fail-closed ke **mati** bila nilainya belum
  ## tersemai, pola yang sama dengan `mfa.enabled`: instalasi yang belum menyemai parameter baru
  ## ini tidak boleh berubah perilaku loginnya.
  ##
  ## Kewajiban **hanya berlaku bila layanan MFA hidup**. Tanpa itu tidak ada rute yang bisa
  ## memverifikasi kode (`mfa_disabled`), sehingga sesi setengah tidak akan pernah bisa dinaikkan
  ## dan setiap akun berfaktor terkunci permanen. Kombinasi `require_login` tanpa `mfa.enabled`
  ## karena itu dibaca sebagai "MFA mati", bukan sebagai kunci — dan mematikan layanan MFA memang
  ## mematikan seluruh kebijakan MFA, bukan hanya rute pendaftaran.
  if not db.mfaEnabledFlag(scope, asOf):
    return false
  let value = db.activeValueOpt(
    keyString(P_platform_security_mfa_require_login), asOf, lookupFor(scope))
  if value.isNone:
    return false
  if value.get().kind != JBool:
    raise newException(ValueError,
      "parameter mfa.require_login bukan boolean: " & $value.get())
  value.get().getBool

proc mfaSettingsOf*(db: DbConn, scope: ScopeRef, asOf: string): MfaSettings =
  ## Kebijakan MFA institusi. Dipisahkan dari `settingsOf` (login) supaya login tidak ikut
  ## bergantung pada nilai parameter MFA: bila nilai ini belum tersemai, hanya rute MFA yang menolak.
  ##
  ## Saklarnya fail-closed ke **mati** (`mfaEnabledFlag`). Nilai lain dibaca **hanya** saat
  ## saklarnya hidup, sehingga kebijakan yang setengah tersemai tetap gagal keras alih-alih memakai
  ## bentuk kode yang tak pernah diputuskan siapa pun.
  let lookup = lookupFor(scope)
  if not db.mfaEnabledFlag(scope, asOf):
    return MfaSettings(enabled: false)
  let issuer = db.activeValueJson(keyString(P_platform_security_mfa_issuer), asOf, lookup)
  if issuer.kind != JString:
    raise newException(ValueError, "parameter mfa.issuer bukan string: " & $issuer)
  MfaSettings(
    enabled: true,
    issuer: issuer.getStr,
    digits: db.activeParamInt(keyString(P_platform_security_mfa_digits), asOf, lookup),
    periodSeconds: db.activeParamInt(
      keyString(P_platform_security_mfa_period_seconds), asOf, lookup),
    driftSteps: db.activeParamInt(keyString(P_platform_security_mfa_drift_steps), asOf, lookup))

proc mfaStatusOf*(db: DbConn, userId: string): MfaStatus =
  ## Status pendaftaran akun; tidak mendekripsi rahasia (hanya membaca status).
  let found = mfaOf(db, userId)
  if found.isNone:
    return msNone
  if found.get().status == "ACTIVE":
    return msActive
  msPending

proc auditMfa(db: DbConn, ctx: AuditContext, clock: Clock, scope: ScopeRef,
              action, userId: string, payload: JsonNode) =
  discard appendAudit(db, newAuditEntry(ctx, action, "app_user", userId, clock,
    businessDate = businessDateFor(db, scope, utcIso(clock.now())), after = payload))

proc startEnrolment*(db: DbConn, fc: FieldCrypto, ctx: AuditContext, clock: Clock,
                     scope: ScopeRef, settings: MfaSettings,
                     userId, username: string): tuple[outcome: MfaEnrolOutcome,
                                                      enrolment: MfaEnrolment] =
  ## Membuat (atau mengganti) pendaftaran PENDING dan mengembalikan rahasia sekali.
  ##
  ## Faktor yang sudah ACTIVE tidak diganti di sini: mengganti rahasia faktor aktif adalah operasi
  ## pemulihan yang butuh jalur sendiri (O-071), bukan efek samping enrolment biasa.
  let existing = mfaOf(db, userId)
  if existing.isSome and existing.get().status == "ACTIVE":
    return (meoAlreadyActive, MfaEnrolment())

  let secret = newTotpSecret()
  let nowIso = utcIso(clock.now())
  # `encryptField` melempar `NotConfiguredError` bila `KRAN_KEK_FILE` kosong — dibiarkan menembus
  # supaya pemanggil menjawab galat konfigurasi yang jelas, bukan menyimpan rahasia plaintext.
  let encrypted = encryptField(fc, mfaTableName, secret)
  if not upsertPending(db, userId, encrypted, settings.digits, settings.periodSeconds, nowIso):
    # Balapan: permintaan lain mengaktifkan faktor di antara pembacaan dan penulisan.
    return (meoAlreadyActive, MfaEnrolment())

  # Audit hanya memuat bentuk pendaftaran; rahasia/kode tidak pernah masuk jejak audit.
  auditMfa(db, ctx, clock, scope, "auth.mfa.enrol", userId,
    %*{"status": "PENDING", "digits": settings.digits,
       "period_seconds": settings.periodSeconds})
  (meoStarted, MfaEnrolment(
    secret: secret,
    otpauthUri: otpauthUri(settings.issuer, username, secret, settings.digits,
      settings.periodSeconds),
    digits: settings.digits,
    periodSeconds: settings.periodSeconds))

proc confirmEnrolment*(db: DbConn, fc: FieldCrypto, ctx: AuditContext, clock: Clock,
                       scope: ScopeRef, settings: MfaSettings,
                       userId, code: string): MfaVerifyOutcome =
  ## Memverifikasi satu kode terhadap pendaftaran PENDING; kode benar → ACTIVE.
  ##
  ## Digit/periode dibaca dari **baris pendaftaran**, bukan dari `settings`: rahasia didaftarkan
  ## dengan bentuk itu, dan parameter yang berubah tidak boleh membuat kode yang sah berhenti cocok.
  ## `settings.driftSteps` tetap dari parameter karena itu toleransi jam, bukan bentuk rahasia.
  let found = mfaOf(db, userId)
  if found.isNone or found.get().status != "PENDING":
    return mvoNoPending
  let row = found.get()

  var secret: seq[byte]
  try:
    secret = base32Decode(decryptField(fc, mfaTableName, row.secretEnc))
  except DecryptError:
    raise newException(MfaDataError, "rahasia MFA tersimpan tidak bisa didekripsi")
  except ValueError:
    raise newException(MfaDataError, "rahasia MFA tersimpan bukan base32 yang sah")

  let now = clock.now()
  let matched = verifyTotp(secret, code, now.toTime.toUnix, row.periodSeconds, row.digits,
    settings.driftSteps)
  if matched.isNone:
    auditMfa(db, ctx, clock, scope, "auth.mfa.verify_failure", userId,
      %*{"reason": "invalid_code"})
    return mvoInvalidCode

  if not activateMfa(db, userId, matched.get(), utcIso(now)):
    # Baris berubah di tengah jalan (dihapus/diaktifkan permintaan lain): jawab konflik yang sama
    # seperti "belum ada pendaftaran" — jangan menulis audit sukses untuk keadaan yang tidak terjadi.
    return mvoNoPending

  auditMfa(db, ctx, clock, scope, "auth.mfa.verify", userId,
    %*{"status": "ACTIVE", "digits": row.digits, "period_seconds": row.periodSeconds})
  mvoActivated

proc verifyLoginChallenge*(db: DbConn, fc: FieldCrypto, ctx: AuditContext, clock: Clock,
                           scope: ScopeRef, settings: MfaSettings,
                           userId, code: string): MfaLoginOutcome =
  ## Memverifikasi kode pada sesi **setengah** (login, O-071). Berbeda dengan `confirmEnrolment`:
  ## status tidak berubah (sudah `ACTIVE`), dan langkah waktu yang berhasil dipakai **dicatat**
  ## (`recordUsedStep`, RFC 6238 §5.2) supaya satu kode tidak bisa membuka dua sesi.
  ##
  ## Digit/periode tetap dari baris pendaftaran; `settings.driftSteps` dari parameter (toleransi
  ## jam, bukan bentuk rahasia).
  ##
  ## Batas yang disengaja: tidak ada pembatas jumlah percobaan kode dan tidak ada kode pemulihan.
  ## Keduanya sisa pekerjaan O-071 yang dicatat, bukan sesuatu yang dianggap selesai di sini.
  ## Akibat yang diterima: penebak kode dibatasi hanya oleh rentang langkah TOTP + laju request.
  let found = mfaOf(db, userId)
  if found.isNone or found.get().status != "ACTIVE":
    return mloNoActiveFactor
  let row = found.get()

  var secret: seq[byte]
  try:
    secret = base32Decode(decryptField(fc, mfaTableName, row.secretEnc))
  except DecryptError:
    raise newException(MfaDataError, "rahasia MFA tersimpan tidak bisa didekripsi")
  except ValueError:
    raise newException(MfaDataError, "rahasia MFA tersimpan bukan base32 yang sah")

  let now = clock.now()
  let matched = verifyTotp(secret, code, now.toTime.toUnix, row.periodSeconds, row.digits,
    settings.driftSteps)
  if matched.isNone:
    auditMfa(db, ctx, clock, scope, "auth.mfa.login_failure", userId,
      %*{"reason": "invalid_code"})
    return mloInvalidCode

  if not recordUsedStep(db, userId, matched.get(), utcIso(now)):
    # Langkah ini sudah pernah dipakai: kode yang sama tidak boleh membuka sesi kedua. Dijawab
    # sama seperti kode salah — bedanya hanya di audit, supaya penebak tidak bisa menyimpulkan
    # status langkah dari respons.
    auditMfa(db, ctx, clock, scope, "auth.mfa.login_failure", userId,
      %*{"reason": "code_replayed"})
    return mloInvalidCode

  auditMfa(db, ctx, clock, scope, "auth.mfa.login", userId, %*{"status": "ACTIVE"})
  mloVerified
