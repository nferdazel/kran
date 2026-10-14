## Versi aplikasi (spec §21.4: dipakai `/healthz` dan log startup).
##
## Sumber: env `CBS_VERSION` (diisi saat deploy/systemd) bila ada; kalau tidak, konstanta
## `FallbackVersion`. Catatan: pengisian otomatis dari `git describe` saat build belum ada —
## sampai itu, naikkan `FallbackVersion` bersamaan dengan `version` di `cbs.nimble`.

import std/os

const FallbackVersion* = "0.1.0"

proc appVersion*(): string =
  let fromEnv = getEnv("CBS_VERSION")
  if fromEnv.len > 0: fromEnv else: FallbackVersion
