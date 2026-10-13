import std/unittest
import std/[sets, times]
import kernel

suite "ids (UUIDv7)":
  test "newId menghasilkan UUIDv7 yang valid":
    let c = fakeClock(dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc()))
    let id = newId(c)
    check ($id).len == 36
    check isUuidV7($id)
    check ($id)[8] == '-' and ($id)[13] == '-' and ($id)[18] == '-' and ($id)[23] == '-'
    check ($id)[14] == '7'
    check ($id)[19] in {'8', '9', 'a', 'b'}

  test "prefiks timestamp membuat urutan bertambah seiring waktu":
    let c = fakeClock(dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc()))
    let a = $newId(c)
    c.advance(1) # 1 detik
    let b = $newId(c)
    c.advance(3600)
    let d = $newId(c)
    check a < b
    check b < d

  test "unik dalam satu milidetik yang sama":
    let c = fakeClock(dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc()))
    var seen = initHashSet[string]()
    for _ in 0 ..< 2000:
      seen.incl($newId(c))
    check seen.len == 2000

  test "parseId round-trip & validasi":
    let c = systemClock()
    let id = newId(c)
    check parseId($id).value == id
    check parseId("00000000-0000-7000-8000-000000000000").isOk
    check parseId("00000000-0000-0000-8000-000000000000").isOk # versi 0 tetap sah diparsing
    check not isUuidV7("00000000-0000-0000-8000-000000000000")
    check isUuidV7($parseId("00000000-0000-7000-8000-000000000000").value)
    check parseId("00000000000070008000000000000000").isErr # tanpa dash
    check parseId("00000000-0000-7000-8000-00000000000g").isErr
    check parseId("not-a-uuid").isErr
    check parseId("00000000-0000-7000-8000-0000000000000").isErr
    # bentuk huruf besar dinormalkan ke lowercase
    check $parseId("ABCDEF00-0000-7000-8000-000000000000").value ==
      "abcdef00-0000-7000-8000-000000000000"

  test "correlation id: 32 hex, unik":
    let a = newCorrelationId()
    let b = newCorrelationId()
    check a.len == 32
    check a != b
    for c in a:
      check c in {'0' .. '9', 'a' .. 'f'}
