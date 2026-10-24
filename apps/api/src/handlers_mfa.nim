## Handler REST MFA TOTP (T-046, spec §13). **HUMAN-REVIEW-REQUIRED (autentikasi)**.
##
## Ketiga rute di sini **self-service**: faktornya milik pemilik sesi, jadi tidak ada izin baru —
## pola yang sama dengan `POST /api/v1/auth/password`. Saklar fitur
## `platform.security.mfa.enabled` bernilai **default `false`**: selama itu, ketiga rute menjawab
## 403 `mfa_disabled` — termasuk di instalasi tanpa `KRAN_KEK_FILE`, karena gerbang fitur diperiksa
## lebih dulu dan tidak ada jalur yang menyentuh rahasia/kripto saat fitur mati.
##
## **Alur login tidak berubah di task ini** — MFA belum diminta saat login (D-046 butir 9). Yang
## tersedia hanya pendaftaran + pembuktian satu kode.
##
## Respons **selalu** ditulis setelah transaksi selesai (bukan dari dalam closure `withDbTx`):
## COMMIT yang gagal setelah respons terkirim akan mengirim respons kedua di koneksi yang sama.
##
## Pesan untuk pengguna tidak ditulis dalam bahasa apa pun di sini: klien memakai `i18nKey` +
## `params.reason` dari amplop Problem (spec §16).

import std/[json, options]

import mummy
import db_connector/db_postgres

import platform/domain/scope
import platform/infrastructure/mfa_service
import "platform-lib/crypto/fieldcrypto"
import "platform-lib/crypto/totp"
import kernel/[auditcontext, clock, ids, result]

import ./access
import ./context
import ./db_bridge
import ./http_util
import ./identity
import ./problem

const
  ## Nama field badan permintaan (kontrak OpenAPI) di satu tempat supaya handler, test, dan
  ## kontrak tidak menebak bentuk JSON.
  fieldCode* = "code"

proc respondMfaDisabled(req: Request) =
  req.respondProblem(newProblem(pkForbidden, "Forbidden", "MFA belum diaktifkan",
    traceId = traceIdFrom(req), params = @[("reason", "mfa_disabled")]))

proc respondSecretJson(req: Request, status: int, body: JsonNode) =
  ## Respons yang memuat rahasia TOTP (kredensial berumur panjang) tidak boleh disimpan cache
  ## perantara maupun peramban.
  var headers = headersWithType(ContentTypeJson)
  headers["Cache-Control"] = "no-store"
  headers["Pragma"] = "no-cache"
  req.respondRaw(status, headers, $body)

proc mfaGate(db: DbConn, clock: Clock, settings: var MfaSettings, broken: var string): bool =
  ## `true` = fitur hidup dan `settings` terisi.
  ##
  ## Tidak menulis respons apa pun: pemanggil menjawab **setelah** transaksinya selesai. Gerbangnya
  ## sendiri murni pembacaan parameter — tidak menyentuh kripto — sehingga fitur mati selalu berakhir
  ## 403 `mfa_disabled`, juga di instalasi tanpa `KRAN_KEK_FILE`.
  try:
    settings = mfaSettingsOf(db, institutionScope(), businessDateIso(clock))
  except ValueError as e:
    broken = e.msg
    return false
  settings.enabled

proc handleMfaStatus*(app: AppContext, req: Request) {.gcsafe.} =
  ## `GET /api/v1/auth/mfa` — status pendaftaran akun pemanggil.
  ##
  ## Rute ini tidak memerlukan kripto: ia hanya membaca status, jadi tetap berfungsi di instalasi
  ## tanpa keyring selama fiturnya hidup.
  if app.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi (KRAN_DATABASE_URL kosong saat start)")
    return
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  let p = principal.get()

  var settings: MfaSettings
  var gateLive = false
  var broken = ""
  var status = msNone
  try:
    withDbConn(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        gateLive = mfaGate(db, app.clock, settings, broken)
        if gateLive:
          status = mfaStatusOf(db, p.user.userId))
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "status MFA gagal diproses")
    return

  if broken.len > 0:
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan tidak sah: " & broken)
    return
  if not gateLive:
    respondMfaDisabled(req)
    return

  req.respondJson(200, %*{"featureEnabled": settings.enabled, "status": $status})

