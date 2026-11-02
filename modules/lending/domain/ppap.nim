## Penyisihan penghapusan aset produktif (PPAP/CKPN) — murni, tanpa I/O (T-167, D-180 butir 3).
##
## Tarif per golongan datang dari parameter `lending.ppap.rates` (`["0","0.5","10","50","100"]`
## persen, urutan = urutan `Collectibility`). Tidak ada tarif di kode: angka PPAP adalah ketentuan
## yang harus disetujui compliance (REG-204 `V!`), dan tarif yang ditulis di kode akan menjadi
## kebijakan yang tidak pernah ditandatangani siapa pun.
##
## Pembulatan **satu kali per pinjaman** (half-to-even, sama seperti bunga): menjumlahkan hasil
## pembulatan per komponen akan menyimpang beberapa sen dari tarif × dasar, dan penyisihan adalah
## angka laporan keuangan — selisihnya harus berasal dari pembulatan yang bisa dijelaskan, bukan dari
## urutan penjumlahan.

import std/json

import kernel/[money, rate, result]

import ./collectibility

const ppapErrCode* = "LEN-1005"

proc ppapErr(msg: string): AppError {.inline.} =
  appError(ppapErrCode, "error.lending.ppap", aekValidation, msg)

proc gradeCount*(): int {.inline.} =
  ## Jumlah golongan diturunkan dari enum, bukan konstanta lepas: menambah golongan tanpa
  ## memperbarui tarif parameter lalu gagal di sini, bukan diam-diam menyisihkan 0%.
  ord(high(Collectibility)) + 1

proc parsePpapRates*(node: JsonNode): AppResult[seq[Rate]] =
  ## Tarif persen per golongan. Wajib **tepat satu per golongan**: tarif yang kurang membuat sebagian
  ## pinjaman tidak punya dasar penyisihan, dan itu bukan pilihan konfigurasi — itu galat.
  if node.isNil or node.kind != JArray:
    return err[seq[Rate], AppError](ppapErr("tarif PPAP harus array persen"))
  var rates: seq[Rate] = @[]
  for item in node:
    if item.kind != JString:
      return err[seq[Rate], AppError](ppapErr(
        "tarif PPAP harus teks persen, mis. \"0.5\", bukan " & $item))
    let parsed = rateFromPercentString(item.getStr())
    if not parsed.isOk:
      return err[seq[Rate], AppError](ppapErr(
        "tarif PPAP bukan persen sah: " & item.getStr()))
    if parsed.val.isNegative:
      return err[seq[Rate], AppError](ppapErr(
        "tarif PPAP tidak boleh negatif: " & item.getStr()))
    if microUnits(parsed.val) > rateDenominator:
      return err[seq[Rate], AppError](ppapErr(
        "tarif PPAP melebihi 100%: " & item.getStr()))
    rates.add parsed.val
  if rates.len != gradeCount():
    return err[seq[Rate], AppError](ppapErr(
      "tarif PPAP harus " & $gradeCount() & " nilai (satu per golongan), dapat " & $rates.len))
  ok[seq[Rate], AppError](rates)

proc allowanceFor*(outstanding: Money; ratePercent: Rate): Money =
  ## Penyisihan satu pinjaman: `dasar × tarif`, satu pembulatan half-to-even.
  ##
  ## Memakai `kernel.money.applyRate` alih-alih aritmetika sendiri: aturan pembulatan uang harus ada
  ## di satu tempat, dan salinan kedua cepat atau lambat menyimpang (versi pertama berkas ini memakai
  ## penyebut `1e8` dan menyisihkan seperseratus dari seharusnya — tepat jenis kesalahan yang tidak
  ## terlihat sampai angkanya masuk laporan).
  applyRate(outstanding, ratePercent)

proc provisionDelta*(previous, current: Money): Money =
  ## Perubahan penyisihan yang harus dijurnal: positif = menambah beban, negatif = membalik.
  ## Ditulis sebagai fungsi bernama supaya tanda tidak "kebetulan" benar di pemanggil.
  current - previous

proc rateFor*(rates: openArray[Rate]; grade: Collectibility): Rate =
  ## Tarif golongan. Indeks diturunkan dari `ord`, jadi urutan parameter dan urutan enum adalah
  ## kontrak yang sama — `parsePpapRates` sudah memastikan panjangnya cukup.
  rates[ord(grade)]
