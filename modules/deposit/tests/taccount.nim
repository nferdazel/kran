## Unit test domain `deposit` (T-088a): nomor rekening provisoris, tipe/status, bentuk rekening.
##
## Murni (tanpa DB) — invarian DB diuji di `itaccount`.

import std/unittest

import kernel/[ids, money]
import ../api

suite "deposit: nomor rekening (kode cabang + nomor urut)":
  test "kode cabang 3 digit di depan, nomor urut 7 digit (D-135)":
    check formatAccountNo("001", 1) == "0010000001"
    check formatAccountNo("001", 42) == "0010000042"
    check formatAccountNo("123", 9_999_999) == "1239999999"
    for n in [1'i64, 7, 12345, 9_999_999'i64]:
      check formatAccountNo("001", n).len == accountNoWidth

  test "kode cabang harus tepat 3 digit":
    check validBranchCode("001")
    for bad in ["", "1", "1234", "12a", " 01", "abc"]:
      check not validBranchCode(bad)
      expect ValueError:
        discard formatAccountNo(bad, 1)

  test "urutan tidak sah ditolak, bukan menghasilkan nomor aneh":
    expect ValueError:
      discard formatAccountNo("001", 0)
    expect ValueError:
      discard formatAccountNo("001", -1)
    expect ValueError:
      discard formatAccountNo("001", 10_000_000'i64) # 8 digit: tak muat selebar 7

suite "deposit: tipe & status":
  test "tipe SAVINGS/TIME_DEPOSIT dikenal, tipe lain ditolak":
    check parseAccountType("savings") == atSavings
    check parseAccountType(" SAVINGS ") == atSavings
    check parseAccountType("time_deposit") == atTimeDeposit
    check parseAccountType("Time_Deposit") == atTimeDeposit
    expect ValueError:
      discard parseAccountType("GIRO")
    expect ValueError:
      discard parseAccountType("")

  test "status dikenal dan dinormalisasi":
    check parseAccountStatus("active") == asActive
    check parseAccountStatus("Closed") == asClosed
    # DORMANT baru sah setelah T-138e/0071 punya aturan deteksi + reaktivasi (D-157).
    check parseAccountStatus(" dormant ") == asDormant
    expect ValueError:
      discard parseAccountStatus("FROZEN")

  test "instruksi ARO dikenal, nilai asing ditolak (D-155)":
    check parseAroInstruction("none") == aiNone
    check parseAroInstruction(" PRINCIPAL ") == aiPrincipal
    check parseAroInstruction("principal_and_interest") == aiPrincipalAndInterest
    expect ValueError:
      discard parseAroInstruction("")
    expect ValueError:
      discard parseAroInstruction("ROLLOVER")

suite "deposit: bentuk rekening":
  proc sample(seqNo = 1'i64): Account =
    newAccount(Id("11111111-1111-7111-8111-111111111111"),
      Id("22222222-2222-7222-8222-222222222222"),
      Id("33333333-3333-7333-8333-333333333333"),
      Id("44444444-4444-7444-8444-444444444444"), "SAV01",
      Id("55555555-5555-7555-8555-555555555555"), "001", "2026-10-22", seqNo)

  test "rekening baru ACTIVE, SAVINGS, saldo nol":
    let a = sample()
    check a.accountType == atSavings
    check a.status == asActive
    check a.balance == zero()
    check a.productCode == "SAV01"
    check a.accountNo == "0010000001"
    # Klasifikasi simpanan datang dari join produk, bukan dibuat di sini (T-111): default kosong.
    check a.savingsKind == ""

  test "field wajib dan tanggal divalidasi":
    expect ValueError:
      discard newAccount(Id("11111111-1111-7111-8111-111111111111"), Id(""),
        Id("33333333-3333-7333-8333-333333333333"),
        Id("44444444-4444-7444-8444-444444444444"), "SAV01",
        Id("55555555-5555-7555-8555-555555555555"), "001", "2026-10-22", 1)
    expect ValueError:
      discard newAccount(Id("11111111-1111-7111-8111-111111111111"),
        Id("22222222-2222-7222-8222-222222222222"),
        Id("33333333-3333-7333-8333-333333333333"),
        Id("44444444-4444-7444-8444-444444444444"), "SAV01",
        Id("55555555-5555-7555-8555-555555555555"), "001", "22-10-2026", 1)
