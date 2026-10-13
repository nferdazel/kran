import std/unittest
import std/times
import std/strutils

import kernel/ids
import kernel/clock

suite "ids":
  test "newId menghasilkan UUIDv7 valid":
    let c = fakeClock(dateTime(2026, mOct, 13, 0, 0, 0, 0, utc()))
    let id = newId(c)
    check isUuidV7($id)
    check parseId($id).isOk
    check parseId($id).value == id

  test "UUIDv7 terurut waktu":
    let c = fakeClock(dateTime(2026, mOct, 13, 0, 0, 0, 0, utc()))
    let a = newId(c)
    c.advance(1)
    let b = newId(c)
    check ($a) < ($b)

  test "newId unik walau waktu sama":
    let c = fakeClock(dateTime(2026, mOct, 13, 0, 0, 0, 0, utc()))
    let a = newId(c)
    let b = newId(c)
    check a != b

  test "parseId menolak non-v7 dan bentuk salah":
    check not isUuidV7("00000000-0000-4000-8000-000000000000")  # versi 4
    check not isUuidV7("tidak-uuid")
    check parseId("00000000-0000-4000-8000-000000000000").isErr

  test "parseId menormalkan ke lowercase":
    let c = fakeClock(dateTime(2026, mOct, 13, 0, 0, 0, 0, utc()))
    let id = newId(c)
    check parseId(($id).toUpperAscii()).value == id

  test "newCorrelationId 32 hex":
    let corr = newCorrelationId()
    check corr.len == 32
    for ch in corr:
      check ch in {'0' .. '9', 'a' .. 'f'}
