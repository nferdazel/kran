## Enkripsi field-level untuk data sensitif (spec §18.2): NIK, NPWP, no. HP, alamat.
##
## **Keputusan**: envelope encryption dengan **KEK** di berkas terpisah (`KRAN_KEK_FILE`,
## mode 600) dan **DEK diturunkan** dari KEK (domain separation per nama tabel), bukan
## disimpan terbungkus di DB. Algoritme: AES-256-GCM (nimcrypto `rijndael` + `bcmode`, tanpa
## dependensi baru) dan KDF `HMAC-SHA256`. Alasan lengkap + alternatif yang ditolak:
## `docs/adr/017-field-level-encryption.md` dan `docs/DECISIONS.md` D-048.
##
## **HUMAN-REVIEW-REQUIRED**: ini area kriptografi (spec §18.2, AGENTS.md §8). Vektor uji
## (AES-256-GCM + KDF) dihitung **independen** dengan Node `node:crypto` (perintah pembuatnya
## dicatat di header `tests/tfieldcrypto.nim`) — bukan oleh pustaka yang sama. Jangan mengubah
## format ciphertext, derivasi kunci, atau panjang nonce/tag tanpa review manusia.
##
## Bentuk ciphertext (self-describing, TIDAK bergantung skema DB):
##
##     kran:enc:v1:<kid>:<nonce_b64url>:<ciphertext||tag_b64url>
##
##   - `v1` menandai algoritme (AES-256-GCM, nonce 96-bit, tag 128-bit);
##   - `kid` = id kunci KEK aktif, supaya dekripsi tetap jalan setelah rotasi KEK;
##   - AAD = nama tabel, supaya ciphertext tidak bisa dipindahkan antar tabel.
##
## Data yang gagal didekripsi **selalu** menjadi `DecryptError` — tidak pernah mengembalikan
## plaintext atau string kosong. Pesan galat tidak pernah memuat materi kunci atau plaintext.
##
## **Pengaktifan**: bila `KRAN_KEK_FILE` tidak diset, `fieldCryptoFromEnv` mengembalikan keyring
## *belum-terkonfigurasi* dan aplikasi boleh start apa adanya (belum ada kolom terenkripsi);
## setiap `encryptField`/`decryptField` saat itu gagal dengan `NotConfiguredError`. Bila diset,
## berkas dibaca & divalidasi saat startup (hilang/rusak/kid tidak sah/mode bukan 600 → `KekError`,
## tolak start). Tidak ada fallback diam-diam (O-056 / D-046 butir 6).
##
## Berkas KEK berisi satu atau beberapa kunci berversi, satu per baris:
##
##     # komentar
##     v1:PGtpPy1yPLO7g0QVQKvzZ8QvJnDkBb+NOtHQk8Cw7vc
##     v2:AAAA...   # baris terakhir = kunci AKTIF untuk enkripsi baru
##
## Kunci lama tetap dibaca untuk dekripsi (rotasi tanpa membaca ulang). Format kunci = base64
## dari 32 byte acak. **Tidak ada materi kunci di dalam string ciphertext maupun galat.**

import std/[base64, os, strutils, tables, sysrand]

import nimcrypto/[rijndael, bcmode, hmac, sha2]
import nimcrypto/utils as ncUtils

const
  envVarKekFile* = "KRAN_KEK_FILE"
  ciphertextPrefix* = "kran:enc:v1"
  dekInfoPrefix = "kran:dek:v1:"   ## domain separation DEK (per nama tabel)
  bidxInfoPrefix = "kran:bidx:v1:" ## domain separation blind index (per nama tabel)
  keyBytes* = 32                   # nomagic:ok teknis: kunci AES-256/KEK 256-bit
  nonceBytes* = 12                 # nomagic:ok teknis: nonce GCM 96-bit
  tagBytes* = 16                   # nomagic:ok teknis: tag GCM 128-bit
  kidMaxLen = 64
  separator = ':'

