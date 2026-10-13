import std/unittest
import std/times

import kernel/ids
import kernel/clock
import kernel/auditcontext

suite "auditcontext":
  test "startedAt eksplisit":
    let c = fakeClock(dateTime(2026, mOct, 13, 0, 0, 0, 0, utc()))
    let uid = newId(c)
    let t = dateTime(2026, mJan, 1, 8, 0, 0, 0, utc())
    let ctx = newAuditContext(uid, startedAt = t)
    check ctx.userId == uid
    check ctx.startedAt == t

  test "overload clock mengisi startedAt":
    let t = dateTime(2026, mOct, 13, 9, 30, 0, 0, utc())
    let c = fakeClock(t)
    let uid = newId(c)
    let ctx = newAuditContext(uid, c, reason = "koreksi")
    check ctx.startedAt == t
    check ctx.reason == "koreksi"

  test "branchIds dan field teks":
    let c = fakeClock(dateTime(2026, mOct, 13, 0, 0, 0, 0, utc()))
    let uid = newId(c)
    let b1 = newId(c)
    let b2 = newId(c)
    let ctx = newAuditContext(uid, @[b1, b2], "127.0.0.1", "web", "audit", "corr-1",
                              c.now())
    check ctx.branchIds == @[b1, b2]
    check ctx.ip == "127.0.0.1"
    check ctx.device == "web"
    check ctx.correlationId == "corr-1"
