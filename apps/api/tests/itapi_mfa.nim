## Test integrasi HTTP MFA TOTP (T-046, spec §13/§18.2). Butuh `KRAN_DATABASE_URL`.
##
## Yang dibuktikan di sini adalah **jalur penuh lewat HTTP**: gerbang fitur (default mati → 403,
## juga saat keyring tidak ada), pendaftaran yang mengembalikan rahasia sekali saja, penyimpanan
## rahasia sebagai ciphertext (`kran:enc:v1`) dan bukan plaintext, bahwa **bentuk kode datang dari
## parameter** tapi dibekukan di baris pendaftaran, jejak audit, dan bahwa **alur login tidak
## berubah** (tanpa tantangan MFA).
##
## Rahasia/kode tidak pernah masuk audit — itu juga diperiksa (assertion pada `after_value`).
##
## Satu test sengaja membuat **bentuk baris ≠ bentuk parameter** lewat UPDATE langsung: jalur resmi
## menolak perubahan parameter kedua pada hari bisnis yang sama (`period_conflict`, EXCLUDE), jadi
## hanya begitu "verifikasi membaca baris" bisa dibedakan dari "verifikasi membaca parameter". Yang
## dinilai tetap perilaku HTTP-nya.
##
## Test ini **menghapus schema `platform`** di DB yang ditunjuk `KRAN_DATABASE_URL` (DB dev), lalu
## menyiapkan ulang migrasi + seed pack `base` + seed pengguna dev. Data dev murni sintetis.

import std/[httpclient, json, net, os, strutils, times, unittest]

import mummy
import db_connector/db_postgres

import dbtools/lib
import kernel/clock
import openapi/lib
import "platform-lib/crypto/fieldcrypto"
import "platform-lib/crypto/totp"
import "platform-lib/db/config"
import "platform-lib/db/pool"

import platform/infrastructure/[auth_service, mfa_repo]

import ../src/[context, readiness, server]

const
  ContractPath = "packages/contracts/openapi/kran-api.yaml"
  StatusPath = "/api/v1/auth/mfa"
  EnrolmentPath = "/api/v1/auth/mfa/enrolment"
  VerifyPath = "/api/v1/auth/mfa/verify"
  LoginPath = "/api/v1/auth/login"
  MfaEnabledKey = "platform.security.mfa.enabled"
  MfaDigitsKey = "platform.security.mfa.digits"
  MfaPeriodKey = "platform.security.mfa.period_seconds"
  MfaIssuerKey = "platform.security.mfa.issuer"
  MakerUser = "dev.maker"
  CheckerUser = "dev.checker"
  DevPassword = "rahasia-panjang-123"
  CookieName = "kran_session"
  ## Bentuk kode uji: **berbeda dari nilai seed** (6 digit / 30 detik) supaya test bisa
  ## membuktikan angka-angka itu datang dari parameter, bukan dari konstanta di kode.
  DevDigits = 8
  DevPeriod = 60
  DevIssuer = "KRAN Uji"
  ## Bentuk ciphertext field crypto (T-054). Rahasia TOTP di DB harus berbentuk ini — bukan teks
  ## base32 yang bisa dibaca langsung.
  CipherPrefix = "kran:enc:v1"
  ## Kunci KEK uji: 32 byte 0x00..0x1f dalam base64 — pola yang sama dengan `tfieldcrypto`.
  KekB64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

let envT = envTableFromProcess()
if not databaseUrlSet(envT):
  echo "itapi_mfa: KRAN_DATABASE_URL kosong — dilewati"
  quit(0)

let contract = loadContractFile(ContractPath)
let dbPool = newDbPool(dbConfigFromEnv(envT))

