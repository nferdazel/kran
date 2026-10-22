## Unit test domain `deposit` transaksi tunai (T-088b): arah, tipe, aritmetika saldo, kunci jurnal.
##
## Murni (tanpa DB) — invarian DB (conditional UPDATE, CHECK saldo, jurnal) diuji di `ittransaction`.

import std/[strutils, unittest]

import kernel/money
import ../api

suite "deposit: arah & tipe transaksi":
  test "arah dinormalisasi (DEPOSIT/WITHDRAWAL), lain ditolak":
    check parseCashDirection("deposit") == cdDeposit
    check parseCashDirection(" WITHDRAWAL ") == cdWithdrawal
    expect ValueError:
      discard parseCashDirection("TRANSFER")
    expect ValueError:
      discard parseCashDirection("")

  test "arah memetakan tipe baris & event ledger":
    check txTypeOf(cdDeposit) == ttCashDeposit
    check txTypeOf(cdWithdrawal) == ttCashWithdrawal
    check sourceEventOf(cdDeposit) == "DepositPosted"
    check sourceEventOf(cdWithdrawal) == "DepositWithdrawn"
    check parseTransactionType("cash_deposit") == ttCashDeposit
    check parseTransactionType("CASH_WITHDRAWAL") == ttCashWithdrawal
    expect ValueError:
      discard parseTransactionType("TRANSFER")

suite "deposit: nominal & narration":
  test "nominal harus positif":
    check validateAmount(money(1)) == money(1)
    expect ValueError:
      discard validateAmount(zero())
    expect ValueError:
      discard validateAmount(money(-1))

  test "narration opsional, dibatasi panjang kolom":
    check validateNarration("") == ""
    check validateNarration("  setor  ") == "setor"
    expect ValueError:
      discard validateNarration(repeat('x', maxNarrationLength + 1))

suite "deposit: aritmetika saldo":
  test "setor menambah saldo":
    check balanceAfterDeposit(money(100_0000), money(50_0000)) == money(150_0000)
    check balanceAfterDeposit(zero(), money(1)) == money(1)

  test "tarik mengurangi saldo sampai tepat minimum":
    check balanceAfterWithdrawal(money(100_0000), money(40_0000), zero()) == money(60_0000)
    # Tarik tepat sebesar saldo (min 0) boleh → saldo 0, tidak negatif.
    check balanceAfterWithdrawal(money(100_0000), money(100_0000), zero()) == zero()
    # Saldo minimum dihormati: 100 - 70 = 30, tepat minimum 30 → boleh.
    check balanceAfterWithdrawal(money(100_0000), money(70_0000), money(30_0000)) == money(30_0000)

  test "tarik melebihi saldo/minimum ditolak":
    expect ValueError:
      discard balanceAfterWithdrawal(money(40_0000), money(41_0000), zero())
    # Melewati minimum dengan 1 unit terkecil juga ditolak.
    expect ValueError:
      discard balanceAfterWithdrawal(money(100_0000), money(70_0001), money(30_0000))

suite "deposit: kunci idempotensi jurnal":
  test "kunci gabungan di bawah batas kolom":
    let key = tellerJournalKey("11111111-1111-7111-8111-111111111111", "abc-123")
    check key == "teller:11111111-1111-7111-8111-111111111111:abc-123"
    check key.len <= maxJournalIdempotencyKeyLength

  test "kunci terlalu panjang ditolak (bukan dipotong)":
    let principal = "11111111-1111-7111-8111-111111111111"
    let headroom = maxJournalIdempotencyKeyLength - journalKeyPrefix.len - principal.len - 1
    check tellerJournalKey(principal, repeat('k', headroom)).len ==
      maxJournalIdempotencyKeyLength
    expect ValueError:
      discard tellerJournalKey(principal, repeat('k', headroom + 1))
