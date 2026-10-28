## Domain murni modul `deposit` (T-088a): rekening simpanan (spec §9.2).
##
## Yang ada di sini hanya bentuk dan invarian struktural (tipe, status, nomor rekening provisoris).
## **Tidak ada angka bisnis**: saldo minimum, batas transaksi, dan bunga datang dari binding versi
## produk (dipakai T-088b) — bukan konstanta di kode (spec §10, AGENTS.md §1.2).

import std/strutils

import kernel/[businessdate, ids, money, result]

const
  ## Format nomor rekening (D-135, keputusan pemilik 24 Okt 2026): **kode cabang 3 digit** +
  ## **nomor urut 7 digit** = 10 digit, tanpa check digit. Kode cabang berasal dari master cabang
  ## (`platform.branch.code`), jadi nomor rekening langsung memperlihatkan cabang pembukanya.
  ## Check digit & bentuk final lain masih terbuka untuk compliance (lihat O-104).
  branchCodeWidth* = 3 # nomagic:ok panjang kode cabang (D-135)
  accountSeqWidth* = 7 # nomagic:ok lebar nomor urut di dalam nomor rekening (D-135)
  accountNoWidth* = branchCodeWidth + accountSeqWidth
  maxAccountNoLength* = 32 # nomagic:ok batas teknis kolom deposit.account.account_no

type
  AccountType* = enum
    ## `TIME_DEPOSIT` (D-152) = deposito berjangka: rekening yang sama, ditambah jatuh tempo/ARO di
    ## DB. Perpindahan saat jatuh tempo ditangani task day-close `deposit.maturity_aro` (T-138d).
    atSavings = "SAVINGS"
    atTimeDeposit = "TIME_DEPOSIT"

  AccountStatus* = enum
    asActive = "ACTIVE"
    asClosed = "CLOSED"

  AroInstruction* = enum
    ## Instruksi automatic roll-over saat deposito berjangka jatuh tempo (T-138b/D-152,
    ## CHECK `deposit_account_aro_instruction_chk`). Nilai string = nilai kolom DB.
    ## Keputusan artinya milik D-155, bukan modul ini.
    aiNone = "NONE"
    aiPrincipal = "PRINCIPAL"
    aiPrincipalAndInterest = "PRINCIPAL_AND_INTEREST"

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

proc parseAroInstruction*(raw: string): AroInstruction =
  ## Tanpa fallback: instruksi yang tidak dikenal adalah data rusak, bukan "pakai NONE".
  let s = raw.strip.toUpperAscii()
  for aro in AroInstruction:
    if $aro == s:
      return aro
  raise newException(ValueError, "instruksi ARO tidak dikenal: " & raw)

proc validBranchCode*(branchCode: string): bool =
  ## Kode cabang = tepat `branchCodeWidth` digit. Sumbernya master cabang, tetapi domain tetap
  ## memeriksa sendiri supaya nomor rekening tidak pernah dibentuk dari kode berbentuk lain.
  if branchCode.len != branchCodeWidth:
    return false
  for ch in branchCode:
    if ch notin {'0' .. '9'}:
      return false
  true

proc formatAccountNo*(branchCode: string, seqNo: int64): string =
  ## Nomor rekening: kode cabang + nomor urut `deposit.account_seq` (dipad nol selebar
  ## `accountSeqWidth`). Nilai tidak sah adalah kondisi operator (kode cabang rusak, sequence
  ## mundur/terlalu besar) — raise `ValueError`, bukan menghasilkan nomor aneh.
  if not validBranchCode(branchCode):
    raise newException(ValueError,
      "kode cabang harus " & $branchCodeWidth & " digit, bukan '" & branchCode & "'")
  if seqNo < 1:
    raise newException(ValueError, "nomor urut rekening minimal 1")
  let digits = $seqNo
  if digits.len > accountSeqWidth:
    raise newException(ValueError,
      "nomor urut " & digits & " tidak muat di lebar " & $accountSeqWidth)
  branchCode & repeat('0', accountSeqWidth - digits.len) & digits

proc newAccount*(accountId: Id, partyId: Id, productId: Id, productVersionId: Id,
                 productCode: string, branchId: Id, branchCode: string, openedOn: string,
                 seqNo: int64): Account =
  ## Rekening baru berstatus `ACTIVE`, tipe `SAVINGS`, saldo nol. Nomor rekening dari
  ## `formatAccountNo` (kode cabang + nomor urut).
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
    accountNo: formatAccountNo(branchCode, seqNo),
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
