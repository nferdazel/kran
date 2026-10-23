## Domain murni modul `deposit` (T-088a): rekening simpanan (spec §9.2).
##
## Yang ada di sini hanya bentuk dan invarian struktural (tipe, status, nomor rekening provisoris).
## **Tidak ada angka bisnis**: saldo minimum, batas transaksi, dan bunga datang dari binding versi
## produk (dipakai T-088b) — bukan konstanta di kode (spec §10, AGENTS.md §1.2).

import std/strutils

import kernel/[businessdate, ids, money, result]

const
  ## Lebar nomor rekening **provisoris** (10 digit zero-padded). Bentuk final (prefix/check digit)
  ## menunggu parameter `deposit.account.number_format` — **NEEDS-COMPLIANCE-REVIEW**; jangan
  ## mengarang format lain sebelum pemilik/compliance memutuskan.
  accountNoWidth* = 10 # nomagic:ok lebar format nomor rekening provisoris (lihat NEEDS-COMPLIANCE-REVIEW)
  maxAccountNoLength* = 32 # nomagic:ok batas teknis kolom deposit.account.account_no

type
  AccountType* = enum
    atSavings = "SAVINGS"

  AccountStatus* = enum
    asActive = "ACTIVE"
    asClosed = "CLOSED"

  Account* = object
    accountId*: Id
    accountNo*: string
    partyId*: Id
    productId*: Id
    productVersionId*: Id
    productCode*: string
    branchId*: Id
    accountType*: AccountType
    status*: AccountStatus
    openedOn*: string ## ISO `yyyy-MM-dd`
    createdAt*: string
    balance*: Money
    ## Klasifikasi simpanan dari produk yang di-pin rekening (join `product.product.savings_kind`,
    ## T-111). `""` = belum terklasifikasi (`NULL` di DB); jenis **tidak** disimpan di
    ## `deposit.account` supaya klasifikasi tetap properti produk, bukan rekening.
    savingsKind*: string

proc parseAccountType*(raw: string): AccountType =
  let s = raw.strip.toUpperAscii()
  for t in AccountType:
    if $t == s:
      return t
  raise newException(ValueError, "accountType tidak dikenal: " & raw)

proc parseAccountStatus*(raw: string): AccountStatus =
  let s = raw.strip.toUpperAscii()
  for st in AccountStatus:
    if $st == s:
      return st
  raise newException(ValueError, "status rekening tidak dikenal: " & raw)

proc formatAccountNo*(seqNo: int64): string =
  ## Nomor rekening **provisoris**: nomor urut `deposit.account_seq` dipad nol di kiri selebar
  ## `accountNoWidth`, **tanpa** check digit. Nilai tidak sah adalah kondisi operator (sequence
  ## mundur/terlalu besar) — raise `ValueError`, bukan menghasilkan nomor aneh.
  if seqNo < 1:
    raise newException(ValueError, "nomor urut rekening minimal 1")
  let digits = $seqNo
  if digits.len > accountNoWidth:
    raise newException(ValueError,
      "nomor urut " & digits & " tidak muat di lebar " & $accountNoWidth)
  repeat('0', accountNoWidth - digits.len) & digits

proc newAccount*(accountId: Id, partyId: Id, productId: Id, productVersionId: Id,
                 productCode: string, branchId: Id, openedOn: string, seqNo: int64): Account =
  ## Rekening baru berstatus `ACTIVE`, tipe `SAVINGS`, saldo nol. Nomor rekening dari `formatAccountNo`.
  if $partyId == "":
    raise newException(ValueError, "party rekening wajib diisi")
  if $productId == "":
    raise newException(ValueError, "produk rekening wajib diisi")
  if $productVersionId == "":
    raise newException(ValueError, "versi produk rekening wajib diisi")
  if $branchId == "":
    raise newException(ValueError, "cabang rekening wajib diisi")
  if parseBusinessDate(openedOn).isErr:
    raise newException(ValueError, "openedOn bukan tanggal ISO (yyyy-MM-dd) yang sah")
  Account(
    accountId: accountId,
    accountNo: formatAccountNo(seqNo),
    partyId: partyId,
    productId: productId,
    productVersionId: productVersionId,
    productCode: productCode,
    branchId: branchId,
    accountType: atSavings,
    status: asActive,
    openedOn: openedOn,
    balance: zero(),
  )
