## Domain murni modul `deposit` (T-088b): transaksi tunai simpanan (spec §9.2).
##
## Yang ada di sini hanya bentuk dan invarian struktural (arah, tipe, aritmetika saldo). **Tidak ada
## angka bisnis**: saldo minimum datang dari binding versi produk (`product.savings.min_balance`)
## yang dibaca composition root, bukan konstanta di kode (spec §10, AGENTS.md §1.2).
##
## Sumber kebenaran saldo tetap jurnal ledger (spec §9.1(4)); `deposit.account_balance` adalah cache
## yang digerakkan fungsi mutasi di sini (tercermin di SQL `transaction_repo`).

import std/strutils

import kernel/[ids, money]

const
  ## Batas teknis kolom, bukan nilai bisnis: `ledger.journal.idempotency_key` dan
  ## `deposit.transaction.narration` (T-088b).
  maxJournalIdempotencyKeyLength* = 200 # nomagic:ok batas teknis kolom idempotency_key
  maxNarrationLength* = 200 # nomagic:ok batas teknis kolom narration

  ## Awalan kunci idempotensi jurnal transaksi teller. Lapis kedua: `platform.idempotency_key`
  ## mencegah replay HTTP, kunci ini mencegah jurnal ganda bila replay lolos.
  journalKeyPrefix* = "teller:"

type
  ## Arah transaksi yang diterima API (`DEPOSIT`/`WITHDRAWAL`); memetakan ke tipe baris + event
  ## ledger yang berbeda (spec §3 rujukan: `DepositPosted`/`DepositWithdrawn`).
  CashDirection* = enum
    cdDeposit = "DEPOSIT"
    cdWithdrawal = "WITHDRAWAL"

  ## Tipe baris `deposit.transaction` (cermin CHECK kolom DB).
  TransactionType* = enum
    ttCashDeposit = "CASH_DEPOSIT"
    ttCashWithdrawal = "CASH_WITHDRAWAL"

  Transaction* = object
    transactionId*: Id
    txType*: TransactionType
    accountId*: Id
    amount*: Money
    businessDate*: string ## ISO `yyyy-MM-dd`
    narration*: string    ## "" = tidak diisi
    journalId*: Id
    createdAt*: string    ## ISO-8601 UTC

proc parseCashDirection*(raw: string): CashDirection =
  let s = raw.strip.toUpperAscii()
  for d in CashDirection:
    if $d == s:
      return d
  raise newException(ValueError, "direction harus DEPOSIT atau WITHDRAWAL")

proc parseTransactionType*(raw: string): TransactionType =
  let s = raw.strip.toUpperAscii()
  for t in TransactionType:
    if $t == s:
      return t
  raise newException(ValueError, "tx_type tidak dikenal: " & raw)

proc txTypeOf*(d: CashDirection): TransactionType =
  case d
  of cdDeposit: ttCashDeposit
  of cdWithdrawal: ttCashWithdrawal

proc sourceEventOf*(d: CashDirection): string =
  ## Event ledger yang dipakai posting rule: setor = `DepositPosted` (D 101/K 201),
  ## tarik = `DepositWithdrawn` (D 201/K 101). Keduanya dari data (`ledger.posting_rule`).
  case d
  of cdDeposit: "DepositPosted"
  of cdWithdrawal: "DepositWithdrawn"

proc validateAmount*(amount: Money): Money =
  ## Nominal transaksi wajib **positif**: arah sudah menentukan tanda; nominal negatif/nol adalah
  ## permintaan tidak sah, bukan transaksi.
  if amount <= zero():
    raise newException(ValueError, "amount harus lebih besar dari nol")
  amount

proc validateNarration*(raw: string): string =
  let s = raw.strip
  if s.len > maxNarrationLength:
    raise newException(ValueError, "narration melebihi " & $maxNarrationLength & " karakter")
  s

proc balanceAfterDeposit*(balance, amount: Money): Money =
  ## Saldo setelah setor. Tanpa batas atas di domain (batas nominal = parameter, T-093).
  discard validateAmount(amount)
  balance + amount

proc balanceAfterWithdrawal*(balance, amount, minBalance: Money): Money =
  ## Saldo setelah tarik; **ditolak** bila hasilnya di bawah saldo minimum (yang datang dari
  ## binding versi produk). Cermin klausa `balance - ? >= min` di `transaction_repo`.
  discard validateAmount(amount)
  let after = balance - amount
  if after < minBalance:
    raise newException(ValueError, "saldo tidak cukup setelah tarik (di bawah saldo minimum)")
  after

proc tellerJournalKey*(principalId, key: string): string =
  ## `teller:<principalId>:<Idempotency-Key>` — kunci idempotensi jurnal (T-088 §3). Ditolak bila
  ## melebihi batas kolom `ledger.journal.idempotency_key` (200): lebih baik 400 terang daripada
  ## kunci terpotong yang bisa menabrak kunci lain.
  let combined = journalKeyPrefix & principalId & ":" & key
  if combined.len > maxJournalIdempotencyKeyLength:
    raise newException(ValueError,
      "Idempotency-Key terlalu panjang untuk kunci jurnal (maks " &
      $maxJournalIdempotencyKeyLength & " karakter gabungan)")
  combined
