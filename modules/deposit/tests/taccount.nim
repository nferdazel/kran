## Unit test domain `deposit` (T-088a): nomor rekening provisoris, tipe/status, bentuk rekening.
##
## Murni (tanpa DB) — invarian DB diuji di `itaccount`.

import std/unittest

import kernel/[ids, money]
import ../api

suite "deposit: nomor rekening provisoris":
  test "dipad nol selebar 10, tanpa check digit":
    check formatAccountNo(1) == "0000000001"
    check formatAccountNo(42) == "0000000042"
    check formatAccountNo(1_234_567_890) == "1234567890"
    check formatAccountNo(9_999_999_999) == "9999999999"
    for n in [1'i64, 7, 12345, 9_999_999_999'i64]:
      check formatAccountNo(n).len == accountNoWidth

  test "urutan tidak sah ditolak, bukan menghasilkan nomor aneh":
    expect ValueError:
      discard formatAccountNo(0)
    expect ValueError:
      discard formatAccountNo(-1)
    expect ValueError:
      discard formatAccountNo(10_000_000_000'i64) # 11 digit: tak muat selebar 10

suite "deposit: tipe & status":
  test "tipe hanya SAVINGS":
    check parseAccountType("savings") == atSavings
    check parseAccountType(" SAVINGS ") == atSavings
    expect ValueError:
      discard parseAccountType("TIME_DEPOSIT")

  test "status dikenal dan dinormalisasi":
    check parseAccountStatus("active") == asActive
    check parseAccountStatus("Closed") == asClosed
    expect ValueError:
      discard parseAccountStatus("DORMANT")

suite "deposit: bentuk rekening":
  proc sample(seqNo = 1'i64): Account =
    newAccount(Id("11111111-1111-7111-8111-111111111111"),
      Id("22222222-2222-7222-8222-222222222222"),
      Id("33333333-3333-7333-8333-333333333333"),
      Id("44444444-4444-7444-8444-444444444444"), "SAV01",
      Id("55555555-5555-7555-8555-555555555555"), "2026-10-22", seqNo)

  test "rekening baru ACTIVE, SAVINGS, saldo nol":
    let a = sample()
    check a.accountType == atSavings
    check a.status == asActive
    check a.balance == zero()
    check a.productCode == "SAV01"
    check a.accountNo == "0000000001"

  test "field wajib dan tanggal divalidasi":
    expect ValueError:
      discard newAccount(Id("11111111-1111-7111-8111-111111111111"), Id(""),
        Id("33333333-3333-7333-8333-333333333333"),
        Id("44444444-4444-7444-8444-444444444444"), "SAV01",
        Id("55555555-5555-7555-8555-555555555555"), "2026-10-22", 1)
    expect ValueError:
      discard newAccount(Id("11111111-1111-7111-8111-111111111111"),
        Id("22222222-2222-7222-8222-222222222222"),
        Id("33333333-3333-7333-8333-333333333333"),
        Id("44444444-4444-7444-8444-444444444444"), "SAV01",
        Id("55555555-5555-7555-8555-555555555555"), "22-10-2026", 1)
