## Unit test utilitas HTTP (T-128): gerbang Origin WebSocket dan header respons.
##
## Keduanya murni (tanpa server/DB), jadi dinamai `t*`. Gerbang Origin adalah pengganti praktis
## `SameSite=Strict` untuk handshake WebSocket; salah di sini berarti stream bisa dibuka dari situs
## lain memakai cookie sesi pengguna.

import std/[strutils, unittest]

import mummy

import ../src/http_util

suite "sameOrigin (gerbang WebSocket, T-128/SEC-4)":
  test "origin yang sama diloloskan":
    check sameOrigin("https://kran.example", "kran.example")
    check sameOrigin("http://127.0.0.1:8080", "127.0.0.1:8080")
    check sameOrigin("HTTPS://KRAN.EXAMPLE", "kran.example")

  test "origin kosong diloloskan (klien non-browser)":
    # Bukan pelonggaran: koneksi tanpa Origin tetap harus membawa cookie sesi yang sah.
    check sameOrigin("", "kran.example")

  test "origin lain ditolak":
    check not sameOrigin("https://evil.example", "kran.example")
    check not sameOrigin("https://kran.example.evil.example", "kran.example")
    check not sameOrigin("https://kran.example:8443", "kran.example")

  test "origin tanpa skema yang dikenal atau 'null' ditolak":
    # `Origin: null` dikirim sandbox/iframe/file://; itu bukan host kita.
    check not sameOrigin("null", "kran.example")
    check not sameOrigin("kran.example", "kran.example")
    check not sameOrigin("wss://kran.example", "kran.example")


suite "headersWithType (T-128/SEC-3)":
  test "respons API tidak boleh disimpan browser":
    for contentType in [ContentTypeJson, ContentTypeProblem]:
      let headers = headersWithType(contentType)
      check headers["Content-Type"] == contentType
      check headers["Cache-Control"] == "no-store"

suite "sanitizeCorrelationId (T-133/API-10)":
  test "id wajar dipakai apa adanya":
    check sanitizeCorrelationId("req-1234_ab.cd:ef") == "req-1234_ab.cd:ef"
    check sanitizeCorrelationId("  4bf92f3577b34da6  ") == "4bf92f3577b34da6"

  test "kosong, kepanjangan, atau berisi karakter lain diganti (bukan dipotong)":
    check sanitizeCorrelationId("") == ""
    check sanitizeCorrelationId("   ") == ""
    check sanitizeCorrelationId(repeat('a', maxCorrelationIdLength + 1)) == ""
    check sanitizeCorrelationId("id dengan spasi") == ""
    check sanitizeCorrelationId("id\nbaru") == ""
    check sanitizeCorrelationId("id;palsu") == ""
