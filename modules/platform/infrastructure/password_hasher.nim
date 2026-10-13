## Hash password & token sesi (spec §13, §18.2).
##
## **Keputusan**: PBKDF2-HMAC-SHA256 (RFC 2898 §5.2) dari pustaka `nimcrypto` — KDF standar,
## pure Nim (tanpa dependensi native di dev maupun server), sudah terpasang 0.7.3 dan dipin di
## `cbs.nimble`. Alasan lengkap: `docs/DECISIONS.md` D-013.
##
## **HUMAN-REVIEW-REQUIRED**: ini area kriptografi (penyimpanan password). Vektor uji di
## `tests/tpassword.nim` dihitung independen dengan `hashlib.pbkdf2_hmac` (Python), bukan dari
## pustaka yang sama. Jangan mengubah parameter tanpa meninjau biaya & keamanan.
##
## Token sesi **bukan** password: token 256-bit acak disimpan sebagai SHA-256 (hash cepat cukup
## untuk entropi tinggi; PBKDF2 hanya untuk rahasia berentropi rendah seperti password).

import std/[base64, options, strutils, sysrand]

import nimcrypto/[pbkdf2, sha2]
import nimcrypto/utils as ncUtils

const
  algoName* = "pbkdf2-hmac-sha256"
  saltBytes* = 32   # nomagic:ok teknis: salt 256-bit
  digestBytes* = 32 # nomagic:ok teknis: keluaran PBKDF2 256-bit
  tokenBytes* = 32  # nomagic:ok teknis: token sesi 256-bit
  encodedSeparator* = '$'

type
  PasswordHash* = object
    algo*: string
    iterations*: int
    saltB64*: string
    digestB64*: string

proc newSaltB64*(): string =
  ## Salt acak dari CSPRNG OS (`std/sysrand`).
  base64.encode(urandom(saltBytes))

proc newSessionToken*(): string =
  ## Token sesi acak, aman untuk cookie (base64 URL-safe tanpa padding).
  base64.encode(urandom(tokenBytes), safe = true).strip(chars = {'='})

proc hashPassword*(plaintext: string, iterations: int,
                   saltB64 = ""): PasswordHash =
  ## Menghitung hash password. `iterations` datang dari parameter
  ## (`platform.security.password_pbkdf2_iterations`) — bukan konstanta di kode.
  if iterations <= 0:
    raise newException(ValueError, "iterasi PBKDF2 harus positif")
  let salt = if saltB64.len > 0: saltB64 else: newSaltB64()
  let saltBytesRaw = base64.decode(salt)
  if saltBytesRaw.len == 0:
    raise newException(ValueError, "salt kosong/tidak sah")
  let digest = pbkdf2(sha256, plaintext, saltBytesRaw, iterations, digestBytes)
  PasswordHash(algo: algoName, iterations: iterations, saltB64: salt,
    digestB64: base64.encode(digest))

proc `$`*(h: PasswordHash): string =
  ## Bentuk tersimpan di DB: `algo$iterasi$salt$digest`. Parameter ikut tersimpan supaya
  ## perubahan kebijakan tidak mematahkan hash lama.
  h.algo & encodedSeparator & $h.iterations & encodedSeparator & h.saltB64 &
    encodedSeparator & h.digestB64

proc parseEncoded*(encoded: string): Option[PasswordHash] =
  ## Menerima bentuk `$`-dipisah. `none` bila bukan hash yang dikenali kode ini.
  let parts = encoded.split(encodedSeparator)
  if parts.len != 4:
    return none(PasswordHash)
  if parts[0] != algoName:
    return none(PasswordHash)
  var iterations: int
  try:
    iterations = parseInt(parts[1])
  except ValueError:
    return none(PasswordHash)
  if iterations <= 0:
    return none(PasswordHash)
  if parts[2].len == 0 or parts[3].len == 0:
    return none(PasswordHash)
  some PasswordHash(algo: parts[0], iterations: iterations, saltB64: parts[2],
    digestB64: parts[3])

proc constantTimeEquals(a, b: openArray[byte]): bool =
  ## Perbandingan waktu-tetap: panjang berbeda tetap diperiksa sampai selesai.
  var diff = a.len xor b.len
  let n = max(a.len, b.len)
  for i in 0 ..< n:
    let x = if i < a.len: a[i] else: 0'u8
    let y = if i < b.len: b[i] else: 0'u8
    diff = diff or (int(x) xor int(y))
  diff == 0

proc verifyPassword*(plaintext, encoded: string): bool =
  ## Memeriksa password terhadap hash tersimpan. Bentuk yang tidak dikenali = `false`
  ## (gagal-tertutup, tanpa membocorkan alasan ke pemanggil/log).
  let parsed = parseEncoded(encoded)
  if parsed.isNone:
    return false
  let stored = parsed.get()
  try:
    let candidate = hashPassword(plaintext, stored.iterations, stored.saltB64)
    let a = base64.decode(candidate.digestB64)
    let b = base64.decode(stored.digestB64)
    if a.len == 0 or b.len == 0:
      return false
    constantTimeEquals(a.toOpenArrayByte(0, a.len - 1), b.toOpenArrayByte(0, b.len - 1))
  except ValueError:
    # Bentuk hash/salt tidak bisa diproses: gagal-tertutup, tanpa membocorkan alasan.
    false

proc tokenHash*(token: string): string =
  ## SHA-256 heksadesimal (huruf kecil) dari token sesi — yang disimpan di DB, bukan tokennya.
  var ctx: sha256
  ctx.init()
  ctx.update(token)
  let digest = ctx.finish()
  ctx.clear()
  ncUtils.toHex(digest.data, lowercase = true)
