## Primitif TOTP (RFC 6238) di atas HOTP (RFC 4226) + base32 (RFC 4648).
##
## **HUMAN-REVIEW-REQUIRED (kripto/autentikasi)** — AGENTS.md §8: berkas ini menyediakan faktor
## kedua. Perubahan di sini wajib di-review manusia, bukan hanya test hijau.
##
## Kenapa di sini (bukan `modules/platform`): ini primitif kripto murni tanpa I/O, sekamar dengan
## `fieldcrypto`; Fase 1 modul lain (mis. `lending` untuk tanda tangan operator) bisa memakainya,
## dan `shared/*` boleh diimpor modul mana pun (tools/archcheck). Tidak ada dependensi baru:
## `nimcrypto` sudah dipakai field crypto.
##
## Yang **tidak** ada di sini (sengaja): pemanggilan waktu, penyimpanan, dan kebijakan (digit,
## periode, toleransi drift). Semuanya parameter DB + milik pemanggil, supaya fungsinya bisa diuji
## dengan vektor RFC pada waktu yang tetap.

import std/[options, strutils, sysrand]

import nimcrypto/[hmac, sha]

const
  ## Panjang rahasia awal, mengikuti RFC 4226 §4 R6 (minimal 128 bit, dianjurkan 160 bit).
  secretBytes* = 20 # nomagic:ok teknis: 160 bit = panjang HMAC-SHA-1 (RFC 4226 R6)
  ## Batas bentuk kode yang diterima (RFC 4226 §5.3 mengizinkan 6–8 digit; di atas itu tidak ada
  ## aplikasi authenticator yang memakainya, dan `10^digits` masih muat di `int64`).
  minDigits* = 6
  maxDigits* = 10
  ## Batas periode: di bawah 15 detik jam perangkat tidak realistis, di atas 300 detik jendela
  ## tebak terlalu lebar.
  minPeriodSeconds* = 15
  maxPeriodSeconds* = 300

  base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  bitsPerChar = 5 # nomagic:ok teknis: base32 = 5 bit per karakter (RFC 4648 §6)
  byteBits = 8 # nomagic:ok teknis: satu byte = 8 bit

type
  TotpError* = object of CatchableError
    ## Parameter bentuk tidak sah (digit/periode di luar rentang, rahasia terlalu pendek).
    ## Kesalahan konfigurasi, bukan kesalahan pengguna.

proc base32Encode*(data: openArray[byte], padding = true): string =
  ## Base32 RFC 4648 §6 huruf besar. `padding = false` menghasilkan bentuk tanpa `=` (bentuk yang
  ## lazim dipakai rahasia `otpauth://`).
  var buffer = 0
  var bits = 0
  for b in data:
    buffer = (buffer shl byteBits) or int(b)
    bits += byteBits
    while bits >= bitsPerChar:
      bits -= bitsPerChar
      result.add base32Alphabet[(buffer shr bits) and (1 shl bitsPerChar) - 1]
      buffer = buffer and ((1 shl bits) - 1)
  if bits > 0:
    result.add base32Alphabet[(buffer shl (bitsPerChar - bits)) and (1 shl bitsPerChar) - 1]
  if padding:
    while result.len mod 8 != 0:
      result.add '='

proc base32Decode*(text: string): seq[byte] =
  ## Kebalikan `base32Encode`. Menerima huruf besar/kecil, mengabaikan spasi dan `-` (bentuk yang
  ## ditampilkan ke pengguna sering dikelompokkan), padding `=` opsional.
  ##
  ## Galat = `ValueError`, bukan hasil kosong/terpotong: rahasia yang salah ketik tidak boleh
  ## diam-diam menjadi kunci **berbeda** yang gagal tanpa sebab yang terlihat.
  var buffer = 0
  var bits = 0
  var afterPadding = false
  for raw in text:
    if raw == ' ' or raw == '-':
      continue
    if raw == '=':
      afterPadding = true
      continue
    if afterPadding:
      raise newException(ValueError, "base32: karakter setelah padding")
    let idx = base32Alphabet.find(raw.toUpperAscii)
    if idx < 0:
      raise newException(ValueError, "base32: karakter tidak sah")
    buffer = (buffer shl bitsPerChar) or idx
    bits += bitsPerChar
    if bits >= byteBits:
      bits -= byteBits
      result.add byte((buffer shr bits) and 0xff)
      buffer = buffer and ((1 shl bits) - 1)
  if bits > 0 and buffer != 0:
    raise newException(ValueError, "base32: sisa bit tidak nol")

proc newTotpSecret*(bytes = secretBytes): string =
  ## Rahasia baru dari CSPRNG OS (`std/sysrand`), dikembalikan sebagai base32 tanpa padding.
  if bytes < secretBytes:
    raise newException(TotpError,
      "rahasia minimal " & $secretBytes & " byte (diminta " & $bytes & ")")
  base32Encode(urandom(bytes), padding = false)

proc normalizeCode*(code: string): string =
  ## Kode dari pengguna: spasi/`-` dibuang; selain angka → `""` (pasti tidak cocok, tanpa galat
  ## yang membedakan "bentuk salah" dari "kode salah").
  for c in code:
    if c in {'0' .. '9'}:
      result.add c
    elif c == ' ' or c == '-':
      discard
    else:
      return ""

proc constantTimeEquals*(a, b: string): bool =
  ## Perbandingan waktu-tetap untuk kode: panjang berbeda tetap dibandingkan sampai selesai.
  var diff = a.len xor b.len
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: ord(a[i]) else: 0
    let y = if i < b.len: ord(b[i]) else: 0
    diff = diff or (x xor y)
  diff == 0

