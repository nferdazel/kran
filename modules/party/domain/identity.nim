## Dokumen identitas party (T-071, spec §18.2): bentuk nilai + normalisasi.
##
## Modul ini **tidak** menyentuh kriptografi: enkripsi/blind index dilakukan composition root
## (`apps/api`) dengan `FieldCrypto`, karena kepemilikan kunci adalah urusan platform (ADR-017).
## Yang diputuskan di sini hanyalah bentuk nomor yang diterima dan bentuk tersamar untuk UI.

import std/[options, strutils]

import kernel/ids

const
  maxDocTypeLength* = 32 # nomagic:ok batas teknis kolom party.identity_doc.doc_type
  maxNumberLength* = 64  # nomagic:ok batas teknis: panjang maksimum nomor sebelum enkripsi
  maskedChars* = 2       # nomagic:ok teknis: bentuk tersamar = dua karakter terakhir

type
  IdentityDoc* = object
    docId*: Id
    partyId*: Id
    docType*: string
    numberEnc*: string   ## ciphertext field crypto (AAD `identity_doc`)
    numberBidx*: string  ## blind index hex 64
    numberLast2*: string ## bentuk tersamar untuk tampilan
    issuedAt*: string    ## ISO `yyyy-MM-dd`; "" bila tidak dicatat
    expiresAt*: string
    createdAt*: string

proc normalizeNumber*(raw: string): string =
  ## Huruf besar, hanya `A-Z 0-9` — sehingga blind index deterministik dan perbedaan
  ## spasi/tanda hubung tidak membuat nomor yang sama dianggap berbeda.
  for c in raw:
    let u = c.toUpperAscii
    if u in {'A' .. 'Z', '0' .. '9'}:
      result.add u

proc parseDocType*(raw: string, allowed: openArray[string]): Option[string] =
  ## Jenis dokumen yang sah = yang terdaftar di parameter `party.identity.doc_types`
  ## (perbandingan case-insensitive). Yang dikembalikan **selalu huruf besar**: institusi boleh
  ## menulis daftarnya dengan gaya apa pun, tetapi nilai yang tersimpan satu bentuk. Itu penting
  ## karena `doc_type` ikut kunci unik `(doc_type, number_bidx)`: kalau ejaan data berubah saat
  ## operator merapikan parameter, deteksi duplikat akan pecah tanpa galat.
  let t = raw.strip.toUpperAscii
  if t.len == 0 or t.len > maxDocTypeLength:
    return none(string)
  for entry in allowed:
    if entry.strip.toUpperAscii == t:
      return some(t)
  none(string)

proc validateNumber*(normalized: string, maxLength: int, fixedLength = 0): string =
  ## Raise `ValueError` bila bentuk nomor tidak sah. `normalized` = hasil `normalizeNumber`.
  ## `fixedLength > 0` memakai panjang tetap dari parameter per jenis dokumen.
  if normalized.len == 0:
    raise newException(ValueError, "nomor dokumen kosong setelah normalisasi")
  if maxLength <= 0 or maxLength > maxNumberLength:
    raise newException(ValueError, "batas panjang nomor dokumen di parameter tidak sah")
  if normalized.len > maxLength:
    raise newException(ValueError, "nomor dokumen melebihi batas panjang di parameter")
  if fixedLength > 0 and normalized.len != fixedLength:
    raise newException(ValueError, "panjang nomor tidak sama dengan panjang yang ditetapkan parameter")
  normalized

proc maskNumber*(normalized: string): string =
  ## Bentuk tersamar yang aman dipajang: `maskedChars` karakter terakhir (dua).
  if normalized.len == 0:
    ""
  elif normalized.len <= maskedChars:
    normalized
  else:
    normalized[normalized.len - maskedChars .. ^1]
