## Detail PII party (orang/lembaga) + alamat (T-078, spec §8/§9.2/§18.2): bentuk nilai + validasi.
##
## Modul ini **tidak** menyentuh kriptografi: ciphertext + blind index dibuat composition root
## (`apps/api`) dengan `FieldCrypto`, karena kepemilikan kunci adalah urusan platform (ADR-017).
## Yang diputuskan di sini hanyalah bentuk nilai yang diterima, validasi per jenis party, dan
## bentuk tersamar untuk UI (pola D-069). Alasan + format kolom: `docs/tasks/T-078.md`.
##
## **HUMAN-REVIEW-REQUIRED**: area PII/enkripsi (AGENTS.md §8).

import std/[options, strutils]

import kernel/ids
import ./identity # `maskNumber` — aturan bentuk tersamar dipakai bersama (D-069)
import ./party

const
  maxLegalNameLength* = 200   # nomagic:ok batas teknis nilai nama sebelum dienkripsi
  maxOccupationLength* = 100  # nomagic:ok batas teknis nilai pekerjaan
  maxAddressLineLength* = 300 # nomagic:ok batas teknis nilai baris alamat
  maxCityLength* = 100        # nomagic:ok batas teknis nilai kota
  maxPostalCodeLength* = 16   # nomagic:ok batas teknis nilai kode pos
  maxSexLength* = 16          # nomagic:ok batas teknis nilai jenis kelamin
  minNameLength* = 2          # nomagic:ok nama resmi minimal, konsisten dengan nama tampil party

type
  PersonDetail* = object
    ## Detail orang. Tiap field = ciphertext + blind index + bentuk tersamar (D-069).
    partyId*: Id
    legalNameEnc*: string
    legalNameBidx*: string
    legalNameMask*: string
    birthDateEnc*: string  ## nilai asli `yyyy-MM-dd`
    birthDateBidx*: string
    birthDateMask*: string
    sexEnc*: string
    sexBidx*: string
    sexMask*: string
    occupationEnc*: string ## "" bila tidak dicatat
    occupationBidx*: string
    occupationMask*: string
    createdAt*: string
    updatedAt*: string

  OrgDetail* = object
    ## Detail lembaga: nama resmi. Pola penyimpanan sama dengan `PersonDetail`.
    partyId*: Id
    legalNameEnc*: string
    legalNameBidx*: string
    legalNameMask*: string
    createdAt*: string
    updatedAt*: string

  Address* = object
    ## Alamat party. `line` wajib; `city`/`postalCode` opsional ("" = tidak dicatat).
    addressId*: Id
    partyId*: Id
    lineEnc*: string
    lineBidx*: string
    lineMask*: string
    cityEnc*: string
    cityBidx*: string
    cityMask*: string
    postalCodeEnc*: string
    postalCodeBidx*: string
    postalCodeMask*: string
    createdAt*: string
    updatedAt*: string

proc validateText*(raw, field: string, maxLen: int, minLen = 1): string =
  ## Teks wajib: dipangkas, panjang dijaga, karakter kontrol ditolak. Raise `ValueError` bila tidak
  ## sah — input pengguna → 400. Nilai yang dikembalikan inilah yang dienkripsi.
  let t = raw.strip
  if t.len < minLen:
    raise newException(ValueError, field & " wajib diisi (minimal " & $minLen & " karakter)")
  if t.len > maxLen:
    raise newException(ValueError, field & " melebihi batas panjang " & $maxLen & " karakter")
  for ch in t:
    if ord(ch) < ord(' ') or ord(ch) == ord('\x7F'):
      raise newException(ValueError, field & " memuat karakter kontrol")
  t

proc validateOptionalText*(raw, field: string, maxLen: int): string =
  ## Teks opsional: kosong tetap kosong (bukan galat), selebihnya divalidasi seperti teks wajib.
  let t = raw.strip
  if t.len == 0:
    return ""
  validateText(t, field, maxLen)

proc validateLegalName*(raw: string): string =
  validateText(raw, "nama resmi", maxLegalNameLength, minNameLength)

proc validateOccupation*(raw: string): string =
  validateOptionalText(raw, "pekerjaan", maxOccupationLength)

proc validateAddressLine*(raw: string): string =
  validateText(raw, "alamat", maxAddressLineLength)

proc validateCity*(raw: string): string =
  validateOptionalText(raw, "kota", maxCityLength)

proc validatePostalCode*(raw: string): string =
  validateOptionalText(raw, "kode pos", maxPostalCodeLength)

proc parseSex*(raw: string, allowed: openArray[string]): Option[string] =
  ## Jenis kelamin sah = anggota `party.person.sex_values` (perbandingan case-insensitive). Yang
  ## dikembalikan **selalu huruf besar** supaya nilai tersimpan satu bentuk, walau parameter
  ## ditulis dengan gaya huruf berbeda (pola sama dengan jenis dokumen/tingkat risiko).
  let t = raw.strip.toUpperAscii
  if t.len == 0 or t.len > maxSexLength:
    return none(string)
  for entry in allowed:
    if entry.strip.toUpperAscii == t:
      return some(t)
  none(string)

proc checkDetailKind*(kind: PartyKind, hasPerson, hasOrg: bool) =
  ## Validasi per jenis party: blok detail yang wajib dan yang dilarang. Raise `ValueError` bila
  ## tidak sesuai — permintaan yang tidak cocok dijawab 400, bukan disimpan setengah.
  case kind
  of pkPerson:
    if not hasPerson:
      raise newException(ValueError, "party PERSON wajib memuat blok person")
    if hasOrg:
      raise newException(ValueError, "party PERSON tidak boleh memuat blok org")
  of pkOrg:
    if not hasOrg:
      raise newException(ValueError, "party ORG wajib memuat blok org")
    if hasPerson:
      raise newException(ValueError, "party ORG tidak boleh memuat blok person")

proc maskTail*(value: string): string =
  ## Bentuk tersamar (dua karakter terakhir) — aturan bersama dengan dokumen identitas (D-069).
  maskNumber(value)
