## Unit test domain `deposit` transaksi tunai (T-088b): arah, tipe, validasi nominal, kunci jurnal.
##
## Murni (tanpa DB) — invarian DB (conditional UPDATE, CHECK saldo, jurnal) diuji di `ittransaction`.
## Aritmetika saldo tidak diuji di sini: aturannya hidup di SQL (`transaction_repo`), bukan domain
## (T-103).

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
    check parseTransactionType("maturity_out") == ttMaturityOut
    check parseTransactionType("MATURITY_IN") == ttMaturityIn
    check parseTransactionType("INTEREST_CREDIT") == ttInterestCredit
    expect ValueError:
      discard parseTransactionType("TRANSFER")

  test "arah kas hanya untuk transaksi tunai; jatuh tempo bukan slip setoran":
    check cashDirectionOf(ttCashDeposit) == cdDeposit
    check cashDirectionOf(ttCashWithdrawal) == cdWithdrawal
    for t in [ttMaturityOut, ttMaturityIn, ttInterestCredit]:
      check not isCashTransaction(t)
      expect ValueError:
        discard cashDirectionOf(t)
    check isCashTransaction(ttCashDeposit)
    check isCashTransaction(ttCashWithdrawal)

  test "arah rekening koran mengikuti efek saldo, bukan arah kas":
    check statementDirectionOf(ttCashDeposit) == "IN"
    check statementDirectionOf(ttCashWithdrawal) == "OUT"
    check statementDirectionOf(ttMaturityIn) == "IN"
    check statementDirectionOf(ttInterestCredit) == "IN"
    check statementDirectionOf(ttMaturityOut) == "OUT"

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
