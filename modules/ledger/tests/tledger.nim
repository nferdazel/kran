## Unit test modul `ledger` (T-072): tipe akun, kode COA dari parameter, periode.

import std/[options, strutils, unittest]

import ../api

suite "coa: tipe akun & sisi normal":
  test "tipe dikenal (case-insensitive), lainnya ditolak":
    check parseAccountType("asset") == some(atAsset)
    check parseAccountType(" Liability ") == some(atLiability)
    check parseAccountType("REVENUE") == some(atRevenue)
    check parseAccountType("ASET").isNone
    check parseAccountType("").isNone

  test "sisi normal adalah invarian dari tipe akun":
    check normalSideOf(atAsset) == nsDebit
    check normalSideOf(atExpense) == nsDebit
    check normalSideOf(atLiability) == nsCredit
    check normalSideOf(atEquity) == nsCredit
    check normalSideOf(atRevenue) == nsCredit

  test "status akun dikenal":
    check parseAccountStatus("active") == some(asActive)
    check parseAccountStatus("INACTIVE") == some(asInactive)
    check parseAccountStatus("DELETED").isNone

suite "coa: kode dari pola parameter":
  test "kode yang cocok diterima":
    let rx = compileCodePattern("^[0-9]{1,3}(\\.[0-9]{1,3})*$")
    check validateCode("1", rx) == "1"
    check validateCode("101", rx) == "101"
    check validateCode(" 1.100.01 ", rx) == "1.100.01"

  test "kecocokan harus seluruh string, bukan sebagian":
    let rx = compileCodePattern("^[0-9]{1,3}$")
    expect ValueError:
      discard validateCode("1010", rx)
    expect ValueError:
      discard validateCode("x101", rx)
    expect ValueError:
      discard validateCode("101x", rx)
    # Pola tanpa anchor pun tetap diwajibkan cocok penuh.
    let noAnchor = compileCodePattern("[0-9]{1,3}")
    expect ValueError:
      discard validateCode("x101", noAnchor)

  test "kode kosong dan kepanjangan ditolak":
    let rx = compileCodePattern("^.*$")
    expect ValueError:
      discard validateCode("   ", rx)
    expect ValueError:
      discard validateCode(repeat('1', maxCodeLength + 1), rx)

  test "pola sah yang bisa cocok kosong menolak kode, bukan menjatuhkan request":
    # `findBounds` melempar RangeDefect untuk match kosong; `validateCode` harus memakai
    # `matchLen` sehingga kode tidak cocok = ValueError biasa (400), bukan defect (500 generik).
    let rx = compileCodePattern("[0-9]*")
    check validateCode("101", rx) == "101"
    expect ValueError:
      discard validateCode("ABC", rx)

  test "pola parameter rusak = kesalahan konfigurasi":
    expect ValueError:
      discard compileCodePattern("")
    expect ValueError:
      discard compileCodePattern("(")

  test "nama dinormalisasi dan divalidasi":
    check validateName("  Kas   Kecil ") == "Kas Kecil"
    expect ValueError:
      discard validateName(" ")
    expect ValueError:
      discard validateName(repeat('x', maxNameLength + 1))

suite "period: tanggal & rentang":
  test "tanggal ISO yang benar-benar ada":
    check parseIsoDate("2026-10-01", "startsOn") == "2026-10-01"
    expect ValueError:
      discard parseIsoDate("2026-02-31", "startsOn")
    expect ValueError:
      discard parseIsoDate("2026-13-01", "startsOn")
    expect ValueError:
      discard parseIsoDate("01-10-2026", "startsOn")
    expect ValueError:
      discard parseIsoDate("", "startsOn")

  test "rentang urut diterima, terbalik ditolak":
    check validateRange("2026-10-01", "2026-10-31") == ("2026-10-01", "2026-10-31")
    check validateRange("2026-10-01", "2026-10-01") == ("2026-10-01", "2026-10-01")
    expect ValueError:
      discard validateRange("2026-10-31", "2026-10-01")

  test "status periode dikenal":
    check parsePeriodStatus("open") == some(psOpen)
    check parsePeriodStatus("CLOSED") == some(psClosed)
    check parsePeriodStatus("LOCKED").isNone

  test "alasan penutupan wajib dan dibatasi":
    check validateCloseReason("  tutup bulan September  ") == "tutup bulan September"
    expect ValueError:
      discard validateCloseReason("  ")
    expect ValueError:
      discard validateCloseReason(repeat('x', maxReasonLength + 1))