type
  FieldCryptoError* = object of CatchableError
  KekError* = object of FieldCryptoError ## berkas/konfigurasi KEK tidak sah
  NotConfiguredError* = object of FieldCryptoError ## `KRAN_KEK_FILE` kosong
  DecryptError* = object of FieldCryptoError ## ciphertext tidak bisa didekripsi

  KekKey* = object
    kid*: string
    raw: array[keyBytes, byte]

  FieldCrypto* = ref object
    configured*: bool
    activeKid*: string
    keys*: Table[string, KekKey]

proc newFieldCrypto*(): FieldCrypto =
  ## Keyring **belum terkonfigurasi** (tanpa KEK). Aman untuk deploy yang belum punya berkas
  ## KEK; enkripsi/dekripsi akan menolak dengan pesan eksplisit.
  FieldCrypto(configured: false, activeKid: "", keys: initTable[string, KekKey]())

proc isConfigured*(fc: FieldCrypto): bool =
  ## `true` bila keyring punya kunci aktif (berkas KEK sudah dibaca & sah).
  not fc.isNil and fc.configured

proc requireConfigured(fc: FieldCrypto) =
  if not fc.isConfigured:
    raise newException(NotConfiguredError,
      "enkripsi field belum dikonfigurasi (set " & envVarKekFile & ")")

proc b64url(data: openArray[byte]): string =
  base64.encode(data, safe = true).strip(chars = {'='})

proc decodeB64(s: string): seq[byte] =
  ## Base64 standar maupun URL-safe (tabel decode stdlib menerima keduanya). Angka galat
  ## `ValueError` ditangkap pemanggil; pesannya tidak dipakai agar tidak membocorkan isi.
  let decoded = base64.decode(s)
  result = newSeq[byte](decoded.len)
  for i, c in decoded:
    result[i] = byte(c)

proc hmacSha256(key: openArray[byte], data: string): array[keyBytes, byte] =
  var ctx: HMAC[sha256]
  ctx.init(key)
  ctx.update(data)
  let digest = ctx.finish()
  ctx.clear()
  for i in 0 ..< keyBytes:
    result[i] = digest.data[i]

proc deriveKey(kek: openArray[byte], info: string): array[keyBytes, byte] =
  ## KDF = `HMAC-SHA256(KEK, info)`. KEK sudah seragam 256-bit, jadi tahap Extract HKDF tidak
  ## menambah keamanan; domain separation eksplisit lewat prefiks `info` (ADR-017).
  hmacSha256(kek, info)

proc constantTimeEquals(a, b: openArray[byte]): bool =
  ## Perbandingan waktu-tetap: panjang berbeda tetap diperiksa sampai selesai.
  var diff = a.len xor b.len
  let n = max(a.len, b.len)
  for i in 0 ..< n:
    let x = if i < a.len: a[i] else: 0'u8
    let y = if i < b.len: b[i] else: 0'u8
    diff = diff or (int(x) xor int(y))
  diff == 0

proc validKid(kid: string): bool =
  if kid.len == 0 or kid.len > kidMaxLen:
    return false
  for c in kid:
    if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-', '.'}:
      return false
  true

proc decodeKekKey(text, source: string, lineNo: int): array[keyBytes, byte] =
  var raw: seq[byte]
  try:
    raw = decodeB64(text)
  except ValueError:
    raise newException(KekError,
      source & ":" & $lineNo & ": nilai kunci bukan base64 yang sah")
  if raw.len != keyBytes:
    raise newException(KekError,
      source & ":" & $lineNo & ": kunci harus " & $keyBytes & " byte (dapat " &
      $raw.len & ")")
  for i in 0 ..< keyBytes:
    result[i] = raw[i]

