## Unit test kunci & sidik jari idempotensi (T-084). Tanpa DB.

import std/[strutils, unittest]

import ../domain/idempotency

suite "validateIdempotencyKey":
  test "spasi tepi dipangkas, kunci wajar diterima":
    check validateIdempotencyKey("  abc-123  ") == "abc-123"

  test "kunci kosong atau hanya spasi ditolak":
    expect ValueError:
      discard validateIdempotencyKey("   ")

  test "batas panjang 200 diterima, 201 ditolak":
    let batas = repeat('k', maxIdempotencyKeyLength)
    check validateIdempotencyKey(batas).len == maxIdempotencyKeyLength
    expect ValueError:
      discard validateIdempotencyKey(batas & "k")

  test "karakter kontrol ditolak":
    expect ValueError:
      discard validateIdempotencyKey("abc\ndef")

suite "requestHash":
  test "SHA-256 vektor kosong":
    check requestHash("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  test "deterministik dan membedakan isi":
    check requestHash("""{"a":1}""") == requestHash("""{"a":1}""")
    check requestHash("""{"a":1}""") != requestHash("""{"a":2}""")
