## Layanan parameter (lapisan application): akses bertipe + cache in-proc (spec §10.3, §10.4).
##
## Application **tidak** menyentuh driver DB (archcheck rule B): sumber nilai datang lewat port
## `ParamSource`, yang di produksi diisi adaptor `infrastructure/param_source_db.nim`.
##
## Aturan yang dipertahankan sama seperti penyimpanan: nilai wajib ada (tidak ada fallback
## diam-diam, §10.6) dan konversi bertipe memakai aturan domain (`checkedSnapshot`).

import std/[json, options]

import ../domain/[param, scope]
import ./param_cache
import kernel/[paramkey, result]

type
  ParamSource* = object
    ## Port pengambil nilai aktif + definisinya.
    fetch*: proc(key: string; asOf: string; scope: ScopeRef): Result[ParamSnapshot, ParamError]

  ParamService* = ref object
    source*: ParamSource
    cache*: ParamCache

proc newParamService*(source: ParamSource; cache = newParamCache()): ParamService =
  ParamService(source: source, cache: cache)

proc snapshotOf*(service: ParamService; key, asOf: string;
                 scope: ScopeRef): Result[ParamSnapshot, ParamError] =
  ## Snapshot (nilai + definisi) dari cache, atau ambil dari sumber lalu simpan.
  let ck = cacheKey(key, scope, asOf)
  let cached = service.cache.get(ck)
  if cached.isSome:
    return ok[ParamSnapshot, ParamError](cached.get())
  let fetched = service.source.fetch(key, asOf, scope)
  if fetched.isErr:
    return fetched
  service.cache.put(ck, fetched.value())
  ok[ParamSnapshot, ParamError](fetched.value())

proc get*[T](service: ParamService; key: ParamKey[T]; asOf: string;
             scope: ScopeRef): Result[T, ParamError] =
  ## Akses bertipe: `service.get(P_lending_ppap_rate_kl, asOf = bizDate, scope = scope)`.
  ## Key tak terdaftar mustahil di sini (tipe `ParamKey[T]` hanya dibuat `tools/paramgen`,
  ## spec §10.4) — yang bisa gagal hanyalah nilai tidak ada / tidak sesuai schema.
  let snapshot = service.snapshotOf(keyString(key), asOf, scope)
  if snapshot.isErr:
    return err[T, ParamError](snapshot.error())
  checkedSnapshot[T](keyString(key), snapshot.value())

proc invalidate*(service: ParamService; key: string): int =
  ## Dipanggil `infrastructure/param_watcher.nim` saat `NOTIFY platform_param_changed` datang.
  service.cache.invalidateKey(key)

proc invalidateAll*(service: ParamService): int =
  service.cache.invalidateAll()
