import std/unittest
import kernel/result

suite "result":
  test "ok dan err dasar":
    let a = ok[int, string](3)
    check a.isOk
    check not a.isErr
    check a.value == 3
    let b = err[int, string]("boom")
    check b.isErr
    check b.error == "boom"

  test "value() pada error adalah bug -> ValueError":
    let b = err[int, string]("boom")
    expect ValueError:
      discard b.value

  test "error() pada ok adalah bug -> ValueError":
    expect ValueError:
      discard ok[int, string](1).error

  test "mapOk / mapErr":
    check ok[int, string](2).mapOk(proc(v: int): int = v * 3).value == 6
    check err[int, string]("x").mapOk(proc(v: int): int = v * 3).isErr
    check err[int, string]("x").mapErr(proc(s: string): string = s & "!").error == "x!"
    check ok[int, string](2).mapErr(proc(s: string): string = s & "!").value == 2

  test "AppError membawa kode + kunci i18n (bukan kalimat jadi)":
    let e = appError("DEP-1001", "deposit.error.limit", aekValidation, "limit harian")
    check e.code == "DEP-1001"
    check e.i18nKey == "deposit.error.limit"
    check e.kind == aekValidation
    check $e == "DEP-1001 [VALIDATION] deposit.error.limit: limit harian"
    check appError("X-1", "k", aekNotFound).kind == aekNotFound
