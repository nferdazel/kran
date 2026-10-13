## Test hash password & token sesi (T-006). Tanpa DB.
##
## Vektor PBKDF2 di bawah **bukan** keluaran kode ini: dihitung independen dengan
## `hashlib.pbkdf2_hmac('sha256', ...)` (Python) — jadi test benar-benar membandingkan
## implementasi dengan oracle lain, bukan dengan dirinya sendiri.

import std/[base64, options, unittest]

import platform/infrastructure/password_hasher

const
  saltKb = "MDEyMzQ1Njc4OWFiY2RlZg=="                          # base64("0123456789abcdef")
  vectorDigest = "cYbq+2ndA9+QznC+aJXBQGTHybxE2799+S43kXhwqz8=" # pbkdf2(sha256,"rahasia-panjang-123",salt,1000,32)
  vectorEmpty = "1SowFvcyM8WmWKE5mw1mE6SzWhTrQkI1ozLfFjQpvY4=" # pbkdf2(sha256,"",salt,1000,32)

suite "hash password: vektor independen":
  test "PBKDF2-HMAC-SHA256 cocok dengan oracle python (hashlib)":
    let h = hashPassword("rahasia-panjang-123", 1000, saltKb)
    check h.algo == algoName
    check h.iterations == 1000
    check h.saltB64 == saltKb
    check h.digestB64 == vectorDigest

  test "password kosong pun punya hash spesifik (tidak ada jalur pintas)":
    check hashPassword("", 1000, saltKb).digestB64 == vectorEmpty

  test "salt berbeda → hash berbeda untuk password yang sama":
    let a = hashPassword("rahasia-panjang-123", 1000)
    let b = hashPassword("rahasia-panjang-123", 1000)
    check a.saltB64 != b.saltB64
    check a.digestB64 != b.digestB64
    check verifyPassword("rahasia-panjang-123", $a)
    check verifyPassword("rahasia-panjang-123", $b)

  test "iterasi berbeda → hash berbeda":
    check hashPassword("rahasia-panjang-123", 1000, saltKb).digestB64 !=
      hashPassword("rahasia-panjang-123", 2000, saltKb).digestB64

  test "iterasi tidak sah ditolak":
    var raised = false
    try:
      discard hashPassword("x", 0)
    except ValueError:
      raised = true
    check raised

suite "verify password":
  test "password benar diterima, salah ditolak":
    let stored = $hashPassword("rahasia-panjang-123", 1000)
    check verifyPassword("rahasia-panjang-123", stored)
    check not verifyPassword("rahasia-panjang-124", stored)
    check not verifyPassword("", stored)
    check not verifyPassword("RAHASIA-PANJANG-123", stored)

  test "bentuk hash rusak → ditolak (gagal-tertutup)":
    for bad in ["", "rahasia", "pbkdf2-hmac-sha256$1000$salt", "pbkdf2-hmac-sha256$abc$s$d",
                "pbkdf2-hmac-sha256$0$s$d", "scrypt$1000$s$d", "pbkdf2-hmac-sha256$1000$$d",
                "pbkdf2-hmac-sha256$1000$s$"]:
      check not verifyPassword("rahasia-panjang-123", bad)
      check parseEncoded(bad).isNone

  test "digest yang diubah tidak diterima (integritas)":
    let h = hashPassword("rahasia-panjang-123", 1000, saltKb)
    let digestPalsu = base64.encode(newSeq[byte](digestBytes))
    let rusak = algoName & encodedSeparator & $h.iterations & encodedSeparator & h.saltB64 &
      encodedSeparator & digestPalsu
    check not verifyPassword("rahasia-panjang-123", rusak)

  test "hash lama tetap valid setelah kebijakan iterasi naik (parameter ikut tersimpan)":
    let lama = $hashPassword("rahasia-panjang-123", 1000)
    # kebijakan baru: 2000 iterasi — password lama harus tetap bisa diverifikasi
    check verifyPassword("rahasia-panjang-123", lama)
    let baru = hashPassword("rahasia-panjang-123", 2000)
    check baru.iterations == 2000
    check verifyPassword("rahasia-panjang-123", $baru)

suite "token sesi":
  test "token acak: unik, URL-safe, 256-bit":
    let a = newSessionToken()
    let b = newSessionToken()
    check a != b
    check a.len >= 40 # 32 byte → 43 karakter base64 tanpa padding
    for c in a:
      check c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_'}

  test "hash token cocok dengan oracle python (sha256)":
    check tokenHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check tokenHash("token-uji") ==
      "229dfca6c2b1fe88bae75f2bddc51a853aa9f699ad6341286e148afb0d4901d1"

  test "hash token deterministik dan token berbeda → hash berbeda":
    check tokenHash("token-uji") == tokenHash("token-uji")
    check tokenHash("token-uji") != tokenHash("token-uji-2")