proc hotp*(secret: openArray[byte], counter: uint64, digits: int): string =
  ## HOTP RFC 4226 §5.3: `HMAC-SHA-1(secret, counter)` → pemotongan dinamis → modulo `10^digits`.
  if digits < minDigits or digits > maxDigits:
    raise newException(TotpError, "jumlah digit di luar rentang " & $minDigits & "–" & $maxDigits)
  if secret.len == 0:
    raise newException(TotpError, "rahasia kosong")
  var message: array[8, byte]
  var rest = counter
  for i in countdown(message.len - 1, 0):
    message[i] = byte(rest and 0xff)
    rest = rest shr byteBits

  var ctx: HMAC[sha1]
  ctx.init(secret)
  ctx.update(message)
  let digest = ctx.finish()
  ctx.clear()

  # Pemotongan dinamis (RFC 4226 §5.3 butir 4): nibble terakhir → offset, 4 byte big-endian,
  # bit paling atas dibuang supaya hasilnya tidak bergantung tanda.
  let offset = int(digest.data[digest.data.len - 1] and 0x0f)
  let truncated =
    ((int(digest.data[offset]) and 0x7f) shl 24) or
    (int(digest.data[offset + 1]) shl 16) or
    (int(digest.data[offset + 2]) shl 8) or
    int(digest.data[offset + 3])
  var modulus = 1
  for _ in 0 ..< digits:
    modulus *= 10
  let value = truncated mod modulus
  result = $value
  if result.len < digits:
    result = repeat('0', digits - result.len) & result

proc stepAt*(unixSeconds: int64, periodSeconds: int): int64 =
  ## Nomor langkah waktu (RFC 6238 §4.2 `T = (Current Unix time - T0) / X`; `T0 = 0`).
  if periodSeconds < minPeriodSeconds or periodSeconds > maxPeriodSeconds:
    raise newException(TotpError, "periode di luar rentang")
  unixSeconds div int64(periodSeconds)

proc totpCode*(secret: openArray[byte], unixSeconds: int64, periodSeconds, digits: int): string =
  ## Kode TOTP pada satu titik waktu (dipakai test & bantu operasional; server selalu memverifikasi).
  hotp(secret, uint64(stepAt(unixSeconds, periodSeconds)), digits)

proc verifyTotp*(secret: openArray[byte], code: string, unixSeconds: int64,
                 periodSeconds, digits, driftSteps: int): Option[int64] =
  ## Memverifikasi kode dan mengembalikan **langkah waktu yang cocok**, bukan sekadar `true`:
  ## pemanggil memakainya untuk menolak kode yang sudah dipakai (`last_used_step`, anti-replay).
  ##
  ## `none` = tidak cocok (termasuk bentuk kode salah) — tanpa membedakan sebab, seperti kebijakan
  ## pesan login (O-034: jangan memberi sinyal yang membedakan keadaan internal).
  ##
  ## Jendela toleransi = `driftSteps` langkah ke belakang dan ke depan (jam perangkat vs server).
  ## Langkah dari yang paling lama ke yang paling baru, jadi kode paling lama yang dipakai ulang
  ## tetap terdeteksi pemanggil lewat `last_used_step` (bukan diam-diam dianggap baru).
  if driftSteps < 0:
    raise newException(TotpError, "toleransi drift tidak boleh negatif")
  let normalized = normalizeCode(code)
  if normalized.len != digits:
    return none(int64)
  let current = stepAt(unixSeconds, periodSeconds)
  for delta in -driftSteps .. driftSteps:
    let step = current + int64(delta)
    if step < 0:
      continue
    if constantTimeEquals(hotp(secret, uint64(step), digits), normalized):
      return some(step)
  none(int64)

proc percentEncode*(text: string): string =
  ## Persen-encoding RFC 3986 (hanya karakter *unreserved* yang dibiarkan). Dipakai untuk label &
  ## nilai `otpauth://` supaya issuer/username ber-spasi atau ber-`@` tidak mengubah makna URI.
  const unreserved = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '.', '_', '~'}
  const hex = "0123456789ABCDEF"
  for c in text:
    if c in unreserved:
      result.add c
    else:
      let b = ord(c)
      result.add '%'
      result.add hex[(b shr 4) and 0x0f]
      result.add hex[b and 0x0f]

proc otpauthUri*(issuer, account, secretBase32: string, digits, periodSeconds: int,
                 algorithm = "SHA1"): string =
  ## URI `otpauth://totp/…` (Key Uri Format) untuk ditampilkan sebagai QR/tautan pendaftaran.
  ## `algorithm` sengaja bisa diisi supaya nilai yang dikirim ke authenticator **eksplisit**
  ## cocok dengan yang divalidasi server, bukan bergantung default aplikasi.
  ##
  ## Nama algoritma di sini adalah nama yang dipakai format URI (`SHA1`/`SHA256`/`SHA512`), bukan
  ## nama modul `nimcrypto`.
  if issuer.len == 0 or account.len == 0 or secretBase32.len == 0:
    raise newException(TotpError, "issuer, akun, dan rahasia wajib diisi")
  "otpauth://totp/" & percentEncode(issuer) & ':' & percentEncode(account) &
    "?secret=" & secretBase32 &
    "&issuer=" & percentEncode(issuer) &
    "&algorithm=" & algorithm &
    "&digits=" & $digits &
    "&period=" & $periodSeconds