proc parseKekFile*(content, source: string): FieldCrypto =
  ## Membaca isi berkas KEK. `source` hanya untuk pesan galat. Format tiap baris:
  ## `<kid>:<base64>`. Baris kosong/`#` diabaikan. **Kunci aktif = entri terakhir.**
  ## Galat tidak pernah memuat nilai kunci.
  result = FieldCrypto(configured: false, activeKid: "",
    keys: initTable[string, KekKey]())
  var lastKid = ""
  for idx, rawLine in content.splitLines().pairs():
    let lineNo = idx + 1
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let pos = line.find(separator)
    if pos <= 0:
      raise newException(KekError,
        source & ":" & $lineNo & ": format baris harus `<kid>:<base64>`")
    let kid = line[0 ..< pos].strip()
    let value = line[pos + 1 .. ^1].strip()
    if not validKid(kid):
      raise newException(KekError, source & ":" & $lineNo & ": kid tidak sah")
    if value.len == 0:
      raise newException(KekError, source & ":" & $lineNo & ": nilai kunci kosong")
    if kid in result.keys:
      raise newException(KekError, source & ":" & $lineNo & ": kid duplikat: " & kid)
    result.keys[kid] = KekKey(kid: kid, raw: decodeKekKey(value, source, lineNo))
    lastKid = kid
  if lastKid.len == 0:
    raise newException(KekError,
      source & ": tidak ada kunci (berkas kosong atau hanya komentar)")
  result.activeKid = lastKid
  result.configured = true

proc loadKekFile*(path: string): FieldCrypto =
  ## Memuat & memvalidasi berkas KEK (fail-fast). `KekError` bila berkas hilang, tidak
  ## terbaca, mode bukan 600, atau isinya tidak sah.
  if path.len == 0:
    raise newException(KekError, envVarKekFile & " kosong")
  if not fileExists(path):
    raise newException(KekError, "berkas KEK tidak ditemukan: " & path)
  when not defined(windows):
    var perm: set[FilePermission]
    try:
      perm = getFilePermissions(path)
    except OSError:
      raise newException(KekError, "berkas KEK tidak bisa dibaca: " & path)
    if fpGroupRead in perm or fpGroupWrite in perm or fpGroupExec in perm or
        fpOthersRead in perm or fpOthersWrite in perm or fpOthersExec in perm:
      raise newException(KekError,
        "berkas KEK harus mode 600 (hanya pemilik): " & path)
  var content = ""
  try:
    content = readFile(path)
  except CatchableError:
    raise newException(KekError, "berkas KEK tidak bisa dibaca: " & path)
  parseKekFile(content, path)

proc fieldCryptoFromEnv*(env: Table[string, string]): FieldCrypto =
  ## Titik masuk startup. `KRAN_KEK_FILE` kosong → keyring belum-terkonfigurasi (aplikasi start
  ## seperti sekarang). Diset → berkas dibaca & divalidasi **sekarang** (galat = tolak start).
  let path = env.getOrDefault(envVarKekFile, "").strip()
  if path.len == 0:
    return newFieldCrypto()
  loadKekFile(path)

proc fieldCryptoFromProcessEnv*(): FieldCrypto =
  ## Sama seperti `fieldCryptoFromEnv`, tetapi membaca variabel lingkungan proses (pola
  ## `dbConfigFromProcessEnv`). Dipakai jalur startup biner agar keyring divalidasi sekali.
  var env = initTable[string, string]()
  env[envVarKekFile] = getEnv(envVarKekFile)
  fieldCryptoFromEnv(env)

proc activeKey(fc: FieldCrypto): KekKey =
  fc.keys[fc.activeKid]

proc encryptField*(fc: FieldCrypto, tableName, plaintext: string): string =
  ## Mengenkripsi `plaintext` dengan DEK turunan untuk `tableName` (AAD = nama tabel).
  ## Nonce 96-bit acak dari CSPRNG OS (`std/sysrand`) per panggilan. Hasil = bentuk
  ## `kran:enc:v1:…` di atas.
  requireConfigured(fc)
  if tableName.len == 0:
    raise newException(FieldCryptoError, "nama tabel tidak boleh kosong")
  let kek = fc.activeKey()
  let nonce = urandom(nonceBytes)
  var dek = deriveKey(kek.raw, dekInfoPrefix & tableName)
  defer:
    ncUtils.burnMem(dek)

  var ctx: GCM[aes256]
  ctx.init(dek, nonce, tableName.toOpenArrayByte(0, tableName.len - 1))
  var ct = newSeq[byte](plaintext.len)
  var tag: array[tagBytes, byte]
  if plaintext.len == 0:
    ctx.getTag(tag)
  else:
    ctx.encrypt(plaintext.toOpenArrayByte(0, plaintext.len - 1), ct, tag)
  ctx.clear()

  var blob = newSeq[byte](ct.len + tag.len)
  if ct.len > 0:
    copyMem(addr blob[0], addr ct[0], ct.len)
  copyMem(addr blob[ct.len], addr tag[0], tag.len)
  ciphertextPrefix & $separator & kek.kid & $separator & b64url(nonce) &
    $separator & b64url(blob)

