## Batas nominal kas dari parameter (O-099/K-5, D-133).
##
## Angka limit adalah **kebijakan institusi** (spec §10.5), bukan konstanta kode: nilainya hidup di
## `modules/teller/seeds/params.yaml` → `kernel/generated/paramkeys`. Handler membacanya dengan
## scope institusi pada tanggal bisnis, lalu menolak **409** bila nominal melewati plafon.
##
## Kegagalan membaca parameter = konfigurasi institusi (500 lewat `CashLimitConfigError`), bukan
## permintaan cacat. Fail-closed: tanpa nilai aktif, jalur kas tidak berjalan tanpa batas diam-diam.

import std/json

import db_connector/db_postgres

import kernel/[money, paramkey, result]
import platform/domain/scope
import platform/infrastructure/param_repo

type
  CashLimitConfigError* = object of CatchableError
    ## Parameter limit hilang/rusak atau bukan nominal desimal.

proc cashLimit*(db: DbConn, key: ParamKey[Money], asOf: string): Money =
  ## Nilai plafon aktif untuk `key` pada `asOf`. Raise `CashLimitConfigError` bila tidak terbaca.
  {.cast(gcsafe).}:
    let node =
      try:
        activeValueJson(db, keyString(key), asOf, lookupFor(institutionScope()))
      except ValueError as e:
        raise newException(CashLimitConfigError, e.msg)
    if node.kind != JString:
      raise newException(CashLimitConfigError,
        "parameter " & keyString(key) & " bukan nominal desimal")
    let parsed = moneyFromString(node.getStr())
    if parsed.isErr:
      raise newException(CashLimitConfigError,
        "parameter " & keyString(key) & " bukan nominal desimal")
    parsed.value()

proc exceedsLimit*(amount, limit: Money): bool =
  ## Ketat lebih besar: nominal **tepat** di plafon masih diterima.
  cmp(amount, limit) > 0
