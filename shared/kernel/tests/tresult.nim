import std/unittest
import std/strutils

import kernel/result

suite "result":
  test "ok / err dan isOk / isErr":
    let a = ok[int, string](42)
    check a.isOk
    check not a.isErr
    check a.value == 42
    let b = err[int, string]("boom")
    check b.isErr
    check not b.isOk
    check b.error == "boom"

  test "value menaikkan ValueError bila error":
    let b = err[int, string]("boom")
    expect ValueError:
      discard b.value

  test "error menaikkan ValueError bila sukses":
    let a = ok[int, string](1)
    expect ValueError:
      discard a.error

  test "value AppError memuat code":
    let r = err[int, AppError](appError("DEP-1001", "deposit.err", aekDomain, "gagal"))
    var msg = ""
    try:
      discard r.value
    except ValueError as e:
      msg = e.msg
    check msg.contains("DEP-1001")
    check msg.contains("gagal")

  test "mapOk hanya mengubah jalur sukses":
    let a = ok[int, string](3)
    check a.mapOk(proc(v: int): int = v * 2).value == 6
    let b = err[int, string]("x")
    check b.mapOk(proc(v: int): int = v * 2).error == "x"

  test "appError dan $":
    let e = appError("DEP-1001", "deposit.err", aekDomain, "detail",
                     @[("amount", "1000")])
    check e.code == "DEP-1001"
    check e.kind == aekDomain
    check e.params.len == 1
    check ($e).contains("DEP-1001")
