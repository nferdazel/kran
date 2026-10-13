import std/unittest
import std/times
import kernel

suite "clock":
  test "systemClock mengembalikan waktu UTC dekat sekarang":
    let c = systemClock()
    let before = utcNow()
    let t = c.now()
    let after = utcNow()
    check t.timezone == utc()
    check before - initDuration(milliseconds = 2500) <= t
    check t <= after + initDuration(milliseconds = 2500)
    check utcNow().timezone == utc()

  test "fakeClock deterministik":
    let start = dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc())
    let c = fakeClock(start)
    check c.now() == start
    check c.now() == start
    c.advance(3600)
    check c.now() == start + initDuration(seconds = 3600)
    c.setNow(dateTime(2027, Month(1), 1, 0, 0, 0, 0, utc()))
    check c.now().year == 2027
    check c.now().timezone == utc()

  test "fakeClock menormalkan input non-UTC":
    let localish = dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc())
    let c = fakeClock(localish)
    check c.now().timezone == utc()
