## Cache nilai parameter in-proc (spec §10.3, §10.4) — murni, tanpa DB/thread.
##
## Pembacaan parameter terjadi di hampir setiap use case; query DB per pembacaan mahal. Cache
## ini menyimpan nilai **per (key, scope, tanggal)**: nilai parameter efektif-dated, jadi
## tanggal buku ikut menjadi bagian kunci (spec §10.3).
##
## Invalidasi (bukan TTL) adalah mekanismenya: `infrastructure/param_watcher.nim` menerjemahkan
## `NOTIFY platform_param_changed` menjadi `invalidateKey`. Sengaja **tidak** ada kedaluwarsa
## berbasis waktu — nilai parameter berubah karena keputusan (maker-checker), bukan karena waktu,
## sehingga invalidasi eksplisit lebih mudah diprediksi (dan lebih aman).

import std/[json, options, tables]

import ../domain/[param, scope]

type
  CacheKey* = object
    key*: string
    scope*: string ## hasil `$ScopeRef` ("" = global/institusi)
    asOf*: string

  ParamCache* = ref object
    entries*: Table[CacheKey, ParamSnapshot]
    hits*: int
    misses*: int

proc newParamCache*(): ParamCache =
  ParamCache(entries: initTable[CacheKey, ParamSnapshot]())

proc cacheKey*(key: string, scope: ScopeRef, asOf: string): CacheKey =
  CacheKey(key: key, scope: $scope, asOf: asOf)

proc get*(cache: ParamCache, key: CacheKey): Option[ParamSnapshot] =
  ## Mengembalikan snapshot bila ada; menghitung hits/misses untuk observabilitas.
  if cache.entries.hasKey(key):
    inc cache.hits
    some(cache.entries[key])
  else:
    inc cache.misses
    none(ParamSnapshot)

proc put*(cache: ParamCache, key: CacheKey, snapshot: ParamSnapshot) =
  cache.entries[key] = snapshot

proc size*(cache: ParamCache): int =
  cache.entries.len

proc invalidateKey*(cache: ParamCache, key: string): int =
  ## Menghapus semua entri untuk satu key parameter (semua scope & tanggal).
  ## Mengembalikan jumlah entri yang dibuang.
  var buang: seq[CacheKey]
  for k in cache.entries.keys:
    if k.key == key:
      buang.add k
  for k in buang:
    cache.entries.del k
  buang.len

proc invalidateAll*(cache: ParamCache): int =
  result = cache.entries.len
  cache.entries.clear()
