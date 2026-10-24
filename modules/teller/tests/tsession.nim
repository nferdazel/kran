## Unit test domain `teller` sesi kas (T-093): expected cash, variance, validasi nominal/note.
##
## Murni (tanpa DB) — invarian DB (partial unique sesi OPEN, vault FOR UPDATE + tidak negatif,
## CHECK variance, immutability movement) diuji di `itsession`; jalur HTTP di `itapi_teller_sessions`.

import std/[options, strutils, times, unittest]

import kernel/[clock, ids, money]
import ../api

let testClock = fakeClock(dateTime(2026, mOct, 22, 9, 0, 0))

suite "teller: validasi opening float & counted cash":
  test "opening float boleh nol, tidak boleh negatif":
    check validateOpeningFloat(zero()) == zero()
    check validateOpeningFloat(money(100_0000)) == money(100_0000)
    expect ValueError:
      discard validateOpeningFloat(money(-1))

  test "counted cash boleh nol, tidak boleh negatif":
    check validateCountedCash(zero()) == zero()
    check validateCountedCash(money(1234)) == money(1234)
    expect ValueError:
      discard validateCountedCash(money(-1))

  test "note opsional, dibatasi panjang kolom":
    check validateSessionNote("") == ""
    check validateSessionNote("  tutup kas sore  ") == "tutup kas sore"
    expect ValueError:
      discard validateSessionNote(repeat('x', maxSessionNoteLength + 1))

suite "teller: expected cash":
  test "tanpa movement = opening float":
    check expectedCashOf(money(100_0000), zero(), zero()) == money(100_0000)

  test "campuran CASH_IN dan CASH_OUT":
    # 100 float + 30 setoran - 10 penarikan = 120.
    check expectedCashOf(money(100_0000), money(30_0000), money(10_0000)) == money(120_0000)

  test "penarikan melebihi float menghasilkan negatif (bukan dibulatkan)":
    check expectedCashOf(zero(), zero(), money(1)) == money(-1)

  test "net movement dari daftar movement":
    let s = Id("11111111-1111-7111-8111-111111111111")
    let tx = Id("22222222-2222-7222-8222-222222222222")
    let movements = @[
      newCashMovement(Id("33333333-3333-7333-8333-333333333333"), s, cmCashIn, money(30_0000),
        tx, "2026-10-22", "u"),
      newCashMovement(Id("44444444-4444-7444-8444-444444444444"), s, cmCashOut, money(10_0000),
        tx, "2026-10-22", "u"),
    ]
    check netMovementOf(movements) == money(20_0000)
    check expectedCashOf(money(100_0000), money(30_0000), money(10_0000)) ==
      money(100_0000) + netMovementOf(movements)

  test "nominal movement harus positif":
    let s = Id("11111111-1111-7111-8111-111111111111")
    let tx = Id("22222222-2222-7222-8222-222222222222")
    expect ValueError:
      discard newCashMovement(newId(testClock), s, cmCashIn, zero(), tx, "2026-10-22", "u")
    expect ValueError:
      discard newCashMovement(newId(testClock), s, cmCashOut, money(-1), tx, "2026-10-22", "u")

suite "teller: variance":
  test "kas pas = 0, lebih positif, kurang negatif":
    check varianceOf(money(120_0000), money(120_0000)) == zero()
    check varianceOf(money(125_0000), money(120_0000)) == money(5_0000)
    check varianceOf(money(115_0000), money(120_0000)) == money(-5_0000)

  test "skala 2 desimal (sen), tanpa float":
    # Selisih sekecil yang bisa disimpan = 0,01 (D-136).
    check varianceOf(money(100_0001), money(100_0000)) == money(1)
    check varianceOf(money(100_0001), money(100_0000)).toDecimalString == "0.01"

suite "teller: bentuk sesi baru":
  test "sesi baru OPEN tanpa kolom penutup":
    let s = newOpenSession(newId(testClock), Id("11111111-1111-7111-8111-111111111111"),
      Id("22222222-2222-7222-8222-222222222222"), "2026-10-22", money(50_0000),
      Id("22222222-2222-7222-8222-222222222222"))
    check s.status == tssOpen
    check s.expectedCash.isNone
    check s.countedCash.isNone
    check s.variance.isNone
    check s.openingFloat == money(50_0000)

  test "cabang/teller wajib diisi":
    expect ValueError:
      discard newOpenSession(newId(testClock), Id(""), Id("22222222-2222-7222-8222-222222222222"),
        "2026-10-22", zero(), Id("22222222-2222-7222-8222-222222222222"))

  test "status & tipe movement diparse dinormalisasi":
    check parseTellerSessionStatus("open") == tssOpen
    check parseTellerSessionStatus(" CLOSED ") == tssClosed
    check parseCashMovementType("cash_in") == cmCashIn
    check parseCashMovementType("CASH_OUT") == cmCashOut
    expect ValueError:
      discard parseTellerSessionStatus("PENDING")
    expect ValueError:
      discard parseCashMovementType("OPENING_FLOAT")
