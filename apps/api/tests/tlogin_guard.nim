## Unit test pembatas login (T-128).
##
## Waktu selalu dioper eksplisit (`now`) supaya jendela per-IP bisa diuji tanpa menunggu dan tanpa
## bergantung pada jam mesin. Yang diuji adalah kontraknya, bukan angkanya: batas konkurensi
## menahan KDF, jendela per-IP menahan pengulangan, dan slot selalu bisa dilepas.

import std/[times, unittest]

import ../src/login_guard

suite "pembatas login (T-128)":
  test "tanpa guard (test/CLI) tidak pernah menahan":
    var absent: LoginGuard
    check absent.tryBegin("10.0.0.1").allowed
    absent.finish() # tidak melempar

  test "batas konkurensi menahan percobaan berikutnya":
    let guard = newLoginGuard()
    let now = epochTime()
    for i in 0 ..< loginConcurrencyLimit:
      check guard.tryBegin("10.0.0.1", now).allowed
    let denied = guard.tryBegin("10.0.0.1", now)
    check not denied.allowed
    check denied.retryAfter == 1
    # Satu slot dilepas → satu percobaan berikutnya diterima.
    guard.finish()
    check guard.tryBegin("10.0.0.1", now).allowed

  test "jendela per-IP membatasi pengulangan walau tanpa konkurensi":
    let started = epochTime()
    let guard = newLoginGuard()
    for i in 0 ..< loginAttemptsPerMinute:
      check guard.tryBegin("10.0.0.1", started + 1).allowed
      guard.finish()

    let blocked = guard.tryBegin("10.0.0.1", started + 1)
    check not blocked.allowed
    check blocked.retryAfter >= int(loginWindowSeconds) - 1

    # IP lain punya jatahnya sendiri: satu pengguna nakal tidak mengunci kantor.
    check guard.tryBegin("10.0.0.2", started + 1).allowed
    guard.finish()

    # Lewat jendela, jatah IP pertama pulih.
    check guard.tryBegin("10.0.0.1", started + loginWindowSeconds + 2).allowed
