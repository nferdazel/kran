## `Id` — UUIDv7 (terurut waktu) untuk PK internal (spec §9.1(8)).
##
## Tipe id per-aggregate (`PartyId`, `AccountId`, …) didefinisikan di modul masing-masing,
## bukan di kernel. Kernel hanya tahu bentuk kanonik UUIDv7 lowercase.

import std/sysrand
import std/strutils
import std/times

import ./result
import ./clock

export result

type
  ## Id kanonik lowercase (UUIDv7).
  Id* = distinct string

const hexDigits = "0123456789abcdef"

proc toHex(b: openArray[byte]): string =
  result = newStringOfCap(b.len * 2)
  for x in b:
    result.add hexDigits[(x shr 4).int]
    result.add hexDigits[(x and 0x0f).int]

proc isHexChar(c: char): bool {.inline.} =
  c in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}

proc newId*(clock: Clock): Id =
  ## UUIDv7: 48-bit timestamp ms dari `clock` + 74 bit acak (std/sysrand).
  let dt = clock.now()
  let ms = dt.toTime.toUnix * 1000'i64 + int64(dt.nanosecond div 1_000_000)
  let ts = uint64(ms) and 0xFFFFFFFFFFFF'u64

  var b: array[16, byte]
  for k in 0 .. 5:
    b[k] = byte((ts shr (8 * (5 - k))) and 0xff'u64)
  let r = urandom(10)
  b[6] = 0x70'u8 or byte(int(r[0]) and 0x0f)
  b[7] = r[1]
  b[8] = 0x80'u8 or byte(int(r[2]) and 0x3f)
  for k in 0 .. 6:
    b[9 + k] = r[3 + k]

  var s = newStringOfCap(36)
  for k in 0 .. 15:
    if k == 4 or k == 6 or k == 8 or k == 10:
      s.add '-'
    s.add hexDigits[(b[k] shr 4).int]
    s.add hexDigits[(b[k] and 0x0f).int]
  Id(s)

proc isUuidV7*(s: string): bool =
  ## Cek bentuk UUID kanonik + version nibble 7 + variant RFC 4122.
  if s.len != 36:
    return false
  for i in 0 ..< 36:
    if i == 8 or i == 13 or i == 18 or i == 23:
      if s[i] != '-':
        return false
    elif not isHexChar(s[i]):
      return false
  if s[14] != '7':
    return false
  s[19] in {'8', '9', 'a', 'b', 'A', 'B'}

proc parseId*(s: string): AppResult[Id] =
  ## Parse UUIDv7 kanonik; bentuk tak sah (termasuk versi bukan 7) ditolak.
  if not isUuidV7(s):
    return err[Id, AppError](
      appError("KRN-1301", "kernel.id.invalid", aekValidation, s))
  ok[Id, AppError](Id(s.toLowerAscii()))

proc `$`*(id: Id): string =
  ## Bentuk string kanonik.
  string(id)

proc `==`*(a, b: Id): bool {.inline.} =
  ## Kesamaan Id.
  string(a) == string(b)

proc newCorrelationId*(): string =
  ## Id korelasi acak: 16 byte hex (32 karakter) untuk logging/trace.
  toHex(urandom(16))