# --- penyiapan DB: skema bersih + seed pack + seed pengguna dev -------------------------------
block:
  let db = dbPool.acquire()
  resetTestSchemas(db, ".")
  discard applyAllMigrations(db, ".")
  execScript(db, readFile("packs/base/generated/param_definitions.sql"))
  execScript(db, readFile("packs/base/generated/param_values.sql"))
  execScript(db, readFile("packs/base/seed/0001_dev_users.sql"))

  # Biaya KDF untuk test: parameter ini menentukan hash password **baru** (ganti kata sandi) dan
  # hash tiruan login akun tak dikenal. Nilai produksi (600.000) membuat suite ini ~90 detik CPU
  # tanpa menguji apa pun tentang biaya hashing — biaya KDF diuji di `tpassword`/`itpassword` dan
  # `./task bench-password`. Turunkan **hanya di DB test**; seed pack tetap 600.000.
  exec(db, sql"""UPDATE platform.param_value
                    SET value = '1000'::jsonb
                  WHERE key = 'platform.security.password_pbkdf2_iterations'
                    AND status = 'ACTIVE'""")

# --- keyring: berkas KEK sungguhan (mode 600) lewat jalur startup nyata -----------------------
block:
  let path = getTempDir() / "kran-itapi-mfa-kek.txt"
  writeFile(path, "v1:" & KekB64 & "\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite})
  putEnv("KRAN_KEK_FILE", path)

var app = AppContext(version: "itapi-mfa-0.0.0", role: "api", startedAt: epochTime(),
                     pool: dbPool, clock: systemClock(), readiness: databaseProbe())
app.fieldCrypto = fieldCryptoFromProcessEnv()
doAssert app.fieldCrypto.isConfigured, "keyring uji tidak terbaca — periksa berkas KEK sementara"

## Server kedua yang **sengaja** kehilangan keyring (tidak memanggil `fieldCryptoFromProcessEnv`):
## dipakai untuk membuktikan urutan gerbang fitur vs konfigurasi enkripsi lewat HTTP sungguhan.
var appNoKey = AppContext(version: "itapi-mfa-nokey-0.0.0", role: "api", startedAt: epochTime(),
                          pool: dbPool, clock: systemClock(), readiness: databaseProbe())
doAssert not appNoKey.fieldCrypto.isConfigured

type
  ServeArgs = object
    server: Server
    port: int

var serverThreads: array[2, Thread[ServeArgs]]
var baseUrl = ""
var baseUrlNoKey = ""

proc freePort(): int =
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = int(socket.getLocalAddr()[1])
  socket.close()

proc serveInThread(args: ServeArgs) {.thread.} =
  try:
    args.server.serve(Port(args.port), "127.0.0.1")
  except CatchableError:
    discard # proses test berakhir dengan sendirinya (lihat O-025)

proc startServer(a: AppContext, slot: int): string =
  let port = freePort()
  let server = newApiServer(a)
  createThread(serverThreads[slot], serveInThread, ServeArgs(server: server, port: port))
  result = "http://127.0.0.1:" & $port
  let deadline = epochTime() + 10.0
  var up = false
  while epochTime() < deadline and not up:
    try:
      let probe = newHttpClient(timeout = 1000)
      defer: probe.close()
      up = probe.get(result & "/healthz").code.int == 200
    except CatchableError:
      discard
    if not up:
      sleep(50)
  doAssert up, "server test tidak pernah siap"

block:
  baseUrl = startServer(app, 0)
  baseUrlNoKey = startServer(appNoKey, 1)

# --- klien HTTP kecil -------------------------------------------------------------------------

type
  Reply = object
    code: int
    body: JsonNode
    setCookie: string
    cacheControl: string

var idemCounter = 0

proc autoIdemKey(): string =
  inc idemCounter
  "it-mfa-" & $idemCounter

proc call(base, verb, path, payload, token: string): Reply =
  let client = newHttpClient(timeout = 15000)
  defer: client.close()
  if token.len > 0:
    client.headers["Cookie"] = CookieName & "=" & token
  var response: Response
  if verb == "GET":
    response = client.get(base & path)
  else:
    if payload.len > 0:
      client.headers["Content-Type"] = "application/json"
    client.headers["Idempotency-Key"] = autoIdemKey()
    response = client.post(base & path, payload)
  result.code = response.code.int
  result.cacheControl = response.headers.getOrDefault("Cache-Control")
  result.setCookie = response.headers.getOrDefault("Set-Cookie")
  result.body = newJNull()
  if response.body.len > 0:
    try:
      result.body = parseJson(response.body)
    except JsonParsingError:
      discard

proc getJson(path: string, token = "", base = baseUrl): Reply =
  call(base, "GET", path, "", token)

proc postJson(path: string, payload: JsonNode, token = "", base = baseUrl): Reply =
  call(base, "POST", path, $payload, token)

proc tokenOf(reply: Reply): string =
  for part in reply.setCookie.split(';'):
    let item = part.strip()
    if item.startsWith(CookieName & "="):
      return item[CookieName.len + 1 .. ^1]
  ""

proc login(username: string, password = DevPassword): Reply =
  postJson(LoginPath, %*{"username": username, "password": password})

proc checkJson(path, verb, status: string, body: JsonNode) =
  let problems = contract.validateValue(contract.responseSchema(path, verb, status), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem

proc checkProblem(path, verb, status: string, body: JsonNode, reason = "") =
  ## Amplop problem: bentuk sesuai kontrak + kode sebab stabil (dipakai UI untuk menerjemahkan).
  let problems = contract.validateValue(
    contract.responseSchema(path, verb, status, "application/problem+json"), body, "$")
  check problems.len == 0
  for problem in problems:
    checkpoint problem
  if reason.len > 0:
    check body["params"]["reason"].getStr() == reason

# --- helper baca DB (klaim "tersimpan terenkripsi" tidak boleh hanya dari respons HTTP) --------

proc userIdOf(username: string): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(sql"SELECT user_id::text FROM platform.app_user WHERE username = ?", username)
  finally:
    dbPool.release(conn)

proc mfaStatusOf(username: string): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(
      sql"SELECT coalesce(max(status), 'NONE') FROM platform.user_mfa WHERE user_id = ?::uuid",
      userIdOf(username))
  finally:
    dbPool.release(conn)

proc mfaSecretEncOf(username: string): string =
  let conn = dbPool.acquire()
  try:
    conn.getValue(
      sql"SELECT coalesce(max(secret_enc), '') FROM platform.user_mfa WHERE user_id = ?::uuid",
      userIdOf(username))
  finally:
    dbPool.release(conn)

proc mfaShapeOf(username: string): tuple[digits, period: int] =
  ## Bentuk kode yang **tersimpan di baris pendaftaran** (bukan parameter aktif).
  let conn = dbPool.acquire()
  try:
    let row = conn.getRow(sql"""
      SELECT digits::text, period_seconds::text FROM platform.user_mfa WHERE user_id = ?::uuid""",
      userIdOf(username))
    (parseInt(row[0]), parseInt(row[1]))
  finally:
    dbPool.release(conn)

proc auditRows(action, username: string): int =
  let conn = dbPool.acquire()
  try:
    parseInt(conn.getValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action = ? AND resource_id = ?""", action, userIdOf(username)))
  finally:
    dbPool.release(conn)

proc auditPayloadLeaksSecret(username, secret: string): bool =
  ## `true` bila ada entri audit MFA yang memuat rahasia/kode mentah. Audit **tidak boleh**
  ## menyimpan rahasia (spec §18.2) — pemeriksaan ini yang membuktikannya, bukan konvensi.
  let conn = dbPool.acquire()
  try:
    let leaked = conn.getValue(sql"""
      SELECT count(*)::text FROM platform.audit_log
       WHERE action LIKE 'auth.mfa.%' AND resource_id = ?
         AND (after_value::text LIKE ? OR before_value::text LIKE ?)""",
      userIdOf(username), "%" & secret & "%", "%" & secret & "%")
    parseInt(leaked) > 0
  finally:
    dbPool.release(conn)

proc setParamValue(key: string, value: JsonNode): bool =
  ## Mengubah satu parameter institusi lewat **jalur resmi** (maker-checker), bukan UPDATE
  ## langsung: jalur itulah yang dipakai operator, jadi test tidak mengambil jalan pintas yang
  ## belum pernah diuji orang lain.
  let maker = login(MakerUser)
  let checker = login(CheckerUser)
  let submitted = postJson("/api/v1/params/" & key & "/changes",
    %*{"value": value, "reason": "uji otomatis MFA"}, tokenOf(maker))
  if submitted.code != 201:
    checkpoint "submit parameter gagal: " & key & " → " & $submitted.code
    return false
  let approved = postJson(
    "/api/v1/params/changes/" & submitted.body["paramValueId"].getStr() & "/approve",
    newJObject(), tokenOf(checker))
  if approved.code != 200:
    checkpoint "approve parameter gagal: " & key & " → " & $approved.code
    return false
  true

proc codeFor(secretBase32: string, digits: int, periodSeconds: int, offsetSteps = 0): string =
  ## Kode yang benar dihitung test dari rahasia yang dikembalikan server — memakai implementasi
  ## `totp` yang sudah terbukti terhadap vektor RFC di `ttotp.nim`.
  let seconds = epochTime().int64 + int64(offsetSteps) * int64(periodSeconds)
  totpCode(base32Decode(secretBase32), seconds, periodSeconds, digits)

# --- suite: gerbang fitur (default mati) ------------------------------------------------------

suite "MFA: gerbang fitur":

  test "tanpa sesi → 401 pada ketiga rute (bukan 403/501)":
    let status = getJson(StatusPath)
    check status.code == 401
    checkProblem(StatusPath, "GET", "401", status.body)
    let enrol = postJson(EnrolmentPath, newJObject())
    check enrol.code == 401
    checkProblem(EnrolmentPath, "POST", "401", enrol.body)
    let verify = postJson(VerifyPath, %*{"code": "123456"})
    check verify.code == 401
    checkProblem(VerifyPath, "POST", "401", verify.body)

  test "fitur mati (default) → 403 mfa_disabled, tidak ada baris MFA yang lahir":
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    check token.len > 0

    let status = getJson(StatusPath, token)
    check status.code == 403
    checkProblem(StatusPath, "GET", "403", status.body, reason = "mfa_disabled")

    let enrol = postJson(EnrolmentPath, newJObject(), token)
    check enrol.code == 403
    checkProblem(EnrolmentPath, "POST", "403", enrol.body, reason = "mfa_disabled")

    let verify = postJson(VerifyPath, %*{"code": "123456"}, token)
    check verify.code == 403
    checkProblem(VerifyPath, "POST", "403", verify.body, reason = "mfa_disabled")

    check mfaStatusOf(MakerUser) == "NONE"
    check auditRows("auth.mfa.enrol", MakerUser) == 0

  test "kebijakan MFA belum tersemai sama sekali → 403 mfa_disabled, bukan 500":
    # Keadaan nyata di produksi saat deploy ini: `dbtools seed` bukan bagian dari deploy (O-066), jadi
    # lima nilai `platform.security.mfa.*` belum ada. Saklar keamanan harus fail-closed ke **mati**,
    # bukan gagal 500 — dan yang diuji adalah keadaan itu sendiri, bukan asumsinya.
    let conn = dbPool.acquire()
    try:
      discard conn.execAffectedRows(sql"""
        DELETE FROM platform.param_value WHERE key LIKE 'platform.security.mfa.%'""")
    finally:
      dbPool.release(conn)

    let maker = login(MakerUser)
    let token = tokenOf(maker)
    let status = getJson(StatusPath, token)
    check status.code == 403
    checkProblem(StatusPath, "GET", "403", status.body, reason = "mfa_disabled")
    let enrol = postJson(EnrolmentPath, newJObject(), token)
    check enrol.code == 403
    checkProblem(EnrolmentPath, "POST", "403", enrol.body, reason = "mfa_disabled")
    check mfaStatusOf(MakerUser) == "NONE"

    # Kembalikan nilai seed (berkasnya idempotent) supaya test berikutnya menguji jalur normal.
    let restore = dbPool.acquire()
    try:
      execScript(restore, readFile("packs/base/generated/param_values.sql"))
    finally:
      dbPool.release(restore)
    let setelahPulih = getJson(StatusPath, token)
    check setelahPulih.code == 403 # nilai seed `enabled` = false
    checkProblem(StatusPath, "GET", "403", setelahPulih.body, reason = "mfa_disabled")

  test "fitur mati + server tanpa keyring → tetap 403 mfa_disabled (gerbang fitur lebih dulu)":
    # Urutan ini disengaja: fitur yang belum diaktifkan tidak boleh menjawab 501 hanya karena
    # instalasi ini belum punya KEK — dan pemanggil tidak bisa menyimpulkan status konfigurasi
    # enkripsi server dari beda 403/501.
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    check token.len > 0
    let enrol = postJson(EnrolmentPath, newJObject(), token, baseUrlNoKey)
    check enrol.code == 403
    checkProblem(EnrolmentPath, "POST", "403", enrol.body, reason = "mfa_disabled")
    check mfaStatusOf(MakerUser) == "NONE"

  test "menyalakan fitur + bentuk kode lewat maker-checker":
    check setParamValue(MfaDigitsKey, %DevDigits)
    check setParamValue(MfaPeriodKey, %DevPeriod)
    check setParamValue(MfaIssuerKey, %DevIssuer)
    check setParamValue(MfaEnabledKey, %true)

    let maker = login(MakerUser)
    let status = getJson(StatusPath, tokenOf(maker))
    check status.code == 200
    checkJson(StatusPath, "GET", "200", status.body)
    check status.body["featureEnabled"].getBool()
    check status.body["status"].getStr() == "NONE"

  test "fitur hidup + server tanpa keyring → 501 fail-closed, status tetap terbaca":
    # Pendaftaran tanpa keyring harus menolak, bukan menyimpan rahasia plaintext.
    let maker = login(MakerUser)
    let token = tokenOf(maker)
    let enrol = postJson(EnrolmentPath, newJObject(), token, baseUrlNoKey)
    check enrol.code == 501
    checkProblem(EnrolmentPath, "POST", "501", enrol.body)
    check mfaStatusOf(MakerUser) == "NONE"

    # Rute status tidak menyentuh kripto, jadi ia tetap bekerja tanpa keyring.
    let status = getJson(StatusPath, token, baseUrlNoKey)
    check status.code == 200
    checkJson(StatusPath, "GET", "200", status.body)
    check status.body["status"].getStr() == "NONE"

# --- suite: pendaftaran & verifikasi ----------------------------------------------------------

suite "MFA: pendaftaran & verifikasi":

  var secret = ""

  test "enrolment memakai bentuk kode dari parameter dan menyimpan rahasia terenkripsi":
    let maker = login(MakerUser)
    let reply = postJson(EnrolmentPath, newJObject(), tokenOf(maker))
    check reply.code == 201
    checkJson(EnrolmentPath, "POST", "201", reply.body)
    secret = reply.body["secret"].getStr()
    check base32Decode(secret).len == 20 # 160 bit rahasia (RFC 4226 §4 R6)
    check reply.body["digits"].getInt() == DevDigits
    check reply.body["periodSeconds"].getInt() == DevPeriod
    let uri = reply.body["otpauthUri"].getStr()
    check uri.startsWith("otpauth://totp/")
    check uri.contains("secret=" & secret)
    check uri.contains("issuer=" & DevIssuer.replace(" ", "%20")) # dari parameter, bukan konstanta
    # Rahasia berumur panjang: responsnya tidak boleh di-cache perantara/peramban.
    check reply.cacheControl == "no-store"

    # Klaim penyimpanan: status PENDING + ciphertext, bukan plaintext base32.
    check mfaStatusOf(MakerUser) == "PENDING"
    let stored = mfaSecretEncOf(MakerUser)
    check stored.startsWith(CipherPrefix)
    check not stored.contains(secret)
    check mfaShapeOf(MakerUser) == (DevDigits, DevPeriod)

    # Rahasia tidak pernah masuk audit.
    check auditRows("auth.mfa.enrol", MakerUser) == 1
    check not auditPayloadLeaksSecret(MakerUser, secret)

  test "enrolment ulang saat masih PENDING mengganti rahasia":
    let maker = login(MakerUser)
    let reply = postJson(EnrolmentPath, newJObject(), tokenOf(maker))
    check reply.code == 201
    let baru = reply.body["secret"].getStr()
    check baru.len > 0
    check baru != secret
    secret = baru
    check mfaStatusOf(MakerUser) == "PENDING"

  test "kode salah → 403 mfa_code_invalid, tetap PENDING, tercatat di audit":
    let maker = login(MakerUser)
    let reply = postJson(VerifyPath, %*{"code": "0".repeat(DevDigits)}, tokenOf(maker))
    check reply.code == 403
    checkProblem(VerifyPath, "POST", "403", reply.body, reason = "mfa_code_invalid")
    check mfaStatusOf(MakerUser) == "PENDING"
    check auditRows("auth.mfa.verify_failure", MakerUser) == 1

  test "badan tanpa code → 400 (tidak menyentuh pendaftaran)":
    let maker = login(MakerUser)
    let reply = postJson(VerifyPath, newJObject(), tokenOf(maker))
    check reply.code == 400
    checkProblem(VerifyPath, "POST", "400", reply.body)
    check mfaStatusOf(MakerUser) == "PENDING"

  test "bentuk kode diverifikasi dari baris pendaftaran, bukan dari parameter aktif":
    # Divergensi bentuk sengaja dibuat lewat UPDATE langsung, **bukan** pengubahan parameter:
    # jalur resmi mengubah nilai pada hari bisnis yang sama ditolak `period_conflict` (EXCLUDE
    # `param_value`, 409) — jadi bentuk baris ≠ parameter adalah satu-satunya cara membedakan
    # "verifikasi membaca baris" dari "verifikasi membaca parameter" tanpa menunggu hari berikutnya.
    # Yang diuji tetap perilaku HTTP-nya: kode dengan bentuk **parameter** ditolak, kode dengan
    # bentuk **baris** diterima.
    let conn = dbPool.acquire()
    try:
      discard conn.execAffectedRows(sql"""
        UPDATE platform.user_mfa SET digits = 6, period_seconds = 30
         WHERE user_id = ?::uuid""", userIdOf(MakerUser))
    finally:
      dbPool.release(conn)
    check mfaShapeOf(MakerUser) == (6, 30)

    let maker = login(MakerUser)
    # Kode dengan bentuk parameter aktif (8 digit / 60 detik) — 6 digit / 30 detik yang cocok.
    let dariParameter = postJson(VerifyPath, %*{"code": codeFor(secret, DevDigits, DevPeriod)},
      tokenOf(maker))
    check dariParameter.code == 403
    checkProblem(VerifyPath, "POST", "403", dariParameter.body, reason = "mfa_code_invalid")
    check mfaStatusOf(MakerUser) == "PENDING"
    check auditRows("auth.mfa.verify_failure", MakerUser) == 2

    let dariBaris = postJson(VerifyPath, %*{"code": codeFor(secret, 6, 30)}, tokenOf(maker))
    check dariBaris.code == 204
    check mfaStatusOf(MakerUser) == "ACTIVE"
    check auditRows("auth.mfa.verify", MakerUser) == 1

    let checkConn = dbPool.acquire()
    try:
      check parseInt(checkConn.getValue(sql"""
        SELECT count(*)::text FROM platform.user_mfa
         WHERE user_id = ?::uuid AND confirmed_at IS NOT NULL""", userIdOf(MakerUser))) == 1
    finally:
      dbPool.release(checkConn)

    # Status akun yang sudah terdaftar terbaca lewat GET, tanpa rahasia.
    let status = getJson(StatusPath, tokenOf(maker))
    check status.code == 200
    checkJson(StatusPath, "GET", "200", status.body)
    check status.body["status"].getStr() == "ACTIVE"
    check not status.body.hasKey("secret")

    # Rahasia tetap tidak pernah muncul di audit setelah verifikasi sukses.
    check not auditPayloadLeaksSecret(MakerUser, secret)

  test "enrolment lagi saat ACTIVE → 409 mfa_already_active, rahasia lama tidak tertimpa":
    let sebelum = mfaSecretEncOf(MakerUser)
    let maker = login(MakerUser)
    let reply = postJson(EnrolmentPath, newJObject(), tokenOf(maker))
    check reply.code == 409
    checkProblem(EnrolmentPath, "POST", "409", reply.body, reason = "mfa_already_active")
    check not reply.body.hasKey("secret")
    check mfaSecretEncOf(MakerUser) == sebelum

  test "verifikasi tanpa pendaftaran menunggu → 409 mfa_no_pending_enrolment":
    let checker = login(CheckerUser)
    let reply = postJson(VerifyPath, %*{"code": codeFor(secret, DevDigits, DevPeriod)},
      tokenOf(checker))
    check reply.code == 409
    checkProblem(VerifyPath, "POST", "409", reply.body, reason = "mfa_no_pending_enrolment")

  test "penjagaan anti-replay repo: langkah sama/lebih lama ditolak, langkah lebih baru diterima":
    # `recordUsedStep` belum dipakai jalur HTTP mana pun (verifikasi di sini hanya untuk aktivasi;
    # jalur login menyusul di O-071), jadi penjagaannya diuji langsung di lapisan repo — bukan
    # dibiarkan sebagai kode mati tanpa bukti.
    let conn = dbPool.acquire()
    try:
      let userId = userIdOf(MakerUser)
      let nowIso = utcIso(systemClock().now())
      let step = epochTime().int64 div 30
      check conn.recordUsedStep(userId, step + 100, nowIso) # belum pernah dipakai
      check not conn.recordUsedStep(userId, step + 100, nowIso) # langkah yang sama
      check not conn.recordUsedStep(userId, step + 50, nowIso) # langkah lebih lama
    finally:
      dbPool.release(conn)

  test "enrolment baru memakai bentuk parameter aktif; kode akun lain ditolak":
    # Dua hal sekaligus, dan keduanya saling menguatkan: parameter yang aktif **tetap** 8 digit /
    # 60 detik (bentuk baris maker tadi dibuat berbeda di DB, bukan lewat parameter), sehingga
    # pendaftaran baru harus mengikuti parameter — bukan bentuk lama baris akun lain.
    let checker = login(CheckerUser)
    let enroll = postJson(EnrolmentPath, newJObject(), tokenOf(checker))
    check enroll.code == 201
    check enroll.body["digits"].getInt() == DevDigits
    check enroll.body["periodSeconds"].getInt() == DevPeriod
    let checkerSecret = enroll.body["secret"].getStr()
    check checkerSecret != secret
    check mfaShapeOf(CheckerUser) == (DevDigits, DevPeriod)

    # Kode yang sah untuk akun lain (bentuk baris maker: 6/30) tidak bisa mengaktifkan akun ini.
    let salah = postJson(VerifyPath, %*{"code": codeFor(secret, 6, 30)}, tokenOf(checker))
    check salah.code == 403
    checkProblem(VerifyPath, "POST", "403", salah.body, reason = "mfa_code_invalid")
    check mfaStatusOf(CheckerUser) == "PENDING"

    let benar = postJson(VerifyPath, %*{"code": codeFor(checkerSecret, DevDigits, DevPeriod)},
      tokenOf(checker))
    check benar.code == 204
    check mfaStatusOf(CheckerUser) == "ACTIVE"

  test "login tetap tidak meminta MFA (alur login tidak berubah)":
    # D-046 butir 9 / batas task T-046: faktor ACTIVE **tidak** mengubah proses masuk. Ini akan
    # berubah di task aktivasi login (O-071) — saat itu test ini yang harus diubah lebih dulu.
    let reply = login(MakerUser)
    check reply.code == 200
    checkJson(LoginPath, "POST", "200", reply.body)
    check tokenOf(reply).len > 0
    check not reply.body.hasKey("mfa")
    check not reply.body.hasKey("mfaRequired")
