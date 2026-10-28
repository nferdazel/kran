## Domain murni modul `deposit` (T-088b): transaksi tunai simpanan (spec §9.2).
##
## Yang ada di sini hanya bentuk dan invarian struktural (arah, tipe, validasi nominal). **Tidak ada
## angka bisnis**: saldo minimum datang dari binding versi produk (`product.savings.min_balance`)
## yang dibaca composition root, bukan konstanta di kode (spec §10, AGENTS.md §1.2).
##
## Sumber kebenaran saldo tetap jurnal ledger (spec §9.1(4)); `deposit.account_balance` adalah cache.
## Mutasi saldo **tidak** dihitung di sini (dulu ada `balanceAfterDeposit`/`balanceAfterWithdrawal`
## yang hanya dipakai unit test — duplikasi aturan SQL): satu-satunya tempat aturan itu hidup adalah
## `UPDATE ... WHERE balance - ? >= min_balance` di `infrastructure/transaction_repo`. T-103.

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

  ## Tipe baris `deposit.transaction` (cermin CHECK kolom DB, migrasi `deposit/0068`).
  ##
  ## `MATURITY_*`/`INTEREST_CREDIT` (T-138d) bukan transaksi tunai: jatuh tempo deposito
  ## memindahkan saldo antar-rekening dan membayar bunga akrual tanpa kas yang bergerak. Memakai
  ## `CASH_*` untuk keduanya akan berbohong di rekening koran anggota dan di rekonsiliasi.
  TransactionType* = enum
    ttCashDeposit = "CASH_DEPOSIT"
    ttCashWithdrawal = "CASH_WITHDRAWAL"
    ttMaturityOut = "MATURITY_OUT"
    ttMaturityIn = "MATURITY_IN"
    ttInterestCredit = "INTEREST_CREDIT"

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

proc cashDirectionOf*(t: TransactionType): CashDirection =
  ## Kebalikan `txTypeOf`: baris transaksi tunai → arah API. Dipakai endpoint baca slip
  ## (T-094a) yang membaca baris tersimpan, bukan permintaan masuk.
  ##
  ## Jenis non-tunai **melempar** `ValueError`: slip kas hanya untuk baris yang benar-benar
  ## memindahkan uang tunai. Mengarang `DEPOSIT`/`WITHDRAWAL` untuk jatuh tempo akan menampilkan
  ## slip setoran palsu; arah rekening koran memakai `statementDirectionOf`.
  case t
  of ttCashDeposit: cdDeposit
  of ttCashWithdrawal: cdWithdrawal
  of ttMaturityOut, ttMaturityIn, ttInterestCredit:
    raise newException(ValueError,
      "jenis transaksi " & $t & " bukan transaksi tunai (tidak punya arah kas)")

proc isCashTransaction*(t: TransactionType): bool =
  ## `true` hanya untuk baris yang lahir dari transaksi tunai teller (T-088b).
  t in {ttCashDeposit, ttCashWithdrawal}

proc statementDirectionOf*(t: TransactionType): string =
  ## Arah baris subledger untuk rekening koran (T-094b): `IN` menambah saldo rekening, `OUT`
  ## mengurangi. Semua jenis baris punya arah saldo, termasuk yang tidak memindahkan kas —
  ## karena itu arah statement tidak boleh diturunkan dari `cashDirectionOf`.
  case t
  of ttCashDeposit, ttMaturityIn, ttInterestCredit: "IN"
  of ttCashWithdrawal, ttMaturityOut: "OUT"

proc sourceEventOf*(d: CashDirection): string =
  ## Event ledger yang dipakai posting rule: setor = `DepositPosted` (D 101/K 201),
  ## tarik = `DepositWithdrawn` (D 201/K 101). Keduanya dari data (`ledger.posting_rule`).
  case d
  of cdDeposit: "DepositPosted"
  of cdWithdrawal: "DepositWithdrawn"

proc validateAmount*(amount: Money): Money =
  ## Nominal transaksi wajib **positif**: arah sudah menentukan tanda; nominal negatif/nol adalah
  ## permintaan tidak sah, bukan transaksi. Dipakai handler tunai (bukan cek inline yang terpisah).
  if amount <= zero():
    raise newException(ValueError, "amount harus lebih besar dari nol")
  amount

proc validateNarration*(raw: string): string =
  let s = raw.strip
  if s.len > maxNarrationLength:
    raise newException(ValueError, "narration melebihi " & $maxNarrationLength & " karakter")
  s

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
