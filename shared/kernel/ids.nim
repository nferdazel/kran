## Id — UUIDv7 (terurut waktu) untuk PK internal (spec §9.1(8)).
##
## Alasan v7 (bukan v4): indeks B-tree Postgres tetap ramah insert karena prefiksnya
## bertambah secara monoton, sementara sisanya tetap acak (tidak bisa ditebak urutannya).
##
## Tipe id per-aggregate (`PartyId`, `AccountId`, …) didefinisikan modul masing-masing di
## atas `Id` ini — kernel tidak boleh mengumpulkan daftar tipe milik modul.

import std/hashes
import std/sysrand
import std/strutils
import std/times
import ./result, ./clock

type
  Id* = distinct string ## bentuk kanonik lowercase: 8-4-4-4-12

const
  uuidLen* = 36
  hexDigits = "0123456789abcdef"

proc hexByte(b: byte): string {.inline.} =
  result = newString(2)
  result[0] = hexDigits[int(b shr 4)]
  result[1] = hexDigits[int(b and 0x0F)]

proc randomBytes(n: int): seq[byte] =
  result = newSeq[byte](n)
  if not urandom(result):
    # Bukan kondisi bisnis: tanpa sumber acak, keamanan sistem tidak bisa dijamin.
    raise newException(IOError, "gagal membaca sumber acak sistem")

proc formatUuid*(b: openArray[byte]): string =
  doAssert b.len == 16
  result = ""
  for i in 0 ..< 16:
    if i in {4, 6, 8, 10}:
      result.add('-')
    result.add(hexByte(b[i]))

proc newId*(clock: Clock): Id =
  ## UUIDv7: 48 bit timestamp milidetik dari `clock` + 74 bit acak.
  let dt = clock.now()
  let ms = dt.toTime.toUnix * 1000'i64 + int64(dt.nanosecond div 1_000_000)
  var b = randomBytes(16)
  let ts = ms and 0xFFFFFFFFFFFF'i64
  for i in 0 .. 5:
    b[i] = byte((ts shr (8 * (5 - i))) and 0xFF)
  b[6] = byte(0x70 or (int(b[6]) and 0x0F)) # version 7
  b[8] = byte(0x80 or (int(b[8]) and 0x3F)) # variant RFC 4122
  Id(formatUuid(b))

proc idErr(msg: string): AppError {.inline.} =
  appError("CBS-1301", "error.id.invalid", aekValidation, msg)

proc isHexChar(c: char): bool {.inline.} =
  c in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}

proc parseId*(s: string): AppResult[Id] =
  ## Menerima UUID bentuk kanonik versi apa pun (id dari sistem luar mungkin bukan v7).
  ## Pemeriksaan versi khusus v7 ada di `isUuidV7`.
  let t = s.strip()
  if t.len != uuidLen:
    return err[Id, AppError](idErr("panjang bukan 36: " & s))
  for i in 0 ..< uuidLen:
    if i in {8, 13, 18, 23}:
      if t[i] != '-':
        return err[Id, AppError](idErr("posisi dash salah: " & s))
    elif not isHexChar(t[i]):
      return err[Id, AppError](idErr("bukan heksadesimal: " & s))
  ok[Id, AppError](Id(t.toLowerAscii()))

proc `$`*(id: Id): string {.inline.} =
  string(id)

proc `==`*(a, b: Id): bool {.inline.} =
  ## `Id` adalah `distinct string`, jadi `==` tidak diwarisi — didefinisikan eksplisit.
  string(a) == string(b)

proc `<`*(a, b: Id): bool {.inline.} =
  string(a) < string(b)

proc hash*(id: Id): Hash {.inline.} =
  ## Dibutuhkan agar `Id` bisa jadi kunci tabel/himpunan.
  hash(string(id))

proc isUuidV7*(s: string): bool =
  if s.len != uuidLen:
    return false
  if parseId(s).isErr:
    return false
  s[14] == '7' and (s[19] in {'8', '9', 'a', 'b', 'A', 'B'})

proc newCorrelationId*(): string =
  ## 16 byte acak dalam hex — dipakai sebagai correlation ID lintas request/event/batch
  ## (spec §22). Bukan UUID: nilainya tidak perlu terurut.
  var b = randomBytes(16)
  result = ""
  for x in b:
    result.add(hexByte(x))
