import std/unittest
import std/times

import kernel/clock

suite "clock":
  test "systemClock mendekati utcNow":
    let c = systemClock()
    let delta = abs((c.now() - utcNow()).inSeconds)
    check delta <= 5

  test "fakeClock set & advance":
    let t = dateTime(2026, mOct, 13, 0, 0, 0, 0, utc())
    let fc = fakeClock(t)
    check fc.now() == t
    fc.advance(3600)
    check fc.now() == t + initDuration(seconds = 3600)
    fc.setNow(t)
    check fc.now() == t

  test "dispatch lewat tipe dasar Clock":
    let t = dateTime(2026, mOct, 13, 12, 0, 0, 0, utc())
    let c: Clock = fakeClock(t)
    check c.now() == t
    let s: Clock = systemClock()
    check abs((s.now() - utcNow()).inSeconds) <= 5
