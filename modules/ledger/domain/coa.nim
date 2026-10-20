## Chart of Accounts (T-072): tipe akun, sisi normal, dan bentuk kode.
##
## Format kode adalah **kebijakan institusi** (spec §10.5) dan datang sebagai parameter
## `ledger.coa.code_pattern` (regex). Yang ada di kode hanya invarian akuntansi: tipe akun
## menentukan sisi normal (ASSET/EXPENSE = DEBIT, LIABILITY/EQUITY/REVENUE = CREDIT).

import std/[options, re, strutils]

import kernel/ids

const
  maxCodeLength* = 32  # nomagic:ok batas teknis kolom ledger.coa_account.code
  maxNameLength* = 200 # nomagic:ok batas teknis kolom ledger.coa_account.name

type
  AccountType* = enum
    atAsset = "ASSET"
    atLiability = "LIABILITY"
    atEquity = "EQUITY"
    atRevenue = "REVENUE"
    atExpense = "EXPENSE"

  NormalSide* = enum
    nsDebit = "DEBIT"
    nsCredit = "CREDIT"

  AccountStatus* = enum
    asActive = "ACTIVE"
    asInactive = "INACTIVE"

  CoaAccount* = object
    accountId*: Id
    code*: string
    name*: string
    accountType*: AccountType
    normalSide*: NormalSide
    postable*: bool
    status*: AccountStatus
    createdAt*: string

proc parseAccountType*(raw: string): Option[AccountType] =
  for t in AccountType:
    if $t == raw.strip.toUpperAscii:
      return some(t)
  none(AccountType)

proc parseAccountStatus*(raw: string): Option[AccountStatus] =
  for s in AccountStatus:
    if $s == raw.strip.toUpperAscii:
      return some(s)
  none(AccountStatus)

proc normalSideOf*(t: AccountType): NormalSide =
  ## Invarian akuntansi — bukan nilai yang bisa disetel institusi (lihat CHECK migrasi).
  case t
  of atAsset, atExpense: nsDebit
  of atLiability, atEquity, atRevenue: nsCredit

proc compileCodePattern*(pattern: string): Regex =
  ## Pola kode dari parameter. Pola kosong/tidak sah = **konfigurasi** yang salah (pemanggil
  ## menerjemahkannya jadi 500), bukan kesalahan permintaan.
  if pattern.strip.len == 0:
    raise newException(ValueError, "pola kode COA kosong")
  try:
    re(pattern)
  except RegexError:
    raise newException(ValueError, "pola kode COA tidak sah")

proc validateCode*(code: string, rx: Regex): string =
  ## Kode lengkap harus cocok dengan pola (pencocokan seluruh string, bukan sebagian).
  let c = code.strip
  if c.len == 0:
    raise newException(ValueError, "kode COA wajib diisi")
  if c.len > maxCodeLength:
    raise newException(ValueError, "kode COA melebihi batas panjang kolom")
  # `matchLen`, bukan `findBounds`: `findBounds` melempar `RangeDefect` (bukan error) untuk pola
  # yang sah tetapi bisa cocok kosong seperti `[0-9]*`, sehingga request akan jatuh sebagai 500
  # generik alih-alih ditolak 400. `matchLen` mengembalikan -1 (tidak cocok di awal) atau panjang
  # kecocokan, jadi kecocokan penuh = panjang kode.
  if matchLen(c, rx) != c.len:
    raise newException(ValueError, "kode COA tidak cocok dengan pola parameter")
  c

proc validateName*(raw: string): string =
  let n = raw.strip.splitWhitespace.join(" ")
  if n.len < 2:
    raise newException(ValueError, "nama akun minimal 2 karakter")
  if n.len > maxNameLength:
    raise newException(ValueError, "nama akun melebihi batas panjang kolom")
  for ch in n:
    if ord(ch) < ord(' ') or ord(ch) == ord('\x7F'):
      raise newException(ValueError, "nama akun memuat karakter kontrol")
  n