proc handleMfaEnrolment*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/auth/mfa/enrolment` — mulai (atau ulangi) pendaftaran; rahasia dikembalikan
  ## **sekali** di sini dan tidak pernah bisa dibaca lagi setelahnya.
  if app.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi (KRAN_DATABASE_URL kosong saat start)")
    return
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  let p = principal.get()

  var settings: MfaSettings
  var gateLive = false
  var broken = ""
  var outcome = meoStarted
  var enrolment: MfaEnrolment
  try:
    # Satu transaksi: baris pendaftaran + audit harus lahir bersama.
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        gateLive = mfaGate(db, app.clock, settings, broken)
        if gateLive:
          let ctx = newAuditContext(parseId(p.user.userId).value(), ip = clientIp(req),
            device = deviceOf(req), reason = "daftar MFA",
            correlationId = traceIdFrom(req), startedAt = app.clock.now())
          (outcome, enrolment) = startEnrolment(db, app.fieldCrypto, ctx, app.clock,
            institutionScope(), settings, p.user.userId, p.user.username))
  except NotConfiguredError:
    # Rahasia TOTP tidak boleh disimpan tanpa enkripsi: tanpa keyring, rutenya menolak eksplisit
    # (fail-closed) alih-alih menulis plaintext. Urutannya **setelah** gerbang fitur, jadi fitur
    # yang mati tetap menjawab 403 dan status konfigurasi server tidak terbaca dari bedanya.
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "enkripsi field belum dikonfigurasi (" & envVarKekFile & " kosong saat start)")
    return
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "pendaftaran MFA gagal diproses")
    return
  except TotpError as e:
    # Bentuk rahasia dari parameter di luar rentang yang didukung (`mfa.digits`/`mfa.period_seconds`).
    req.respondProblem(pkInternal, "Internal Server Error",
      "bentuk kode MFA tidak sah: " & e.msg)
    return
  except ValueError as e:
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan tidak sah: " & e.msg)
    return

  if broken.len > 0:
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan tidak sah: " & broken)
    return
  if not gateLive:
    respondMfaDisabled(req)
    return

  case outcome
  of meoAlreadyActive:
    req.respondProblem(newProblem(pkConflict, "Conflict", "MFA sudah aktif",
      traceId = traceIdFrom(req), params = @[("reason", "mfa_already_active")]))
  of meoStarted:
    req.respondSecretJson(201, %*{
      "secret": enrolment.secret,
      "otpauthUri": enrolment.otpauthUri,
      "digits": enrolment.digits,
      "periodSeconds": enrolment.periodSeconds})

proc handleMfaVerify*(app: AppContext, req: Request) {.gcsafe.} =
  ## `POST /api/v1/auth/mfa/verify` — konfirmasi satu kode untuk pendaftaran PENDING → ACTIVE.
  if app.pool.isNil:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "layanan basis data tidak dikonfigurasi (KRAN_DATABASE_URL kosong saat start)")
    return
  let principal = requirePrincipal(app, req)
  if principal.isNone:
    return
  let p = principal.get()

  # Bentuk badan diperiksa sebelum menyentuh DB: kesalahan pemanggil tidak boleh jadi 500.
  let body = parseJsonBody(req)
  if body.isNone:
    req.respondProblem(pkBadRequest, "Bad Request", "badan permintaan harus JSON")
    return
  let code = body.get().jsonField(fieldCode)
  if code.len == 0:
    req.respondProblem(pkBadRequest, "Bad Request", "code wajib diisi")
    return

  var settings: MfaSettings
  var gateLive = false
  var broken = ""
  var outcome = mvoNoPending
  try:
    withDbTx(app.pool, proc(db: DbConn) {.gcsafe.} =
      dbCalls:
        gateLive = mfaGate(db, app.clock, settings, broken)
        if gateLive:
          let ctx = newAuditContext(parseId(p.user.userId).value(), ip = clientIp(req),
            device = deviceOf(req), reason = "konfirmasi MFA",
            correlationId = traceIdFrom(req), startedAt = app.clock.now())
          outcome = confirmEnrolment(db, app.fieldCrypto, ctx, app.clock, institutionScope(),
            settings, p.user.userId, code))
  except NotConfiguredError:
    req.respondProblem(pkNotImplemented, "Not Implemented",
      "enkripsi field belum dikonfigurasi (" & envVarKekFile & " kosong saat start)")
    return
  except MfaDataError as e:
    req.respondProblem(pkInternal, "Internal Server Error",
      "pendaftaran MFA tidak bisa dibaca: " & e.msg)
    return
  except DbError:
    req.respondProblem(pkInternal, "Internal Server Error", "verifikasi MFA gagal diproses")
    return
  except TotpError as e:
    req.respondProblem(pkInternal, "Internal Server Error",
      "bentuk kode MFA tidak sah: " & e.msg)
    return
  except ValueError as e:
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan tidak sah: " & e.msg)
    return

  if broken.len > 0:
    req.respondProblem(pkInternal, "Internal Server Error",
      "kebijakan keamanan tidak sah: " & broken)
    return
  if not gateLive:
    respondMfaDisabled(req)
    return

  case outcome
  of mvoActivated:
    req.respondRaw(204, emptyHttpHeaders(), "")
  of mvoInvalidCode:
    # 403, bukan 401: sesinya sah, yang salah hanya kodenya. Klien yang memperlakukan 401 sebagai
    # "sesi berakhir" tidak jadi mengeluarkan pengguna dari halaman pendaftaran (pola yang sama
    # dengan `old_password_mismatch` di ganti kata sandi).
    req.respondProblem(newProblem(pkForbidden, "Forbidden", "kode MFA tidak cocok",
      traceId = traceIdFrom(req), params = @[("reason", "mfa_code_invalid")]))
  of mvoNoPending:
    req.respondProblem(newProblem(pkConflict, "Conflict", "tidak ada pendaftaran MFA menunggu",
      traceId = traceIdFrom(req), params = @[("reason", "mfa_no_pending_enrolment")]))
