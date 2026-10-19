## Test primitif TOTP (T-046). Tanpa DB.
##
## **Vektor di bawah diambil dari RFC**, bukan keluaran kode ini:
##   - HOTP: RFC 4226 Appendix D (rahasia ASCII `12345678901234567890`, 6 digit, counter 0–9).
##   - TOTP: RFC 6238 Appendix B baris `SHA1` (rahasia yang sama, 8 digit, periode 30 detik).
##   - base32: RFC 4648 §10 (vektor `f`, `fo`, `foo`, `foob`, `fooba`, `foobar`).
##
## Kalau implementasi berubah dan vektor ini merah, yang salah implementasinya — bukan vektornya.

import std/[options, unittest]

import "platform-lib/crypto/totp"

# RFC 4226/6238 memakai rahasia ASCII 20 byte ini.
const rfcSecret = "12345678901234567890"
let rfcSecretBytes = @(rfcSecret.toOpenArrayByte(0, rfcSecret.len - 1))

# RFC 4226 Appendix D.
const hotpVectors = [
  ("755224", 0'u64), ("287082", 1'u64), ("359152", 2'u64), ("969429", 3'u64),
  ("338314", 4'u64), ("254676", 5'u64), ("287922", 6'u64), ("162583", 7'u64),
  ("399871", 8'u64), ("520489", 9'u64),
]

# RFC 6238 Appendix B, kolom SHA1 (8 digit).
const totpVectors = [
  (59'i64, "94287082"), (1111111109'i64, "07081804"), (1111111111'i64, "14050471"),
  (1234567890'i64, "89005924"), (2000000000'i64, "69279037"),
  (20000000000'i64, "65353130"),
]

suite "TOTP: base32 RFC 4648":
  test "vektor resmi (dengan padding)":
    check base32Encode(newSeq[byte]()) == ""
    for (plain, encoded) in [("f", "MY======"), ("fo", "MZXQ===="), ("foo", "MZXW6==="),
                            ("foob", "MZXW6YQ="), ("fooba", "MZXW6YTB"),
                            ("foobar", "MZXW6YTBOI======")]:
      let bytes = @(plain.toOpenArrayByte(0, plain.len - 1))
      check base32Encode(bytes) == encoded
      check base32Decode(encoded) == bytes

  test "tanpa padding, huruf kecil, spasi, dan tanda hubung diterima":
    check base32Encode("foobar".toOpenArrayByte(0, 5), padding = false) == "MZXW6YTBOI"
    check base32Decode("mzxw 6ytb-oi") == @("foobar".toOpenArrayByte(0, 5))

  test "rahasia baru: 160-bit, bolak-balik, tidak berulang":
    let a = newTotpSecret()
    let b = newTotpSecret()
    check a.len == 32 # 20 byte * 8 / 5 karakter
    check a != b
    check base32Decode(a).len == 20
    expect TotpError:
      discard newTotpSecret(bytes = 19)

  test "karakter tak sah / sisa bit tak nol ditolak, bukan dipotong diam-diam":
    expect ValueError:
      discard base32Decode("MZXW6YTB1")
    expect ValueError:
      discard base32Decode("MZ") # 1 byte + sisa bit 1 yang tidak nol

suite "TOTP: HOTP RFC 4226":
  test "Appendix D: counter 0-9":
    for (expected, counter) in hotpVectors:
      check hotp(rfcSecretBytes, counter, 6) == expected

  test "jumlah digit di luar rentang ditolak":
    expect TotpError:
      discard hotp(rfcSecretBytes, 0, 5)
    expect TotpError:
      discard hotp(rfcSecretBytes, 0, 11)
    expect TotpError:
      discard hotp(newSeq[byte](), 0, 6)

suite "TOTP: RFC 6238":
  test "Appendix B (SHA1, 8 digit, periode 30 detik)":
    for (unixTime, expected) in totpVectors:
      check totpCode(rfcSecretBytes, unixTime, 30, 8) == expected

  test "jendela drift: menerima tetangga, menolak di luar jendela, dan melaporkan langkahnya":
    # Kode sah untuk langkah 1 (T=59). Pada T=89 (langkah 2) kode itu hanya boleh lolos
    # lewat toleransi satu langkah ke belakang.
    check verifyTotp(rfcSecretBytes, "94287082", 89, 30, 8, 0).isNone
    let previous = verifyTotp(rfcSecretBytes, "94287082", 89, 30, 8, 1)
    check previous.isSome
    check previous.get() == 1
    # Pada T=29 (langkah 0) kode langkah 1 adalah langkah **berikutnya**.
    let upcoming = verifyTotp(rfcSecretBytes, "94287082", 29, 30, 8, 1)
    check upcoming.isSome
    check upcoming.get() == 1
    expect TotpError:
      discard verifyTotp(rfcSecretBytes, "94287082", 29, 30, 8, -1)

  test "bentuk kode: spasi/hubung diabaikan, panjang/isi salah = tidak cocok":
    check verifyTotp(rfcSecretBytes, "9428 7082", 59, 30, 8, 0).isSome
    check verifyTotp(rfcSecretBytes, "9428-7082", 59, 30, 8, 0).isSome
    check verifyTotp(rfcSecretBytes, "9428708", 59, 30, 8, 0).isNone
    check verifyTotp(rfcSecretBytes, "9428708x", 59, 30, 8, 0).isNone
    check normalizeCode(" 12-34 56 ") == "123456"

  test "perbandingan waktu-tetap tetap membedakan isi":
    check constantTimeEquals("123456", "123456")
    check not constantTimeEquals("123456", "123457")
    check not constantTimeEquals("123456", "12345")

suite "TOTP: URI pendaftaran":
  test "bentuk otpauth:// dengan label & issuer ter-encode":
    check otpauthUri("KRAN Koperasi", "budi@example.com", "JBSWY3DPEHPK3PXP", 6, 30) ==
      "otpauth://totp/KRAN%20Koperasi:budi%40example.com?secret=JBSWY3DPEHPK3PXP" &
      "&issuer=KRAN%20Koperasi&algorithm=SHA1&digits=6&period=30"

  test "komponen kosong ditolak":
    expect TotpError:
      discard otpauthUri("", "budi", "JBSWY3DPEHPK3PXP", 6, 30)
    expect TotpError:
      discard otpauthUri("KRAN", "budi", "", 6, 30)
