## Aggregate `party` (T-070, spec §8).
##
## Murni: tanpa I/O. Validasi bentuk di sini, bukan di handler — supaya aturan yang sama dipakai
## jalur HTTP dan test integrasi. Batas panjang mengikuti CHECK di `party.party` (2..200).

import std/[options, strutils]

import kernel/ids
import ./cif

const
  maxNameLength* = 200 # nomagic:ok batas teknis kolom party.party.display_name

type
  PartyKind* = enum
    pkPerson = "PERSON"
    pkOrg = "ORG"

  PartyStatus* = enum
    psActive = "ACTIVE"
    psSuspended = "SUSPENDED"
    psClosed = "CLOSED"

  Party* = object
    partyId*: Id
    cif*: string
    kind*: PartyKind
    displayName*: string
    status*: PartyStatus
    branchId*: Id

proc parsePartyKind*(s: string): Option[PartyKind] =
  case s
  of "PERSON": some(pkPerson)
  of "ORG": some(pkOrg)
  else: none(PartyKind)

proc kindOf*(s: string): PartyKind =
  ## Untuk membaca baris DB; nilai di luar enum = data rusak, bukan input pengguna.
  let parsed = parsePartyKind(s)
  if parsed.isNone:
    raise newException(ValueError, "jenis party tidak dikenal: " & s)
  parsed.get()

proc statusOf*(s: string): PartyStatus =
  case s
  of "ACTIVE": psActive
  of "SUSPENDED": psSuspended
  of "CLOSED": psClosed
  else: raise newException(ValueError, "status party tidak dikenal: " & s)

proc normalizeName*(displayName: string): string =
  ## Nama tanpa spasi tepi; spasi ganda di tengah dibiarkan (nama orang/lembaga bisa memang begitu).
  displayName.strip()

proc validateName*(displayName: string): string =
  ## Nama yang sudah dinormalisasi. Raise `ValueError` bila tidak sah (input pengguna → 400).
  let name = normalizeName(displayName)
  if name.len < 2 or name.len > maxNameLength:
    raise newException(ValueError, "nama party harus 2..200 karakter")
  for ch in name:
    if ord(ch) < ord(' ') or ord(ch) == ord('\x7F'):
      raise newException(ValueError, "nama party memuat karakter kontrol")
  name

proc newParty*(partyId: Id, kind: PartyKind, displayName: string, branchId: Id,
               cifPattern: string, seqNo: int64): Party =
  ## Party baru berstatus ACTIVE. CIF disusun dari pola parameter + nomor urut.
  if $branchId == "":
    raise newException(ValueError, "cabang party wajib diisi")
  Party(
    partyId: partyId,
    cif: formatCif(cifPattern, seqNo),
    kind: kind,
    displayName: validateName(displayName),
    status: psActive,
    branchId: branchId,
  )