proc decryptField*(fc: FieldCrypto, tableName, ciphertext: string): string =
  ## Mendekripsi `ciphertext` yang dibuat `encryptField` untuk `tableName`. Galat eksplisit
  ## (`DecryptError`) untuk format tak dikenal, `kid` tak dikenal, data diubah, atau salah tabel —
  ## tidak pernah mengembalikan plaintext kosong/palsu.
  requireConfigured(fc)
  if not ciphertext.startsWith(ciphertextPrefix & $separator):
    raise newException(DecryptError, "format ciphertext tidak dikenali")
  let rest = ciphertext[ciphertextPrefix.len + 1 .. ^1]
  let parts = rest.split(separator)
  if parts.len != 3:
    raise newException(DecryptError, "format ciphertext tidak dikenali")
  let kid = parts[0]
  if kid notin fc.keys:
    raise newException(DecryptError, "kid tidak dikenal: " & kid)
  var nonce, blob: seq[byte]
  try:
    nonce = decodeB64(parts[1])
    blob = decodeB64(parts[2])
  except ValueError:
    raise newException(DecryptError, "ciphertext bukan base64 yang sah")
  if nonce.len != nonceBytes:
    raise newException(DecryptError, "panjang nonce tidak sah")
  if blob.len < tagBytes:
    raise newException(DecryptError, "ciphertext terlalu pendek")

  let ctLen = blob.len - tagBytes
  var ct = newSeq[byte](ctLen)
  var tag = newSeq[byte](tagBytes)
  if ctLen > 0:
    copyMem(addr ct[0], addr blob[0], ctLen)
  copyMem(addr tag[0], addr blob[ctLen], tagBytes)

  var dek = deriveKey(fc.keys[kid].raw, dekInfoPrefix & tableName)
  defer:
    ncUtils.burnMem(dek)

  var ctx: GCM[aes256]
  ctx.init(dek, nonce, tableName.toOpenArrayByte(0, tableName.len - 1))
  var pt = newSeq[byte](ctLen)
  var ok: bool
  if ctLen == 0:
    var computed: array[tagBytes, byte]
    ctx.getTag(computed)
    ok = constantTimeEquals(computed, tag)
  else:
    ok = ctx.decrypt(ct, pt, tag)
  ctx.clear()

  if not ok:
    raise newException(DecryptError,
      "dekripsi gagal: data rusak, berubah, atau salah tabel")
  result = newString(pt.len)
  if pt.len > 0:
    copyMem(addr result[0], addr pt[0], pt.len)

proc normalizeDigits*(s: string): string =
  ## Normalisasi eksplisit untuk field bernilai angka (NIK/NPWP/no. HP): sisakan digit ASCII
  ## saja. **Bukan** normalisasi Unicode — nilai huruf/alamat tidak dinormalisasi di sini.
  for c in s:
    if c in {'0' .. '9'}:
      result.add c

proc blindIndex*(fc: FieldCrypto, tableName, value: string): string =
  ## Blind index deterministik (HMAC-SHA256, keluaran hex huruf kecil) dengan kunci turunan
  ## **terpisah** dari kunci enkripsi dan ber-domain per tabel. Pencarian kesamaan dilakukan
  ## dengan membandingkan indeks; nilai asli tidak pernah muncul di keluaran/galat.
  ## Panggil `normalizeDigits` lebih dulu untuk field angka bila perlu.
  requireConfigured(fc)
  if tableName.len == 0:
    raise newException(FieldCryptoError, "nama tabel tidak boleh kosong")
  let kek = fc.activeKey()
  var bidxKey = deriveKey(kek.raw, bidxInfoPrefix & tableName)
  defer:
    ncUtils.burnMem(bidxKey)
  let digest = hmacSha256(bidxKey, value)
  ncUtils.toHex(digest, lowercase = true)
