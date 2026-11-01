## Kolektibilitas pinjaman (T-166, D-180 butir 2) — murni, tanpa I/O.
##
## Golongan ditentukan **hanya** oleh hari tunggakan (DPD) terhadap ambang yang berlaku, dan ambang
## itu datang dari parameter `lending.collectibility.dpd_bounds` (seed `[90, 120, 180]`). Tidak ada
## angka di berkas ini: ambang bawaan yang ditulis di kode akan menjadi kebijakan yang tidak pernah
## disetujui siapa pun, dan regulator meminta ambang yang berlaku pada tanggal buku.
##
## DPD dihitung dari tanggal jatuh tempo angsuran **tertua yang belum lunas**, bukan dari pembayaran
## terakhir: anggota yang hanya membayar bunga tetap menunggak pokok, dan kolektibilitas harus
## melihatnya.

import std/[json, options, strutils]

import kernel/[businessdate, result]

const collectibilityErrCode* = "LEN-1004"

proc collectibilityErr(msg: string): AppError {.inline.} =
  appError(collectibilityErrCode, "error.lending.collectibility", aekValidation, msg)

type
  Collectibility* = enum
    ## Urutan enum = urutan keparahan: kode memakai `ord` untuk memetakan ambang ke golongan, jadi
    ## menambah golongan di tengah akan menggeser pemetaan tanpa suara.
    colCollectible = "COLLECTIBLE"
    colSpecialMention = "SPECIAL_MENTION"
    colSubstandard = "SUBSTANDARD"
    colDoubtful = "DOUBTFUL"
    colLoss = "LOSS"

proc parseCollectibility*(raw: string): Option[Collectibility] =
  let value = raw.strip()
  for grade in Collectibility:
    if $grade == value:
      return some(grade)
  none(Collectibility)

proc parseDpdBounds*(node: JsonNode): AppResult[seq[int]] =
  ## Ambang atas golongan 2…n dari parameter JSON (`[90, 120, 180]`). Harus bilangan bulat positif
  ## dan **naik ketat**: ambang yang tidak naik membuat sebagian golongan tidak mungkin dicapai, dan
  ## itu kesalahan konfigurasi, bukan pilihan kebijakan.
  if node.isNil or node.kind != JArray:
    return err[seq[int], AppError](collectibilityErr("ambang DPD harus array bilangan bulat"))
  var bounds: seq[int] = @[]
  for item in node:
    if item.kind != JInt or item.getInt() < 1:
      return err[seq[int], AppError](collectibilityErr(
        "ambang DPD harus bilangan bulat positif, bukan " & $item))
    bounds.add int(item.getInt())
  let expected = ord(high(Collectibility)) - 1
  if bounds.len != expected:
    return err[seq[int], AppError](collectibilityErr(
      "ambang DPD harus " & $expected & " nilai untuk " & $(expected + 1) & " golongan, dapat " &
      $bounds.len))
  var previous = 0
  for bound in bounds:
    if bound <= previous:
      return err[seq[int], AppError](collectibilityErr(
        "ambang DPD harus naik ketat; " & $bound & " tidak lebih besar dari " & $previous))
    previous = bound
  ok[seq[int], AppError](bounds)

proc daysPastDue*(dueOn, businessDate: string): AppResult[int] =
  ## Hari tunggakan per tanggal buku. Jatuh tempo di masa depan = 0 (belum menunggak), bukan negatif:
  ## angka negatif akan lolos ke laporan sebagai "tunggakan minus".
  let due = parseBusinessDate(dueOn)
  if not due.isOk:
    return err[int, AppError](collectibilityErr("tanggal jatuh tempo tidak sah: " & dueOn))
  let asOf = parseBusinessDate(businessDate)
  if not asOf.isOk:
    return err[int, AppError](collectibilityErr("tanggal buku tidak sah: " & businessDate))
  let gap = daysBetween(due.val, asOf.val)
  ok[int, AppError](if gap < 0: 0 else: gap)

proc gradeOf*(dpd: int; bounds: openArray[int]): AppResult[Collectibility] =
  ## `0` hari = lancar; selebihnya dipetakan ke ambang pertama yang menampungnya, dan di atas ambang
  ## terakhir = macet. `dpd` negatif diperlakukan sebagai 0 (lihat `daysPastDue`).
  let expected = ord(high(Collectibility)) - 1
  if bounds.len != expected:
    return err[Collectibility, AppError](collectibilityErr(
      "ambang DPD harus " & $expected & " nilai, dapat " & $bounds.len))
  var previous = 0
  for bound in bounds:
    if bound <= previous:
      return err[Collectibility, AppError](collectibilityErr(
        "ambang DPD harus naik ketat; " & $bound & " tidak lebih besar dari " & $previous))
    previous = bound
  if dpd <= 0:
    return ok[Collectibility, AppError](colCollectible)
  for index, bound in bounds:
    if dpd <= bound:
      return ok[Collectibility, AppError](Collectibility(ord(colCollectible) + 1 + index))
  ok[Collectibility, AppError](colLoss)
