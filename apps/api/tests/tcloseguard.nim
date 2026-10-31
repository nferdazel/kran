## Unit test gerbang penutupan buku (T-135) — murni, tanpa DB.
##
## Yang diuji di sini hanya aturan "permintaan mana yang dijaga"; perilaku 409-nya diuji di
## `itapi_closeguard.nim` dengan server sungguhan.

import std/unittest

import ../src/close_guard

suite "close guard: cakupan permintaan":
  test "hanya metode yang mengubah data":
    for verb in ["GET", "HEAD", "OPTIONS"]:
      check not closeGuardApplies(verb, "/api/v1/deposit/accounts")
    for verb in ["POST", "PUT", "PATCH", "DELETE"]:
      check closeGuardApplies(verb, "/api/v1/deposit/accounts")

  test "rute autentikasi tetap boleh menulis":
    check not closeGuardApplies("POST", "/api/v1/auth/login")
    check not closeGuardApplies("POST", "/api/v1/auth/password")
    check not closeGuardApplies("POST", "/api/v1/auth/mfa/enrolment")
    # Awalan yang mirip tetapi bukan rute auth tidak ikut dikecualikan.
    check closeGuardApplies("POST", "/api/v1/authorization/roles")
