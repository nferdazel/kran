import std/unittest
import std/times
import kernel

suite "auditcontext":
  test "konstruksi eksplisit":
    let uid = newId(systemClock())
    let b1 = newId(systemClock())
    let b2 = newId(systemClock())
    let t = dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc())
    let ctx = newAuditContext(
      uid,
      branchIds = @[b1, b2],
      ip = "10.0.0.9",
      device = "teller-01",
      reason = "override limit harian",
      correlationId = "abc123",
      startedAt = t,
    )
    check ctx.userId == uid
    check ctx.branchIds.len == 2
    check ctx.branchIds[0] == b1
    check ctx.ip == "10.0.0.9"
    check ctx.device == "teller-01"
    check ctx.reason == "override limit harian"
    check ctx.correlationId == "abc123"
    check ctx.startedAt == t

  test "varian dengan Clock: waktu & correlation id terisi otomatis":
    let c = fakeClock(dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc()))
    let ctx = newAuditContext(newId(c), c)
    check ctx.startedAt == c.now()
    check ctx.correlationId.len == 32
    check ctx.branchIds.len == 0
    check ctx.reason == ""

  test "dua konteks tidak berbagi correlation id":
    let c = fakeClock(dateTime(2026, Month(10), 13, 9, 0, 0, 0, utc()))
    check newAuditContext(newId(c), c).correlationId !=
      newAuditContext(newId(c), c).correlationId
