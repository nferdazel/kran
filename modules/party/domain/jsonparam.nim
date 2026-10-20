## Pembacaan parameter bertipe JSON di lapisan domain (T-071).
##
## Bentuk nilai parameter diperiksa di sini dan **selalu** gagal-cepat (`ValueError`) bila tidak
## sesuai: parameter tidak punya nilai default di kode (spec §10.6, D-046 butir 6).

import std/[json, options, strutils]

proc stringList*(node: JsonNode, paramName: string): seq[string] =
  ## Larik teks dari parameter (mis. daftar jenis dokumen/tingkat risiko).
  if node.isNil or node.kind != JArray:
    raise newException(ValueError, "parameter " & paramName & " harus larik teks")
  for item in node:
    if item.kind != JString:
      raise newException(ValueError, "parameter " & paramName & " memuat nilai bukan teks")
    result.add item.getStr

proc intByKey*(node: JsonNode, key, paramName: string): Option[int] =
  ## Nilai angka untuk satu kunci peta (mis. bulan re-KYC per tingkat risiko), case-insensitive.
  ## `none` bila kunci tidak ada; `ValueError` bila bentuknya salah.
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "parameter " & paramName & " harus objek")
  for k, v in node:
    if k.toUpperAscii != key.toUpperAscii:
      continue
    if v.kind != JInt:
      raise newException(ValueError,
        "parameter " & paramName & " untuk " & key & " bukan angka")
    return some(v.getInt)
  none(int)
